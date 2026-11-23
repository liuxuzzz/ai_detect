use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::TaskAction,
    services::{cache::clear, tasks::enabled_owner},
    state::AppState,
};
use serde_json::{json, Value};

pub(crate) async fn control(state: &AppState, id: i64, action: TaskAction) -> ServiceResult<Value> {
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    let owner: i64 = transaction
        .query_opt("SELECT owner_id FROM async_tasks WHERE id=$1", &[&id])
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "任务不存在"))?
        .get(0);
    // Use the same user-before-task lock order as disabling accounts and finishing a run.
    enabled_owner(&transaction, owner).await?;
    let task = transaction
        .query_opt(
            "SELECT status FROM async_tasks WHERE id=$1 FOR UPDATE",
            &[&id],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "任务不存在"))?;
    let status: &str = task.get(0);
    let next = match action {
        TaskAction::Pause if matches!(status, "queued" | "running") => "paused",
        TaskAction::Resume if status == "paused" => "queued",
        TaskAction::Stop if matches!(status, "queued" | "running" | "paused") => "stopped",
        _ => {
            return Err(err(
                ErrorKind::Conflict,
                "当前任务状态不支持此操作，请刷新后重试",
            ))
        }
    };
    transaction
        .execute(
            "UPDATE async_tasks SET status=$2,
            started_at=CASE WHEN $2='queued' THEN NULL ELSE started_at END,
            finished_at=CASE WHEN $2 IN ('paused','stopped') THEN now() ELSE NULL END,
            error=CASE WHEN $2='stopped' THEN '管理员已停止测试' ELSE NULL END
         WHERE id=$1",
            &[&id, &next],
        )
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({"id": id, "status": next}))
}

pub(crate) async fn delete(state: &AppState, id: i64) -> ServiceResult<()> {
    let deleted = state
        .connection()
        .await?
        .execute("DELETE FROM async_tasks WHERE id=$1", &[&id])
        .await
        .map_err(AppError::internal)?;
    if deleted == 0 {
        return Err(err(ErrorKind::NotFound, "任务不存在"));
    }
    clear(state).await;
    Ok(())
}
