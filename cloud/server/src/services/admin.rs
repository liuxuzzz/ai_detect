use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    state::AppState,
};
use crate::{
    models::{PageQuery, UserPatch},
    services::cache::clear,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

pub(crate) async fn users(state: &AppState, query: PageQuery) -> ServiceResult<Value> {
    let limit = query.limit.clamp(1, 100);
    let page = query.page.max(0);
    let offset = page * limit;
    let db = state.connection().await?;
    let total: i64 = db
        .query_one("SELECT count(*) FROM users", &[])
        .await
        .map_err(AppError::internal)?
        .get(0);
    let rows = db.query("SELECT id,email,is_admin,disabled,created_at,is_superadmin FROM users ORDER BY id DESC LIMIT $1 OFFSET $2", &[&limit, &offset]).await.map_err(AppError::internal)?;
    Ok(
        json!({"items": rows.iter().map(|row| json!({"id": row.get::<_, i64>(0), "email": row.get::<_, String>(1), "is_admin": row.get::<_, bool>(2), "disabled": row.get::<_, bool>(3), "created_at": row.get::<_, DateTime<Utc>>(4), "is_superadmin": row.get::<_, bool>(5)})).collect::<Vec<_>>(), "total": total, "page": page, "limit": limit}),
    )
}

pub(crate) async fn patch_user(
    state: &AppState,
    id: i64,
    patch: UserPatch,
) -> ServiceResult<Value> {
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    let user = transaction
        .query_opt(
            "SELECT disabled,is_superadmin FROM users WHERE id=$1 FOR UPDATE",
            &[&id],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "用户不存在"))?;
    let was_disabled: bool = user.get(0);
    if user.get::<_, bool>(1) && (patch.disabled == Some(true) || patch.is_admin == Some(false)) {
        return Err(err(
            ErrorKind::Forbidden,
            "超级管理员不能被禁用或取消管理员权限",
        ));
    }
    transaction.execute("UPDATE users SET disabled=COALESCE($2,disabled),is_admin=COALESCE($3,is_admin),
        auth_version=auth_version+CASE WHEN $2 IS TRUE AND NOT disabled THEN 1 ELSE 0 END WHERE id=$1",
        &[&id, &patch.disabled, &patch.is_admin]).await.map_err(AppError::internal)?;
    if patch.disabled == Some(true) {
        transaction.execute(
            "UPDATE async_tasks SET status='disabled',finished_at=now(),error='用户已禁用，任务不可执行'
             WHERE owner_id=$1 AND status IN ('queued','running','paused')", &[&id],
        ).await.map_err(AppError::internal)?;
    } else if was_disabled && patch.disabled == Some(false) {
        transaction.execute(
            "UPDATE async_tasks SET status='paused',error=NULL WHERE owner_id=$1 AND status='disabled'", &[&id],
        ).await.map_err(AppError::internal)?;
    }
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({"ok": true}))
}

pub(crate) async fn reports(state: &AppState, query: PageQuery) -> ServiceResult<Value> {
    let limit = query.limit.clamp(1, 100);
    let page = query.page.max(0);
    let offset = page * limit;
    let db = state.connection().await?;
    let total: i64 = db
        .query_one("SELECT count(*) FROM reports WHERE deleted_at IS NULL", &[])
        .await
        .map_err(AppError::internal)?
        .get(0);
    let rows = db.query("SELECT id,owner_id,slug,api_domain,model,prompt_name,created_at FROM reports WHERE deleted_at IS NULL ORDER BY id DESC LIMIT $1 OFFSET $2", &[&limit, &offset]).await.map_err(AppError::internal)?;
    Ok(
        json!({"items": rows.iter().map(|row| json!({"id": row.get::<_, i64>(0), "owner_id": row.get::<_, i64>(1), "slug": row.get::<_, String>(2), "api_domain": row.get::<_, String>(3), "model": row.get::<_, String>(4), "prompt_name": row.get::<_, String>(5), "created_at": row.get::<_, DateTime<Utc>>(6)})).collect::<Vec<_>>(), "total": total, "page": page, "limit": limit}),
    )
}

pub(crate) async fn delete_report(state: &AppState, id: i64) -> ServiceResult<Value> {
    state
        .connection()
        .await?
        .execute("UPDATE reports SET deleted_at=now() WHERE id=$1", &[&id])
        .await
        .map_err(AppError::internal)?;
    clear(state).await;
    Ok(json!({"ok": true}))
}

pub(crate) async fn tasks(state: &AppState, query: PageQuery) -> ServiceResult<Value> {
    let limit = query.limit.clamp(1, 100);
    let page = query.page.max(0);
    let offset = page * limit;
    let db = state.connection().await?;
    let total: i64 = db
        .query_one("SELECT count(*) FROM async_tasks", &[])
        .await
        .map_err(AppError::internal)?
        .get(0);
    let rows = db.query("SELECT t.id,t.owner_id,t.upstream_id,t.status,t.scheduled_for,t.error,t.model,t.prompt_name,u.email AS owner_email,u.disabled AS owner_disabled FROM async_tasks t JOIN users u ON u.id=t.owner_id ORDER BY t.id DESC LIMIT $1 OFFSET $2", &[&limit, &offset]).await.map_err(AppError::internal)?;
    Ok(
        json!({"items": rows.iter().map(|row| json!({"id": row.get::<_, i64>(0), "owner_id": row.get::<_, i64>(1), "upstream_id": row.get::<_, Option<i64>>(2), "status": row.get::<_, String>(3), "scheduled_for": row.get::<_, DateTime<Utc>>(4), "error": row.get::<_, Option<String>>(5), "model": row.get::<_, String>(6), "prompt_name": row.get::<_, Option<String>>(7), "owner_email": row.get::<_, String>(8), "owner_disabled": row.get::<_, bool>(9)})).collect::<Vec<_>>(), "total": total, "page": page, "limit": limit}),
    )
}
