# Cloud Development

- After completing Cloud changes and relevant validation, automatically deploy to the development environment configured in the repository root's `.deploy/development.toml`. Do not request separate deployment confirmation unless the user explicitly asks to defer deployment. This local profile must remain ignored by Git; never hardcode a personal host, domain or checkout path in published source, tests or documentation.
- Keep deployment work inside the configured project root: stage releases in `.deploy/releases/`, keep database backups in `.deploy/backups/`, and retain one previous known-good release in `.deploy/rollback/previous/`. Remove obsolete staging after successful verification.
- Build versioned server and web images before switching services. Preserve production environment values and data volumes, and retain the previous images and Compose override for rollback. Keep the Compose project name `aijiance-cloud` to reuse its existing PostgreSQL and Redis volumes.
- Limit cleanup to this project's artifacts. Do not modify other projects' files, containers, images or volumes.
- Publish the Vue frontend on port `8080` and Axum's JSON API on port `8081` by default. Client uploads, browser API calls and SSE connect directly to Axum. Report/share pages belong to Vue and fetch JSON. Nginx serves static files only; do not add API proxy routes.
- The frontend URL lives in site settings and is learned from the first authenticated administrator browser session; do not require `PUBLIC_BASE_URL`. `WEB_API_BASE_URL` configures the external API address. Public examples use loopback IPs and ports, or reserved example domains for optional custom domains.
- Verify write operations with isolated test data. After deployment, check service health, the published frontend and changed endpoints. Restore the previous release if verification fails.
- Report deployment and validation results, including any failure that prevents publishing changes.
