"""Package a release built by Flutter, using native installer tools."""
import argparse
import hashlib
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "release"
APP = "AI质量检测"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def macos(version):
    app = ROOT / "build/macos/Build/Products/Release" / f"{APP}.app"
    if not app.is_dir():
        raise SystemExit(f"Build the macOS release first: {app}")
    # Keep the complete app bundle, including Flutter, plugins and DuckDB.
    # The distributed runtime keeps App Sandbox enabled on CI as on local builds.
    run("codesign", "--force", "--deep", "--sign", "-", "--entitlements", ROOT / "macos/Runner/Release.entitlements", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / APP)], text=True).split()
    arch = "universal" if {"arm64", "x86_64"}.issubset(architectures) else architectures[0]
    name = f"ai-detect-{version}-macos-{arch}"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, OUTPUT / f"{name}.zip")
    with tempfile.TemporaryDirectory(prefix="ai-detect-dmg-") as temp:
        stage = Path(temp)
        shutil.copytree(app, stage / app.name, symlinks=True)
        (stage / "Applications").symlink_to("/Applications")
        run("hdiutil", "create", "-volname", APP, "-srcfolder", stage, "-ov", "-format", "UDZO", OUTPUT / f"{name}.dmg")


def windows(version):
    bundle = ROOT / "build/windows/x64/runner/Release"
    if not (bundle / "aijiance.exe").is_file() or not (bundle / "duckdb.dll").is_file():
        raise SystemExit("Build the complete Windows release with DuckDB first")
    if not (bundle / "MicrosoftEdgeWebview2Setup.exe").is_file():
        raise SystemExit("Run tool/prepare_webview2.ps1 to bundle the WebView2 installer first")
    iscc = shutil.which("ISCC") or str(Path(r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"))
    run(iscc, f"/DAppVersion={version}", f"/DBundleDir={bundle}", f"/DOutputDir={OUTPUT}", ROOT / "packaging/windows.iss")
    shutil.make_archive(str(OUTPUT / f"ai-detect-{version}-windows-x64-portable"), "zip", bundle)


def linux(version):
    bundle = ROOT / "build/linux/x64/release/bundle"
    if not (bundle / "aijiance").is_file():
        raise SystemExit("Build the Linux release first")
    # Explicitly include DuckDB; not all versions of the plugin export it as a bundled library.
    shutil.copy2(ROOT / ".dart_tool/duckdb/libduckdb.so", bundle / "lib/libduckdb.so")
    for library in (bundle / "lib").glob("*.so"):
        run("patchelf", "--set-rpath", "$ORIGIN", library)
        needed = subprocess.check_output(["patchelf", "--print-needed", str(library)], text=True).splitlines()
        for dependency in needed:
            if "/" in dependency and "duckdb" in dependency:
                run("patchelf", "--replace-needed", dependency, "libduckdb.so", library)
    for binary in [bundle / "aijiance", *(bundle / "lib").glob("*.so")]:
        dependencies = subprocess.check_output(["ldd", str(binary)], text=True)
        if "not found" in dependencies:
            raise SystemExit(f"Missing runtime dependency for {binary}:\n{dependencies}")
    with tarfile.open(OUTPUT / f"ai-detect-{version}-linux-x64.tar.gz", "w:gz") as archive:
        archive.add(bundle, arcname="ai-detect")
    with tempfile.TemporaryDirectory(prefix="ai-detect-linux-") as temp:
        work = Path(temp)
        stage = work / "root"
        shutil.copytree(bundle, stage / "opt/ai-detect", symlinks=True)
        launcher = stage / "usr/bin/ai-detect"
        launcher.parent.mkdir(parents=True)
        launcher.write_text('#!/bin/sh\nexec /opt/ai-detect/aijiance "$@"\n')
        launcher.chmod(0o755)
        desktop = stage / "usr/share/applications/ai-detect.desktop"
        desktop.parent.mkdir(parents=True)
        desktop.write_text(f"[Desktop Entry]\nType=Application\nName={APP}\nExec=ai-detect\nIcon=ai-detect\nTerminal=false\nCategories=Development;Utility;\n")
        icon = stage / "usr/share/icons/hicolor/256x256/apps/ai-detect.png"
        icon.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png", icon)
        documentation = stage / "usr/share/doc/ai-detect"
        documentation.mkdir(parents=True)
        for name in ["README.md", "CHANGELOG.md"]:
            shutil.copy2(ROOT / name, documentation / name)
        control = stage / "DEBIAN/control"
        control.parent.mkdir()
        control.write_text(f"Package: ai-detect\nVersion: {version}\nSection: utils\nPriority: optional\nArchitecture: amd64\nMaintainer: ai_detect contributors\nHomepage: https://github.com/liuxuzzz/ai_detect\nDepends: libgtk-3-0, libstdc++6, libgcc-s1, libc6 (>= 2.35), liblzma5\nDescription: AI quality testing desktop application\n Local model diagnostics and optional cloud report sharing.\n")
        run("dpkg-deb", "--root-owner-group", "--build", stage, OUTPUT / f"ai-detect-{version}-linux-amd64.deb")
        shutil.rmtree(control.parent)
        for directory in ["BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"]:
            (work / directory).mkdir()
        spec = work / "SPECS/ai-detect.spec"
        spec.write_text(f"""Name: ai-detect
Version: {version}
Release: 1
Summary: AI quality testing desktop application
License: LicenseRef-Unspecified
URL: https://github.com/liuxuzzz/ai_detect
BuildArch: x86_64
Requires: gtk3, libstdc++, libgcc, glibc >= 2.35, xz-libs
AutoReqProv: no
%global __os_install_post %{{nil}}
%description
Local model diagnostics and optional cloud report sharing.
%install
mkdir -p %{{buildroot}}
cp -a "{stage}/." %{{buildroot}}/
%files
/opt/ai-detect
/usr/bin/ai-detect
/usr/share/applications/ai-detect.desktop
/usr/share/icons/hicolor/256x256/apps/ai-detect.png
/usr/share/doc/ai-detect
""")
        run("rpmbuild", "--define", f"_topdir {work}", "--define", "_build_id_links none", "-bb", spec)
        rpm = next((work / "RPMS").rglob("*.rpm"))
        shutil.copy2(rpm, OUTPUT / f"ai-detect-{version}-linux-x86_64.rpm")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    options = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", options.version):
        parser.error("version must be a plain semantic version, e.g. 0.1.0")
    OUTPUT.mkdir(exist_ok=True)
    {"Darwin": macos, "Windows": windows, "Linux": linux}[platform.system()](options.version)
    files = sorted(path for path in OUTPUT.iterdir() if path.is_file() and path.suffix != ".sha256")
    for file in files:
        (OUTPUT / f"{file.name}.sha256").write_text(f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}\n")


if __name__ == "__main__":
    main()
