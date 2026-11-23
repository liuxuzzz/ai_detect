use super::benchmark::Metrics;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::watch;

pub(super) struct Progress {
    sender: Option<watch::Sender<Value>>,
    start: Instant,
    sent_at: Option<Instant>,
    endpoint: String,
    status: Option<u16>,
    content_type: String,
    pub(super) tcp_ms: Option<f64>,
    pub(super) received_bytes: usize,
    pub(super) chunks: usize,
}

impl Progress {
    pub(super) fn new(
        sender: Option<watch::Sender<Value>>,
        start: Instant,
        endpoint: String,
        tcp_ms: Option<f64>,
    ) -> Self {
        Self {
            sender,
            start,
            sent_at: None,
            endpoint,
            status: None,
            content_type: String::new(),
            tcp_ms,
            received_bytes: 0,
            chunks: 0,
        }
    }

    pub(super) fn response(&mut self, response: &reqwest::Response) {
        self.status = Some(response.status().as_u16());
        self.content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .into();
    }

    pub(super) fn publish(&mut self, phase: &str, metrics: &Metrics, force: bool) {
        let Some(sender) = &self.sender else {
            return;
        };
        if !force
            && self
                .sent_at
                .is_some_and(|sent| sent.elapsed() < Duration::from_millis(200))
        {
            return;
        }
        self.sent_at = Some(Instant::now());
        let elapsed_ms = self.start.elapsed().as_secs_f64() * 1000.0;
        let estimated: u64 = metrics.samples.iter().sum();
        sender.send_replace(json!({
            "phase": phase, "updated_at": chrono::Utc::now(),
            "output": metrics.text, "reasoning": metrics.reasoning,
            "metrics": metrics.measurements(elapsed_ms), "samples": metrics.samples,
            "estimated_output_tokens": estimated,
            "estimated_tokens_per_second": if elapsed_ms > 0.0 { estimated as f64 * 1000.0 / elapsed_ms } else { 0.0 },
            "diagnostics": {
                "method": "POST", "endpoint": self.endpoint, "status": self.status,
                "content_type": self.content_type, "received_bytes": self.received_bytes,
                "chunks": self.chunks, "tcp_connect_ms": self.tcp_ms,
            },
            "events": metrics.events,
        }));
    }
}
