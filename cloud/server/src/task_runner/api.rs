use crate::services::upstream_http::api_endpoint;
use reqwest::Url;
use serde_json::{json, Value};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Api {
    Responses,
    #[default]
    ChatCompletions,
}

impl Api {
    pub(super) fn for_channel(base: &str, model: &str, provider: &str) -> Self {
        let url = Url::parse(base.trim()).ok();
        let model = model.to_ascii_lowercase();
        let responses = provider == "openai"
            || url.as_ref().is_some_and(|url| {
                url.host_str() == Some("api.openai.com")
                    || url.path().trim_end_matches('/').ends_with("/responses")
            })
            || model.contains("gpt")
            || model.contains("openai")
            || ["o1", "o3", "o4"].iter().any(|prefix| {
                model
                    .rsplit('/')
                    .next()
                    .unwrap_or(&model)
                    .starts_with(prefix)
            });
        if responses {
            Self::Responses
        } else {
            Self::ChatCompletions
        }
    }

    pub(super) fn endpoint(self, base: &str) -> anyhow::Result<Url> {
        api_endpoint(
            base,
            match self {
                Self::Responses => "responses",
                Self::ChatCompletions => "chat/completions",
            },
        )
    }

    pub(super) fn request(self, model: &str, prompt: &str, effort: &str) -> Value {
        let mut body = match self {
            Self::Responses => json!({
                "model": model,
                "input": [{"role": "user", "content": prompt}],
                "stream": true,
                "store": false,
            }),
            Self::ChatCompletions => json!({
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "stream": true,
                "stream_options": {"include_usage": true},
            }),
        };
        if matches!(
            effort,
            "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
        ) {
            match self {
                Self::Responses => body["reasoning"] = json!({"effort": effort, "summary": "auto"}),
                Self::ChatCompletions => body["reasoning_effort"] = json!(effort),
            }
        }
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_responses_for_openai_and_explicit_responses_urls() {
        for (base, model, provider, responses) in [
            (
                "https://example.test/v1",
                "gpt-5",
                "openai-compatible",
                true,
            ),
            ("https://example.test/v1", "openai/gpt-5", "custom", true),
            ("https://example.test/v1", "openai/o3", "custom", true),
            ("https://api.openai.com/v1", "alias", "custom", true),
            (
                "https://example.test/v1/responses/",
                "alias",
                "custom",
                true,
            ),
            ("https://example.test/v1", "alias", "openai", true),
            (
                "https://example.test/v1",
                "deepseek-reasoner",
                "openai-compatible",
                false,
            ),
            (
                "https://example.test/v1",
                "claude-sonnet-4",
                "custom",
                false,
            ),
        ] {
            assert_eq!(
                Api::for_channel(base, model, provider) == Api::Responses,
                responses
            );
        }
    }
}
