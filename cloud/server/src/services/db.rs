use crate::state::AppState;
use tokio_postgres::{Client, Row};

pub async fn initialize(client: &Client) -> anyhow::Result<()> {
    let sql = concat!(
        include_str!("../../migrations/001_init.sql"),
        "\n",
        include_str!("../../migrations/002_cloud_dashboard.sql"),
        "\n",
        include_str!("../../migrations/003_public_rankings.sql"),
        "\n",
        include_str!("../../migrations/004_report_measurements.sql"),
        "\n",
        include_str!("../../migrations/005_report_display_time.sql"),
        "\n",
        include_str!("../../migrations/006_task_results_and_key_secrets.sql"),
        "\n",
        include_str!("../../migrations/007_task_prompts.sql"),
        "\n",
        include_str!("../../migrations/008_account_sessions.sql"),
        "\n",
        include_str!("../../migrations/009_prompts_and_task_monitoring.sql"),
        "\n",
        include_str!("../../migrations/010_structured_reports.sql"),
        "\n",
        include_str!("../../migrations/011_registration_settings.sql"),
        "\n",
        include_str!("../../migrations/012_upload_policy.sql"),
        "\n",
        include_str!("../../migrations/013_identity.sql"),
        "\n",
        include_str!("../../migrations/014_site_url.sql"),
        "\n",
        include_str!("../../migrations/015_report_visibility.sql"),
        "\n",
        include_str!("../../migrations/016_report_ranking_override.sql")
    );
    client.batch_execute(sql).await?;
    super::report_legacy::migrate(client).await?;
    client.execute(
        "INSERT INTO managed_prompts(name,content,preset_key) VALUES($1,$2,'pelican') ON CONFLICT(preset_key) DO NOTHING",
        &[&super::tasks::PELICAN_NAME, &super::tasks::PELICAN_PROMPT.trim()],
    ).await?;
    Ok(())
}

pub async fn user(state: &AppState, id: i64) -> Option<Row> {
    state
        .connection()
        .await
        .ok()?
        .query_opt(
            "SELECT id,email,is_admin,disabled,auth_version,is_superadmin,public_reports FROM users WHERE id=$1",
            &[&id],
        )
        .await
        .ok()
        .flatten()
}
