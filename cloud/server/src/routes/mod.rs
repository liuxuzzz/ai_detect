use crate::{
    handlers::{
        admin, auth, dashboard, identity, prompts, reports, site_settings, task_live, tasks,
        upstreams,
    },
    middleware,
    state::AppState,
};
use axum::{
    extract::DefaultBodyLimit,
    routing::{delete, get, patch, post, put},
    Router,
};

mod web;
pub use web::application;

pub fn router(state: AppState) -> Router {
    middleware::apply(
        Router::new()
            .route("/health", get(health))
            .nest("/api", api_routes())
            .fallback(not_found)
            .with_state(state),
    )
}

fn api_routes() -> Router<AppState> {
    Router::new()
        .nest("/auth", auth_routes())
        .nest("/reports", report_routes())
        .route("/dashboard", get(dashboard::dashboard))
        .route("/public/rankings", get(dashboard::public_rankings))
        .nest("/channels", upstream_routes())
        .nest("/upstreams", upstream_routes())
        .route("/tasks", get(tasks::list).post(tasks::create))
        .route("/tasks/{id}", delete(tasks::delete))
        .route("/tasks/{id}/retry", post(tasks::retry))
        .route("/tasks/{id}/live", get(task_live::snapshot))
        .route("/tasks/{id}/events", get(task_live::events))
        .route("/prompts", get(prompts::available))
        .nest("/admin", admin_routes())
        .route("/public/reports/{slug}", get(reports::report))
        .route("/public/shares/{token}", get(reports::share))
        .layer(DefaultBodyLimit::max(32 * 1024 * 1024))
        .fallback(not_found)
}

async fn not_found() -> crate::error::AppError {
    crate::error::err(crate::error::ErrorKind::NotFound, "API 不存在")
}

async fn health() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({"status": "ok"}))
}

fn auth_routes() -> Router<AppState> {
    Router::new()
        .route("/register", post(auth::register))
        .route("/options", get(identity::options))
        .route("/email-code", post(identity::send_code))
        .route("/password/reset", post(identity::reset_password))
        .route("/oauth/exchange", post(identity::oauth_exchange))
        .route("/oauth/{provider}/start", get(identity::oauth_start))
        .route("/oauth/{provider}/callback", get(identity::oauth_callback))
        .route("/registration", get(site_settings::registration))
        .route("/login", post(auth::login))
        .route("/me", get(auth::me))
        .route(
            "/report-visibility",
            get(auth::report_visibility).put(auth::update_report_visibility),
        )
        .route("/password", put(auth::change_password))
        .route("/client-keys", get(auth::list_keys).post(auth::create_key))
        .route(
            "/client-keys/{id}",
            get(auth::reveal_key).delete(auth::revoke_key),
        )
}

fn report_routes() -> Router<AppState> {
    Router::new()
        .route("/aggregate", get(dashboard::dashboard))
        .route("/upload", post(reports::upload))
        .route("/{id}", delete(reports::delete))
        .route("/{id}/details", get(reports::details))
        .route(
            "/{id}/ranking-visibility",
            put(reports::update_ranking_visibility),
        )
        .route(
            "/{id}/comments",
            get(reports::public_comments).post(reports::add_comment),
        )
        .route("/{id}/rating", post(reports::add_rating))
        .route("/{id}/share", post(reports::create_share))
}

fn upstream_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(upstreams::list).post(upstreams::add))
        .route("/models/discover", post(upstreams::discover_models))
        .route("/test", post(upstreams::test_draft))
        .route("/{id}", put(upstreams::update).delete(upstreams::delete))
        .route("/{id}/models/sync", post(upstreams::sync_models))
        .route("/{id}/test", post(upstreams::test))
}

fn admin_routes() -> Router<AppState> {
    Router::new()
        .route(
            "/auth-settings",
            get(identity::settings).put(identity::update_settings),
        )
        .route("/auth-settings/test-mail", post(identity::test_mail))
        .route(
            "/settings",
            get(site_settings::get).put(site_settings::update),
        )
        .route("/users", get(admin::users))
        .route("/users/{id}", patch(admin::patch_user))
        .route("/reports", get(admin::reports))
        .route("/reports/{id}", delete(admin::delete_report))
        .route("/tasks", get(admin::tasks))
        .route("/tasks/{id}", delete(admin::delete_task))
        .route("/tasks/{id}/control", post(admin::control_task))
        .route("/prompts", get(prompts::list).post(prompts::create))
        .route(
            "/prompts/{id}",
            put(prompts::update).delete(prompts::delete),
        )
}
