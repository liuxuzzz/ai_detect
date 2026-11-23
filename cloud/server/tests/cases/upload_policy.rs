use super::*;

async fn update(app: &Router, admin: (&str, &str), limit: i64, window: i64) -> Value {
    let response = request(
        app,
        Method::PUT,
        "/api/admin/settings",
        Some(admin),
        Some(json!({"upload_limit": limit, "upload_window_seconds": window})),
    )
    .await;
    let result = json_body(response, StatusCode::OK).await;
    assert_eq!(result["registration_enabled"], true);
    assert_eq!(result["upload_limit"], limit);
    assert_eq!(result["upload_window_seconds"], window);
    result
}

async fn key(app: &Router, bearer: &str) -> String {
    let response = request(
        app,
        Method::POST,
        "/api/auth/client-keys",
        Some(("authorization", bearer)),
        None,
    )
    .await;
    json_body(response, StatusCode::OK).await["key"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn upload(app: &Router, key: &str) -> Response {
    request(
        app,
        Method::POST,
        "/api/reports/upload",
        Some(("x-client-key", key)),
        Some(
            json!({"api_domain":"quota.example.test", "model":"quota-test",
            "data":{"version":1,"source":"cloud","output":"upload quota fixture"}}),
        ),
    )
    .await
}

pub(super) async fn check(app: &Router, settings: &Settings, admin: (&str, &str)) {
    let response = request(app, Method::GET, "/api/admin/settings", Some(admin), None).await;
    let initial = json_body(response, StatusCode::OK).await;
    assert_eq!(initial["upload_limit"], 100);
    assert_eq!(initial["upload_window_seconds"], 86400);
    for invalid in [
        json!({"upload_limit":0}),
        json!({"upload_limit":-1}),
        json!({"upload_limit":1000001}),
        json!({"upload_limit":1.5}),
        json!({"upload_window_seconds":0}),
        json!({"upload_window_seconds":31536001}),
        json!({"upload_limit":"100"}),
        json!({"upload_window_seconds":true}),
    ] {
        let response = request(
            app,
            Method::PUT,
            "/api/admin/settings",
            Some(admin),
            Some(invalid),
        )
        .await;
        assert!(json_body(response, StatusCode::BAD_REQUEST).await["error"].is_string());
    }
    let response = request(app, Method::GET, "/api/admin/settings", Some(admin), None).await;
    assert_eq!(json_body(response, StatusCode::OK).await, initial);
    let (_, bearer) = member_session(app, "quota").await;
    let first_key = key(app, &bearer).await;
    let second_key = key(app, &bearer).await;
    let (_, other_bearer) = member_session(app, "other-quota").await;
    let other_key = key(app, &other_bearer).await;
    update(app, admin, 2, 60).await;
    let first = json_body(upload(app, &first_key).await, StatusCode::OK).await;
    let attempts = tokio::join!(
        upload(app, &first_key),
        upload(app, &second_key),
        upload(app, &first_key)
    );
    let mut successes = 0;
    let mut limited = 0;
    for response in [attempts.0, attempts.1, attempts.2] {
        match response.status() {
            StatusCode::OK => {
                json_body(response, StatusCode::OK).await;
                successes += 1;
            }
            StatusCode::TOO_MANY_REQUESTS => {
                let result = json_body(response, StatusCode::TOO_MANY_REQUESTS).await;
                assert!(result["error"].as_str().unwrap().contains("60 秒最多 2 次"));
                limited += 1;
            }
            _ => panic!("{}", text(response, StatusCode::OK).await),
        }
    }
    assert_eq!(
        (successes, limited),
        (1, 2),
        "Keys share an atomic per-user quota"
    );
    let deleted = request(
        app,
        Method::DELETE,
        &format!("/api/reports/{}", first["id"]),
        Some(("authorization", bearer.as_str())),
        None,
    )
    .await;
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    json_body(upload(app, &first_key).await, StatusCode::TOO_MANY_REQUESTS).await;
    json_body(upload(app, &other_key).await, StatusCode::OK).await;

    let me = request(
        app,
        Method::GET,
        "/api/auth/me",
        Some(("authorization", &bearer)),
        None,
    )
    .await;
    let owner = json_body(me, StatusCode::OK).await["id"].as_i64().unwrap();
    let (db, connection) = tokio_postgres::connect(&settings.database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection = tokio::spawn(async move { connection.await.unwrap() });
    db.execute(
        "UPDATE reports SET created_at=now()-interval '61 seconds' WHERE owner_id=$1",
        &[&owner],
    )
    .await
    .unwrap();
    // A cloud-generated report does not consume the client upload quota.
    db.execute(
        "INSERT INTO reports(owner_id,slug,api_domain,model,metadata,data)
        SELECT owner_id,slug||'-cloud','quota.example.test','cloud-fixture','{}',
        '{\"version\":1,\"source\":\"cloud\"}' FROM reports WHERE id=$1",
        &[&first["id"].as_i64().unwrap()],
    )
    .await
    .unwrap();
    json_body(upload(app, &first_key).await, StatusCode::OK).await;
    // Expanding the window immediately counts previous uploads in that window.
    update(app, admin, 2, 3600).await;
    json_body(upload(app, &first_key).await, StatusCode::TOO_MANY_REQUESTS).await;
    let restarted = routes::router(AppState::from_settings(settings).await.unwrap());
    let response = request(
        &restarted,
        Method::GET,
        "/api/admin/settings",
        Some(admin),
        None,
    )
    .await;
    assert_eq!(
        json_body(response, StatusCode::OK).await["upload_window_seconds"],
        3600
    );
    json_body(
        upload(&restarted, &first_key).await,
        StatusCode::TOO_MANY_REQUESTS,
    )
    .await;
    update(app, admin, 100, 86400).await;
    drop(db);
    connection.await.unwrap();
}
