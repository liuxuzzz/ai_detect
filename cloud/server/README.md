# Cloud API Server

`src/main.rs` loads configuration, initializes logging and shared state, and starts Axum. `src/lib.rs` exposes the configuration, state, and router for integration tests.

| File or directory | Responsibility |
| --- | --- |
| `src/config.rs`, `config/` | Parse packaged TOML defaults and apply environment overrides. |
| `src/state.rs` | Initialize and share the PostgreSQL connection pool and Redis client. |
| `src/routes/` | Register and group endpoints. `/api/channels` and `/api/upstreams` share the same resource router. |
| `src/middleware/` | Configure CORS and tracing, and extract authenticated users, administrators, and client keys. |
| `src/handlers/` | Extract request inputs, call services, and build JSON responses. |
| `src/services/`, `src/models/` | Implement business rules and queries, and define input and output types. |
| `src/error.rs` | Map service errors to status codes and the `{ "error": "..." }` response format. |
| `migrations/` | Apply the schema and data migrations at startup, before bootstrapping the administrator. |
| `tests/` | Exercise HTTP contracts against an isolated PostgreSQL database. |

## Structured Reports

The desktop client retains its local DuckDB database and works offline. Uploading a saved test sends structured data through `POST /api/reports/upload` with an active Client Key. It does not send an HTML report or connect directly to PostgreSQL. Upload failure leaves the local test intact for a later upload.

The upload envelope contains `api_domain`, `model`, `prompt_name`, a `metadata` object for scalar measurements, and a required versioned `data` object:

```json
{
  "api_domain": "api.example.test",
  "model": "example-model",
  "prompt_name": "Example test",
  "metadata": {"ttft_ms": 1250, "total_tokens": 23, "cache_read_tokens": null},
  "data": {
    "version": 1,
    "prompt": "Test prompt",
    "output": "Original model output",
    "samples": [{"seconds": 0.25, "tps": 8}],
    "activities": [],
    "retries": []
  }
}
```

`data` also records the channel name, start time, error, detection mode and reasoning effort. Activities contain reasoning, tool results and model artifacts; retries contain attempt timing and failure reasons. Raw HTTP requests, headers and upstream credentials stay local. Samples must be finite, nonnegative and in time order. Missing cache counts remain unknown; explicit zero is preserved. Uploads are limited to 32 MiB. Old HTML upload envelopes return JSON HTTP 400 with an upgrade message.

PostgreSQL stores scalar measurements in `reports.metadata` and complete versioned content in `reports.data` (JSONB). New reports leave the legacy `html` column null. Cloud Tasks save the same data structure. Rankings and dashboards query only summaries. Opening a Vue report fetches the full record from `GET /api/reports/{id}/details` or `GET /api/public/reports/{slug}`. `GET /api/public/shares/{token}` checks expiry and returns the report plus sharing settings. Responses are JSON and are not cached. The frontend renders metrics, interactive curves, model output, ratings and comments. Model-generated HTML is data and is previewed in a sandboxed frame.

Migration 010 makes the old HTML column optional. Startup recovers available scalar measurements, samples and model output from legacy reports into structured content, only where `data IS NULL`. Existing HTML is retained solely for rollback; no API serves it. Older documents cannot recover prompt or activity records they never saved. The desktop's standalone HTML export remains a local feature, with its assets under the root `assets/` directory.

The Vue frontend owns `/r/{slug}` and `/share/{token}`. Axum has no HTML or static-asset routes. Share expiry is checked by the API; iframe display preferences are checked by the Vue page and do not replace access control.

## Public Rankings

Public daily, weekly and monthly rankings sort by average rating descending, with unrated reports last. Equal scores and unrated reports sort by completion time descending, then report ID descending for stable pagination. The latest-tests list always sorts by completion time and report ID descending, regardless of ratings.

## Personal Center

Ordinary users and administrators share the personal center for Client Keys and password changes. `PUT /api/auth/password` accepts `current_password` and `new_password` with the account's bearer token. New passwords must contain at least eight characters. A successful change returns a replacement login session; older sessions are rejected using the account's session version. Client Keys remain valid. Fresh deployments create no default account. The first successful registration becomes super administrator; existing installations retain their earliest active administrator. Restarts preserve account passwords and settings.

`DELETE /api/reports/{id}` soft-deletes the owner's report and removes it from personal results, rankings and report/share links. `DELETE /api/tasks/{id}` deletes the owner's queue record and preserves any generated report. A running task returns HTTP 409; queued deletion serializes against task claiming so a successfully deleted task cannot start later. Personal deletion endpoints enforce ownership for administrators as well.

## Registration Settings

Administrators can enable or disable new account registration under Management Center → Site Settings → Open Registration. Registration defaults to enabled, and PostgreSQL preserves the saved setting across restarts and deployments. Closing registration returns JSON HTTP 403 from `POST /api/auth/register`; existing accounts can still log in and use their sessions. The login dialog hides its registration action while registration is closed.

`GET /api/auth/registration` publicly returns `{ "registration_enabled": true }`. Administrators read registration and upload settings at `GET /api/admin/settings` and update individual fields with `PUT /api/admin/settings`. These responses use `Cache-Control: no-store`. Anonymous users and ordinary accounts cannot access the administration endpoints. Registration inserts and setting changes coordinate through a database row lock so that closing registration waits for already accepted inserts to finish before returning.

## Email and Provider Authentication

`GET /api/auth/options` advertises registration, first-account setup, email verification/reset and configured providers. Public registration status remains available at `/api/auth/registration`. Administrators configure encrypted SMTP and OAuth credentials using `GET/PUT /api/admin/auth-settings`; responses redact secrets. `POST /api/admin/auth-settings/test-mail` sends only to the signed-in administrator's mailbox.

`POST /api/auth/email-code` accepts `{ "email": "...", "purpose": "register" | "reset" }`. Codes are HMAC protected, valid for 15 minutes, single-use and limited to five guesses. Requests use a per-email cooldown and hourly limit. Registration accepts `email_code` when SMTP is enabled, except during first-account setup. `POST /api/auth/password/reset` accepts `email`, `code`, and `new_password` and invalidates older sessions. Reset requests do not reveal whether an account exists.

`GET /api/auth/oauth/{github|google}/start` redirects to a configured provider with browser-bound state and PKCE. The corresponding `/callback` consumes the state once and redirects to the Vue `/auth/callback` page with a 60-second single-use ticket in the fragment. `POST /api/auth/oauth/exchange` swaps that ticket for a session. The API never serves an HTML page. Provider identity IDs are stable; automatic linking to a local account requires that local email to have been verified. Disabled users and newly registered users when registration is closed are rejected.

## Upload Limits

Management Center → Site Settings configures a shared policy that applies independently to each account, including administrators. The default is **100 successful client uploads per rolling 24-hour window**. Set `upload_limit` and `upload_window_seconds` with `PUT /api/admin/settings`; for example `{ "upload_limit": 20, "upload_window_seconds": 60 }` allows 20 uploads per user in the latest minute. The UI offers seconds, minutes, hours and days with a configurable duration. Counts must be positive integers, at most 1,000,000; windows are 1 second to 365 days.

PostgreSQL persists settings and applies changes immediately across instances. Concurrent uploads serialize on the account row, so multiple Client Keys cannot bypass the limit. Invalid/failed uploads do not count. Deleted client reports still count within the window, and cloud-generated Task reports do not consume client upload quota. Exhausted uploads receive JSON HTTP 429 with the current limit. Migration 012 installs the default only once; the former `UPLOAD_DAILY_LIMIT` environment variable no longer controls uploads.

## Client Keys

All signed-in users, including administrators, can manage their own keys with a bearer token. `GET /api/auth/client-keys` lists key metadata, `POST /api/auth/client-keys` creates a key, `GET /api/auth/client-keys/{id}` reveals an active key to its owner, and `DELETE /api/auth/client-keys/{id}` revokes it. New key secrets are encrypted at rest. Keep `CLIENT_KEY_ENCRYPTION_SECRET` stable across restarts and deployments. If unset, it falls back to `JWT_SECRET`. Older hash-only keys still authenticate uploads. Create a new key to use the reveal action. Clients send an active key in `X-Client-Key` when calling `POST /api/reports/upload`.

## Background Task

Administrators maintain shared prompts at `/api/admin/prompts` with list/create and update/delete operations on `/{id}`. Signed-in users read enabled prompts at `GET /api/prompts`. Creating a task with `prompt_kind: "library"` and `prompt_id` reads the trusted text on the server; client-supplied text cannot replace it. Tasks keep a name/content snapshot when a prompt is later edited, disabled or deleted.

`POST /api/admin/tasks/{id}/control` accepts `action` as `pause`, `resume` or `stop`; `DELETE /api/admin/tasks/{id}` deletes a queue record, including an active run. Pausing an active run closes its upstream request and preserves partial output. Resuming queues a new request with the same inputs; upstream APIs cannot continue a paused generation. Stopping retains diagnostics without requeueing. Removing a queue record preserves any completed report.

Disabling an account revokes its login sessions, disables queued/running/paused tasks, cancels its active request and removes its reports from homepage rankings and facets. Re-enabling the account leaves those tasks paused until explicitly resumed. Claiming and finishing tasks both check account state; disabling and completion serialize on the user row.

`GET /api/tasks/{id}/live` returns the latest execution snapshot to its owner or an administrator. `GET /api/tasks/{id}/events` streams snapshots over authenticated SSE, rechecking access on each event. It includes output, reasoning, per-second token estimates, reported usage/cache values, timing, response status, received bytes/chunks and recent SSE payloads. Authorization headers and upstream credentials are excluded. Snapshots are persisted during execution and remain available after reconnecting or stopping. The browser connects directly to the backend for SSE. Partial token estimates are labelled separately from upstream-reported usage.

The server starts a Tokio Task alongside Axum. It claims due jobs in PostgreSQL with `FOR UPDATE SKIP LOCKED`, runs OpenAI Responses API tests, and saves reports and execution status in the same transaction. Timeouts and interrupted jobs are recorded as failures.

`POST /api/tasks` accepts `execution_mode` as `immediate`, `delayed` with a positive `delay_ms`, or `scheduled` with a future RFC 3339 `scheduled_for`. The web form provides a duration picker for delayed execution and a date/time picker in the browser's local timezone for a one-time scheduled execution; timestamps are submitted in UTC.

`POST /api/tasks/{id}/retry` requeues the owner's failed task for immediate execution, preserving its channel, model, prompt and reasoning settings. It clears the prior error and execution timestamps. The channel must be available and enabled. Concurrent retries serialize on the task, and requests for a queued, running or completed task return HTTP 409.

## Channel Models

`POST /api/channels/models/discover` accepts a bearer token and a JSON body with `base_url` and `api_key`. It returns model IDs from the upstream OpenAI-compatible `/models` endpoint as `{ "models": [...] }`. During editing, send `channel_id` and leave `api_key` empty to reuse the saved key for the same address. Saving the channel stores the selected `models` and its default `model`.

`POST /api/channels/test` accepts the same draft channel credentials and checks connectivity without saving a channel. It returns `ok`, the upstream HTTP `status`, and `latency_ms`. Both draft and saved-channel connection tests use the upstream `/models` endpoint.

## Production Deployment

Run `docker compose up -d --build` from `cloud/`; no `.env` is required. A one-shot initialization service generates independent random database, JWT and encryption secrets in the persistent `runtime_secrets` volume. PostgreSQL and Axum read their secret files from a read-only mount. Existing `.env` values take precedence; importing an older installation preserves its JWT-based encryption fallback. An existing database without its original password stops initialization instead of resetting data. Back up the secrets volume alongside PostgreSQL and any custom `.env`.

The Compose project name is `aijiance-cloud`, preserving container and volume names independently of the checkout directory. Open `http://SERVER_IP:6600`; the browser derives the API host from the current page and uses port `6601`. Copy `.env.example` to `.env` only when overriding ports, configuring an external database or assigning a custom public API domain.

The web service publishes port `6600` and serves static files only. The Axum backend publishes port `6601` (container port `6601`). Browsers and desktop clients call the backend directly; Nginx does not proxy APIs or SSE; report pages are Vue routes. PostgreSQL stores reports and Redis provides caching. There is no object-storage service.

The frontend URL is learned from the first authenticated administrator browser session and persisted in site settings. Administrators can update it under Management Center → Site Settings → Site Address; the server does not read `PUBLIC_BASE_URL`. Before a site URL has been saved, report APIs return relative page paths. The desktop client's Cloud API address must use the backend port. The client preserves the configured API host, port and path; it does not rewrite addresses for any particular deployment. Existing frontend report/share links now load Vue and fetch JSON from the backend.

`SERVER_PORT` and `WEB_PORT` configure host port publishing. Set the public API URL with `WEB_API_BASE_URL`, e.g. `https://api.example.com`. The frontend site address is managed through the web UI. The backend receives this API address as `API_PUBLIC_BASE_URL` for OAuth callbacks. The web container generates an uncached `app-config.js` at startup, so changing `.env` requires container recreation, not an image rebuild. An explicit HTTPS API URL never acquires a Docker port. Vite development reads the same `cloud/.env` API address. Nginx serves static files only.

Keep release staging under `.deploy/releases/`, database backups under `.deploy/backups/`, and one previous known-good release under `.deploy/rollback/previous/`. Remove obsolete staging after verification. Do not create temporary release directories directly under `/root` or clean up other projects' resources.

## Local Development

Deployment configuration is centralized in `cloud/.env.example` with Chinese comments; see `cloud/README.md`. For native development copy that example to `cloud/.env`, set local `DATABASE_URL`, `JWT_SECRET`, and the public API URL, then start from `cloud` with `cargo run --manifest-path server/Cargo.toml`. The first registered account becomes super administrator. Run the check commands below from `cloud/server`. `config/default.toml` supplies defaults, `APP_ENV=prod` merges `config/prod.toml`, and environment variables take precedence. The TOML files are embedded at compile time. Report URLs use the site address saved in PostgreSQL; fresh installations learn it from an administrator browser login.

```sh
cargo run --locked
cargo fmt --all -- --check
cargo test --locked
```

Use a disposable PostgreSQL database for the HTTP contract test. It applies migrations and writes test records.

```sh
TEST_DATABASE_URL=postgres://localhost/aijiance_test cargo test --locked --test http_contract -- --ignored
```
