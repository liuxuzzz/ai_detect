"""Exercise disposable first-start deployments; never uses the site's .env or volumes."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

CLOUD = Path(__file__).resolve().parents[1]
OPENER = build_opener(ProxyHandler({}))


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def request(base, path, body=None, token=None, key=None, origin=None):
    headers = {"Content-Type": "application/json", "Origin": origin or base}
    if token:
        headers["Authorization"] = "Bearer " + token
    if key:
        headers["X-Client-Key"] = key
    query = Request(base + path, headers=headers,
                    data=None if body is None else json.dumps(body).encode())
    with OPENER.open(query, timeout=10) as response:
        data = response.read().decode()
        return json.loads(data) if "json" in response.headers.get("Content-Type", "") else data


def wait_ready(api, web):
    for attempt in range(60):
        try:
            assert request(api, "/health") == {"status": "ok"}
            assert "<title>AI质量检测</title>" in request(web, "/")
            return
        except (URLError, HTTPError, OSError, AssertionError):
            if attempt == 59:
                raise
            time.sleep(1)


def scenario(options, mode):
    project = "aijiance-first-start-test-" + mode
    with tempfile.TemporaryDirectory(prefix=project + "-") as temporary:
        work = Path(temporary)
        configuration = work / ".env"
        if mode == "example":
            shutil.copy2(CLOUD / ".env.example", configuration)
        else:
            configuration.touch()
        override = work / "images.json"
        override.write_text(json.dumps({"services": {
            "app": {"image": options.image},
        }}))
        variables = {line.split("=", 1)[0] for line in (CLOUD / ".env.example").read_text().splitlines()
                     if line and not line.startswith("#") and "=" in line}
        environment = {key: value for key, value in os.environ.items() if key not in variables}
        environment.update(WEB_BIND_ADDRESS="127.0.0.1")
        port = free_port()
        environment.update(WEB_PORT=str(port))
        if mode == "explicit":
            environment.update(POSTGRES_PASSWORD="space ' \\ : / @ ? # %40 $",
                               JWT_SECRET="existing-installation-signing-secret")
        command = ["docker", "compose", "--project-name", project, "--env-file", str(configuration),
                   "-f", str(CLOUD / "docker-compose.yml"), "-f", str(override)]

        def compose(*arguments):
            return subprocess.check_output(command + list(arguments), env=environment, text=True)

        def secrets():
            # Read hashes only; plaintext secrets never enter test output.
            return compose("exec", "-T", "app", "sha256sum",
                           "/run/secrets/postgres_password", "/run/secrets/jwt_secret",
                           "/run/secrets/client_key_encryption_secret")

        api = web = f"http://127.0.0.1:{port}"
        try:
            compose("config", "--quiet")
            compose("up", "-d", "--no-build", "--pull", "missing")
            wait_ready(api, web)
            configuration_view = json.loads(compose("config", "--format", "json"))
            assert set(configuration_view["services"]) == {"app", "postgres", "redis", "init-secrets"}
            assert len(configuration_view["services"]["app"]["ports"]) == 1
            assert "WEB_API_BASE_URL" not in configuration_view["services"]["app"]["environment"]
            for path in ["/api/not-a-route", "/api/reports/upload/not-a-route"]:
                try:
                    request(web, path)
                    raise AssertionError("Unknown API should return JSON 404")
                except HTTPError as error:
                    assert error.code == 404 and "error" in json.load(error)
            assert request(api, "/api/auth/options")["bootstrap_required"] is True
            credentials = {"email": "first-admin@example.test", "password": "isolated-first-start-password"}
            request(api, "/api/auth/register", credentials)
            session = request(api, "/api/auth/login", credentials)
            token = session["token"]
            assert session["user"]["is_superadmin"] is True
            created = request(api, "/api/auth/client-keys", token=token, body={})
            key, key_id = created["key"], created["id"]
            report = request(api, "/api/reports/upload", key=key, body={
                "api_domain": "first-start.example.test", "model": "fixture", "prompt_name": "first-start",
                "metadata": {"total_tokens": 2},
                "data": {"version": 1, "output": "Persisted first-start result", "samples": [], "activities": [], "retries": []},
            })
            assert report["owner_url"] == web + "/r/" + report["slug"]
            assert '<div id="app">' in request(web, "/r/" + report["slug"])
            assert '<div id="app">' in request(web, "/auth/callback")
            owner = int(session["user"]["id"])
            task = compose("exec", "-T", "postgres", "psql", "-U", "aijiance", "-d", "aijiance", "-Atq",
                           "-v", "ON_ERROR_STOP=1", "-c",
                           f"INSERT INTO async_tasks(owner_id,status,scheduled_for,model,live) VALUES ({owner},'completed',now(),'same-origin','{{\"output\":\"same-origin-sse\"}}') RETURNING id").strip()
            stream = request(api, f"/api/tasks/{int(task)}/events", token=token)
            assert 'event: snapshot' in stream and 'same-origin-sse' in stream
            before = secrets()
            if mode == "explicit":
                hashes = [line.split()[0] for line in before.splitlines()]
                assert hashes[1] == hashes[2], "Legacy JWT encryption key must be preserved"
            else:
                assert len({line.split()[0] for line in before.splitlines()}) == 3

            # Recreate the stack, including its one-shot initializer. Its volumes
            # must keep the password, active session, encrypted Client Key and report.
            compose("down")
            compose("up", "-d", "--no-build", "--pull", "never")
            wait_ready(api, web)
            assert secrets() == before
            assert request(api, "/api/auth/me", token=token)["is_superadmin"] is True
            assert request(api, f"/api/auth/client-keys/{key_id}", token=token)["key"] == key
            assert request(api, "/api/public/reports/" + report["slug"])["data"]["output"] == "Persisted first-start result"
            assert request(api, "/api/auth/login", credentials)["user"]["is_superadmin"] is True
            print(f"PASS {mode}: first administrator, upload, restart, sessions and encrypted keys", flush=True)
        finally:
            # Only resources belonging to this disposable project are removed.
            compose("down", "--volumes", "--remove-orphans")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    options = parser.parse_args()
    for mode in ("empty", "example", "explicit"):
        scenario(options, mode)


if __name__ == "__main__":
    main()
