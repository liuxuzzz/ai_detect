use crate::{
    config::Settings,
    error::{AppError, ServiceResult},
    services,
};
use deadpool_postgres::{Manager, Object, Pool};
use tokio_postgres::NoTls;

#[derive(Clone)]
pub struct AppState {
    db: Pool,
    pub(crate) jwt_secret: String,
    pub(crate) client_key_cipher: std::sync::Arc<services::key_cipher::KeyCipher>,
    pub(crate) task_limit: i64,
    pub(crate) cache: Option<redis::Client>,
}

impl AppState {
    pub async fn from_settings(settings: &Settings) -> anyhow::Result<Self> {
        anyhow::ensure!(
            settings.database_pool_size > 0,
            "DATABASE_POOL_SIZE 必须大于 0"
        );
        let manager = Manager::new(settings.database_url.parse()?, NoTls);
        let db = Pool::builder(manager)
            .max_size(settings.database_pool_size)
            .build()?;

        {
            let client = db.get().await?;
            services::db::initialize(&client).await?;
        }

        Ok(Self {
            db,
            jwt_secret: settings.jwt_secret.clone(),
            client_key_cipher: std::sync::Arc::new(services::key_cipher::KeyCipher::new(
                settings
                    .client_key_encryption_secret
                    .as_deref()
                    .unwrap_or(&settings.jwt_secret),
            )?),
            task_limit: settings.task_daily_limit,
            cache: redis::Client::open(settings.redis_url.as_str()).ok(),
        })
    }

    pub(crate) async fn connection(&self) -> ServiceResult<Object> {
        self.db.get().await.map_err(AppError::internal)
    }
}
