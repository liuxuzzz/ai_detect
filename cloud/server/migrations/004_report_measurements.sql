CREATE OR REPLACE FUNCTION report_metric(metadata jsonb, metric text)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN jsonb_typeof(metadata -> metric) = 'number'
                AND (metadata -> metric) > '0'::jsonb
                AND (metadata -> metric) < '1e30'::jsonb
                THEN (metadata ->> metric)::double precision END
$$;

CREATE OR REPLACE FUNCTION report_measurements(html text, metadata jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    result jsonb := CASE WHEN jsonb_typeof(metadata) = 'object' THEN metadata ELSE '{}'::jsonb END;
    summary text;
    measured double precision;
    output_count double precision;
    duration double precision;
BEGIN
    IF report_metric(result, 'ttft_ms') IS NOT NULL
       AND report_metric(result, 'tokens_per_second') IS NOT NULL THEN
        RETURN result;
    END IF;

    summary := split_part(split_part(html, '<h2>检测指标</h2><table>', 2), '</table>', 1);
    IF summary = '' THEN RETURN result; END IF;

    IF report_metric(result, 'ttft_ms') IS NULL THEN
        measured := replace(substring(summary FROM '<th>首 Token 延时</th><td>((?:[0-9]{1,3}(?:,[0-9]{3}){1,5}|[0-9]{1,18})(?:\.[0-9]{1,9})?) s</td>'), ',', '')::double precision;
        IF measured > 0 THEN
            result := result || jsonb_build_object('ttft_ms', round(measured * 1000));
        END IF;
    END IF;

    IF report_metric(result, 'tokens_per_second') IS NULL THEN
        duration := report_metric(result, 'duration_ms');
        output_count := COALESCE(report_metric(result, 'output_tokens'),
            replace(substring(summary FROM '<th>输出 Token</th><td>([0-9]{1,3}(?:,[0-9]{3}){1,5}|[0-9]{1,18})</td>'), ',', '')::double precision);
        measured := CASE WHEN duration > 0 AND output_count > 0 THEN output_count * 1000 / duration
            ELSE replace(substring(summary FROM '<th>平均吞吐</th><td>((?:[0-9]{1,3}(?:,[0-9]{3}){1,5}|[0-9]{1,18})(?:\.[0-9]{1,9})?) token/s</td>'), ',', '')::double precision END;
        IF measured > 0 THEN
            result := result || jsonb_build_object('tokens_per_second', measured);
        END IF;
    END IF;
    RETURN result;
END;
$$;

WITH measurements AS MATERIALIZED (
    SELECT id, report_measurements(html, metadata) AS metadata
    FROM reports
    WHERE report_metric(metadata, 'ttft_ms') IS NULL
       OR report_metric(metadata, 'tokens_per_second') IS NULL
)
UPDATE reports AS report SET metadata = measurements.metadata
FROM measurements
WHERE report.id = measurements.id AND report.metadata IS DISTINCT FROM measurements.metadata;
