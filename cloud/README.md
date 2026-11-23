# AI质量检测云端

Vue 前端与 Axum API 独立部署，PostgreSQL 保存账号和报告，Redis 提供缓存。前端 Nginx 只服务静态文件；浏览器和桌面客户端直接访问 API。

## 首次部署

```sh
cd cloud
docker compose up -d --build
```

无需创建 `.env` 或手填密码、密钥。启动时自动生成独立的随机数据库密码、签名密钥和加密密钥，保存在 `runtime_secrets` Docker 数据卷中，重启、重建容器时复用。数据库不映射公网端口。

启动完成后打开 `http://服务器IP:6600`；本机部署打开 `http://127.0.0.1:6600`。浏览器自动连接同一台服务器的 `6601` API 端口，服务器放行这两个端口即可。

需要自定义端口、API 域名或外部数据库时，再执行 `cp .env.example .env` 并修改对应项目。所有可选变量统一列在 [`.env.example`](.env.example)，包含中文说明；留空的密钥仍会自动生成。不要提交 `.env`。

**升级已有站点时保留原 `.env`。** 其中已有的密码和密钥优先生效；旧版未单独设置加密密钥时，会保留原 JWT 密钥用于解密已有数据。如果检测到已有数据库但缺少原密码或签名密钥，且没有对应的持久化密钥文件，启动会停止并提示恢复原配置，不会重置数据库。备份时同时保留 PostgreSQL、Redis、`runtime_secrets` 数据卷和自定义 `.env`；`docker compose down` 保留数据，`down -v` 会删除它们。

首次打开网站后注册自己的账号。**新数据库的第一个成功注册账号自动成为超级管理员**；并发注册也只会选出一个。程序不再读取预置管理员邮箱/密码，不创建默认账号。超级管理员不能被后台禁用或取消权限。升级已有数据库会保留原有账号和密码，将最早的有效管理员标记为超级管理员。

## IP 和域名部署

前端站点地址无需环境变量：首次管理员通过网页登录时自动记录当前浏览器地址，保存到 PostgreSQL，用于报告分享与登录完成后的跳转。更换域名后，在「管理中心 → 站点设置 → 站点地址」更新即可，立即生效。纯 API 初始化且没有浏览器登录时，报告 API 返回相对页面路径；在后台保存站点地址后即可返回完整分享链接。

| 场景 | 前端实际访问地址（自动记录） | `.env` 的 `WEB_API_BASE_URL` |
| --- | --- | --- |
| 本机开发 | `http://127.0.0.1:6600` | 留空，自动使用当前主机 |
| IP 直连 | `http://服务器IP:6600` | 留空，自动使用当前服务器 IP |
| Cloudflare/反向代理 | `https://ai.example.com` | `https://api.example.com` |

IP 直连无需配置 API 地址。使用 Cloudflare/反向代理或启用第三方登录时，在 `.env` 中指定 API 公网地址；HTTPS 域名不会被自动补上 Docker 端口。`WEB_PORT`、`SERVER_PORT` 配置宿主机端口。分别把前端域名和 API 域名路由到对应服务即可；同机代理或 Cloudflare Tunnel 可将两个 `*_BIND_ADDRESS` 设为 `127.0.0.1`。

修改 API 地址后执行 `docker compose up -d --force-recreate server web`。Web 在容器启动时生成 `app-config.js`，无需重新构建镜像。SMTP 和 OAuth 应用密钥不会写入此文件。HTTPS 页面须配 HTTPS API；客户端「云端 API 地址」填写 `WEB_API_BASE_URL`，不是前端地址。旧的 `PUBLIC_BASE_URL` 环境变量不再使用。

升级时，若已有 `.env` 明确设置了端口，请将 `WEB_PORT` 改为 `6600`、`SERVER_PORT` 改为 `6601`；IP 形式的 `WEB_API_BASE_URL` 和客户端云端 API 地址也使用 `6601`。站点通过 IP 加端口访问时，同时在后台更新「站点地址」为新的前端地址。

## 邮箱注册和找回密码

超级管理员登录后，在「管理中心 → 站点设置 → 邮件与第三方登录」填写 SMTP 服务器、端口、加密方式、认证信息和发件人邮箱。支持 TLS（通常 465）和 STARTTLS（通常 587）；不加密选项仅用于内部邮件服务。先保存，再发送测试邮件到当前账号邮箱。

没有配置邮件服务时支持邮箱和密码注册/登录，首个账号可完成站点初始化；不会显示邮箱验证码和忘记密码入口。启用邮件服务后，新注册账号必须填写邮箱验证码，登录页显示「忘记密码」。验证码有效期 15 分钟、仅可使用一次、最多尝试 5 次；同邮箱每分钟最多发送一次、每小时最多 5 次。找回密码后旧登录会话失效，已有 Client Key 不变。

邮件配置和应用密钥经加密后保存于 PostgreSQL。后台读取时只返回「已保存」状态，不回传 SMTP 密码和 Client Secret；密钥输入留空表示保留已保存值。保持 `CLIENT_KEY_ENCRYPTION_SECRET` 稳定。

## GitHub / Google 登录

在对应平台创建应用，将后台显示的完整回调地址原样填入应用配置，再填写 Client ID、Client Secret 并启用。未填写完整或未启用时，登录页不显示入口，服务端也不开放该登录方式。

| 提供商 | 公网 API 示例回调地址 |
| --- | --- |
| GitHub OAuth App | `https://api.example.com/api/auth/oauth/github/callback` |
| Google Web OAuth Client | `https://api.example.com/api/auth/oauth/google/callback` |

地址来自 `.env` 中的 `WEB_API_BASE_URL`。Google 应用需开放 `openid email profile`，GitHub 使用 `read:user user:email`。Google 应用处于测试状态时需在其控制台添加测试用户。

第三方登录只接受提供商返回的已验证邮箱，使用一次性 state、浏览器绑定 cookie 和 PKCE。服务端处理授权回调，浏览器仅接收有效期 60 秒的一次性登录凭据，会话令牌通过 API 交换获得。关闭注册后，已关联账号仍可登录，但不能创建新账号。

已有邮箱密码账号若尚未验证邮箱，不会仅凭同名邮箱自动关联第三方身份；先通过邮箱找回密码完成验证，再使用第三方登录。提供商返回的身份 ID 用于后续登录，邮箱变更不会产生重复关联。

API 结构和其他功能见 [`server/README.md`](server/README.md)，桌面安装包发布见 [`../docs/releases.md`](../docs/releases.md)。
