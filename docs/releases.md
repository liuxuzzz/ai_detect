# 安装包与 GitHub 发布

应用显示名称为 **AI质量检测**，当前版本为 **v0.1.0**。应用版本取自 `pubspec.yaml`，关于页从安装包读取版本，并展示打包进去的 `CHANGELOG.md`。

## 下载产物

| 平台 | GitHub Release 资产 |
| --- | --- |
| Windows x64 | `ai-detect-0.1.0-windows-x64-setup.exe` 安装程序、`*-portable.zip` 完整便携包 |
| macOS Intel / Apple Silicon | `ai-detect-0.1.0-macos-universal.dmg`、完整应用 `.zip` |
| Debian / Ubuntu x64 | `ai-detect-0.1.0-linux-amd64.deb` |
| Fedora / RPM 系统 x64 | `ai-detect-0.1.0-linux-x86_64.rpm` |
| Linux x64 便携包 | `ai-detect-0.1.0-linux-x64.tar.gz` |

每个文件附带 `.sha256` 校验文件。Windows 包含所需的 Visual C++ 运行库，所有平台携带 Flutter、插件、资源文件和校验过的 DuckDB 原生库。不要只分发 `.exe` 或 Linux 可执行文件。

macOS 要求 11.0 及以上。

Linux 构建基于 Ubuntu 22.04，依赖 glibc 2.35 及以上、GTK 3 和桌面图形环境，不需要安装 Java/JVM。Android 插件间接引入的 JNI 库不随 Linux 安装包分发。DEB/RPM 声明系统依赖，由包管理器安装。RPM 平台同样必须满足这个 glibc 版本要求。

当前配置不包含 Apple Developer 或 Windows 代码签名证书。macOS 会进行本地 ad-hoc 签名并验证应用包，尚未进行 Apple 公证；下载者可能收到系统安全提示。正式分发若需要已认证开发者身份，应提供自己的签名证书和公证凭证；仓库中不保存证书或私钥。

## 首次发布

将代码推送到 GitHub 仓库后，在仓库 Actions 页面启用工作流。普通 `main` 推送、Pull Request 和手动运行会检查代码、构建桌面包，在该次运行的 **Artifacts** 中保存 30 天。

准备发布时，确认 `pubspec.yaml` 中的 `version: 0.1.0+1` 和 `CHANGELOG.md` 的版本说明，然后推送对应标签：

```sh
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

标签必须与 `pubspec.yaml` 版本一致。三个平台全部成功后，工作流先创建草稿 Release、上传并校验全部产物，再发布 Release。其他人可以在仓库 **Releases** 页面直接下载安装包，无需等待本地编译；公开 Release 的资产下载不需要登录。普通提交不会发布 Release。

工作流使用 GitHub 自动提供的 `GITHUB_TOKEN`，仅发布作业有 `contents: write` 权限，不需要额外配置个人访问令牌。组织策略如禁用了写权限，需要由仓库所有者调整 Actions 策略。不要把部署服务器的 SSH 密钥放到公共仓库；这里的工作流只构建和发布安装包。

## 本地复现

使用 Flutter **3.44.2**，保留 `pubspec.lock`、`Cargo.lock`、`package-lock.json` 和 `Podfile.lock`。Windows/Linux 构建当前为 x64；macOS Release 为 universal。

```sh
flutter pub get --enforce-lockfile
python3 tool/bootstrap_duckdb.py
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --release --no-pub
python3 tool/package_desktop.py --version 0.1.0
```

将 `macos` 换成对应平台；打包需在目标系统进行。Windows 需要 Visual Studio C++ 桌面工具、Inno Setup 6，并把 Visual C++ CRT DLL 放进 Flutter Release 目录；Linux 需要 clang、CMake、Ninja、GTK 3 开发库、rpm 和 patchelf；macOS 需要 Xcode 和 CocoaPods。工作流已配置这些步骤。安装包和校验文件输出到被 Git 忽略的 `release/`。
