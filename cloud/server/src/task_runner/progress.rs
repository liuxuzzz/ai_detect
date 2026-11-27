use super::benchmark::Metrics;
use reqwest::{header::HeaderMap, Request, Url};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use tokio::sync::watch;

const BODY_HEAD_LIMIT: usize = 128 * 1024;
const BODY_TAIL_LIMIT: usize = 384 * 1024;

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
    pub(super) response_incomplete: bool,
    credential: String,
    request: Option<Value>,
    response_headers: Option<Vec<Value>>,
    response_head: Vec<u8>,
    response_tail: VecDeque<u8>,
    finished: bool,
}

impl Progress {
    pub(super) fn new(
        sender: Option<watch::Sender<Value>>,
        start: Instant,
        mut endpoint: Url,
        tcp_ms: Option<f64>,
        credential: String,
    ) -> Self {
        if endpoint.query().is_some() {
            endpoint.set_query(Some("已隐藏"));
        }
        Self {
            sender,
            start,
            sent_at: None,
            endpoint: redact(endpoint.as_str(), &credential),
            status: None,
            content_type: String::new(),
            tcp_ms,
            received_bytes: 0,
            chunks: 0,
            response_incomplete: true,
            credential,
            request: None,
            response_headers: None,
            response_head: Vec::new(),
            response_tail: VecDeque::new(),
            finished: false,
        }
    }

    pub(super) fn request(&mut self, request: &Request) {
        self.request = Some(json!({
            "headers": headers(request.headers(), &self.credential),
            "body": redact(&String::from_utf8_lossy(request.body().and_then(|body| body.as_bytes()).unwrap_or_default()), &self.credential),
        }));
    }

    pub(super) fn response(&mut self, response: &reqwest::Response) {
        self.status = Some(response.status().as_u16());
        self.response_headers = Some(headers(response.headers(), &self.credential));
        self.content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .into();
    }

    pub(super) fn chunk(&mut self, chunk: &[u8]) {
        self.received_bytes += chunk.len();
        self.chunks += 1;
        if self.sender.is_none() {
            return;
        }
        let split = chunk.len().min(BODY_HEAD_LIMIT - self.response_head.len());
        self.response_head.extend_from_slice(&chunk[..split]);
        let rest = &chunk[split..];
        let rest = &rest[rest.len().saturating_sub(BODY_TAIL_LIMIT)..];
        let excess = (self.response_tail.len() + rest.len()).saturating_sub(BODY_TAIL_LIMIT);
        self.response_tail.drain(..excess);
        self.response_tail.extend(rest);
    }

    pub(super) fn complete(&mut self) {
        self.finished = true;
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
                "content_type": redact(&self.content_type, &self.credential), "received_bytes": self.received_bytes,
                "chunks": self.chunks, "tcp_connect_ms": self.tcp_ms,
            },
            "events": metrics.events,
        }));
    }
}

impl Drop for Progress {
    fn drop(&mut self) {
        let Some(sender) = self.sender.as_ref().filter(|_| !self.finished) else {
            return;
        };
        let omitted_bytes =
            self.received_bytes - self.response_head.len() - self.response_tail.len();
        let mut body = std::mem::take(&mut self.response_head);
        if omitted_bytes > 0 {
            body.extend_from_slice(
                format!("\n\n… 已省略中间 {omitted_bytes} 字节 …\n\n").as_bytes(),
            );
        }
        body.extend(self.response_tail.drain(..));
        sender.send_modify(|live| {
            let diagnostics = &mut live["diagnostics"];
            diagnostics["received_bytes"] = json!(self.received_bytes);
            diagnostics["chunks"] = json!(self.chunks);
            diagnostics["request"] = self.request.take().unwrap_or(Value::Null);
            if let Some(headers) = self.response_headers.take() {
                diagnostics["response"] = json!({
                    "headers": headers,
                    "body": redact(&String::from_utf8_lossy(&body), &self.credential).replace('\0', "\\x00"),
                    "incomplete": self.response_incomplete,
                });
            }
        });
    }
}

fn headers(map: &HeaderMap, credential: &str) -> Vec<Value> {
    map.iter()
        .map(|(name, value)| {
            let name = name.as_str();
            let sensitive = value.is_sensitive()
                || [
                    "authorization",
                    "cookie",
                    "token",
                    "secret",
                    "key",
                    "credential",
                ]
                .iter()
                .any(|part| name.contains(part));
            let value = if sensitive {
                "[已隐藏]".into()
            } else {
                redact(&String::from_utf8_lossy(value.as_bytes()), credential)
            };
            json!([name, value])
        })
        .collect()
}

fn redact(text: &str, credential: &str) -> String {
    if credential.is_empty() {
        return text.to_owned();
    }
    let escaped = Value::String(credential.into()).to_string();
    text.replace(credential, "[已隐藏]")
        .replace(&escaped[1..escaped.len() - 1], "[已隐藏]")
}
