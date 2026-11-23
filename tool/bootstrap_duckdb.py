"""Prepare checksum-pinned DuckDB v1.4.2 for desktop builds and tests."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import urllib.parse
import urllib.request
import zipfile


ASSETS = {
    "Darwin": ("macos", "libduckdb.dylib", 315529468,
               "3951dd422902e8a02db6128520b94e71aed88c42af80ead134da0efd62fc49ed"),
    "Linux": ("linux", "libduckdb.so", 315529456,
              "0a68e623cbdcfa06e10e1b5d6a3092d3fd3679f616008fb1a39b92e4a10d8f43"),
    "Windows": ("windows", "duckdb.dll", 315529474,
                "4d3e5f2ee009a8fff5b8d43bc50f61c6b246b2b227748bc900f8520ec8fac0b0"),
}


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
        request = urllib.request.Request(
            f"https://api.github.com/repos/duckdb/duckdb/releases/assets/{asset}",
            headers={"Accept": "application/octet-stream", "User-Agent": "ai-detect-build"},
        )
        temporary = archive.with_suffix(".download")
        try:
            with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
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
