"""Prepare checksum-pinned DuckDB v1.4.2 for desktop builds and tests."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import urllib.parse
import urllib.error
import urllib.request
import time
import zipfile


ASSETS = {
    "Darwin": ("macos", "libduckdb.dylib", "libduckdb-osx-universal.zip",
               "3951dd422902e8a02db6128520b94e71aed88c42af80ead134da0efd62fc49ed"),
    "Linux": ("linux", "libduckdb.so", "libduckdb-linux-amd64.zip",
              "0a68e623cbdcfa06e10e1b5d6a3092d3fd3679f616008fb1a39b92e4a10d8f43"),
    "Windows": ("windows", "duckdb.dll", "libduckdb-windows-amd64.zip",
                "4d3e5f2ee009a8fff5b8d43bc50f61c6b246b2b227748bc900f8520ec8fac0b0"),
}


def download_archive(url, archive, digest):
    temporary = archive.with_suffix(".download")
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "ai-detect-build"})
            with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                raise ValueError("DuckDB checksum mismatch")
            temporary.replace(archive)
            return
        except (OSError, ValueError) as error:
            if attempt == 2:
                raise SystemExit("Unable to download verified DuckDB: " + str(error)) from error
            print("DuckDB download failed; retrying...", flush=True)
            time.sleep(2 ** attempt)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    system = platform.system()
    if system not in ASSETS:
        raise SystemExit(f"Unsupported platform: {system}")
    if system != "Darwin" and platform.machine().lower() not in ("x86_64", "amd64"):
        raise SystemExit("Windows and Linux packages currently require x86_64")
    target, library, asset, digest = ASSETS[system]
    root = Path(__file__).resolve().parent.parent
    cache = root / ".dart_tool" / "duckdb"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"duckdb-{target}-1.4.2.zip"
    if not archive.exists():
        # Official release downloads do not consume the shared runner's GitHub API quota.
        download_archive(f"https://github.com/duckdb/duckdb/releases/download/v1.4.2/{asset}", archive, digest)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        archive.unlink()
        raise SystemExit("DuckDB checksum mismatch; invalid download removed")
    with zipfile.ZipFile(archive) as files:
        (cache / library).write_bytes(files.read(library))
    config = root / ".dart_tool" / "package_config.json"
    packages = json.loads(config.read_text())["packages"]
    package = next(item for item in packages if item["name"] == "dart_duckdb")
    uri = urllib.parse.urljoin(config.as_uri(), package["rootUri"])
    package_root = Path(urllib.request.url2pathname(urllib.parse.urlparse(uri).path))
    destination = package_root / target / "Libraries" / "release"
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(cache / library, destination / library)
    if system != "Windows":
        (cache / library).chmod(0o755)
        (destination / library).chmod(0o755)
    print(f"DuckDB v1.4.2 ready for {target} (SHA-256 verified)")


if __name__ == "__main__":
    main()
