use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{Claims, TaskInput},
    services::cache::clear,
    state::AppState,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};

pub(crate) const PELICAN_PROMPT: &str = include_str!("../../config/pelican_prompt.txt");
pub(crate) const PELICAN_NAME: &str = "鹈鹕测试";

pub(crate) async fn create(
    state: &AppState,
    claims: &Claims,
    input: TaskInput,
) -> ServiceResult<Value> {
    let schedule = execution_schedule(&input, Utc::now())?;
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    enabled_owner(&transaction, claims.sub).await?;
    let count: i64 = transaction.query_one(
        "SELECT count(*) FROM async_tasks WHERE owner_id=$1 AND created_at >= date_trunc('day',now())",
        &[&claims.sub],
    ).await.map_err(AppError::internal)?.get(0);
    if count >= state.task_limit {
        return Err(err(ErrorKind::QuotaExceeded, "今日异步任务已达上限"));
    }
    let model = input.model.unwrap_or_default();
    let effort = input.reasoning_effort.unwrap_or_else(|| "default".into());
    let custom = input.prompt_text.as_deref().unwrap_or_default().trim();
    let managed = if input.prompt_kind.as_deref() == Some("library") {
        Some(transaction.query_opt(
            "SELECT name,content FROM managed_prompts WHERE id=$1 AND enabled AND deleted_at IS NULL FOR SHARE",
            &[&input.prompt_id],
        ).await.map_err(AppError::internal)?.ok_or_else(|| err(ErrorKind::InvalidInput, "提示词已停用或不存在，请重新选择"))?)
    } else {
        None
    };
    let (prompt_name, prompt_text) = match input.prompt_kind.as_deref() {
        None | Some("channel") => ("渠道提示词", None),
        Some("pelican") => (PELICAN_NAME, Some(PELICAN_PROMPT.trim())),
        Some("library") => {
            let prompt = managed.as_ref().expect("managed prompt loaded above");
            (prompt.get::<_, &str>(0), Some(prompt.get::<_, &str>(1)))
        }
        Some("custom") if !custom.is_empty() && custom.len() <= 64 * 1024 => {
            ("自定义提示词", Some(custom))
        }
        _ => {
            return Err(err(
                ErrorKind::InvalidInput,
                "请选择有效提示词，自定义正文须在 64 KB 以内",
            ))
        }
    };
    let prompt_id = managed.as_ref().and(input.prompt_id);
    let row = transaction.query_opt(
        "INSERT INTO async_tasks(owner_id,upstream_id,model,reasoning_effort,execution_mode,delay_ms,scheduled_for,prompt_name,prompt_text,prompt_id)
         SELECT $1,id,COALESCE(NULLIF($3,''),model),$4,$5,$6,$7,
                CASE WHEN $9::text IS NULL AND btrim(prompt)='' THEN $10 ELSE $8 END,
                COALESCE($9,NULLIF(btrim(prompt),''),$11),$12
         FROM cloud_upstreams WHERE id=$2 AND owner_id=$1
         RETURNING id,status,scheduled_for",
        &[&claims.sub, &input.upstream_id, &model, &effort, &schedule.mode, &schedule.delay_ms, &schedule.when,
            &prompt_name, &prompt_text, &PELICAN_NAME, &PELICAN_PROMPT.trim(), &prompt_id],
    ).await.map_err(AppError::internal)?.ok_or_else(|| err(ErrorKind::NotFound, "渠道不存在"))?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({
        "id": row.get::<_, i64>(0),
        "status": row.get::<_, String>(1),
        "scheduled_for": row.get::<_, DateTime<Utc>>(2),
    }))
}

pub(super) async fn enabled_owner(
    transaction: &deadpool_postgres::Transaction<'_>,
    owner: i64,
) -> ServiceResult<()> {
    let user = transaction
        .query_opt(
            "SELECT disabled FROM users WHERE id=$1 FOR SHARE",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "用户不存在"))?;
    if user.get::<_, bool>(0) {
        return Err(err(ErrorKind::Forbidden, "账户已禁用，任务不可执行"));
    }
    Ok(())
}

pub(crate) async fn delete(state: &AppState, claims: &Claims, id: i64) -> ServiceResult<()> {
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    // Serialize against claiming/retrying a queued task before deciding whether it can be deleted.
    let task = transaction
        .query_opt(
            "SELECT status FROM async_tasks WHERE id=$1 AND owner_id=$2 FOR UPDATE",
            &[&id, &claims.sub],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "任务不存在"))?;
    if task.get::<_, &str>(0) == "running" {
        return Err(err(ErrorKind::Conflict, "任务正在执行，请等待完成后删除"));
    }
    transaction
        .execute(
            "DELETE FROM async_tasks WHERE id=$1 AND owner_id=$2",
            &[&id, &claims.sub],
        )
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(())
}

struct ExecutionSchedule {
    mode: &'static str,
    delay_ms: i32,
    when: DateTime<Utc>,
}

pub(crate) async fn retry(state: &AppState, claims: &Claims, id: i64) -> ServiceResult<Value> {
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    enabled_owner(&transaction, claims.sub).await?;
    let task = transaction
        .query_opt(
            "SELECT t.status,COALESCE(u.enabled,false) AS upstream_enabled
             FROM async_tasks t LEFT JOIN cloud_upstreams u ON u.id=t.upstream_id AND u.owner_id=t.owner_id
             WHERE t.id=$1 AND t.owner_id=$2 FOR UPDATE OF t",
            &[&id, &claims.sub],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "任务不存在"))?;
    if task.get::<_, &str>("status") != "failed" {
        return Err(err(
            ErrorKind::Conflict,
            "仅失败的任务可以重试，请刷新任务状态",
        ));
    }
    if !task.get::<_, bool>("upstream_enabled") {
        return Err(err(
            ErrorKind::InvalidInput,
            "渠道已禁用或不可用，请检查渠道后重试",
        ));
    }
    let task = transaction
        .query_one(
            "UPDATE async_tasks SET status='queued',execution_mode='immediate',delay_ms=0,
                scheduled_for=now(),started_at=NULL,finished_at=NULL,error=NULL,report_id=NULL,live='{}'::jsonb
             WHERE id=$1 AND owner_id=$2 AND status='failed'
             RETURNING id,status,scheduled_for",
            &[&id, &claims.sub],
        )
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({
        "id": task.get::<_, i64>(0), "status": task.get::<_, String>(1),
        "scheduled_for": task.get::<_, DateTime<Utc>>(2), "execution_mode": "immediate",
        "started_at": null, "finished_at": null, "error": null, "report_slug": null,
    }))
}

fn execution_schedule(input: &TaskInput, now: DateTime<Utc>) -> ServiceResult<ExecutionSchedule> {
    let fallback = if input.scheduled_for.is_some() {
        "scheduled"
    } else if input.delay_ms.is_some_and(|delay| delay != 0) {
        "delayed"
    } else {
        "immediate"
    };
    match input.execution_mode.as_deref().unwrap_or(fallback) {
        "immediate" => Ok(ExecutionSchedule {
            mode: "immediate",
            delay_ms: 0,
            when: now,
        }),
        "delayed" => {
            let delay_ms = input
                .delay_ms
                .filter(|delay| *delay > 0)
                .ok_or_else(|| err(ErrorKind::InvalidInput, "请选择大于零的延时时长"))?;
            Ok(ExecutionSchedule {
                mode: "delayed",
                delay_ms,
                when: now + Duration::milliseconds(i64::from(delay_ms)),
            })
        }
        "scheduled" => {
            let when = input
                .scheduled_for
                .filter(|when| *when > now)
                .ok_or_else(|| err(ErrorKind::InvalidInput, "请选择未来的执行日期和时间"))?;
            Ok(ExecutionSchedule {
                mode: "scheduled",
                delay_ms: 0,
                when,
            })
        }
        _ => Err(err(ErrorKind::InvalidInput, "请选择有效的执行方式")),
    }
}

pub(crate) async fn list(state: &AppState, claims: &Claims) -> ServiceResult<Vec<Value>> {
    let rows = state
        .connection()
        .await?
        .query(
            "SELECT t.id,t.owner_id,t.upstream_id,t.model,t.reasoning_effort,t.execution_mode,t.status,
                t.scheduled_for,t.started_at,t.finished_at,t.error,r.slug,t.prompt_name
             FROM async_tasks t LEFT JOIN reports r ON r.id=t.report_id AND r.deleted_at IS NULL
             WHERE t.owner_id=$1 ORDER BY t.id DESC",
            &[&claims.sub],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(rows.iter().map(|row| json!({
        "id": row.get::<_, i64>(0), "owner_id": row.get::<_, i64>(1), "upstream_id": row.get::<_, Option<i64>>(2),
        "model": row.get::<_, String>(3), "reasoning_effort": row.get::<_, String>(4), "execution_mode": row.get::<_, String>(5),
        "status": row.get::<_, String>(6), "scheduled_for": row.get::<_, chrono::DateTime<Utc>>(7),
        "started_at": row.get::<_, Option<chrono::DateTime<Utc>>>(8), "finished_at": row.get::<_, Option<chrono::DateTime<Utc>>>(9),
        "error": row.get::<_, Option<String>>(10), "report_slug": row.get::<_, Option<String>>(11),
        "prompt_name": row.get::<_, Option<String>>(12)
    })).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_modes_use_only_the_selected_schedule() {
        let now = DateTime::parse_from_rfc3339("2026-11-19T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let future = now + Duration::hours(1);
        for (mut input, mode, expected, delay_ms) in [
            (
                json!({"execution_mode": "immediate", "scheduled_for": future, "delay_ms": 60000}),
                "immediate",
                now,
                0,
            ),
            (
                json!({"execution_mode": "delayed", "delay_ms": 60000, "scheduled_for": future}),
                "delayed",
                now + Duration::minutes(1),
                60000,
            ),
            (
                json!({"execution_mode": "scheduled", "scheduled_for": "2026-11-19T21:00:00+08:00", "delay_ms": 60000}),
                "scheduled",
                future,
                0,
            ),
            (
                json!({"delay_ms": 60000}),
                "delayed",
                now + Duration::minutes(1),
                60000,
            ),
        ] {
            input["upstream_id"] = json!(1);
            let input: TaskInput = serde_json::from_value(input).unwrap();
            let schedule = execution_schedule(&input, now).unwrap();
            assert_eq!(schedule.mode, mode);
            assert_eq!(schedule.when, expected);
            assert_eq!(schedule.delay_ms, delay_ms);
        }
    }

    #[test]
    fn rejects_missing_past_and_invalid_schedules() {
        for mut input in [
            json!({"execution_mode": "delayed"}),
            json!({"execution_mode": "delayed", "delay_ms": 0}),
            json!({"execution_mode": "delayed", "delay_ms": -1}),
            json!({"execution_mode": "scheduled"}),
            json!({"execution_mode": "scheduled", "scheduled_for": "2020-01-01T00:00:00Z"}),
            json!({"execution_mode": "other"}),
        ] {
            input["upstream_id"] = json!(1);
            let input: TaskInput = serde_json::from_value(input).unwrap();
            assert!(execution_schedule(&input, Utc::now()).is_err());
        }
    }
}
