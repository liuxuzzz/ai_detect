use super::*;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::mpsc,
};

async fn smtp_fixture() -> (
    u16,
    mpsc::UnboundedReceiver<String>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (sender, receiver) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let sender = sender.clone();
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                write.write_all(b"220 fixture ESMTP\r\n").await.unwrap();
                while let Some(line) = lines.next_line().await.unwrap() {
                    if line.starts_with("EHLO") {
                        write
                            .write_all(b"250-fixture\r\n250 8BITMIME\r\n")
                            .await
                            .unwrap();
                    } else if line == "DATA" {
                        write.write_all(b"354 Start mail input\r\n").await.unwrap();
                        let mut message = String::new();
                        while let Some(line) = lines.next_line().await.unwrap() {
                            if line == "." {
                                break;
                            }
                            message.push_str(&line);
                            message.push('\n');
                        }
                        sender.send(message).unwrap();
                        write.write_all(b"250 Accepted\r\n").await.unwrap();
                    } else if line == "QUIT" {
                        let _ = write.write_all(b"221 Bye\r\n").await;
                        break;
                    } else {
                        write.write_all(b"250 OK\r\n").await.unwrap();
                    }
                }
            });
        }
    });
    (port, receiver, task)
}

async fn code(receiver: &mut mpsc::UnboundedReceiver<String>) -> String {
    let mail = tokio::time::timeout(std::time::Duration::from_secs(5), receiver.recv())
        .await
        .unwrap()
        .unwrap();
    let (headers, body) = mail.split_once("\n\n").unwrap();
    let decoded = if headers
        .to_lowercase()
        .contains("content-transfer-encoding: base64")
    {
        use base64::Engine;
        String::from_utf8(
            base64::engine::general_purpose::STANDARD
                .decode(body.split_whitespace().collect::<String>())
                .unwrap(),
        )
        .unwrap()
    } else {
        body.replace("=\n", "")
    };
    decoded
        .split(|ch: char| !ch.is_ascii_digit())
        .find(|part| part.len() == 6)
        .expect("six digit email code")
        .to_owned()
}

async fn settings(app: &Router, admin: (&str, &str), value: Value) -> Value {
    let response = request(
        app,
        Method::PUT,
        "/api/admin/auth-settings",
        Some(admin),
        Some(value),
    )
    .await;
    json_body(response, StatusCode::OK).await
}

pub(super) async fn check(app: &Router, config: &Settings, admin: (&str, &str), admin_email: &str) {
    let (_, member) = member_session(app, "identity-permissions").await;
    for auth in [None, Some(("authorization", member.as_str()))] {
        let response = request(app, Method::GET, "/api/admin/auth-settings", auth, None).await;
        json_body(
            response,
            if auth.is_none() {
                StatusCode::UNAUTHORIZED
            } else {
                StatusCode::FORBIDDEN
            },
        )
        .await;
    }
    let options = json_body(
        request(app, Method::GET, "/api/auth/options", None, None).await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(options["bootstrap_required"], false);
    for field in ["github", "google", "email_verification", "password_reset"] {
        assert_eq!(options[field], false);
    }
    for provider in ["github", "google"] {
        assert_eq!(
            request(
                app,
                Method::GET,
                &format!("/api/auth/oauth/{provider}/start"),
                None,
                None
            )
            .await
            .status(),
            StatusCode::NOT_FOUND
        );
    }
    let me = json_body(
        request(app, Method::GET, "/api/auth/me", Some(admin), None).await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(me["is_superadmin"], true);
    for patch in [json!({"disabled":true}), json!({"is_admin":false})] {
        let response = request(
            app,
            Method::PATCH,
            &format!("/api/admin/users/{}", me["id"]),
            Some(admin),
            Some(patch),
        )
        .await;
        json_body(response, StatusCode::FORBIDDEN).await;
    }
    let invalid = request(
        app,
        Method::PUT,
        "/api/admin/auth-settings",
        Some(admin),
        Some(json!({"github":{"enabled":true}})),
    )
    .await;
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
    for provider in ["github", "google"] {
        let view=settings(app,admin,json!({(provider):{"enabled":true,"client_id":"fixture-id","client_secret":"isolated-fixture-secret"}})).await;
        assert_eq!(view[provider]["client_secret"], "");
        assert_eq!(view[provider]["client_secret_set"], true);
        assert!(view[provider]["callback_url"]
            .as_str()
            .unwrap()
            .starts_with(&config.api_public_url));
        let start = request(
            app,
            Method::GET,
            &format!("/api/auth/oauth/{provider}/start"),
            None,
            None,
        )
        .await;
        assert_eq!(start.status(), StatusCode::SEE_OTHER);
        let url = reqwest::Url::parse(start.headers()[header::LOCATION].to_str().unwrap()).unwrap();
        let params: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(params["code_challenge_method"], "S256");
        assert!(params["code_challenge"].len() > 40);
        assert!(start.headers()[header::SET_COOKIE]
            .to_str()
            .unwrap()
            .contains("HttpOnly"));
        let path = format!(
            "/api/auth/oauth/{provider}/callback?state={}&code=invalid",
            params["state"]
        );
        let invalid = request(app, Method::GET, &path, None, None).await;
        assert!(invalid.headers()[header::LOCATION]
            .to_str()
            .unwrap()
            .ends_with("#error=oauth_failed"));
        settings(
            app,
            admin,
            json!({(provider):{"enabled":false,"client_id":"fixture-id","client_secret":""}}),
        )
        .await;
    }
    let (port, mut mail, server) = smtp_fixture().await;
    let view = settings(
        app,
        admin,
        json!({"smtp":{"enabled":true,"host":"127.0.0.1","port":port,
        "security":"plain","from_address":"sender@example.test","password":"smtp-fixture-secret"}}),
    )
    .await;
    assert_eq!(view["smtp"]["password"], "");
    assert_eq!(view["smtp"]["password_set"], true);
    let options = json_body(
        request(app, Method::GET, "/api/auth/options", None, None).await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(options["email_verification"], true);
    assert_eq!(options["password_reset"], true);
    let email = format!("verified-{}@example.test", rand::random::<u64>());
    let credentials = json!({"email":email,"password":"email-test-password"});
    let response = request(
        app,
        Method::POST,
        "/api/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    json_body(response, StatusCode::BAD_REQUEST).await;
    let response = request(
        app,
        Method::POST,
        "/api/auth/email-code",
        None,
        Some(json!({"email":email,"purpose":"register"})),
    )
    .await;
    json_body(response, StatusCode::OK).await;
    let register_code = code(&mut mail).await;
    let repeated = request(
        app,
        Method::POST,
        "/api/auth/email-code",
        None,
        Some(json!({"email":email,"purpose":"register"})),
    )
    .await;
    json_body(repeated, StatusCode::TOO_MANY_REQUESTS).await;
    let mut verified = credentials.clone();
    verified["email_code"] = json!(register_code);
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/register",
            None,
            Some(verified.clone()),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    // A registration code cannot reset a password, and successful codes cannot be replayed.
    let reset = json!({"email":email,"code":register_code,"new_password":"updated-email-password"});
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/password/reset",
            None,
            Some(reset),
        )
        .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/register",
            None,
            Some(verified),
        )
        .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let login = json_body(
        request(
            app,
            Method::POST,
            "/api/auth/login",
            None,
            Some(credentials.clone()),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    let bearer = format!("Bearer {}", login["token"].as_str().unwrap());
    let (db, connection) = tokio_postgres::connect(&config.database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection = tokio::spawn(async move { connection.await.unwrap() });
    let encrypted: Vec<u8> = db
        .query_one("SELECT encrypted_config FROM identity_settings", &[])
        .await
        .unwrap()
        .get(0);
    assert!(!encrypted
        .windows(19)
        .any(|part| part == b"smtp-fixture-secret"));
    db.execute(
        "UPDATE email_delivery_attempts SET requested_at=now()-interval '2 minutes' WHERE email=$1",
        &[&email],
    )
    .await
    .unwrap();
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/email-code",
            None,
            Some(json!({"email":email,"purpose":"reset"})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    let reset_code = code(&mut mail).await;
    let reset = json!({"email":email,"code":reset_code,"new_password":"updated-email-password"});
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/password/reset",
            None,
            Some(reset.clone()),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/password/reset",
            None,
            Some(reset),
        )
        .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    json_body(
        request(
            app,
            Method::GET,
            "/api/auth/me",
            Some(("authorization", &bearer)),
            None,
        )
        .await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/login",
            None,
            Some(credentials),
        )
        .await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/login",
            None,
            Some(json!({"email":email,"password":"updated-email-password"})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    json_body(
        request(
            app,
            Method::POST,
            "/api/auth/email-code",
            None,
            Some(json!({"email":"unknown@example.test","purpose":"reset"})),
        )
        .await,
        StatusCode::OK,
    )
    .await;
    assert!(
        mail.try_recv().is_err(),
        "Unknown accounts must not receive reset mail"
    );
    // Expiry and the five-guess budget are enforced by the API, not only the form.
    for exhausted in [false, true] {
        db.execute("UPDATE email_delivery_attempts SET requested_at=now()-interval '2 minutes' WHERE email=$1",&[&email]).await.unwrap();
        json_body(
            request(
                app,
                Method::POST,
                "/api/auth/email-code",
                None,
                Some(json!({"email":email,"purpose":"reset"})),
            )
            .await,
            StatusCode::OK,
        )
        .await;
        let valid_code = code(&mut mail).await;
        if exhausted {
            let wrong = if valid_code == "000000" {
                "111111"
            } else {
                "000000"
            };
            for _ in 0..5 {
                json_body(request(app,Method::POST,"/api/auth/password/reset",None,
                    Some(json!({"email":email,"code":wrong,"new_password":"yet-another-password"}))).await,StatusCode::BAD_REQUEST).await;
            }
        } else {
            db.execute(
                "UPDATE email_challenges SET expires_at=now()-interval '1 second' WHERE email=$1",
                &[&email],
            )
            .await
            .unwrap();
        }
        json_body(
            request(
                app,
                Method::POST,
                "/api/auth/password/reset",
                None,
                Some(
                    json!({"email":email,"code":valid_code,"new_password":"yet-another-password"}),
                ),
            )
            .await,
            StatusCode::BAD_REQUEST,
        )
        .await;
    }
    let current = json_body(
        request(
            app,
            Method::GET,
            "/api/admin/auth-settings",
            Some(admin),
            None,
        )
        .await,
        StatusCode::OK,
    )
    .await;
    let mut smtp = current["smtp"].clone();
    smtp.as_object_mut().unwrap().remove("password_set");
    smtp["enabled"] = json!(false);
    let updated = settings(app, admin, json!({"smtp":smtp})).await;
    assert_eq!(updated["smtp"]["password_set"], true);
    let restarted = routes::router(AppState::from_settings(config).await.unwrap());
    let status = json_body(
        request(&restarted, Method::GET, "/api/auth/options", None, None).await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(status["password_reset"], false);
    assert_eq!(me["email"], admin_email);
    drop(db);
    connection.await.unwrap();
    server.abort();
}
