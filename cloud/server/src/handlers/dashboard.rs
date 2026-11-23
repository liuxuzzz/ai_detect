use crate::{
    error::ApiResult,
    middleware::Authenticated,
    models::{DashboardQuery, PublicQuery},
    services::{dashboard, public_rankings},
    state::AppState,
};
use axum::{
    extract::{Query, State},
    Json,
};
use serde_json::Value;

pub(crate) async fn dashboard(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Query(query): Query<DashboardQuery>,
) -> ApiResult<Value> {
    dashboard::dashboard(&state, &claims, query).await.map(Json)
}

pub(crate) async fn public_rankings(
    State(state): State<AppState>,
    Query(query): Query<PublicQuery>,
) -> ApiResult<Value> {
    public_rankings::list(&state, query).await.map(Json)
}
