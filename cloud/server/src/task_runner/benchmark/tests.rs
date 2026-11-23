use super::*;
use axum::{routing::post, Json, Router};

async fn response_fixture(body: String, streaming: bool) -> (anyhow::Result<Upload>, Value) {
    let app = Router::new().route(
        "/v1/responses",
        post(
            move |headers: axum::http::HeaderMap, Json(request): Json<Value>| async move {
                assert_eq!(headers["authorization"], "Bearer fixture-key");
                assert_eq!(request["model"], "gpt-fixture");
                assert_eq!(request["input"][0]["content"], "原样提示词\n");
                assert_eq!(request["stream"], true);
                assert_eq!(request["store"], false);
                assert_eq!(
                    request["reasoning"],
                    json!({"effort":"high", "summary":"auto"})
                );
                for key in ["messages", "reasoning_effort", "stream_options"] {
                    assert!(request.get(key).is_none());
                }
                // Split within JSON fields and UTF-8 code points, as real network chunks do.
                let chunks = body
                    .into_bytes()
                    .chunks(7)
                    .map(|chunk| Ok::<_, std::convert::Infallible>(chunk.to_vec()))
                    .collect::<Vec<_>>();
                (
                    [(
                        "content-type",
                        if streaming {
                            "text/event-stream"
                        } else {
                            "application/json"
                        },
                    )],
                    axum::body::Body::from_stream(futures_util::stream::iter(chunks)),
                )
            },
        ),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!(
        "http://{}/v1/chat/completions",
        listener.local_addr().unwrap()
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let (sender, receiver) = watch::channel(json!({}));
    let result = measure_with_client(
        &Client::builder().no_proxy().build().unwrap(),
        Api::Responses.endpoint(&base_url).unwrap(),
        "example.test".into(),
        Channel {
            base_url,
            credential: "fixture-key".into(),
            name: "fixture".into(),
            model: "gpt-fixture".into(),
            prompt: "原样提示词\n".into(),
            prompt_name: "fixture prompt".into(),
            provider: "openai-compatible".into(),
            effort: "high",
            started_at: Utc::now(),
            progress: Some(sender),
        },
        Instant::now(),
        Some(10.0),
    )
    .await;
    server.abort();
    let snapshot = receiver.borrow().clone();
    (result, snapshot)
}

fn completed_response() -> Value {
    json!({
        "object":"response", "status":"completed", "error": null,
        "output": [
            {"type":"reasoning", "summary":[{"type":"summary_text", "text":"先思考"}]},
            {"type":"message", "content":[{"type":"output_text", "text":"hello world"}]},
        ],
        "usage": {"input_tokens":20, "output_tokens":5, "total_tokens":25,
            "input_tokens_details":{"cached_tokens":12}, "cache_creation_input_tokens":4},
    })
}

#[tokio::test]
async fn measures_responses_stream_without_done_and_deduplicates_snapshots() {
    let events = [
        json!({"type":"response.created", "response":{"status":"in_progress"}}),
        json!({"type":"response.reasoning_summary_text.delta", "output_index":0, "summary_index":0, "delta":"先思考"}),
        json!({"type":"response.reasoning_summary_text.done", "output_index":0, "summary_index":0, "text":"先思考"}),
        json!({"type":"response.output_text.delta", "output_index":1, "content_index":0, "delta":"hello "}),
        json!({"type":"response.output_text.delta", "output_index":1, "content_index":0, "delta":"world"}),
        json!({"type":"response.output_text.done", "output_index":1, "content_index":0, "text":"hello world"}),
        json!({"type":"response.completed", "response":completed_response()}),
    ];
    let body = events
        .iter()
        .map(|event| {
            format!(
                "event: {}\r\ndata: {event}\r\n\r\n",
                event["type"].as_str().unwrap()
            )
        })
        .collect::<String>();
    let (result, live) = response_fixture(body, true).await;
    let report = result.unwrap();
    assert_eq!(live["output"], "hello world");
    assert_eq!(live["reasoning"], "先思考");
    assert_eq!(live["metrics"]["cache_read_tokens"], 12);
    assert!(live["diagnostics"]["endpoint"]
        .as_str()
        .unwrap()
        .ends_with("/v1/responses"));
    for (key, count) in [
        ("input_tokens", 20),
        ("output_tokens", 5),
        ("total_tokens", 25),
        ("cache_read_tokens", 12),
        ("cache_write_tokens", 4),
    ] {
        assert_eq!(report.metadata[key], count);
    }
    assert_eq!(report.metadata["cache_hit_rate"], 0.6);
    assert!(report.metadata["ttft_ms"].is_number());
    assert_eq!(report.data.output, "hello world");
    assert_eq!(report.data.activities[0].content, "先思考");
}

#[tokio::test]
async fn reads_a_json_responses_result() {
    let (result, live) = response_fixture(completed_response().to_string(), false).await;
    assert_eq!(result.unwrap().metadata["total_tokens"], 25);
    assert_eq!(live["output"], "hello world");
    assert_eq!(live["reasoning"], "先思考");
}

#[tokio::test]
async fn rejects_failed_incomplete_and_truncated_responses() {
    for terminal in [
        json!({"type":"response.failed", "response":{"status":"failed", "error":{"code":"server_error"}}}),
        json!({"type":"response.incomplete", "response":{"status":"incomplete", "incomplete_details":{"reason":"max_output_tokens"}}}),
        json!({"type":"error", "message":"stream failed"}),
    ] {
        let body = format!("data: {{\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}}\n\ndata: {terminal}\n\n");
        assert!(response_fixture(body, true).await.0.is_err());
    }
    let body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: [DONE]\n\n";
    assert!(response_fixture(body.into(), true).await.0.is_err());
}

#[test]
fn cache_usage_supports_gateway_aliases_and_preserves_explicit_zero() {
    for (usage, read, write) in [
        (json!({}), None, None),
        (
            json!({"prompt_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 23}}),
            Some(0),
            Some(23),
        ),
        (
            json!({"prompt_tokens_details": {"cached_tokens": null}, "prompt_cache_hit_tokens": "17", "prompt_cache_miss_tokens": 9}),
            Some(17),
            None,
        ),
        (
            json!({"input_tokens_details": {"cached_tokens": 13}, "cache_creation_input_tokens": 8}),
            Some(13),
            Some(8),
        ),
        (
            json!({"cache_read_input_tokens": 15, "cache_creation_input_tokens": 0}),
            Some(15),
            Some(0),
        ),
    ] {
        let mut metrics = Metrics::default();
        metrics
            .read_payload(&json!({"usage": usage}), None)
            .unwrap();
        metrics
            .read_payload(&json!({"usage": {"completion_tokens": 3}}), None)
            .unwrap();
        assert_eq!(metrics.cached, read);
        assert_eq!(metrics.cache_write, write);
    }
}

#[tokio::test]
async fn measures_a_streamed_chat_completion() {
    let app = Router::new().route("/v1/chat/completions", post(|Json(body): Json<Value>| async move {
        assert_eq!(body["model"], "fixture-model");
        assert_eq!(body["stream"], true);
        assert_eq!(body["stream_options"]["include_usage"], true);
        assert_eq!(body["reasoning_effort"], "high");
        assert_eq!(body["messages"][0]["content"], crate::services::tasks::PELICAN_PROMPT.trim());
        assert!(body.get("max_completion_tokens").is_none());
        ([ ("content-type", "text/event-stream") ], concat!(
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n",
            "data: {\"choices\":[{\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}\n\n",
            "data: [DONE]\n\n"
        ))
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let (progress, receiver) = watch::channel(json!({}));
    let report = measure_with_client(
        &Client::builder().no_proxy().build().unwrap(),
        Api::ChatCompletions.endpoint(&base_url).unwrap(),
        "example.test".into(),
        Channel {
            base_url,
            credential: String::new(),
            name: "fixture-channel".into(),
            model: "fixture-model".into(),
            prompt: crate::services::tasks::PELICAN_PROMPT.trim().into(),
            prompt_name: crate::services::tasks::PELICAN_NAME.into(),
            provider: "openai-compatible".into(),
            effort: "high",
            started_at: Utc::now(),
            progress: Some(progress),
        },
        Instant::now() - Duration::from_secs(2),
        Some(10.0),
    )
    .await
    .unwrap();
    server.abort();
    let snapshot = receiver.borrow().clone();
    assert_eq!(snapshot["output"], "hello");
    assert_eq!(snapshot["reasoning"], "思考");
    assert_eq!(snapshot["metrics"]["output_tokens"], 3);
    assert_eq!(snapshot["diagnostics"]["status"], 200);
    assert_eq!(snapshot["diagnostics"]["content_type"], "text/event-stream");
    assert_eq!(report.metadata["total_tokens"], 5);
    assert!(report.metadata["cache_read_tokens"].is_null());
    assert!(report.metadata["cache_write_tokens"].is_null());
    assert!(report.metadata["cache_hit_rate"].is_null());
    assert_eq!(report.metadata["reasoning_effort"], "high");
    assert_eq!(report.data.reasoning_effort, "high");
    assert!(report.metadata["ttft_ms"].is_number());
    let duration = report.metadata["duration_ms"].as_f64().unwrap();
    assert_eq!(
        report.metadata["tokens_per_second"].as_f64().unwrap(),
        3000.0 / duration
    );
    assert!(report.data.samples.iter().any(|sample| sample.tps == 3.0));
    assert_eq!(report.data.output, "hello");
}
