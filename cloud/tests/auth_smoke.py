"""Read-only login and role checks using an existing administrator account."""
import json
import os
import urllib.error
import urllib.request


base = os.environ.get('CLOUD_URL', 'http://127.0.0.1:6601').rstrip('/')


def request(path, body=None, token=None, method=None, expected=200):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers,
        method=method or ('POST' if body is not None else 'GET'),
    )
    try:
        response = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == expected, f'{path}: {response.status} != {expected}'
        return json.load(response) if response.status != 404 else None


admin = request('/api/auth/login', {
    'email': os.environ['TEST_LOGIN_EMAIL'],
    'password': os.environ['TEST_LOGIN_PASSWORD'],
})
assert admin['user']['is_admin'] is True
admin_token = admin['token']
assert request('/api/auth/me', token=admin_token)['is_admin'] is True
request('/api/admin/users', token=admin_token)

request('/api/admin/login', {
    'email': os.environ['TEST_LOGIN_EMAIL'],
    'password': os.environ['TEST_LOGIN_PASSWORD'],
}, expected=404)
print('PASS: existing administrator unified login and role access (no accounts or data created)')
