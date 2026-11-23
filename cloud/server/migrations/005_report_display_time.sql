CREATE OR REPLACE FUNCTION report_display_time(html text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT regexp_replace(
        regexp_replace(
            html,
            '(<body><h1>AI 渠道检测报告</h1><p>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})[.][0-9]+(</p>)',
            '\1\2'
        ),
        '(<section><h2>检测指标</h2><table>(?:<tr><th>[^<]*</th><td>[^<]*</td></tr>)*?<tr><th>请求时间</th><td>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})[.][0-9]+(</td>)',
        '\1\2'
    )
$$;
