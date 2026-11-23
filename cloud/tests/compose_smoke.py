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


def request(base, path, body=None, token=None, key=None):
    headers = {"Content-Type": "application/json"}
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
            "server": {"image": options.server_image},
            "web": {"image": options.web_image},
        }}))
        variables = {line.split("=", 1)[0] for line in (CLOUD / ".env.example").read_text().splitlines()
                     if line and not line.startswith("#") and "=" in line}
        environment = {key: value for key, value in os.environ.items() if key not in variables}
        environment.update(SERVER_BIND_ADDRESS="127.0.0.1", WEB_BIND_ADDRESS="127.0.0.1")
        if mode == "empty":
            # Exercise the real published defaults, without port overrides.
            api_port, web_port = 6601, 6600
        else:
            api_port, web_port = free_port(), free_port()
            while web_port == api_port:
                web_port = free_port()
            environment.update(SERVER_PORT=str(api_port), WEB_PORT=str(web_port))
        if mode == "explicit":
            environment.update(POSTGRES_PASSWORD="space ' \\ : / @ ? # %40 $",
                               JWT_SECRET="existing-installation-signing-secret")
        command = ["docker", "compose", "--project-name", project, "--env-file", str(configuration),
                   "-f", str(CLOUD / "docker-compose.yml"), "-f", str(override)]

        def compose(*arguments):
            return subprocess.check_output(command + list(arguments), env=environment, text=True)

        def secrets():
            # Read hashes only; plaintext secrets never enter test output.
            return compose("exec", "-T", "server", "sha256sum",
                           "/run/secrets/postgres_password", "/run/secrets/jwt_secret",
                           "/run/secrets/client_key_encryption_secret")

        api, web = f"http://127.0.0.1:{api_port}", f"http://127.0.0.1:{web_port}"
        try:
            compose("config", "--quiet")
            compose("up", "-d", "--no-build", "--pull", "missing")
            wait_ready(api, web)
            runtime = request(web, "/app-config.js")
            assert 'atob("")' in runtime and f'apiPort: "{api_port}"' in runtime
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
    parser.add_argument("--server-image", required=True)
    parser.add_argument("--web-image", required=True)
    options = parser.parse_args()
    for mode in ("empty", "example", "explicit"):
        scenario(options, mode)


if __name__ == "__main__":
    main()
