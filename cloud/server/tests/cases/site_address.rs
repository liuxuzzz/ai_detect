use super::*;

async fn login_from(app: &Router, email: &str, origin: &str) -> Value {
    let request = Request::builder()
        .method(Method::POST)
        .uri("/api/auth/login")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::ORIGIN, origin)
        .body(Body::from(
            json!({"email":email,"password":"local-test-password"}).to_string(),
        ))
        .unwrap();
    json_body(app.clone().oneshot(request).await.unwrap(), StatusCode::OK).await
}

pub(super) async fn check(
    app: &Router,
    settings: &Settings,
    admin: (&str, &str),
    email: &str,
    key: &str,
) {
    let (db, connection) = tokio_postgres::connect(&settings.database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection = tokio::spawn(async move { connection.await.unwrap() });
    let (member, _) = member_session(app, "site-address").await;
    db.execute("UPDATE site_settings SET site_url='' WHERE singleton", &[])
        .await
        .unwrap();
    login_from(app, &member, "https://untrusted.example.test").await;
    let row = db
        .query_one("SELECT site_url FROM site_settings WHERE singleton", &[])
        .await
        .unwrap();
    assert_eq!(
        row.get::<_, String>(0),
        "",
        "Ordinary login must not select the canonical site"
    );
    let upload = || {
        request(
            app,
            Method::POST,
            "/api/reports/upload",
            Some(("x-client-key", key)),
            Some(
                json!({"api_domain":"site.example.test","model":"site-fixture","data":{"version":1,"output":"site fixture"}}),
            ),
        )
    };
    let report = json_body(upload().await, StatusCode::OK).await;
    assert_eq!(
        report["owner_url"],
        format!("/r/{}", report["slug"].as_str().unwrap())
    );
    login_from(app, email, "https://ai.example.test").await;
    login_from(app, email, "https://other.example.test").await;
    let report = json_body(upload().await, StatusCode::OK).await;
    assert_eq!(
        report["owner_url"],
        format!(
            "https://ai.example.test/r/{}",
            report["slug"].as_str().unwrap()
        )
    );
    for invalid in [
        "",
        "javascript:alert(1)",
        "https://user:password@evil.test",
        "https://example.test/?next=bad",
        "https://example.test/#bad",
    ] {
        let response = request(
            app,
            Method::PUT,
            "/api/admin/settings",
            Some(admin),
            Some(json!({"site_url":invalid})),
        )
        .await;
        json_body(response, StatusCode::BAD_REQUEST).await;
    }
    let updated = json_body(
        request(
            app,
            Method::PUT,
            "/api/admin/settings",
            Some(admin),
            Some(json!({"site_url":"https://reports.example.test/"})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["site_url"], "https://reports.example.test");
    let callback = request(
        app,
        Method::GET,
        "/api/auth/oauth/github/callback?state=invalid&code=invalid",
        None,
        None,
    )
    .await;
    assert_eq!(
        callback.headers()[header::LOCATION],
        "https://reports.example.test/auth/callback#error=oauth_failed"
    );
    let share = json_body(
        request(
            app,
            Method::POST,
            &format!("/api/reports/{}/share", report["id"]),
            Some(admin),
            Some(json!({})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    assert!(share["url"]
        .as_str()
        .unwrap()
        .starts_with("https://reports.example.test/share/"));
    let restarted = routes::router(AppState::from_settings(settings).await.unwrap());
    let view = json_body(
        request(
            &restarted,
            Method::GET,
            "/api/admin/settings",
            Some(admin),
            None,
        )
        .await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(view["site_url"], "https://reports.example.test");
    json_body(
        request(
            app,
            Method::PUT,
            "/api/admin/settings",
            Some(admin),
            Some(json!({"site_url":"http://localhost:8080"})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    drop(db);
    connection.await.unwrap();
}
