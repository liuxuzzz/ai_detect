# AI质量检测云端

Vue 页面和 Axum API 打包到同一个应用镜像，使用同一个访问地址。PostgreSQL 保存账号和报告，Redis 提供缓存，数据库和缓存不公开端口。

## 首次部署

```sh
cd cloud
docker compose up -d --build
```

无需创建 `.env` 或配置 API 地址、密码、密钥。启动时自动生成独立的随机数据库密码、签名密钥和加密密钥，保存在 `runtime_secrets` Docker 数据卷中，重建容器时复用。

启动后打开 `http://服务器IP:6600`，客户端的「云端地址」也填写这个地址。新数据库的第一个成功注册账号自动成为超级管理员。

需要自定义端口或外部数据库时，再复制 [`.env.example`](.env.example) 为 `.env`，修改对应项目即可。默认只开放应用端口 `6600`，使用 `WEB_PORT` 调整。

## 域名和 Cloudflare 部署

将自己的域名或 Cloudflare Tunnel 转发到应用的 `6600` 端口即可。例如浏览器访问 `https://ai.example.com`，客户端也填写 `https://ai.example.com`。页面、JSON API、上传和 SSE 都使用这个域名，无需另设 API 域名或 API 地址环境变量。

管理员首次通过浏览器登录时，系统会将浏览器地址记录到 PostgreSQL，用于分享链接和 OAuth 回调。更换域名时，在「管理中心 → 站点设置 → 站点地址」更新即可。未记录站点地址时，报告接口返回相对路径。

## 从分开部署的旧版本升级

保留原 `.env` 和数据卷，在 `cloud` 目录执行：

```sh
docker compose up -d --build --remove-orphans
```

Compose 会移除旧 `web`、`server` 容器，启动新的 `app` 容器。`WEB_PORT` 继续控制站点端口；旧的 `SERVER_PORT`、`WEB_API_BASE_URL` 和 `PUBLIC_BASE_URL` 已不再使用。客户端将原独立 API 地址改为浏览器中的站点地址，例如 `https://ai_detect.wv.gs/`。

升级时保留原数据库密码和密钥。旧版未单独设置加密密钥时，会保留原 JWT 密钥用于解密已有数据。如果检测到已有数据库却缺少原密码、签名密钥和对应持久化文件，初始化会停止并提示恢复原配置，不会重置数据库。

备份时同时保留 PostgreSQL、Redis、`runtime_secrets` 数据卷及自定义 `.env`。`docker compose down` 保留数据；不要在升级时使用删除数据卷的 `down -v`。

## 邮箱注册和找回密码

超级管理员登录后，在「管理中心 → 站点设置 → 邮件与第三方登录」填写 SMTP 服务器、端口、加密方式、认证信息和发件人邮箱。支持 TLS（通常 465）和 STARTTLS（通常 587）；不加密选项仅用于内部邮件服务。先保存，再发送测试邮件到当前账号邮箱。

没有配置邮件服务时支持邮箱和密码注册/登录，首个账号可完成站点初始化；不会显示邮箱验证码和忘记密码入口。启用邮件服务后，新注册账号必须填写邮箱验证码，登录页显示「忘记密码」。验证码有效期 15 分钟、仅可使用一次、最多尝试 5 次；同邮箱每分钟最多发送一次、每小时最多 5 次。找回密码后旧登录会话失效，已有 Client Key 不变。

邮件配置和应用密钥经加密后保存于 PostgreSQL。后台读取时只返回「已保存」状态，不回传 SMTP 密码和 Client Secret；密钥输入留空表示保留已保存值。保持 `CLIENT_KEY_ENCRYPTION_SECRET` 稳定。

## GitHub / Google 登录

在对应平台创建应用，将后台显示的完整回调地址原样填入应用配置，再填写 Client ID、Client Secret 并启用。未填写完整或未启用时，登录页不显示入口，服务端也不开放该登录方式。

| 提供商 | 公网 API 示例回调地址 |
| --- | --- |
| GitHub OAuth App | `https://ai.example.com/api/auth/oauth/github/callback` |
| Google Web OAuth Client | `https://ai.example.com/api/auth/oauth/google/callback` |

回调地址使用后台保存的站点地址。Google 应用需开放 `openid email profile`，GitHub 使用 `read:user user:email`。Google 应用处于测试状态时需在其控制台添加测试用户。

第三方登录只接受提供商返回的已验证邮箱，使用一次性 state、浏览器绑定 cookie 和 PKCE。服务端处理授权回调，浏览器仅接收有效期 60 秒的一次性登录凭据，会话令牌通过 API 交换获得。关闭注册后，已关联账号仍可登录，但不能创建新账号。

已有邮箱密码账号若尚未验证邮箱，不会仅凭同名邮箱自动关联第三方身份；先通过邮箱找回密码完成验证，再使用第三方登录。提供商返回的身份 ID 用于后续登录，邮箱变更不会产生重复关联。

API 结构和其他功能见 [`server/README.md`](server/README.md)，桌面安装包发布见 [`../docs/releases.md`](../docs/releases.md)。
