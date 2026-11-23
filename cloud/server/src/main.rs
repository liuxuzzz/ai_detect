use aijiance_cloud::{config::Settings, routes, state::AppState, task_runner};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt::init();

    let settings = Settings::from_environment()?;
    let state = AppState::from_settings(&settings).await?;
    let listener = tokio::net::TcpListener::bind(settings.bind_address).await?;
    tracing::info!(address = %settings.bind_address, "server listening");
    let mut queue_task = tokio::spawn(task_runner::run(state.clone()));
    tokio::select! {
        result = axum::serve(listener, routes::application(state, "static")) => {
            queue_task.abort();
            let _ = queue_task.await;
            result?;
        }
        result = &mut queue_task => {
            result?;
            anyhow::bail!("queue task exited unexpectedly");
        }
    }
    Ok(())
}
