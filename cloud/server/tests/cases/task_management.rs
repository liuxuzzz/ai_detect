use super::*;

pub(super) async fn check(app: &Router, settings: &Settings, admin: (&str, &str)) {
    let (email, member_token) = member_session(app, "managed").await;
    let member = Some(("authorization", member_token.as_str()));
    let (_, outsider_token) = member_session(app, "observer").await;
    let outsider = Some(("authorization", outsider_token.as_str()));
    let me = request(app, Method::GET, "/api/auth/me", member, None).await;
    let owner = json_body(me, StatusCode::OK).await["id"].as_i64().unwrap();

    let prompt =
        json!({"name": "Managed fixture", "content": "Original trusted prompt", "enabled": true});
    let created = request(
        app,
        Method::POST,
        "/api/admin/prompts",
        Some(admin),
        Some(prompt.clone()),
    )
    .await;
    let created = json_body(created, StatusCode::OK).await;
    let prompt_path = format!("/api/admin/prompts/{}", created["id"]);
    for (method, path, body) in [
        (
            Method::POST,
            "/api/admin/prompts".to_string(),
            Some(prompt.clone()),
        ),
        (Method::PUT, prompt_path.clone(), Some(prompt.clone())),
        (Method::DELETE, prompt_path.clone(), None),
    ] {
        let forbidden = request(app, method, &path, member, body).await;
        assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    }
    let listed = request(app, Method::GET, "/api/prompts", member, None).await;
    assert!(json_body(listed, StatusCode::OK)
        .await
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["id"] == created["id"] && p["content"] == prompt["content"]));
    let anonymous = request(app, Method::GET, "/api/prompts", None, None).await;
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);

    let channel = request(app, Method::POST, "/api/channels", member, Some(json!({
        "name": "Managed fixture", "base_url": "https://example.test/v1", "api_key": "managed-secret-key", "model": "managed-model", "enabled": true,
    }))).await;
    let channel = json_body(channel, StatusCode::OK).await;
    let payload = json!({
        "upstream_id": channel["id"], "prompt_kind": "library", "prompt_id": created["id"],
        "prompt_text": "Forged replacement must be ignored", "execution_mode": "delayed", "delay_ms": 60000,
    });
    let task = request(
        app,
        Method::POST,
        "/api/tasks",
        member,
        Some(payload.clone()),
    )
    .await;
    let task = json_body(task, StatusCode::OK).await;
    let id = task["id"].as_i64().unwrap();
    let (db, connection) = tokio_postgres::connect(&settings.database_url, tokio_postgres::NoTls)
        .await
        .unwrap();
    let connection_task = tokio::spawn(async move { connection.await.unwrap() });
    let snapshot = db
        .query_one(
            "SELECT prompt_name,prompt_text FROM async_tasks WHERE id=$1",
            &[&id],
        )
        .await
        .unwrap();
    assert_eq!(snapshot.get::<_, &str>(0), "Managed fixture");
    assert_eq!(snapshot.get::<_, &str>(1), "Original trusted prompt");
    let changed = request(app, Method::PUT, &prompt_path, Some(admin), Some(json!({"name": "Updated fixture", "content": "Updated trusted prompt", "enabled": true}))).await;
    json_body(changed, StatusCode::OK).await;
    let snapshot = db
        .query_one("SELECT prompt_text FROM async_tasks WHERE id=$1", &[&id])
        .await
        .unwrap();
    assert_eq!(snapshot.get::<_, &str>(0), "Original trusted prompt");

    let live_path = format!("/api/tasks/{id}/live");
    let events_path = format!("/api/tasks/{id}/events");
    for path in [&live_path, &events_path] {
        for (auth, expected) in [
            (None, StatusCode::UNAUTHORIZED),
            (outsider, StatusCode::NOT_FOUND),
        ] {
            let forbidden = request(app, Method::GET, path, auth, None).await;
            assert_eq!(forbidden.status(), expected);
        }
    }
    let live = request(app, Method::GET, &live_path, member, None).await;
    assert_eq!(live.headers()[header::CACHE_CONTROL], "private, no-store");
    assert_eq!(
        json_body(live, StatusCode::OK).await["model"],
        "managed-model"
    );
    let live = request(app, Method::GET, &live_path, Some(admin), None).await;
    json_body(live, StatusCode::OK).await;
    let live_payload = json!({"phase": "测试流式输出", "output": "Partial model output", "reasoning": "Visible reasoning", "metrics": {"cache_read_tokens": 7}});
    db.execute(
        "UPDATE async_tasks SET live=$2,status='failed' WHERE id=$1",
        &[&id, &live_payload],
    )
    .await
    .unwrap();
    let events = request(app, Method::GET, &events_path, member, None).await;
    assert_eq!(events.headers()["x-accel-buffering"], "no");
    assert_eq!(events.headers()[header::CONTENT_TYPE], "text/event-stream");
    let events = text(events, StatusCode::OK).await;
    assert!(events.contains("event: snapshot"));
    assert!(events.contains("Partial model output"));
    assert!(events.contains("Visible reasoning"));
    assert!(!events.contains("managed-secret-key"));
    db.execute("UPDATE async_tasks SET status='queued' WHERE id=$1", &[&id])
        .await
        .unwrap();

    let control_path = format!("/api/admin/tasks/{id}/control");
    let forbidden = request(
        app,
        Method::POST,
        &control_path,
        member,
        Some(json!({"action": "pause"})),
    )
    .await;
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    for (action, expected, status) in [
        ("pause", StatusCode::OK, "paused"),
        ("pause", StatusCode::CONFLICT, ""),
        ("resume", StatusCode::OK, "queued"),
        ("stop", StatusCode::OK, "stopped"),
        ("resume", StatusCode::CONFLICT, ""),
    ] {
        let result = request(
            app,
            Method::POST,
            &control_path,
            Some(admin),
            Some(json!({"action": action})),
        )
        .await;
        let result = json_body(result, expected).await;
        if expected == StatusCode::OK {
            assert_eq!(result["status"], status);
        }
    }
    let forbidden = request(
        app,
        Method::DELETE,
        &format!("/api/admin/tasks/{id}"),
        member,
        None,
    )
    .await;
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    let deleted = request(
        app,
        Method::DELETE,
        &format!("/api/admin/tasks/{id}"),
        Some(admin),
        None,
    )
    .await;
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    let missing = request(app, Method::GET, &live_path, member, None).await;
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);

    for status in ["queued", "running", "paused"] {
        let task = request(
            app,
            Method::POST,
            "/api/tasks",
            member,
            Some(payload.clone()),
        )
        .await;
        let task = json_body(task, StatusCode::OK).await;
        let id = task["id"].as_i64().unwrap();
        db.execute(
            "UPDATE async_tasks SET status=$2 WHERE id=$1",
            &[&id, &status],
        )
        .await
        .unwrap();
    }
    let removed = request(app, Method::DELETE, &prompt_path, Some(admin), None).await;
    assert_eq!(removed.status(), StatusCode::NO_CONTENT);
    let rejected = request(app, Method::POST, "/api/tasks", member, Some(payload)).await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    let listed = request(app, Method::GET, "/api/prompts", member, None).await;
    assert!(!json_body(listed, StatusCode::OK)
        .await
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["id"] == created["id"]));

    let key = request(app, Method::POST, "/api/auth/client-keys", member, None).await;
    let key = json_body(key, StatusCode::OK).await;
    let report = request(app, Method::POST, "/api/reports/upload", Some(("x-client-key", key["key"].as_str().unwrap())),
        Some(json!({"data": {"version": 1, "output": "disabled owner fixture"}, "api_domain": "managed-owner.example.test", "model": "managed-owner-model"}))).await;
    json_body(report, StatusCode::OK).await;
    let ranking_path = "/api/public/rankings?search=managed-owner-model";
    let rankings = request(app, Method::GET, ranking_path, None, None).await;
    assert_eq!(
        json_body(rankings, StatusCode::OK).await["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let user_path = format!("/api/admin/users/{owner}");
    let disabled = request(
        app,
        Method::PATCH,
        &user_path,
        Some(admin),
        Some(json!({"disabled": true})),
    )
    .await;
    json_body(disabled, StatusCode::OK).await;
    let statuses = db
        .query(
            "SELECT status FROM async_tasks WHERE owner_id=$1",
            &[&owner],
        )
        .await
        .unwrap();
    assert_eq!(statuses.len(), 3);
    assert!(statuses
        .iter()
        .all(|row| row.get::<_, &str>(0) == "disabled"));
    let blocked = request(app, Method::GET, "/api/tasks", member, None).await;
    assert_eq!(blocked.status(), StatusCode::FORBIDDEN);
    for path in [
        ranking_path,
        "/api/public/rankings?facet=model&search=managed-owner-model",
        "/api/public/rankings?facet=api_domain&search=managed-owner-model",
    ] {
        let hidden = request(app, Method::GET, path, None, None).await;
        assert_eq!(json_body(hidden, StatusCode::OK).await["items"], json!([]));
    }
    let enabled = request(
        app,
        Method::PATCH,
        &user_path,
        Some(admin),
        Some(json!({"disabled": false})),
    )
    .await;
    json_body(enabled, StatusCode::OK).await;
    let statuses = db
        .query(
            "SELECT status FROM async_tasks WHERE owner_id=$1",
            &[&owner],
        )
        .await
        .unwrap();
    assert!(statuses.iter().all(|row| row.get::<_, &str>(0) == "paused"));
    let stale_session = request(app, Method::GET, "/api/auth/me", member, None).await;
    assert_eq!(stale_session.status(), StatusCode::UNAUTHORIZED);
    let login = request(
        app,
        Method::POST,
        "/api/auth/login",
        None,
        Some(json!({"email": email, "password": "local-test-password"})),
    )
    .await;
    json_body(login, StatusCode::OK).await;
    let visible = request(app, Method::GET, ranking_path, None, None).await;
    assert_eq!(
        json_body(visible, StatusCode::OK).await["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    drop(db);
    connection_task.await.unwrap();
}
