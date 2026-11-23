"""Check an existing split deployment upgrades without replacing its data volumes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from compose_smoke import CLOUD, free_port, request, wait_ready


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--legacy-compose", required=True)
    parser.add_argument("--legacy-server-image", required=True)
    parser.add_argument("--legacy-web-image", required=True)
    options = parser.parse_args()
    project = "aijiance-same-origin-upgrade-test"
    with tempfile.TemporaryDirectory(prefix=project + "-") as directory:
        work = Path(directory)
        environment = dict(os.environ)
        web_port, api_port = free_port(), free_port()
        while web_port == api_port:
            api_port = free_port()
        web = f"http://127.0.0.1:{web_port}"
        old_api = f"http://127.0.0.1:{api_port}"
        environment.update(WEB_BIND_ADDRESS="127.0.0.1", SERVER_BIND_ADDRESS="127.0.0.1",
                           WEB_PORT=str(web_port), SERVER_PORT=str(api_port), WEB_API_BASE_URL=old_api,
                           DATABASE_URL="", POSTGRES_USER="aijiance", POSTGRES_DB="aijiance",
                           POSTGRES_PASSWORD="isolated-upgrade-password", JWT_SECRET="isolated-upgrade-jwt",
                           CLIENT_KEY_ENCRYPTION_SECRET="")
        empty = work / ".env"
        empty.touch()
        legacy = work / "legacy.json"
        legacy.write_text(json.dumps({"services": {
            "server": {"image": options.legacy_server_image},
            "web": {"image": options.legacy_web_image},
        }}))
        combined = work / "combined.json"
        combined.write_text(json.dumps({"services": {"app": {"image": options.image}}}))

        def compose(old, *arguments):
            files = [options.legacy_compose, str(legacy)] if old else [str(CLOUD / "docker-compose.yml"), str(combined)]
            command = ["docker", "compose", "-p", project, "--env-file", str(empty)]
            for file in files:
                command += ["-f", file]
            return subprocess.check_output(command + list(arguments), env=environment, text=True)

        try:
            compose(True, "up", "-d", "--no-build", "--pull", "missing")
            wait_ready(old_api, web)
            credentials = {"email": "upgrade@example.test", "password": "isolated-upgrade-account-password"}
            request(old_api, "/api/auth/register", credentials)
            session = request(old_api, "/api/auth/login", credentials, origin=web)
            token = session["token"]
            key = request(old_api, "/api/auth/client-keys", body={}, token=token)
            report = request(old_api, "/api/reports/upload", key=key["key"], body={
                "api_domain": "upgrade.example.test", "model": "fixture", "prompt_name": "upgrade",
                "metadata": {}, "data": {"version": 1, "output": "Existing report survives upgrade",
                                         "samples": [], "activities": [], "retries": []},
            })
            database_id = compose(True, "ps", "-q", "postgres").strip()
            redis_id = compose(True, "ps", "-q", "redis").strip()
            # This is the documented upgrade command, including removal of the
            # old web container that currently owns the site's published port.
            compose(False, "up", "-d", "--no-build", "--pull", "never", "--remove-orphans")
            wait_ready(web, web)
            assert compose(False, "ps", "-q", "postgres").strip() == database_id
            assert compose(False, "ps", "-q", "redis").strip() == redis_id
            assert request(web, "/api/auth/me", token=token)["is_superadmin"] is True
            assert request(web, f'/api/auth/client-keys/{key["id"]}', token=token)["key"] == key["key"]
            assert request(web, "/api/public/reports/" + report["slug"])["data"]["output"] == "Existing report survives upgrade"
            assert '<div id="app">' in request(web, "/r/" + report["slug"])
            updated = request(web, "/api/reports/upload", key=key["key"] , body={
                "api_domain": "upgrade.example.test", "model": "new", "prompt_name": "same origin",
                "metadata": {}, "data": {"version": 1, "output": "Uploaded through browser address",
                                         "samples": [], "activities": [], "retries": []},
            })
            assert updated["owner_url"] == web + "/r/" + updated["slug"]
            print("PASS: split-to-combined upgrade preserves database/Redis containers, sessions, Client Keys and reports; site URL uploads work", flush=True)
        finally:
            compose(False, "down", "--volumes", "--remove-orphans")


if __name__ == "__main__":
    main()
