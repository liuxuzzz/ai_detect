use super::*;
use std::fs;

pub(super) async fn check(state: AppState) {
    let directory = env::temp_dir().join(format!("aijiance-web-{}", rand::random::<u64>()));
    fs::create_dir_all(directory.join("assets")).unwrap();
    fs::write(
        directory.join("index.html"),
        "<!doctype html><div id=app>Vue fixture</div>",
    )
    .unwrap();
    fs::write(directory.join("assets/app.js"), "console.log('fixture')").unwrap();
    let app = routes::application(state, &directory);
    for path in [
        "/",
        "/r/example",
        "/r/example/",
        "/share/example",
        "/auth/callback",
    ] {
        let response = request(&app, Method::GET, path, None, None).await;
        assert!(response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("text/html"));
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-cache");
        assert!(text(response, StatusCode::OK).await.contains("Vue fixture"));
    }
    let response = request(&app, Method::GET, "/assets/app.js", None, None).await;
    assert!(text(response, StatusCode::OK).await.contains("console.log"));
    for path in ["/api/missing", "/api/reports/missing/path"] {
        let response = request(&app, Method::GET, path, None, None).await;
        assert_eq!(
            json_body(response, StatusCode::NOT_FOUND).await["error"],
            "API 不存在"
        );
    }
    for path in ["/assets/missing.js", "/%2e%2e/Cargo.toml"] {
        assert_eq!(
            request(&app, Method::GET, path, None, None).await.status(),
            StatusCode::NOT_FOUND
        );
    }
    assert_eq!(
        json_body(
            request(&app, Method::GET, "/health", None, None).await,
            StatusCode::OK
        )
        .await["status"],
        "ok"
    );
    fs::remove_dir_all(directory).unwrap();
}
