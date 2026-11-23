"""Exercise direct API access against disposable containers, never production."""
import json
import os
import re
import subprocess
from urllib.error import HTTPError
from urllib.request import Request, urlopen


api = web = os.environ.get('CLOUD_URL', 'http://127.0.0.1:16600').rstrip('/')
postgres = os.environ['FIXTURE_POSTGRES']


def request(path, body=None, headers=None, method=None, expected=200):
    req = Request(api + path, headers={'Origin': web, **(headers or {})},
                  data=json.dumps(body).encode() if body is not None else None,
                  method=method or ('POST' if body is not None else 'GET'))
    if body is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        response = urlopen(req, timeout=15)
    except HTTPError as error:
        response = error
    with response:
        data = response.read().decode()
        assert response.status == expected, (path, response.status, data)
        assert response.headers['Access-Control-Allow-Origin'] in ('*', web), path
        return data, response.headers


def json_request(*args, **kwargs):
    data, _ = request(*args, **kwargs)
    return json.loads(data)


assert json_request('/health') == {'status': 'ok'}
for path, method, headers in (
    ('/api/auth/login', 'POST', 'content-type'),
    ('/api/reports/upload', 'POST', 'content-type,x-client-key'),
    ('/api/tasks/1/events', 'GET', 'authorization'),
):
    _, result = request(path, method='OPTIONS', headers={
        'Access-Control-Request-Method': method,
        'Access-Control-Request-Headers': headers,
    })
    assert result['Access-Control-Allow-Methods'] is not None
    allowed = {name.strip().lower() for name in result['Access-Control-Allow-Headers'].split(',')}
    assert set(headers.split(',')).issubset(allowed)

json_request('/api/auth/register', {'email': 'direct-admin@example.test', 'password': 'isolated-direct-api-password'})
session = json_request('/api/auth/login', {
    'email': 'direct-admin@example.test', 'password': 'isolated-direct-api-password',
})
auth = {'Authorization': 'Bearer ' + session['token']}
assert json_request('/api/auth/me', headers=auth)['is_admin']
key = json_request('/api/auth/client-keys', headers=auth, method='POST')['key']
report = json_request('/api/reports/upload', headers={'X-Client-Key': key}, body={
    'data': {'version': 1, 'output': 'Direct upload fixture', 'samples': [{'seconds': 0.25, 'tps': 8}], 'activities': [], 'retries': []},
    'api_domain': 'direct.example.test', 'model': 'direct-model', 'prompt_name': 'direct-fixture',
    'metadata': {'status': 'success', 'ttft_ms': 20, 'total_tokens': 3, 'duration_ms': 100},
})
assert report['owner_url'] == web + '/r/' + report['slug']
assert json_request('/api/public/reports/' + report['slug'])['data']['output'] == 'Direct upload fixture'
share = json_request(f'/api/reports/{report["id"]}/share', headers=auth, body={
    'expires_at': None, 'allowed_domain': None, 'allow_any_iframe': False,
})
assert share['url'] == web + '/share/' + share['token']
assert json_request('/api/public/shares/' + share['token'])['report']['data']['output'] == 'Direct upload fixture'
for score in (2, 5):
    result = json_request(f'/api/reports/{report["id"]}/rating', body={'score': score}, headers=auth)
    assert result['rating_count'] == 1
assert json_request(f'/api/reports/{report["id"]}/details', headers=auth)['my_score'] == 5
stored = subprocess.check_output([
    'docker', 'exec', postgres, 'psql', '-U', 'fixture', '-d', 'fixture', '-Atq',
    '-v', 'ON_ERROR_STOP=1', '-c', f"SELECT html IS NULL AND data->>'version'='1' FROM reports WHERE id={int(report['id'])}",
], text=True).strip()
assert stored == 't'
for path in ('/api/not-a-route', '/api/reports/not/a/route'):
    assert json_request(path, expected=404)['error']
for url in (report['owner_url'], share['url']):
    with urlopen(url, timeout=15) as response:
        page = response.read().decode()
        assert '<div id="app">' in page and 'Direct upload fixture' not in page

assert json_request('/api/public/rankings?search=direct-fixture')['items'][0]['slug'] == report['slug']

# Completed snapshots avoid sending any request to an external model provider.
owner = int(session['user']['id'])
task_id = subprocess.check_output([
    'docker', 'exec', postgres, 'psql', '-U', 'fixture', '-d', 'fixture', '-Atq',
    '-v', 'ON_ERROR_STOP=1', '-c',
    f"INSERT INTO async_tasks(owner_id,status,scheduled_for,model,live) VALUES "
    f"({owner},'completed',now(),'direct-model','{{\"output\":\"direct-sse-fixture\"}}') RETURNING id",
], text=True).strip()
stream, headers = request(f'/api/tasks/{int(task_id)}/events', headers={
    **auth, 'Accept': 'text/event-stream',
})
assert headers['Content-Type'].startswith('text/event-stream')
assert 'event: snapshot' in stream and 'direct-sse-fixture' in stream

assert json_request('/health') == {'status': 'ok'}
print('PASS: same-origin pages, JSON API, PostgreSQL storage, authentication, upload, report/share pages, editable rating and SSE')
