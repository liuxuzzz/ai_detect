use super::*;

const ADMIN_PATH: &str = "/api/admin/settings";
const PUBLIC_PATH: &str = "/api/auth/registration";

async fn assert_settings(app: &Router, enabled: bool) {
    let response = request(app, Method::GET, PUBLIC_PATH, None, None).await;
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        json_body(response, StatusCode::OK).await,
        json!({"registration_enabled": enabled})
    );
}

async fn set_registration(app: &Router, admin: (&str, &str), enabled: bool) {
    let response = request(
        app,
        Method::PUT,
        ADMIN_PATH,
        Some(admin),
        Some(json!({"registration_enabled": enabled})),
    )
    .await;
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        json_body(response, StatusCode::OK).await,
        json!({"site_url":"http://localhost:6600","registration_enabled": enabled, "upload_limit": 100, "upload_window_seconds": 86400})
    );
    assert_settings(app, enabled).await;
}

pub(super) async fn check(
    app: &Router,
    settings: &Settings,
    admin_email: &str,
    admin_password: &str,
    admin: (&str, &str),
) {
    // Existing deployments keep registration enabled until an administrator changes it.
    assert_settings(app, true).await;
    let (member_email, member_bearer) = member_session(app, "registration").await;
    let member = ("authorization", member_bearer.as_str());
    for method in [Method::GET, Method::PUT] {
        let body = (method == Method::PUT).then(|| json!({"registration_enabled": false}));
        for (auth, status) in [
            (None, StatusCode::UNAUTHORIZED),
            (Some(member), StatusCode::FORBIDDEN),
        ] {
            let denied = request(app, method.clone(), ADMIN_PATH, auth, body.clone()).await;
            assert!(json_body(denied, status).await["error"].is_string());
        }
    }
    let response = request(app, Method::GET, ADMIN_PATH, Some(admin), None).await;
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        json_body(response, StatusCode::OK).await,
        json!({"site_url":"http://localhost:6600","registration_enabled": true, "upload_limit": 100, "upload_window_seconds": 86400})
    );
    for invalid in [
        json!({}),
        json!({"registration_enabled": "false"}),
        json!({"registration_enabled": null}),
        json!({"registration_enabled": false, "other_setting": true}),
    ] {
        let response = request(app, Method::PUT, ADMIN_PATH, Some(admin), Some(invalid)).await;
        assert!(json_body(response, StatusCode::BAD_REQUEST).await["error"].is_string());
        assert_settings(app, true).await;
    }

    set_registration(app, admin, false).await;
    let credentials = json!({
        "email": format!("closed-registration-{}@example.test", rand::random::<u64>()),
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
    assert_eq!(
        json_body(register, StatusCode::FORBIDDEN).await["error"],
        "注册已关闭，请联系管理员"
    );

    // Closing registration must not disable existing sessions or prevent new logins.
    for (email, password, auth) in [
        (member_email.as_str(), "local-test-password", member),
        (admin_email, admin_password, admin),
    ] {
        let login = request(
            app,
            Method::POST,
            "/api/auth/login",
            None,
            Some(json!({"email": email, "password": password})),
        )
        .await;
        assert!(json_body(login, StatusCode::OK).await["token"].is_string());
        let me = request(app, Method::GET, "/api/auth/me", Some(auth), None).await;
        assert_eq!(json_body(me, StatusCode::OK).await["email"], email);
    }

    // Re-running startup migrations must preserve a saved closed setting.
    let restarted = routes::router(AppState::from_settings(settings).await.unwrap());
    assert_settings(&restarted, false).await;
    let register = request(
        &restarted,
        Method::POST,
        "/api/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    json_body(register, StatusCode::FORBIDDEN).await;

    set_registration(&restarted, admin, true).await;
    assert_settings(app, true).await;
    // The rejected request created no account, and reopening works across instances.
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
    assert_eq!(
        json_body(login, StatusCode::OK).await["user"]["is_admin"],
        false
    );
}
