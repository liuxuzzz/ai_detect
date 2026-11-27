mod api;
mod benchmark;
mod progress;
mod report;
mod responses;
#[cfg(test)]
mod tests;

use crate::{
    models::Upload,
    services::{
        cache, reports,
        tasks::{PELICAN_NAME, PELICAN_PROMPT},
    },
    state::AppState,
};
use anyhow::{anyhow, Context};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::watch;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(60 * 60);
const CLAIM_EXPIRY_SECONDS: i64 = REQUEST_TIMEOUT.as_secs() as i64 + 60;

#[derive(Clone)]
struct Task {
    id: i64,
    owner_id: i64,
    upstream_id: Option<i64>,
    model: String,
    effort: String,
    started_at: DateTime<Utc>,
    prompt_name: Option<String>,
    prompt_text: Option<String>,
}

pub async fn run(state: AppState) {
    tracing::info!("queue task started");
    loop {
        match run_next(&state).await {
            Ok(true) => continue,
            Ok(false) => {}
            Err(error) => tracing::error!(%error, "queue task database operation failed"),
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn run_next(state: &AppState) -> anyhow::Result<bool> {
    let Some(task) = claim(state).await? else {
        return Ok(false);
    };
    run_claimed(state, &task).await?;
    Ok(true)
}

async fn run_claimed(state: &AppState, task: &Task) -> anyhow::Result<()> {
    let (sender, progress) = watch::channel(json!({"phase": "准备测试"}));
    drive_execution(state, task, execute(state, task, sender), progress).await
}

async fn drive_execution(
    state: &AppState,
    task: &Task,
    execution: impl std::future::Future<Output = anyhow::Result<Upload>>,
    mut progress: watch::Receiver<Value>,
) -> anyhow::Result<()> {
    let mut execution = Box::pin(tokio::time::timeout(REQUEST_TIMEOUT, execution));
    let mut check = tokio::time::interval(Duration::from_millis(250));
    loop {
        tokio::select! {
            biased;
            _ = check.tick() => {
                let latest = progress.has_changed().unwrap_or(false).then(|| progress.borrow_and_update().clone());
                if !update_live(state, task, latest).await? {
                    // Dropping the execution future closes the in-flight upstream response/request.
                    return Ok(());
                }
            }
            result = execution.as_mut() => {
                // A timed-out request publishes the bytes received so far when dropped.
                drop(execution);
                let latest = progress.borrow().clone();
                update_live(state, task, Some(latest)).await?;
                let result = result.unwrap_or_else(|_| Err(anyhow!("测试超时：60 分钟")));
                finish(state, task, result).await?;
                return Ok(());
            }
        }
    }
}

async fn update_live(state: &AppState, task: &Task, live: Option<Value>) -> anyhow::Result<bool> {
    let db = state
        .connection()
        .await
        .map_err(|_| anyhow!("无法连接任务数据库"))?;
    let active = if let Some(live) = live {
        db.query_opt(
            "UPDATE async_tasks t SET live=$3 FROM users owner
             WHERE t.id=$1 AND t.started_at=$2 AND t.status='running'
               AND owner.id=t.owner_id AND NOT owner.disabled RETURNING t.id",
            &[&task.id, &task.started_at, &live],
        )
        .await?
    } else {
        db.query_opt(
            "SELECT t.id FROM async_tasks t JOIN users owner ON owner.id=t.owner_id
             WHERE t.id=$1 AND t.started_at=$2 AND t.status='running' AND NOT owner.disabled",
            &[&task.id, &task.started_at],
        )
        .await?
    };
    Ok(active.is_some())
}

async fn claim(state: &AppState) -> anyhow::Result<Option<Task>> {
    let db = state
        .connection()
        .await
        .map_err(|_| anyhow!("无法连接任务数据库"))?;
    db.execute(
        "UPDATE async_tasks SET status='failed', finished_at=now(), error='执行中断，请重新提交任务'
         WHERE status='running' AND (started_at IS NULL OR started_at <= now() - $1 * interval '1 second')",
        &[&(CLAIM_EXPIRY_SECONDS as f64)],
    ).await?;
    let row = db
        .query_opt(
            "WITH due AS (
            SELECT t.id FROM async_tasks t JOIN users owner ON owner.id=t.owner_id
            WHERE t.status='queued' AND t.scheduled_for <= now() AND NOT owner.disabled
            ORDER BY t.scheduled_for, t.id LIMIT 1 FOR UPDATE OF t SKIP LOCKED
         )
         UPDATE async_tasks t SET status='running', started_at=now(), finished_at=NULL, error=NULL,
            attempt=attempt+1,live='{}'::jsonb
         FROM due WHERE t.id=due.id
         RETURNING t.id,t.owner_id,t.upstream_id,t.model,t.reasoning_effort,t.started_at,t.prompt_name,t.prompt_text",
            &[],
        )
        .await?;
    Ok(row.map(|row| Task {
        id: row.get(0),
        owner_id: row.get(1),
        upstream_id: row.get(2),
        model: row.get(3),
        effort: row.get(4),
        started_at: row.get(5),
        prompt_name: row.get(6),
        prompt_text: row.get(7),
    }))
}

async fn execute(
    state: &AppState,
    task: &Task,
    progress: watch::Sender<Value>,
) -> anyhow::Result<Upload> {
    let db = state
        .connection()
        .await
        .map_err(|_| anyhow!("无法连接任务数据库"))?;
    let row = db
        .query_opt(
            "SELECT u.base_url,u.api_key_ciphertext,u.model,u.prompt,u.enabled,u.provider_type,u.name
         FROM cloud_upstreams u JOIN users owner ON owner.id=u.owner_id
         WHERE u.id=$1 AND u.owner_id=$2 AND NOT owner.disabled",
            &[&task.upstream_id, &task.owner_id],
        )
        .await
        .map_err(|_| anyhow!("无法加载任务渠道"))?
        .context("任务渠道不可用")?;
    drop(db);
    anyhow::ensure!(row.get::<_, bool>(4), "任务渠道已禁用");
    let (prompt_name, prompt) = match (&task.prompt_name, &task.prompt_text) {
        (Some(name), Some(text)) => (name.clone(), text.clone()),
        _ => {
            let text: String = row.get(3);
            if text.trim().is_empty() {
                (PELICAN_NAME.into(), PELICAN_PROMPT.trim().into())
            } else {
                ("渠道提示词".into(), text)
            }
        }
    };
    let channel = benchmark::Channel {
        base_url: row.get(0),
        credential: row.get(1),
        model: if task.model.trim().is_empty() {
            row.get(2)
        } else {
            task.model.clone()
        },
        name: row.get(6),
        prompt_name,
        prompt,
        provider: row.get(5),
        effort: &task.effort,
        started_at: task.started_at,
        progress: Some(progress),
    };
    benchmark::measure(channel).await
}

async fn finish(
    state: &AppState,
    task: &Task,
    result: anyhow::Result<Upload>,
) -> anyhow::Result<()> {
    let mut db = state
        .connection()
        .await
        .map_err(|_| anyhow!("无法连接任务数据库"))?;
    let transaction = db.transaction().await?;
    let owner = transaction
        .query_opt(
            "SELECT disabled FROM users WHERE id=$1 FOR SHARE",
            &[&task.owner_id],
        )
        .await?;
    if owner.is_none_or(|owner| owner.get::<_, bool>(0)) {
        return Ok(());
    }
    let active = transaction.query_opt(
        "SELECT id FROM async_tasks WHERE id=$1 AND started_at=$2 AND status='running' FOR UPDATE",
        &[&task.id, &task.started_at],
    ).await?;
    if active.is_none() {
        return Ok(());
    }
    let succeeded = result.is_ok();
    match result {
        Ok(report) => {
            let stored = reports::insert(&transaction, task.owner_id, &report).await?;
            let report_id: i64 = stored.get(0);
            transaction.execute(
                "UPDATE async_tasks SET status='completed', report_id=$2, finished_at=now() WHERE id=$1",
                &[&task.id, &report_id],
            ).await?;
        }
        Err(error) => {
            let message = error.to_string();
            transaction.execute(
                "UPDATE async_tasks SET status='failed', error=$2, finished_at=now() WHERE id=$1",
                &[&task.id, &message],
            ).await?;
        }
    }
    transaction.commit().await?;
    drop(db);
    if succeeded {
        cache::clear(state).await
    }
    Ok(())
}
