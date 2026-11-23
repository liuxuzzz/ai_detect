use anyhow::{bail, ensure};
use serde_json::Value;
use std::collections::BTreeMap;

/// Tracks individual output parts so final snapshots do not repeat streamed deltas.
#[derive(Default)]
pub(super) struct Decoder {
    parts: BTreeMap<(u64, u64, &'static str), String>,
}

#[derive(Default)]
pub(super) struct Update {
    pub(super) text: String,
    pub(super) reasoning: String,
    pub(super) usage: Option<Value>,
    pub(super) completed: bool,
}

impl Decoder {
    pub(super) fn read(&mut self, event: &Value) -> anyhow::Result<Update> {
        let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
        let response = event.get("response").unwrap_or(event);
        ensure!(
            response.get("error").is_none_or(Value::is_null),
            "上游 Responses 请求失败"
        );
        let status = response.get("status").and_then(Value::as_str);
        if kind == "error" || kind == "response.failed" || status == Some("failed") {
            bail!("上游 Responses 请求失败");
        }
        if kind == "response.incomplete" || status == Some("incomplete") {
            bail!("上游 Responses 响应未完成");
        }
        ensure!(status != Some("cancelled"), "上游 Responses 请求已取消");
        let mut update = Update {
            usage: response
                .get("usage")
                .filter(|usage| usage.is_object())
                .cloned(),
            completed: kind == "response.completed" || status == Some("completed"),
            ..Update::default()
        };
        if update.completed {
            ensure!(
                status.is_none_or(|status| status == "completed"),
                "上游 Responses 状态异常"
            );
        }
        let output = index(event, "output_index");
        let content = index(event, "content_index");
        match kind {
            "response.output_text.delta" | "response.refusal.delta" => {
                self.part(
                    output,
                    content,
                    "text",
                    event.get("delta"),
                    true,
                    &mut update,
                );
            }
            "response.output_text.done" => {
                self.part(
                    output,
                    content,
                    "text",
                    event.get("text"),
                    false,
                    &mut update,
                );
            }
            "response.refusal.done" => {
                self.part(
                    output,
                    content,
                    "text",
                    event.get("refusal"),
                    false,
                    &mut update,
                );
            }
            "response.reasoning_summary_text.delta" | "response.reasoning_summary_text.done" => {
                self.part(
                    output,
                    index(event, "summary_index"),
                    "summary",
                    event.get(if kind.ends_with(".delta") {
                        "delta"
                    } else {
                        "text"
                    }),
                    kind.ends_with(".delta"),
                    &mut update,
                );
            }
            "response.reasoning_text.delta" | "response.reasoning_text.done" => {
                self.part(
                    output,
                    content,
                    "reasoning",
                    event.get(if kind.ends_with(".delta") {
                        "delta"
                    } else {
                        "text"
                    }),
                    kind.ends_with(".delta"),
                    &mut update,
                );
            }
            "response.output_item.done" => {
                if let Some(item) = event.get("item") {
                    self.item(output, item, &mut update);
                }
            }
            "response.content_part.done" => {
                if let Some(part) = event.get("part") {
                    self.content(output, content, part, &mut update);
                }
            }
            _ => {}
        }
        if let Some(items) = response.get("output").and_then(Value::as_array) {
            for (index, item) in items.iter().enumerate() {
                self.item(index as u64, item, &mut update);
            }
        }
        Ok(update)
    }

    fn item(&mut self, output: u64, item: &Value, update: &mut Update) {
        if let Some(parts) = item.get("content").and_then(Value::as_array) {
            for (index, part) in parts.iter().enumerate() {
                self.content(output, index as u64, part, update);
            }
        }
        if let Some(parts) = item.get("summary").and_then(Value::as_array) {
            for (index, part) in parts.iter().enumerate() {
                self.part(
                    output,
                    index as u64,
                    "summary",
                    part.get("text"),
                    false,
                    update,
                );
            }
        }
    }

    fn content(&mut self, output: u64, index: u64, part: &Value, update: &mut Update) {
        match part.get("type").and_then(Value::as_str) {
            Some("output_text") => {
                self.part(output, index, "text", part.get("text"), false, update)
            }
            Some("refusal") => self.part(output, index, "text", part.get("refusal"), false, update),
            Some("reasoning_text") => {
                self.part(output, index, "reasoning", part.get("text"), false, update)
            }
            _ => {}
        }
    }

    fn part(
        &mut self,
        output: u64,
        index: u64,
        kind: &'static str,
        value: Option<&Value>,
        delta: bool,
        update: &mut Update,
    ) {
        let Some(text) = value.and_then(Value::as_str) else {
            return;
        };
        let current = self.parts.entry((output, index, kind)).or_default();
        let suffix = if delta {
            text
        } else {
            text.strip_prefix(current.as_str()).unwrap_or("")
        };
        if kind == "text" {
            update.text.push_str(suffix);
        } else {
            update.reasoning.push_str(suffix);
        }
        current.push_str(suffix);
    }
}

fn index(event: &Value, key: &str) -> u64 {
    event.get(key).and_then(Value::as_u64).unwrap_or(0)
}
