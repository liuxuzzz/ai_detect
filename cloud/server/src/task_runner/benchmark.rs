use super::{api::Api, progress::Progress, responses};
use crate::{models::Upload, services::upstream_http::public_client};
use anyhow::{anyhow, ensure, Context};
use chrono::{DateTime, Utc};
use reqwest::{Client, Url};
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tokio::{net::TcpStream, time::timeout};

const RESPONSE_LIMIT: usize = 2 * 1024 * 1024;
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(45);
const STREAM_IDLE_TIMEOUT: Duration = super::REQUEST_TIMEOUT;

pub(super) struct Channel<'a> {
    pub(super) base_url: String,
    pub(super) credential: String,
    pub(super) name: String,
    pub(super) model: String,
    pub(super) prompt: String,
    pub(super) prompt_name: String,
    pub(super) provider: String,
    pub(super) effort: &'a str,
    pub(super) started_at: DateTime<Utc>,
    pub(super) progress: Option<watch::Sender<Value>>,
}

pub(super) async fn measure(channel: Channel<'_>) -> anyhow::Result<Upload> {
    ensure!(
        matches!(
            channel.provider.as_str(),
            "openai" | "openai-compatible" | "custom"
        ),
        "当前任务执行器仅支持 OpenAI 兼容渠道"
    );
    ensure!(!channel.model.trim().is_empty(), "任务未配置模型");
    let url = Api::for_channel(&channel.base_url, &channel.model, &channel.provider)
        .endpoint(&channel.base_url)?;
    let host = url.host_str().context("渠道缺少域名")?.to_owned();
    let start = Instant::now();
    if let Some(progress) = &channel.progress {
        progress.send_replace(json!({"phase": "解析域名和建立连接"}));
    }
    let (client, addresses) = timeout(CONNECTION_TIMEOUT, public_client(&url))
        .await
        .context("渠道域名解析超时")??;
    let tcp_ms = timeout(CONNECTION_TIMEOUT, TcpStream::connect(addresses.as_slice()))
        .await
        .ok()
        .and_then(Result::ok)
        .map(|_| elapsed_ms(start));
    measure_with_client(&client, url, host, channel, start, tcp_ms).await
}

async fn measure_with_client(
    client: &Client,
    url: Url,
    host: String,
    channel: Channel<'_>,
    start: Instant,
    tcp_ms: Option<f64>,
) -> anyhow::Result<Upload> {
    let mut progress = Progress::new(channel.progress.clone(), start, url.to_string(), tcp_ms);
    progress.publish("等待上游响应", &Metrics::default(), true);
    let api = Api::for_channel(&channel.base_url, &channel.model, &channel.provider);
    let body = api.request(&channel.model, &channel.prompt, channel.effort);
    let mut request = client
        .post(url)
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .json(&body);
    if !channel.credential.is_empty() {
        request = request.bearer_auth(&channel.credential);
    }
    let response = timeout(super::REQUEST_TIMEOUT, request.send())
        .await
        .context("等待上游响应超时")?
        .map_err(|_| anyhow!("无法连接上游模型接口"))?;
    progress.response(&response);
    progress.publish("已收到响应头", &Metrics::default(), true);
    ensure!(
        response.status().is_success(),
        "上游模型接口返回 HTTP {}",
        response.status().as_u16()
    );
    let mut metrics = read_response(response, start, &mut progress, api).await?;
    metrics.tcp_ms = tcp_ms;
    Ok(super::report::record(host, channel, metrics))
}

#[derive(Default)]
pub(super) struct Metrics {
    pub(super) first_byte_ms: Option<f64>,
    pub(super) ttft_ms: Option<f64>,
    pub(super) duration_ms: f64,
    pub(super) tcp_ms: Option<f64>,
    pub(super) input: Option<u64>,
    pub(super) output: Option<u64>,
    pub(super) total: Option<u64>,
    pub(super) cached: Option<u64>,
    pub(super) cache_write: Option<u64>,
    pub(super) samples: Vec<u64>,
    pub(super) text: String,
    pub(super) reasoning: String,
    pub(super) events: Vec<Value>,
    has_content: bool,
    finished: bool,
    api: Api,
    responses: responses::Decoder,
}

impl Metrics {
    pub(super) fn measurements(&self, duration_ms: f64) -> Value {
        let duration_ms = duration_ms.max(0.001);
        let total = self.total.or_else(|| {
            self.input
                .zip(self.output)
                .map(|(a, b)| a.saturating_add(b))
        });
        let rpm = 60_000.0 / duration_ms;
        json!({
            "ttft_ms": self.ttft_ms, "duration_ms": duration_ms, "first_byte_ms": self.first_byte_ms,
            "tcp_connect_ms": self.tcp_ms, "input_tokens": self.input, "output_tokens": self.output,
            "total_tokens": total, "tokens_per_second": self.output.map(|output| output as f64 * 1000.0 / duration_ms),
            "average_latency_ms": self.ttft_ms.zip(self.output).filter(|(_, output)| *output > 0)
                .map(|(first, output)| (duration_ms - first).max(0.0) / output as f64),
            "rpm": rpm, "tpm": total.map(|total| total as f64 * rpm),
            "cache_read_tokens": self.cached, "cache_write_tokens": self.cache_write,
            "cache_hit_rate": self.input.zip(self.cached).filter(|(input, cached)| *input > 0 && cached <= input)
                .map(|(input, cached)| cached as f64 / input as f64), "retry_count": 0,
        })
    }

    fn read_payload(&mut self, payload: &Value, first_token_ms: Option<f64>) -> anyhow::Result<()> {
        ensure!(
            payload.get("error").is_none_or(Value::is_null),
            "上游模型返回错误"
        );
        let usage = if self.api == Api::Responses {
            let update = self.responses.read(payload)?;
            self.record(&update.reasoning, first_token_ms);
            self.reasoning.push_str(&update.reasoning);
            self.record(&update.text, first_token_ms);
            self.text.push_str(&update.text);
            self.finished |= update.completed;
            update.usage
        } else {
            self.read_chat_payload(payload, first_token_ms);
            payload.get("usage").cloned()
        };
        if let Some(usage) = usage {
            self.read_usage(&usage);
        }
        Ok(())
    }

    fn read_chat_payload(&mut self, payload: &Value, first_token_ms: Option<f64>) {
        if let Some(choices) = payload.get("choices").and_then(Value::as_array) {
            if let Some(choice) = choices.first() {
                let content = choice
                    .pointer("/delta/content")
                    .or_else(|| choice.pointer("/message/content"));
                let reasoning = choice
                    .pointer("/delta/reasoning_content")
                    .or_else(|| choice.pointer("/delta/reasoning"));
                if let Some(text) = reasoning.and_then(Value::as_str) {
                    self.record(text, first_token_ms);
                    self.reasoning.push_str(text);
                }
                if let Some(text) = content.and_then(Value::as_str) {
                    self.record(text, first_token_ms);
                    self.text.push_str(text);
                } else if let Some(parts) = content.and_then(Value::as_array) {
                    for text in parts
                        .iter()
                        .filter_map(|part| part.get("text").and_then(Value::as_str))
                    {
                        self.record(text, first_token_ms);
                        self.text.push_str(text);
                    }
                }
                self.finished |= choice
                    .get("finish_reason")
                    .is_some_and(|value| !value.is_null());
            }
        }
    }

    fn read_usage(&mut self, usage: &Value) {
        self.input = usage
            .get("prompt_tokens")
            .or_else(|| usage.get("input_tokens"))
            .and_then(Value::as_u64)
            .or(self.input);
        self.output = usage
            .get("completion_tokens")
            .or_else(|| usage.get("output_tokens"))
            .and_then(Value::as_u64)
            .or(self.output);
        self.total = usage
            .get("total_tokens")
            .and_then(Value::as_u64)
            .or(self.total);
        self.cached = cache_count(
            usage,
            &["cached_tokens", "cache_read_tokens"],
            &[
                "cache_read_input_tokens",
                "cache_read_tokens",
                "prompt_cache_hit_tokens",
                "cached_tokens",
            ],
        )
        .or(self.cached);
        self.cache_write = cache_count(
            usage,
            &["cache_creation_tokens", "cache_write_tokens"],
            &[
                "cache_creation_input_tokens",
                "cache_write_tokens",
                "cache_creation_tokens",
            ],
        )
        .or(self.cache_write);
    }

    fn record(&mut self, text: &str, elapsed_ms: Option<f64>) {
        if text.is_empty() {
            return;
        }
        self.has_content = true;
        if let Some(elapsed_ms) = elapsed_ms {
            self.ttft_ms.get_or_insert(elapsed_ms);
            let second = (elapsed_ms / 1000.0) as usize;
            self.samples.resize(self.samples.len().max(second + 1), 0);
            self.samples[second] += estimate_tokens(text);
        }
    }

    fn read_line(&mut self, line: &[u8], elapsed_ms: f64) -> anyhow::Result<bool> {
        let Some(data) = line.strip_prefix(b"data:") else {
            return Ok(false);
        };
        let data = data.trim_ascii();
        if data.is_empty() {
            return Ok(false);
        }
        if data == b"[DONE]" {
            return Ok(self.api == Api::ChatCompletions);
        }
        let payload =
            serde_json::from_slice(data).map_err(|_| anyhow!("上游返回无效的流式数据"))?;
        if self.events.len() == 40 {
            self.events.remove(0);
        }
        self.events
            .push(json!({"elapsed_ms": elapsed_ms, "payload": payload}));
        self.read_payload(&payload, Some(elapsed_ms))?;
        Ok(self.api == Api::Responses && self.finished)
    }
}

fn cache_count(usage: &Value, detail_keys: &[&str], usage_keys: &[&str]) -> Option<u64> {
    ["prompt_tokens_details", "input_tokens_details"]
        .into_iter()
        .filter_map(|key| usage.get(key))
        .flat_map(|details| detail_keys.iter().filter_map(|key| details.get(key)))
        .chain(usage_keys.iter().filter_map(|key| usage.get(key)))
        .find_map(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str()?.trim().parse().ok())
        })
}

async fn read_response(
    mut response: reqwest::Response,
    start: Instant,
    progress: &mut Progress,
    api: Api,
) -> anyhow::Result<Metrics> {
    let streaming = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/event-stream"));
    let mut metrics = Metrics {
        api,
        tcp_ms: progress.tcp_ms,
        ..Metrics::default()
    };
    let mut buffer = Vec::new();
    let mut received = 0;
    'response: while let Some(chunk) = timeout(STREAM_IDLE_TIMEOUT, response.chunk())
        .await
        .context("上游流式响应空闲超时")?
        .map_err(|_| anyhow!("读取上游响应失败"))?
    {
        let elapsed = elapsed_ms(start);
        if !chunk.is_empty() {
            metrics.first_byte_ms.get_or_insert(elapsed);
        }
        received += chunk.len();
        progress.received_bytes = received;
        progress.chunks += 1;
        ensure!(received <= RESPONSE_LIMIT, "上游响应超过大小限制");
        buffer.extend_from_slice(&chunk);
        if streaming {
            let mut consumed = 0;
            for line in buffer.split_inclusive(|byte| *byte == b'\n') {
                if !line.ends_with(b"\n") {
                    break;
                }
                consumed += line.len();
                if metrics.read_line(line, elapsed)? {
                    metrics.finished = true;
                    buffer.clear();
                    progress.publish("接收完成", &metrics, true);
                    break 'response;
                }
            }
            buffer.drain(..consumed);
        }
        progress.publish("接收模型输出", &metrics, false);
    }
    metrics.duration_ms = elapsed_ms(start);
    if streaming {
        metrics.finished |= metrics.read_line(&buffer, metrics.duration_ms)?;
        ensure!(metrics.finished, "上游返回的流提前结束");
        let final_second = (metrics.duration_ms / 1000.0) as usize;
        metrics.samples.resize(final_second + 1, 0);
    } else {
        let payload =
            serde_json::from_slice(&buffer).map_err(|_| anyhow!("上游未返回有效模型响应"))?;
        metrics.read_payload(&payload, None)?;
        ensure!(
            api != Api::Responses || metrics.finished,
            "上游 Responses 响应未完成"
        );
    }
    ensure!(metrics.has_content, "上游未返回模型内容");
    progress.publish("生成报告", &metrics, true);
    Ok(metrics)
}

fn elapsed_ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

fn estimate_tokens(text: &str) -> u64 {
    let mut count = 0;
    let mut in_word = false;
    for character in text.chars() {
        let is_word = character.is_ascii_alphanumeric() || character == '_';
        if (is_word && !in_word) || !character.is_ascii() {
            count += 1;
        }
        in_word = is_word;
    }
    count.max(1)
}

#[cfg(test)]
mod tests;
