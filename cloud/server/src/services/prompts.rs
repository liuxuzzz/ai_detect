use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{PageQuery, PromptInput},
    state::AppState,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use tokio_postgres::Row;

fn prompt(row: &Row) -> Value {
    json!({
        "id": row.get::<_, i64>("id"), "name": row.get::<_, String>("name"),
        "content": row.get::<_, String>("content"), "enabled": row.get::<_, bool>("enabled"),
        "updated_at": row.get::<_, DateTime<Utc>>("updated_at"),
    })
}

pub(crate) async fn available(state: &AppState) -> ServiceResult<Vec<Value>> {
    let rows = state.connection().await?.query(
        "SELECT id,name,content,enabled,updated_at FROM managed_prompts WHERE deleted_at IS NULL AND enabled ORDER BY id",
        &[],
    ).await.map_err(AppError::internal)?;
    Ok(rows.iter().map(prompt).collect())
}

pub(crate) async fn list(state: &AppState, query: PageQuery) -> ServiceResult<Value> {
    let limit = query.limit.clamp(1, 100);
    let page = query.page.max(0);
    let offset = page
        .checked_mul(limit)
        .ok_or_else(|| err(ErrorKind::InvalidInput, "页码超出范围"))?;
    let db = state.connection().await?;
    let total: i64 = db
        .query_one(
            "SELECT count(*) FROM managed_prompts WHERE deleted_at IS NULL",
            &[],
        )
        .await
        .map_err(AppError::internal)?
        .get(0);
    let rows = db.query(
        "SELECT id,name,content,enabled,updated_at FROM managed_prompts WHERE deleted_at IS NULL ORDER BY id DESC LIMIT $1 OFFSET $2",
        &[&limit, &offset],
    ).await.map_err(AppError::internal)?;
    Ok(
        json!({"items": rows.iter().map(prompt).collect::<Vec<_>>(), "total": total, "page": page, "limit": limit}),
    )
}

pub(crate) async fn save(
    state: &AppState,
    id: Option<i64>,
    input: PromptInput,
) -> ServiceResult<Value> {
    let name = input.name.trim();
    if name.is_empty()
        || name.chars().count() > 100
        || input.content.trim().is_empty()
        || input.content.len() > 64 * 1024
    {
        return Err(err(
            ErrorKind::InvalidInput,
            "名称须为 1–100 个字符，提示词正文须为 1–64 KB",
        ));
    }
    let db = state.connection().await?;
    let row = if let Some(id) = id {
        db.query_opt(
            "UPDATE managed_prompts SET name=$1,content=$2,enabled=$3,updated_at=now() WHERE id=$4 AND deleted_at IS NULL RETURNING id,name,content,enabled,updated_at",
            &[&name, &input.content, &input.enabled, &id],
        ).await.map_err(AppError::internal)?.ok_or_else(|| err(ErrorKind::NotFound, "提示词不存在"))?
    } else {
        db.query_one(
            "INSERT INTO managed_prompts(name,content,enabled) VALUES($1,$2,$3) RETURNING id,name,content,enabled,updated_at",
            &[&name, &input.content, &input.enabled],
        ).await.map_err(AppError::internal)?
    };
    Ok(prompt(&row))
}

pub(crate) async fn delete(state: &AppState, id: i64) -> ServiceResult<()> {
    let changed = state.connection().await?.execute(
        "UPDATE managed_prompts SET deleted_at=now(),enabled=false,updated_at=now() WHERE id=$1 AND deleted_at IS NULL", &[&id],
    ).await.map_err(AppError::internal)?;
    if changed == 0 {
        return Err(err(ErrorKind::NotFound, "提示词不存在"));
    }
    Ok(())
}
