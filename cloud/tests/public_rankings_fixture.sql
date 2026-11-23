\set ON_ERROR_STOP on

INSERT INTO users(email, password_hash) VALUES ('rankings-fixture@example.test', 'not-a-password');

INSERT INTO reports(owner_id, slug, html, api_domain, model, prompt_name, metadata)
SELECT owner.id, 'page-fixture-' || sample, '<p>Fixture</p>',
    CASE WHEN sample <= 105 THEN 'vendor-' || sample || '.example.test'
         WHEN sample <= 112 THEN 'shared-a.example.test' ELSE 'shared-b.example.test' END,
    CASE WHEN sample <= 105 THEN 'model-' || sample ELSE 'shared-model' END,
    'page-fixture', jsonb_build_object('ttft_ms', sample, 'tokens_per_second', 10, 'duration_ms', 2000, 'total_tokens', 200)
FROM users owner CROSS JOIN generate_series(1, 115) sample
WHERE owner.email = 'rankings-fixture@example.test';

-- Newer rows deliberately have worse performance metrics, so rankings must
-- use score and completion time rather than latency, token count or duration.
INSERT INTO reports(owner_id, slug, html, api_domain, model, prompt_name, metadata, created_at)
SELECT owner.id, slug, '<p>Sort fixture</p>', 'sort.example.test', 'sort-model', 'sort-fixture',
    jsonb_build_object('ttft_ms', ordinal * 1000, 'total_tokens', ordinal * 100,
                      'duration_ms', ordinal * 10000),
    date_trunc('day', now(), 'Asia/Shanghai') + ordinal * interval '1 second'
FROM users owner CROSS JOIN (VALUES
    ('unrated-old', 1), ('high-score-old', 2), ('high-score-new', 3),
    ('low-score', 4), ('unrated-new', 5)
) fixture(slug, ordinal)
WHERE owner.email = 'rankings-fixture@example.test';

INSERT INTO report_ratings(report_id, user_id, score)
SELECT id, owner_id, CASE WHEN slug = 'low-score' THEN 1 ELSE 5 END
FROM reports WHERE slug IN ('high-score-old', 'high-score-new', 'low-score');

INSERT INTO report_ratings(report_id, user_id, score)
SELECT id, owner_id, 5 FROM reports WHERE slug = 'page-fixture-112';

INSERT INTO reports(owner_id, slug, html, api_domain, model, prompt_name, metadata, created_at, deleted_at)
SELECT owner.id, slug, html, 'legacy.example.test', 'legacy-model', prompt, metadata, created, deleted
FROM users owner CROSS JOIN (VALUES
    ('legacy-metrics', '<h2>检测指标</h2><table><tr><th>首 Token 延时</th><td>14.08 s</td></tr><tr><th>输出 Token</th><td>13,106</td></tr></table>', 'legacy', '{"ttft_ms":0,"duration_ms":319371,"total_tokens":24319}'::jsonb, now(), NULL::timestamptz),
    ('missing-metrics', '<p>Unavailable</p>', 'legacy', '{"ttft_ms":0,"tokens_per_second":0}'::jsonb, now(), NULL),
    ('malformed-metrics', '<h2>检测指标</h2><table><tr><th>首 Token 延时</th><td>., s</td></tr></table>', 'legacy', '{}'::jsonb, now(), NULL),
    ('old-fixture', '<p>Old</p>', 'old-fixture', '{}'::jsonb, now() - interval '40 days', NULL),
    ('failed-fixture', '<p>Failed</p>', 'page-fixture', '{"status":"error"}'::jsonb, now(), NULL),
    ('hidden-fixture', '<p>Hidden</p>', 'page-fixture', '{}'::jsonb, now(), now())
) fixture(slug, html, prompt, metadata, created, deleted)
WHERE owner.email = 'rankings-fixture@example.test';
