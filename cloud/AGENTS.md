# Cloud Development

- The user manages deployments. Complete validation and publish requested code/releases to GitHub; do not redeploy an existing instance unless the user explicitly requests it. Keep any private build/test host configuration in the ignored repository-root `.deploy/development.toml`; never hardcode a personal host, domain or checkout path in published source, tests or documentation.
- Keep deployment work inside the configured project root: stage releases in `.deploy/releases/`, keep database backups in `.deploy/backups/`, and retain one previous known-good release in `.deploy/rollback/previous/`. Remove obsolete staging after successful verification.
- Build a versioned application image before switching services. Preserve production environment values and data volumes, and retain the previous images and Compose override for rollback. Keep the Compose project name `aijiance-cloud` to reuse its existing PostgreSQL and Redis volumes.
- Limit cleanup to this project's artifacts. Do not modify other projects' files, containers, images or volumes.
- Build Vue assets and Axum into the single application image defined by `cloud/Dockerfile`. Publish one application port, `6600` by default. Axum serves Vue pages/static assets and JSON `/api` routes from the same origin; client uploads and SSE use that same site address. PostgreSQL and Redis remain internal Compose services.
- Do not require a deployment API URL or a separate API domain. OAuth callback and report links use the site address stored in PostgreSQL, learned from the first administrator browser login. The client accepts the browser's site address. Keep SPA fallback separate from JSON API errors.
- Verify write operations with isolated test data. After deployment, check service health, the published frontend and changed endpoints. Restore the previous release if verification fails.
- Report deployment and validation results, including any failure that prevents publishing changes.
