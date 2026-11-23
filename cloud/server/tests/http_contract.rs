use aijiance_cloud::{config::Settings, routes, state::AppState};
use axum::{
    body::{to_bytes, Body},
    http::{header, Method, Request, StatusCode},
    response::Response,
    Router,
};
use serde_json::{json, Value};
use std::env;
use tower::ServiceExt;

#[path = "cases/identity.rs"]
mod identity;
#[path = "cases/registration.rs"]
mod registration;
#[path = "cases/site_address.rs"]
mod site_address;
#[path = "cases/task_management.rs"]
mod task_management;
#[path = "cases/upload_policy.rs"]
mod upload_policy;

async fn request(
    app: &Router,
    method: Method,
    path: &str,
    auth: Option<(&str, &str)>,
    body: Option<Value>,
) -> Response {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header(header::ORIGIN, "http://localhost:6600");
    if let Some((name, value)) = auth {
        request = request.header(name, value);
    }
    let body = if let Some(value) = body {
        request = request.header(header::CONTENT_TYPE, "application/json");
        Body::from(value.to_string())
    } else {
        Body::empty()
    };
    app.clone()
        .oneshot(request.body(body).unwrap())
        .await
        .unwrap()
}

async fn text(response: Response, expected: StatusCode) -> String {
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    let body = String::from_utf8(bytes.to_vec()).unwrap();
    assert_eq!(status, expected, "{body}");
    body
}

async fn json_body(response: Response, expected: StatusCode) -> Value {
    serde_json::from_str(&text(response, expected).await).unwrap()
}

async fn check_client_key_lifecycle(app: &Router, admin: (&str, &str), admin_key: &Value) {
    let path = "/api/auth/client-keys";
    let response = request(app, Method::GET, path, Some(admin), None).await;
    assert_eq!(
        response.headers()[header::CACHE_CONTROL],
        "private, no-store"
    );
    let listed = json_body(response, StatusCode::OK).await;
    assert_eq!(listed[0]["id"], admin_key["id"]);
    assert!(listed[0].get("key").is_none());
    assert!(listed[0].get("key_hash").is_none());
    assert!(listed[0]["revoked_at"].is_null());

    let credentials = json!({
        "email": format!("key-owner-{}@example.test", rand::random::<u64>()),
        "password": "local-test-password"
    });
    let register = request(
        app,
        Method::POST,
        "/api/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    json_body(register, StatusCode::OK).await;
    let login = request(
        app,
        Method::POST,
        "/api/auth/login",
        None,
        Some(credentials),
    )
    .await;
    let login = json_body(login, StatusCode::OK).await;
    assert_eq!(login["user"]["is_admin"], false);
    let bearer = format!("Bearer {}", login["token"].as_str().unwrap());
    let member = Some(("authorization", bearer.as_str()));
    let list = request(app, Method::GET, path, member, None).await;
    assert_eq!(json_body(list, StatusCode::OK).await, json!([]));
    let created = request(app, Method::POST, path, member, None).await;
    assert_eq!(
        created.headers()[header::CACHE_CONTROL],
        "private, no-store"
    );
    let created = json_body(created, StatusCode::OK).await;
    let secret = created["key"].as_str().unwrap();
    assert!(secret.starts_with(created["prefix"].as_str().unwrap()));
    let item_path = format!("{path}/{}", created["id"].as_i64().unwrap());
    let revealed = request(app, Method::GET, &item_path, member, None).await;
    assert_eq!(
        revealed.headers()[header::CACHE_CONTROL],
        "private, no-store"
    );
    assert_eq!(json_body(revealed, StatusCode::OK).await["key"], secret);
    let foreign = request(app, Method::GET, &item_path, Some(admin), None).await;
    assert_eq!(foreign.status(), StatusCode::NOT_FOUND);

    let foreign = request(app, Method::DELETE, &item_path, Some(admin), None).await;
    assert_eq!(foreign.status(), StatusCode::NOT_FOUND);
    let list = request(app, Method::GET, path, Some(admin), None).await;
    assert_eq!(json_body(list, StatusCode::OK).await, listed);
    let forbidden = request(app, Method::GET, "/api/admin/users", member, None).await;
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    let upload = || {
        request(
            app,
            Method::POST,
            "/api/reports/upload",
            Some(("x-client-key", secret)),
            Some(json!({
                "data": {"version": 1, "output": "key lifecycle fixture"},
                "api_domain": "example.test",
                "model": "review-model"
            })),
        )
    };
    json_body(upload().await, StatusCode::OK).await;
    let revoked = request(app, Method::DELETE, &item_path, member, None).await;
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);
    assert_eq!(upload().await.status(), StatusCode::UNAUTHORIZED);
    let revealed = request(app, Method::GET, &item_path, member, None).await;
    assert_eq!(revealed.status(), StatusCode::NOT_FOUND);
    let list = request(app, Method::GET, path, member, None).await;
    let listed = json_body(list, StatusCode::OK).await;
    assert_eq!(listed[0]["id"], created["id"]);
    assert!(listed[0]["revoked_at"].is_string());
    assert!(listed[0].get("key").is_none());

    let item_path = format!("{path}/{}", admin_key["id"].as_i64().unwrap());
    let revoked = request(app, Method::DELETE, &item_path, Some(admin), None).await;
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
#[ignore = "requires an isolated PostgreSQL database at TEST_DATABASE_URL"]
async fn report_workflow_and_route_compatibility() {
    let mut email = format!("review-{}@example.test", rand::random::<u64>());
    let password = "local-test-password";
    let settings = Settings {
        database_url: env::var("TEST_DATABASE_URL").expect("set TEST_DATABASE_URL"),
        database_pool_size: 2,
        jwt_secret: "local-test-jwt".into(),
        client_key_encryption_secret: Some("isolated-client-key-test-secret".into()),
        bind_address: "127.0.0.1:0".parse().unwrap(),
        redis_url: "disabled".into(),
        task_daily_limit: 20,
        api_public_url: "http://localhost:6601".into(),
    };
    let app = routes::router(AppState::from_settings(&settings).await.unwrap());
    let initial = request(&app, Method::GET, "/api/auth/options", None, None).await;
    assert_eq!(
        json_body(initial, StatusCode::OK).await["bootstrap_required"],
        true
    );
    let competitor = format!("first-race-{}@example.test", rand::random::<u64>());
    let (first, second) = tokio::join!(
        request(
            &app,
            Method::POST,
            "/api/auth/register",
            None,
            Some(json!({"email":email,"password":password}))
        ),
        request(
            &app,
            Method::POST,
            "/api/auth/register",
            None,
            Some(json!({"email":competitor,"password":password}))
        ),
    );
    let first = json_body(first, StatusCode::OK).await;
    let second = json_body(second, StatusCode::OK).await;
    assert_ne!(
        first["is_superadmin"], second["is_superadmin"],
        "Only one concurrent first signup becomes superadmin"
    );
    if second["is_superadmin"] == true {
        email = competitor;
    }

    let health = request(&app, Method::GET, "/health", None, None).await;
    assert_eq!(
        json_body(health, StatusCode::OK).await,
        json!({"status": "ok"})
    );
    let login = request(
        &app,
        Method::POST,
        "/api/auth/login",
        None,
        Some(json!({"email": email, "password": password})),
    )
    .await;
    let login = json_body(login, StatusCode::OK).await;
    assert_eq!(login["user"]["is_admin"], true);
    let bearer = format!("Bearer {}", login["token"].as_str().unwrap());
    let admin = ("authorization", bearer.as_str());
    let authorized = Some(admin);

    registration::check(&app, &settings, &email, password, admin).await;

    let missing = request(&app, Method::GET, "/api/admin/users", None, None).await;
    assert_eq!(
        json_body(missing, StatusCode::UNAUTHORIZED).await["error"],
        "缺少登录令牌"
    );
    let client_key = request(
        &app,
        Method::POST,
        "/api/auth/client-keys",
        authorized,
        None,
    )
    .await;
    let client_key = json_body(client_key, StatusCode::OK).await;

    site_address::check(
        &app,
        &settings,
        admin,
        &email,
        client_key["key"].as_str().unwrap(),
    )
    .await;

    let data = json!({"version": 1, "output": "<p>raw model output</p>",
        "prompt": "render fixture", "samples": [{"seconds": 0.0, "tps": 0.0}, {"seconds": 1.25, "tps": 8.0}],
        "activities": [{"kind": "thinking", "content": "plan"}], "retries": []});
    // Invalid uploads must not create reports.
    for invalid in [
        json!({"html": "<html>old document</html>", "api_domain": "example.test", "model": "old"}),
        json!({"data": {"version": 2}, "api_domain": "example.test", "model": "future"}),
        json!({"data": {"samples": [{"seconds": 1, "tps": -2}]}, "api_domain": "example.test", "model": "invalid"}),
        json!({"data": {"samples": [{"seconds": 2, "tps": 3}, {"seconds": 1, "tps": 4}]}, "api_domain": "example.test", "model": "unordered"}),
    ] {
        let response = request(
            &app,
            Method::POST,
            "/api/reports/upload",
            Some(("x-client-key", client_key["key"].as_str().unwrap())),
            Some(invalid),
        )
        .await;
        assert!(json_body(response, StatusCode::BAD_REQUEST).await["error"].is_string());
    }
    let upload = request(
        &app,
        Method::POST,
        "/api/reports/upload",
        Some(("x-client-key", client_key["key"].as_str().unwrap())),
        Some(
            json!({"data": data, "api_domain": "Example.test", "model": "review-model",
            "metadata": {"ttft_ms": 1250, "total_tokens": 23, "tokens_per_second": 8,
                         "cache_read_tokens": null, "cache_write_tokens": 0}}),
        ),
    )
    .await;
    let uploaded = json_body(upload, StatusCode::OK).await;
    let id = uploaded["id"].as_i64().unwrap();
    let slug = uploaded["slug"].as_str().unwrap();
    let dashboard = request(&app, Method::GET, "/api/dashboard", authorized, None).await;
    let dashboard = json_body(dashboard, StatusCode::OK).await;
    assert_eq!(dashboard["items"][0]["slug"], slug);
    let details_path = format!("/api/reports/{id}/details");
    let rating_path = format!("/api/reports/{id}/rating");

    for score in [2, 5] {
        let rating = request(
            &app,
            Method::POST,
            &rating_path,
            authorized,
            Some(json!({"score": score})),
        )
        .await;
        let rating = json_body(rating, StatusCode::OK).await;
        assert_eq!(rating["score"], score);
        assert_eq!(rating["rating_count"], 1);
    }
    let details = request(&app, Method::GET, &details_path, authorized, None).await;
    assert_eq!(
        details.headers()[header::CACHE_CONTROL],
        "private, no-store"
    );
    let details = json_body(details, StatusCode::OK).await;
    assert_eq!(details["metrics"]["ttft_ms"].as_f64(), Some(1250.0));
    assert_eq!(details["metrics"]["total_tokens"].as_f64(), Some(23.0));
    assert!(details["metrics"]["cache_read_tokens"].is_null());
    assert_eq!(details["metrics"]["cache_write_tokens"].as_f64(), Some(0.0));
    assert!(details["metrics"]["cache_hit_rate"].is_null());
    assert_eq!(details["my_score"], 5);
    assert_eq!(details["data"]["output"], "<p>raw model output</p>");
    assert_eq!(details["data"]["samples"], data["samples"]);
    assert!(details.get("html").is_none());
    assert_eq!(
        uploaded["owner_url"],
        format!("http://localhost:6600/r/{slug}")
    );
    let anonymous = request(&app, Method::GET, &details_path, None, None).await;
    assert!(json_body(anonymous, StatusCode::OK).await["my_score"].is_null());

    let share = request(
        &app,
        Method::POST,
        &format!("/api/reports/{id}/share"),
        authorized,
        Some(json!({"allow_any_iframe": true})),
    )
    .await;
    let share = json_body(share, StatusCode::OK).await;
    let share_token = share["token"].as_str().unwrap();
    assert_eq!(
        share["url"],
        format!("http://localhost:6600/share/{share_token}")
    );
    let response = request(
        &app,
        Method::GET,
        &format!("/api/public/reports/{slug}"),
        None,
        None,
    )
    .await;
    assert!(response.headers()[header::CONTENT_TYPE]
        .to_str()
        .unwrap()
        .starts_with("application/json"));
    assert_eq!(
        json_body(response, StatusCode::OK).await["data"],
        details["data"]
    );
    let response = request(
        &app,
        Method::GET,
        &format!("/api/public/shares/{share_token}"),
        None,
        None,
    )
    .await;
    let shared = json_body(response, StatusCode::OK).await;
    assert_eq!(shared["report"]["data"], details["data"]);
    assert_eq!(shared["sharing"]["allow_any_iframe"], true);
    let expired = request(
        &app,
        Method::POST,
        &format!("/api/reports/{id}/share"),
        authorized,
        Some(json!({"expires_at": "2000-01-01T00:00:00Z"})),
    )
    .await;
    let expired = json_body(expired, StatusCode::OK).await;
    let response = request(
        &app,
        Method::GET,
        &format!("/api/public/shares/{}", expired["token"].as_str().unwrap()),
        None,
        None,
    )
    .await;
    assert_eq!(
        json_body(response, StatusCode::GONE).await["error"],
        "分享已过期"
    );
    for path in [
        format!("/r/{slug}"),
        format!("/share/{share_token}"),
        "/static/report_chart.js".into(),
    ] {
        let response = request(&app, Method::GET, &path, None, None).await;
        assert!(json_body(response, StatusCode::NOT_FOUND).await["error"].is_string());
    }

    let discover_path = "/api/channels/models/discover";
    let local_target = json!({"base_url": "http://127.0.0.1:1/v1", "api_key": "fixture-key"});
    for (credentials, expected) in [
        (None, StatusCode::UNAUTHORIZED),
        (authorized, StatusCode::BAD_REQUEST),
    ] {
        let result = request(
            &app,
            Method::POST,
            discover_path,
            credentials,
            Some(local_target.clone()),
        )
        .await;
        assert_eq!(result.status(), expected);
    }

    let mut channel_input = json!({
        "name": "Fixture", "base_url": "https://example.test/v1", "api_key": "fixture-key",
        "model": "selected-default", "models": ["selected-first", "selected-default", " selected-first "],
    });
    let upstream = request(
        &app,
        Method::POST,
        "/api/channels",
        authorized,
        Some(channel_input.clone()),
    )
    .await;
    let upstream = json_body(upstream, StatusCode::OK).await;
    let upstream_id = upstream["id"].as_i64().unwrap();
    let upstream_path = format!("/api/channels/{upstream_id}");
    for (credentials, payload, expected) in [
        (
            None,
            json!({"base_url": "http://127.0.0.1:1/v1"}),
            StatusCode::UNAUTHORIZED,
        ),
        (
            authorized,
            json!({"base_url": "http://127.0.0.1:1/v1"}),
            StatusCode::BAD_REQUEST,
        ),
        (
            authorized,
            json!({"base_url": "https://other.example.test/v1", "channel_id": upstream_id}),
            StatusCode::BAD_REQUEST,
        ),
        (
            authorized,
            json!({"base_url": "https://example.test/v1", "channel_id": -1}),
            StatusCode::NOT_FOUND,
        ),
    ] {
        let tested = request(
            &app,
            Method::POST,
            "/api/channels/test",
            credentials,
            Some(payload),
        )
        .await;
        assert_eq!(tested.status(), expected);
    }
    let changed_target = request(
        &app,
        Method::POST,
        discover_path,
        authorized,
        Some(json!({
            "channel_id": upstream_id, "base_url": "https://other.example.test/v1",
        })),
    )
    .await;
    assert_eq!(changed_target.status(), StatusCode::BAD_REQUEST);

    channel_input["api_key"] = json!("");
    channel_input["model"] = json!("unselected-default");
    let rejected = request(
        &app,
        Method::PUT,
        &upstream_path,
        authorized,
        Some(channel_input.clone()),
    )
    .await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);

    channel_input["model"] = json!("selected-first");
    let updated = request(
        &app,
        Method::PUT,
        &upstream_path,
        authorized,
        Some(channel_input),
    )
    .await;
    assert_eq!(json_body(updated, StatusCode::OK).await["ok"], true);
    let channels = request(&app, Method::GET, "/api/channels", authorized, None).await;
    let channels = json_body(channels, StatusCode::OK).await;
    let channel = channels
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == upstream_id)
        .unwrap();
    assert_eq!(
        channel["models"],
        json!(["selected-first", "selected-default"])
    );
    assert_eq!(channel["model"], "selected-first");
    let task = request(
        &app,
        Method::POST,
        "/api/tasks",
        authorized,
        Some(json!({"upstream_id": upstream_id})),
    )
    .await;
    let task = json_body(task, StatusCode::OK).await;
    let tasks = request(&app, Method::GET, "/api/tasks", authorized, None).await;
    let tasks = json_body(tasks, StatusCode::OK).await;
    let queued = tasks
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == task["id"])
        .unwrap();
    assert_eq!(queued["prompt_name"], "鹈鹕测试");
    assert_eq!(queued["model"], "selected-first");
    let future =
        chrono::DateTime::from_timestamp(chrono::Utc::now().timestamp() + 3600, 0).unwrap();
    for (mode, schedule) in [
        ("delayed", json!({"delay_ms": 60000})),
        ("scheduled", json!({"scheduled_for": future})),
    ] {
        let mut payload = schedule;
        payload["upstream_id"] = json!(upstream_id);
        payload["execution_mode"] = json!(mode);
        let submitted_at = chrono::Utc::now();
        let created = request(&app, Method::POST, "/api/tasks", authorized, Some(payload)).await;
        let created = json_body(created, StatusCode::OK).await;
        assert_eq!(created["status"], "queued");
        let when = chrono::DateTime::parse_from_rfc3339(created["scheduled_for"].as_str().unwrap())
            .unwrap();
        if mode == "delayed" {
            assert!(when >= submitted_at + chrono::Duration::minutes(1));
            assert!(when < chrono::Utc::now() + chrono::Duration::minutes(1));
        } else {
            assert_eq!(when, future);
        }
        let listed = request(&app, Method::GET, "/api/tasks", authorized, None).await;
        let listed = json_body(listed, StatusCode::OK).await;
        let queued = listed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == created["id"])
            .unwrap();
        assert_eq!(queued["execution_mode"], mode);
        assert_eq!(queued["scheduled_for"], created["scheduled_for"]);
    }
    let rejected = request(&app, Method::POST, "/api/tasks", authorized,
        Some(json!({"upstream_id": upstream_id, "execution_mode": "scheduled", "scheduled_for": "2020-01-01T00:00:00Z"}))).await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    let invalid_prompt = request(
        &app,
        Method::POST,
        "/api/tasks",
        authorized,
        Some(json!({"upstream_id": upstream_id, "prompt_kind": "custom", "prompt_text": " "})),
    )
    .await;
    assert_eq!(invalid_prompt.status(), StatusCode::BAD_REQUEST);

    check_task_retry(&app, &settings.database_url, admin, upstream_id).await;
    task_management::check(&app, &settings, admin).await;
    check_own_deletion(&app, &settings.database_url, admin, id).await;

    for path in [
        "/api/dashboard",
        "/api/reports/aggregate",
        "/api/channels",
        "/api/upstreams",
        "/api/tasks",
    ] {
        let response = request(&app, Method::GET, path, authorized, None).await;
        json_body(response, StatusCode::OK).await;
    }
    let removed = request(
        &app,
        Method::DELETE,
        &format!("/api/upstreams/{upstream_id}"),
        authorized,
        None,
    )
    .await;
    assert_eq!(json_body(removed, StatusCode::OK).await["ok"], true);

    check_client_key_lifecycle(&app, admin, &client_key).await;
    upload_policy::check(&app, &settings, admin).await;
    identity::check(&app, &settings, admin, &email).await;
    check_password_changes(&app, &settings, &email, admin).await;
}

async fn member_session(app: &Router, purpose: &str) -> (String, String) {
    let email = format!("{purpose}-{}@example.test", rand::random::<u64>());
    let credentials = json!({"email": email, "password": "local-test-password"});
    let created = request(
        app,
        Method::POST,
        "/api/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    json_body(created, StatusCode::OK).await;
    let login = request(
        app,
        Method::POST,
        "/api/auth/login",
        None,
        Some(credentials),
    )
    .await;
    let login = json_body(login, StatusCode::OK).await;
    (
        email,
        format!("Bearer {}", login["token"].as_str().unwrap()),
    )
}

async fn check_own_deletion(
    app: &Router,
    database_url: &str,
    admin: (&str, &str),
    admin_report: i64,
) {
    let (_, bearer) = member_session(app, "delete").await;
    let member = Some(("authorization", bearer.as_str()));
    let key = request(app, Method::POST, "/api/auth/client-keys", member, None).await;
    let key = json_body(key, StatusCode::OK).await;
    let uploaded = request(app, Method::POST, "/api/reports/upload",
        Some(("x-client-key", key["key"].as_str().unwrap())),
        Some(json!({"data": {"version": 1, "output": "delete fixture"}, "api_domain": "delete.example.test", "model": "delete-model"}))).await;
    let uploaded = json_body(uploaded, StatusCode::OK).await;
    let report_id = uploaded["id"].as_i64().unwrap();
    let report_path = format!("/api/reports/{report_id}");
    for (auth, expected) in [
        (None, StatusCode::UNAUTHORIZED),
        (Some(admin), StatusCode::NOT_FOUND),
    ] {
        let removed = request(app, Method::DELETE, &report_path, auth, None).await;
        assert_eq!(removed.status(), expected);
    }
    let foreign = request(
        app,
        Method::DELETE,
        &format!("/api/reports/{admin_report}"),
        member,
        None,
    )
    .await;
    assert_eq!(foreign.status(), StatusCode::NOT_FOUND);
    let share = request(
        app,
        Method::POST,
        &format!("{report_path}/share"),
        member,
        Some(json!({})),
    )
    .await;
    let share = json_body(share, StatusCode::OK).await;

    let channel = request(app, Method::POST, "/api/channels", member, Some(json!({
        "name": "Delete fixture", "base_url": "https://example.test/v1", "api_key": "fixture-key",
        "model": "delete-model", "enabled": true,
    }))).await;
    let channel = json_body(channel, StatusCode::OK).await;
    let (db, connection) = tokio_postgres::connect(database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection_task = tokio::spawn(async move { connection.await.unwrap() });
    for status in ["queued", "failed", "completed", "running"] {
        let created = request(app, Method::POST, "/api/tasks", member,
            Some(json!({"upstream_id": channel["id"], "execution_mode": "delayed", "delay_ms": 60000}))).await;
        let task = json_body(created, StatusCode::OK).await;
        let task_id = task["id"].as_i64().unwrap();
        let path = format!("/api/tasks/{task_id}");
        db.execute(
            "UPDATE async_tasks SET status=$1,report_id=$2 WHERE id=$3",
            &[&status, &report_id, &task_id],
        )
        .await
        .unwrap();
        for (auth, expected) in [
            (None, StatusCode::UNAUTHORIZED),
            (Some(admin), StatusCode::NOT_FOUND),
        ] {
            let removed = request(app, Method::DELETE, &path, auth, None).await;
            assert_eq!(removed.status(), expected);
        }
        if status == "running" {
            let removed = request(app, Method::DELETE, &path, member, None).await;
            assert_eq!(removed.status(), StatusCode::CONFLICT);
            db.execute(
                "UPDATE async_tasks SET status='completed' WHERE id=$1",
                &[&task_id],
            )
            .await
            .unwrap();
        }
        let removed = request(app, Method::DELETE, &path, member, None).await;
        assert_eq!(removed.status(), StatusCode::NO_CONTENT);
        let missing = request(app, Method::DELETE, &path, member, None).await;
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    }
    let listed = request(app, Method::GET, "/api/tasks", member, None).await;
    assert_eq!(json_body(listed, StatusCode::OK).await, json!([]));
    let visible = request(
        app,
        Method::GET,
        &format!("/api/public/reports/{}", uploaded["slug"].as_str().unwrap()),
        None,
        None,
    )
    .await;
    assert_eq!(visible.status(), StatusCode::OK);

    let removed = request(app, Method::DELETE, &report_path, member, None).await;
    assert_eq!(removed.status(), StatusCode::NO_CONTENT);
    for path in [
        format!("/api/public/reports/{}", uploaded["slug"].as_str().unwrap()),
        format!("/api/public/shares/{}", share["token"].as_str().unwrap()),
        format!("{report_path}/details"),
    ] {
        let hidden = request(app, Method::GET, &path, member, None).await;
        assert_eq!(hidden.status(), StatusCode::NOT_FOUND);
    }
    let dashboard = request(app, Method::GET, "/api/dashboard", member, None).await;
    assert_eq!(json_body(dashboard, StatusCode::OK).await["total"], 0);
    let rankings = request(
        app,
        Method::GET,
        "/api/public/rankings?search=delete-model",
        None,
        None,
    )
    .await;
    assert_eq!(
        json_body(rankings, StatusCode::OK).await["items"],
        json!([])
    );
    let removed = request(app, Method::DELETE, &report_path, member, None).await;
    assert_eq!(removed.status(), StatusCode::NOT_FOUND);
    let stored = db
        .query_one(
            "SELECT deleted_at IS NOT NULL FROM reports WHERE id=$1",
            &[&report_id],
        )
        .await
        .unwrap();
    assert!(stored.get::<_, bool>(0));
    drop(db);
    connection_task.await.unwrap();
}

async fn check_password_changes(
    app: &Router,
    settings: &Settings,
    admin_email: &str,
    admin: (&str, &str),
) {
    let (email, member_bearer) = member_session(app, "password").await;
    let new_password = "updated-test-password";
    let password_path = "/api/auth/password";
    for (email, auth) in [
        (email.as_str(), ("authorization", member_bearer.as_str())),
        (admin_email, admin),
    ] {
        let key = request(app, Method::POST, "/api/auth/client-keys", Some(auth), None).await;
        let key = json_body(key, StatusCode::OK).await;
        for (credentials, current, next, expected) in [
            (
                None,
                "local-test-password",
                new_password,
                StatusCode::UNAUTHORIZED,
            ),
            (
                Some(auth),
                "wrong-password",
                new_password,
                StatusCode::BAD_REQUEST,
            ),
            (
                Some(auth),
                "local-test-password",
                "short",
                StatusCode::BAD_REQUEST,
            ),
            (
                Some(auth),
                "local-test-password",
                "local-test-password",
                StatusCode::BAD_REQUEST,
            ),
        ] {
            let rejected = request(
                app,
                Method::PUT,
                password_path,
                credentials,
                Some(json!({"current_password": current, "new_password": next})),
            )
            .await;
            assert_eq!(rejected.status(), expected);
        }
        let changed = request(
            app,
            Method::PUT,
            password_path,
            Some(auth),
            Some(json!({"current_password": "local-test-password", "new_password": new_password})),
        )
        .await;
        assert_eq!(
            changed.headers()[header::CACHE_CONTROL],
            "private, no-store"
        );
        let changed = json_body(changed, StatusCode::OK).await;
        let new_bearer = format!("Bearer {}", changed["token"].as_str().unwrap());
        let new_auth = Some(("authorization", new_bearer.as_str()));
        let old_session = request(app, Method::GET, "/api/auth/me", Some(auth), None).await;
        assert_eq!(old_session.status(), StatusCode::UNAUTHORIZED);
        let stale_change = request(
            app,
            Method::PUT,
            password_path,
            Some(auth),
            Some(json!({"current_password": new_password, "new_password": "another-new-password"})),
        )
        .await;
        assert_eq!(stale_change.status(), StatusCode::UNAUTHORIZED);
        let current = request(app, Method::GET, "/api/auth/me", new_auth, None).await;
        assert_eq!(json_body(current, StatusCode::OK).await["email"], email);
        let revealed = request(
            app,
            Method::GET,
            &format!("/api/auth/client-keys/{}", key["id"]),
            new_auth,
            None,
        )
        .await;
        assert_eq!(json_body(revealed, StatusCode::OK).await["key"], key["key"]);
        let upload = request(app, Method::POST, "/api/reports/upload", Some(("x-client-key", key["key"].as_str().unwrap())),
            Some(json!({"data": {"version": 1, "output": "after password change"}, "api_domain": "password.example.test", "model": "password-model"}))).await;
        json_body(upload, StatusCode::OK).await;

        // Reinitialize with the original bootstrap password, as happens during a deployment/restart.
        let restarted = routes::router(AppState::from_settings(settings).await.unwrap());
        for (password, expected) in [
            ("local-test-password", StatusCode::UNAUTHORIZED),
            (new_password, StatusCode::OK),
        ] {
            let login = request(
                &restarted,
                Method::POST,
                "/api/auth/login",
                None,
                Some(json!({"email": email, "password": password})),
            )
            .await;
            assert_eq!(login.status(), expected);
        }
        let current = request(&restarted, Method::GET, "/api/auth/me", new_auth, None).await;
        assert_eq!(current.status(), StatusCode::OK);
    }
}

async fn check_task_retry(app: &Router, database_url: &str, auth: (&str, &str), upstream_id: i64) {
    let created = request(
        app,
        Method::POST,
        "/api/tasks",
        Some(auth),
        Some(json!({
            "upstream_id": upstream_id, "model": "retry-model", "reasoning_effort": "high",
            "prompt_kind": "custom", "prompt_text": "原始重试提示词\n保持不变",
            "execution_mode": "delayed", "delay_ms": 60000,
        })),
    )
    .await;
    let created = json_body(created, StatusCode::OK).await;
    let id = created["id"].as_i64().unwrap();
    let path = format!("/api/tasks/{id}/retry");
    let (db, connection) = tokio_postgres::connect(database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection_task = tokio::spawn(async move { connection.await.unwrap() });
    db.execute(
        "UPDATE async_tasks SET status='failed',error='fixture failure',started_at=now(),finished_at=now() WHERE id=$1",
        &[&id],
    ).await.unwrap();
    db.execute(
        "UPDATE cloud_upstreams SET enabled=false WHERE id=$1",
        &[&upstream_id],
    )
    .await
    .unwrap();

    let unauthorized = request(app, Method::POST, &path, None, None).await;
    assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
    let missing = request(app, Method::POST, "/api/tasks/-1/retry", Some(auth), None).await;
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    let disabled = request(app, Method::POST, &path, Some(auth), None).await;
    assert_eq!(disabled.status(), StatusCode::BAD_REQUEST);

    let email = format!("retry-{}@example.test", rand::random::<u64>());
    let credentials = json!({"email": email, "password": "retry-test-password"});
    let registered = request(
        app,
        Method::POST,
        "/api/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    json_body(registered, StatusCode::OK).await;
    let login = request(
        app,
        Method::POST,
        "/api/auth/login",
        None,
        Some(credentials),
    )
    .await;
    let login = json_body(login, StatusCode::OK).await;
    let foreign_bearer = format!("Bearer {}", login["token"].as_str().unwrap());
    let forbidden = request(
        app,
        Method::POST,
        &path,
        Some(("authorization", &foreign_bearer)),
        None,
    )
    .await;
    assert_eq!(forbidden.status(), StatusCode::NOT_FOUND);

    db.execute(
        "UPDATE cloud_upstreams SET enabled=true WHERE id=$1",
        &[&upstream_id],
    )
    .await
    .unwrap();
    let submitted_at = chrono::Utc::now();
    let (first, second) = tokio::join!(
        request(app, Method::POST, &path, Some(auth), None),
        request(app, Method::POST, &path, Some(auth), None),
    );
    let (accepted, conflict) = if first.status() == StatusCode::OK {
        (first, second)
    } else {
        (second, first)
    };
    let retried = json_body(accepted, StatusCode::OK).await;
    assert_eq!(conflict.status(), StatusCode::CONFLICT);
    assert_eq!(retried["id"], created["id"]);
    assert_eq!(retried["status"], "queued");
    assert_eq!(retried["execution_mode"], "immediate");
    assert!(retried["error"].is_null());
    let when =
        chrono::DateTime::parse_from_rfc3339(retried["scheduled_for"].as_str().unwrap()).unwrap();
    assert!(when >= submitted_at);
    assert!(when <= chrono::Utc::now());

    let task = db.query_one(
        "SELECT model,reasoning_effort,prompt_name,prompt_text,delay_ms,started_at,finished_at,error,report_id FROM async_tasks WHERE id=$1",
        &[&id],
    ).await.unwrap();
    assert_eq!(task.get::<_, String>(0), "retry-model");
    assert_eq!(task.get::<_, String>(1), "high");
    assert_eq!(task.get::<_, String>(2), "自定义提示词");
    assert_eq!(task.get::<_, String>(3), "原始重试提示词\n保持不变");
    assert_eq!(task.get::<_, i32>(4), 0);
    assert!(task
        .get::<_, Option<chrono::DateTime<chrono::Utc>>>(5)
        .is_none());
    assert!(task
        .get::<_, Option<chrono::DateTime<chrono::Utc>>>(6)
        .is_none());
    assert!(task.get::<_, Option<String>>(7).is_none());
    assert!(task.get::<_, Option<i64>>(8).is_none());
    let listed = request(app, Method::GET, "/api/tasks", Some(auth), None).await;
    let listed = json_body(listed, StatusCode::OK).await;
    let listed = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|task| task["id"] == id)
        .unwrap();
    assert_eq!(listed["status"], "queued");
    assert!(listed["error"].is_null());

    for status in ["queued", "running", "completed"] {
        db.execute(
            "UPDATE async_tasks SET status=$1 WHERE id=$2",
            &[&status, &id],
        )
        .await
        .unwrap();
        let rejected = request(app, Method::POST, &path, Some(auth), None).await;
        assert_eq!(rejected.status(), StatusCode::CONFLICT);
    }
    drop(db);
    connection_task.await.unwrap();
}
