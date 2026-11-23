//! One-time recovery of report data from documents produced by older clients.
//! Documents stay in the legacy column for rollback and are never served.
use crate::models::{ReportActivity, ReportData, ReportSample};
use scraper::{Html, Selector};
use serde_json::{json, Map, Value};
use tokio_postgres::Client;

pub(crate) async fn migrate(client: &Client) -> anyhow::Result<()> {
    loop {
        let rows = client.query(
            "SELECT id,COALESCE(html,''),metadata FROM reports WHERE data IS NULL ORDER BY id LIMIT 100", &[]
        ).await?;
        if rows.is_empty() {
            break;
        }
        for row in rows {
            let html: String = row.get(1);
            let metadata: Value = row.get(2);
            let (data, metadata) = recover(&html, metadata);
            client
                .execute(
                    "UPDATE reports SET data=$2,metadata=$3 WHERE id=$1 AND data IS NULL",
                    &[
                        &row.get::<_, i64>(0),
                        &serde_json::to_value(data)?,
                        &metadata,
                    ],
                )
                .await?;
        }
    }
    Ok(())
}

fn selector(value: &str) -> Selector {
    Selector::parse(value).expect("constant legacy selector")
}

fn recover(html: &str, metadata: Value) -> (ReportData, Value) {
    let document = Html::parse_document(html);
    let mut data = ReportData {
        source: "legacy".into(),
        ..ReportData::default()
    };
    let mut metadata = metadata.as_object().cloned().unwrap_or_default();
    let summary = document.select(&selector("table")).next();
    if let Some(table) = summary {
        for row in table.select(&selector("tr")) {
            let label = row
                .select(&selector("th"))
                .next()
                .map(|v| v.text().collect::<String>());
            let value = row
                .select(&selector("td"))
                .next()
                .map(|v| v.text().collect::<String>())
                .unwrap_or_default();
            match label.as_deref() {
                Some("渠道") => data.upstream_name = value,
                Some("请求时间") => data.started_at = value,
                Some("推理强度") => data.reasoning_effort = value,
                Some("状态") if value.starts_with("失败") => data.error = value,
                _ => {}
            }
        }
        let metrics = recover_metrics(&json!(metadata), &table.inner_html());
        metadata.extend(metrics);
    }
    data.samples = document
        .select(&selector(".sample-point"))
        .filter_map(|point| {
            // Early desktop documents stored only their tooltip values.
            // Prefer exact attributes whenever the newer format provides them.
            let title = point
                .select(&selector("title"))
                .next()
                .map(|element| element.text().collect::<String>())
                .unwrap_or_default();
            let displayed = title.split_once(" s · ");
            let seconds: f64 = point
                .value()
                .attr("data-seconds")
                .or_else(|| displayed.map(|(seconds, _)| seconds))?
                .replace(',', "")
                .parse()
                .ok()?;
            let tps: f64 = point
                .value()
                .attr("data-tps")
                .or_else(|| displayed.and_then(|(_, tps)| tps.strip_suffix(" token/s")))?
                .replace(',', "")
                .parse()
                .ok()?;
            (seconds.is_finite() && tps.is_finite() && seconds >= 0.0 && tps >= 0.0)
                .then_some(ReportSample { seconds, tps })
        })
        .collect();
    // Cloud documents retained raw output in <pre>; desktop previews used srcdoc.
    data.output = document
        .select(&selector(".rendered-output pre, section:last-of-type pre"))
        .map(|element| element.text().collect::<String>())
        .collect::<Vec<_>>()
        .join("\n");
    if data.output.is_empty() {
        if let Some(source) = document
            .select(&selector("iframe[srcdoc]"))
            .next()
            .and_then(|frame| frame.value().attr("srcdoc"))
        {
            data.activities.push(ReportActivity {
                kind: "html_artifact".into(),
                content: source.into(),
                name: "旧报告恢复的模型输出".into(),
                attempt: 1,
                ..ReportActivity::default()
            });
        }
    }
    (data, json!(metadata))
}

fn recover_metrics(metadata: &Value, summary: &str) -> Map<String, Value> {
    [
        ("ttft_ms", "首 Token 延时", " s", 1000.0),
        ("tokens_per_second", "平均吞吐", " token/s", 1.0),
        ("total_tokens", "总 Token", "", 1.0),
        ("input_tokens", "输入 Token", "", 1.0),
        ("output_tokens", "输出 Token", "", 1.0),
        ("rpm", "平均 RPM", " req/min", 1.0),
        ("tpm", "平均 TPM", " token/min", 1.0),
        ("first_byte_ms", "首字节延时", " s", 1000.0),
        ("average_latency_ms", "平均 Token 延时", " s/token", 1000.0),
        ("tcp_connect_ms", "TCP 连接成功延时", " ms", 1.0),
        ("cache_read_tokens", "缓存读取", "", 1.0),
        ("cache_write_tokens", "缓存写入", "", 1.0),
        ("cache_hit_rate", "缓存命中率", "%", 0.01),
        ("duration_ms", "总耗时", " s", 1000.0),
        ("retry_count", "故障/重试次数", "", 1.0),
    ]
    .into_iter()
    .filter_map(|(key, label, unit, scale)| {
        let valid = |number: &f64| {
            number.is_finite()
                && *number >= 0.0
                && (!matches!(key, "ttft_ms" | "first_byte_ms") || *number > 0.0)
        };
        let value = super::reports::metric_number(metadata, key)
            .filter(valid)
            .or_else(|| {
                let escaped_label = label.replace('/', "&#47;");
                let (_, rest) = summary
                    .split_once(&format!("<th>{label}</th><td>"))
                    .or_else(|| summary.split_once(&format!("<th>{escaped_label}</th><td>")))?;
                let (value, _) = rest.split_once("</td>")?;
                let value = value.replace("&#47;", "/");
                value
                    .strip_suffix(unit)?
                    .replace(',', "")
                    .parse::<f64>()
                    .ok()
                    .map(|number| number * scale)
                    .filter(valid)
            })?;
        Some((key.into(), json!(value)))
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovers_metrics_samples_and_escaped_output_without_returning_a_document() {
        let html = concat!(
            "<section><table><tr><th>渠道</th><td>原渠道</td></tr>",
            "<tr><th>首 Token 延时</th><td>1.25 s</td></tr></table></section>",
            "<svg><circle class='sample-point' data-seconds='0' data-tps='0'></circle></svg>",
            "<section><pre>&lt;p&gt;中文 &amp; output&lt;/p&gt;</pre></section>"
        );
        let (data, metrics) = recover(html, json!({"cache_write_tokens": 0}));
        assert_eq!(data.source, "legacy");
        assert_eq!(data.output, "<p>中文 & output</p>");
        assert_eq!(data.upstream_name, "原渠道");
        assert_eq!(data.samples.len(), 1);
        assert_eq!(data.samples[0].tps, 0.0);
        assert_eq!(metrics["ttft_ms"], 1250.0);
        assert_eq!(metrics["cache_write_tokens"], 0.0);
        assert!(metrics.get("cache_read_tokens").is_none());
    }

    #[test]
    fn recovers_early_desktop_tooltips_and_prefers_exact_samples() {
        let html = concat!(
            "<svg><circle class='sample-point'><title>0.00 s · 0 token/s</title></circle>",
            "<circle class='sample-point'><title>1.25 s · 1,234 token/s</title></circle>",
            "<circle class='sample-point' data-seconds='2.345' data-tps='8.765'>",
            "<title>2.35 s · 9 token/s</title></circle></svg>"
        );
        let (data, _) = recover(html, json!({}));
        assert_eq!(data.samples.len(), 3);
        assert_eq!(data.samples[0].tps, 0.0);
        assert_eq!(data.samples[1].seconds, 1.25);
        assert_eq!(data.samples[1].tps, 1234.0);
        assert_eq!(data.samples[2].seconds, 2.345);
        assert_eq!(data.samples[2].tps, 8.765);
    }
}
