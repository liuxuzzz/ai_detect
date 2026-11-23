use super::benchmark::{Channel, Metrics};
use crate::models::{ReportActivity, ReportData, ReportSample, Upload};
use serde_json::json;

pub(super) fn record(host: String, channel: Channel<'_>, metrics: Metrics) -> Upload {
    let mut metadata = metrics.measurements(metrics.duration_ms);
    metadata["source"] = json!("cloud");
    metadata["status"] = json!("success");
    metadata["reasoning_effort"] = json!(channel.effort);
    let activities = if metrics.reasoning.is_empty() {
        Vec::new()
    } else {
        vec![ReportActivity {
            kind: "thinking".into(),
            content: metrics.reasoning,
            attempt: 1,
            ..ReportActivity::default()
        }]
    };
    Upload {
        api_domain: host,
        model: channel.model,
        prompt_name: channel.prompt_name,
        metadata,
        data: ReportData {
            source: "cloud".into(),
            upstream_name: channel.name,
            prompt: channel.prompt,
            started_at: channel.started_at.to_rfc3339(),
            output: metrics.text,
            reasoning_effort: channel.effort.into(),
            samples: metrics
                .samples
                .into_iter()
                .enumerate()
                .map(|(second, tokens)| ReportSample {
                    seconds: second as f64,
                    tps: tokens as f64,
                })
                .collect(),
            activities,
            ..ReportData::default()
        },
    }
}
