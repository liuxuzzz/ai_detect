"""Run against an isolated cloud stack seeded with public_rankings_fixture.sql."""
import json
import math
import os
from urllib.parse import urlencode
from urllib.request import urlopen


base = os.environ.get('CLOUD_URL', 'http://127.0.0.1:18080').rstrip('/')


def rankings(**query):
    url = f'{base}/api/public/rankings?{urlencode(query)}'
    with urlopen(url, timeout=15) as response:
        return json.load(response)


for period in ('latest', 'today', 'week', 'month'):
    rows = []
    for index, expected in enumerate((20, 20, 20, 20, 20, 15)):
        page = rankings(period=period, search='PAGE-FIXTURE', page=index)
        assert len(page['items']) == expected, (period, index, page)
        assert page['has_more'] is (index < 5), (period, index)
        rows.extend(page['items'])
    assert len({item['id'] for item in rows}) == 115
    expected_order = [f'page-fixture-{i}' for i in range(115, 0, -1)]
    if period != 'latest':
        expected_order.remove('page-fixture-112')
        expected_order.insert(0, 'page-fixture-112')
    assert [row['slug'] for row in rows] == expected_order, period

    ordered = rankings(period=period, search='sort-fixture')['items']
    expected = (
        ['unrated-new', 'low-score', 'high-score-new', 'high-score-old', 'unrated-old']
        if period == 'latest' else
        ['high-score-new', 'high-score-old', 'low-score', 'unrated-new', 'unrated-old']
    )
    assert [row['slug'] for row in ordered] == expected, (period, ordered)
    by_slug = {row['slug']: row for row in ordered}
    assert by_slug['high-score-new']['average_score'] == 5
    assert by_slug['high-score-old']['average_score'] == 5
    assert by_slug['low-score']['average_score'] == 1
    assert by_slug['unrated-new']['average_score'] is None
    assert by_slug['unrated-old']['average_score'] is None

for facet, remainder in (('api_domain', 7), ('model', 6)):
    first = rankings(facet=facet, search='page-fixture')
    second = rankings(facet=facet, search='page-fixture', page=1)
    assert len(first['items']) == 100 and first['has_more']
    assert len(second['items']) == remainder and not second['has_more']
    assert len({tag['name'] for tag in first['items'] + second['items']}) == 100 + remainder

assert rankings(facet='model', search='page-fixture')['items'][0] == {'name': 'shared-model', 'count': 10}
assert rankings(facet='model', api_domain='shared-a.example.test')['items'] == [{'name': 'shared-model', 'count': 7}]
assert rankings(facet='api_domain', model='shared-model')['items'] == [
    {'name': 'shared-a.example.test', 'count': 7}, {'name': 'shared-b.example.test', 'count': 3},
]
assert len(rankings(api_domain='shared-a.example.test', model='shared-model')['items']) == 7
assert not rankings(api_domain='shared-a.example.test', model='model-1')['items']
assert rankings(period='latest', search='old-fixture')['items']
assert not rankings(period='month', search='old-fixture')['items']

by_slug = {row['slug']: row for row in rankings(search='legacy')['items']}
legacy = by_slug['legacy-metrics']
assert legacy['ttft_ms'] == 14080 and legacy['duration_ms'] == 319371
assert math.isclose(legacy['tokens_per_second'], 13106 * 1000 / 319371)
for slug in ('missing-metrics', 'malformed-metrics'):
    assert by_slug[slug]['ttft_ms'] is None and by_slug[slug]['tokens_per_second'] is None

print('PASS: score ordering, newest-first ties and unrated tests, latest chronology, stable pagination, facets, and legacy metrics')
