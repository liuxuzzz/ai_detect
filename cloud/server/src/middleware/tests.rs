use super::apply;
use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
    routing::get,
    Router,
};
use tower::ServiceExt;

#[tokio::test]
async fn browser_preflights_allow_authentication_uploads_and_sse() {
    let app = apply(Router::new().route("/api/check", get(|| async { "ok" })));
    for (method, requested_headers) in [
        ("POST", "content-type,x-client-key"),
        ("GET", "authorization"),
        ("PUT", "authorization,content-type"),
        ("PATCH", "authorization,content-type"),
        ("DELETE", "authorization"),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::OPTIONS)
                    .uri("/api/check")
                    .header(header::ORIGIN, "http://localhost:6600")
                    .header(header::ACCESS_CONTROL_REQUEST_METHOD, method)
                    .header(header::ACCESS_CONTROL_REQUEST_HEADERS, requested_headers)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::ACCESS_CONTROL_ALLOW_ORIGIN], "*");
        let allowed_headers = response.headers()[header::ACCESS_CONTROL_ALLOW_HEADERS]
            .to_str()
            .unwrap()
            .split(',')
            .map(str::trim)
            .collect::<Vec<_>>();
        for name in requested_headers.split(',') {
            assert!(allowed_headers.contains(&name), "{name} must be explicit");
        }
        let allowed_methods = response.headers()[header::ACCESS_CONTROL_ALLOW_METHODS]
            .to_str()
            .unwrap();
        assert!(allowed_methods
            .split(',')
            .any(|allowed| allowed.trim() == method));
    }
}
