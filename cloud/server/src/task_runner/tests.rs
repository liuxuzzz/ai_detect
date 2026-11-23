use super::*;
use crate::{
    config::Settings,
    models::{TaskAction, UserPatch},
    services::{admin, task_control},
};
use std::{
    env,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

struct Dropped(Arc<AtomicBool>);
impl Drop for Dropped {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

#[tokio::test]
#[ignore = "requires an isolated PostgreSQL database at TEST_DATABASE_URL"]
async fn task_controls_cancel_execution_and_fence_late_results() {
    let email = format!("runner-{}@example.test", rand::random::<u64>());
    let settings = Settings {
        database_url: env::var("TEST_DATABASE_URL").expect("set TEST_DATABASE_URL"),
        database_pool_size: 8,
        jwt_secret: "isolated-runner-jwt".into(),
        client_key_encryption_secret: None,
        bind_address: "127.0.0.1:0".parse().unwrap(),
        redis_url: "disabled".into(),
        task_daily_limit: 20,
        api_public_url: "http://localhost:6601".into(),
    };
    let state = AppState::from_settings(&settings).await.unwrap();
    let db = state.connection().await.unwrap();
    let owner: i64 = db
        .query_one("INSERT INTO users(email,password_hash) VALUES($1,'isolated-runner-no-login') RETURNING id", &[&email])
        .await
        .unwrap()
        .get(0);
    // Long reasoning requests remain active past the former 16-minute lease.
    let long_running: i64 = db
        .query_one(
            "INSERT INTO async_tasks(owner_id,status,model,scheduled_for,started_at)
         VALUES($1,'running','deadline-fixture',now(),now()-interval '20 minutes') RETURNING id",
            &[&owner],
        )
        .await
        .unwrap()
        .get(0);
    let expired: i64 = db
        .query_one(
            "INSERT INTO async_tasks(owner_id,status,model,scheduled_for,started_at)
         VALUES($1,'running','deadline-fixture',now(),now()-interval '62 minutes') RETURNING id",
            &[&owner],
        )
        .await
        .unwrap()
        .get(0);
    assert!(claim(&state).await.unwrap().is_none());
    for (id, expected) in [(long_running, "running"), (expired, "failed")] {
        let status: String = db
            .query_one("SELECT status FROM async_tasks WHERE id=$1", &[&id])
            .await
            .unwrap()
            .get(0);
        assert_eq!(status, expected);
        db.execute("DELETE FROM async_tasks WHERE id=$1", &[&id])
            .await
            .unwrap();
    }
    for action in ["pause", "stop", "delete", "disable"] {
        let row = db
            .query_one(
                "INSERT INTO async_tasks(owner_id,status,model,scheduled_for,started_at,attempt)
             VALUES($1,'running','live-fixture','2000-01-01',now(),1) RETURNING id,started_at",
                &[&owner],
            )
            .await
            .unwrap();
        let task = Task {
            id: row.get(0),
            owner_id: owner,
            upstream_id: None,
            model: "live-fixture".into(),
            effort: "high".into(),
            started_at: row.get(1),
            prompt_name: None,
            prompt_text: None,
        };
        let (sender, progress) = watch::channel(json!({}));
        let dropped = Arc::new(AtomicBool::new(false));
        let probe = dropped.clone();
        let execution = async move {
            let _guard = Dropped(probe);
            sender.send_replace(
                json!({"output": "visible before completion", "reasoning": "partial reasoning"}),
            );
            std::future::pending::<anyhow::Result<Upload>>().await
        };
        let runner_state = state.clone();
        let running = task.clone();
        let runner = tokio::spawn(async move {
            drive_execution(&runner_state, &running, execution, progress).await
        });
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let live: Value = db
                    .query_one("SELECT live FROM async_tasks WHERE id=$1", &[&task.id])
                    .await
                    .unwrap()
                    .get(0);
                if live["output"] == "visible before completion" {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        match action {
            "pause" => {
                task_control::control(&state, task.id, TaskAction::Pause)
                    .await
                    .unwrap();
            }
            "stop" => {
                task_control::control(&state, task.id, TaskAction::Stop)
                    .await
                    .unwrap();
            }
            "delete" => {
                task_control::delete(&state, task.id).await.unwrap();
            }
            "disable" => {
                admin::patch_user(
                    &state,
                    owner,
                    UserPatch {
                        disabled: Some(true),
                        is_admin: None,
                    },
                )
                .await
                .unwrap();
            }
            _ => unreachable!(),
        }
        tokio::time::timeout(Duration::from_secs(3), runner)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(
            dropped.load(Ordering::SeqCst),
            "execution must be dropped on {action}"
        );
        if action == "pause" {
            task_control::control(&state, task.id, TaskAction::Resume)
                .await
                .unwrap();
            let resumed = claim(&state).await.unwrap().unwrap();
            assert_eq!(resumed.id, task.id);
            assert_ne!(resumed.started_at, task.started_at);
            // An old request finishing after resume must not publish into the new attempt.
        }
        finish(
            &state,
            &task,
            Ok(Upload {
                data: crate::models::ReportData {
                    output: "late result".into(),
                    ..Default::default()
                },
                api_domain: "example.test".into(),
                model: "live-fixture".into(),
                prompt_name: "fixture".into(),
                metadata: json!({}),
            }),
        )
        .await
        .unwrap();
        let reports: i64 = db
            .query_one("SELECT count(*) FROM reports WHERE owner_id=$1", &[&owner])
            .await
            .unwrap()
            .get(0);
        assert_eq!(reports, 0, "late {action} result must not be published");
        if action == "pause" {
            task_control::control(&state, task.id, TaskAction::Stop)
                .await
                .unwrap();
        }
        if action == "disable" {
            assert!(claim(&state).await.unwrap().is_none());
        }
    }
    db.execute("DELETE FROM users WHERE id=$1", &[&owner])
        .await
        .unwrap();
}
