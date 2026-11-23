use crate::{
    error::ServiceResult, middleware::Authenticated, services::task_live, state::AppState,
};
use axum::{
    extract::{Path, State},
    http::header,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
    Json,
};
use futures_util::stream;
use std::{convert::Infallible, time::Duration};

pub(crate) async fn snapshot(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(task_live::snapshot(&state, &claims, id).await?),
    ))
}

pub(crate) async fn events(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<impl IntoResponse> {
    let first = task_live::snapshot(&state, &claims, id).await?;
    let events = stream::unfold(
        (Some(first), state, claims, false),
        move |(first, state, claims, done)| async move {
            if done {
                return None;
            }
            let snapshot = if let Some(first) = first {
                Ok(first)
            } else {
                tokio::time::sleep(Duration::from_millis(500)).await;
                task_live::snapshot(&state, &claims, id).await
            };
            let (event, done) = match snapshot {
                Ok(value) => {
                    let done = matches!(
                        value["status"].as_str(),
                        Some("completed" | "failed" | "stopped")
                    );
                    (
                        Event::default().event("snapshot").data(value.to_string()),
                        done,
                    )
                }
                Err(_) => (
                    Event::default()
                        .event("unavailable")
                        .data("任务已删除或查看权限已变化"),
                    true,
                ),
            };
            Some((Ok::<_, Infallible>(event), (None, state, claims, done)))
        },
    );
    Ok((
        [
            (header::CACHE_CONTROL, "private, no-store"),
            (header::HeaderName::from_static("x-accel-buffering"), "no"),
        ],
        Sse::new(events).keep_alive(KeepAlive::default()),
    ))
}
