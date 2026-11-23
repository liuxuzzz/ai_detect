use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    services::site_settings,
    state::AppState,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const CONFIG_OWNER: i64 = -1;

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub(crate) struct ProviderConfig {
    pub enabled: bool,
    pub client_id: String,
    pub client_secret: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub(crate) struct SmtpConfig {
    pub enabled: bool,
    pub host: String,
    pub port: u16,
    pub security: String,
    pub username: String,
    pub password: String,
    pub from_address: String,
    pub from_name: String,
}

impl Default for SmtpConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            host: String::new(),
            port: 465,
            security: "tls".into(),
            username: String::new(),
            password: String::new(),
            from_address: String::new(),
            from_name: "AI质量检测".into(),
        }
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub(crate) struct IdentityConfig {
    pub smtp: SmtpConfig,
    pub github: ProviderConfig,
    pub google: ProviderConfig,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct IdentityUpdate {
    pub smtp: Option<SmtpConfig>,
    pub github: Option<ProviderConfig>,
    pub google: Option<ProviderConfig>,
}

fn decode(state: &AppState, encrypted: Option<Vec<u8>>) -> ServiceResult<IdentityConfig> {
    match encrypted {
        None => Ok(IdentityConfig::default()),
        Some(data) => serde_json::from_str(
            &state
                .client_key_cipher
                .decrypt(CONFIG_OWNER, data)
                .map_err(AppError::internal)?,
        )
        .map_err(AppError::internal),
    }
}

pub(crate) async fn load(state: &AppState) -> ServiceResult<IdentityConfig> {
    let row = state
        .connection()
        .await?
        .query_one(
            "SELECT encrypted_config FROM identity_settings WHERE singleton",
            &[],
        )
        .await
        .map_err(AppError::internal)?;
    decode(state, row.get(0))
}

pub(crate) fn provider<'a>(
    config: &'a IdentityConfig,
    name: &str,
) -> ServiceResult<&'a ProviderConfig> {
    let provider = match name {
        "github" => &config.github,
        "google" => &config.google,
        _ => return Err(err(ErrorKind::NotFound, "登录方式不存在")),
    };
    if !provider.enabled
        || provider.client_id.trim().is_empty()
        || provider.client_secret.is_empty()
    {
        return Err(err(ErrorKind::NotFound, "该登录方式未启用"));
    }
    Ok(provider)
}

pub(crate) async fn callback_url(state: &AppState, provider: &str) -> ServiceResult<String> {
    site_settings::page_url(state, &format!("/api/auth/oauth/{provider}/callback")).await
}

pub(crate) async fn public_admin_view(
    state: &AppState,
    config: &IdentityConfig,
) -> ServiceResult<Value> {
    let mut view = serde_json::to_value(config).expect("serializable configuration");
    view["smtp"]["password_set"] = json!(!config.smtp.password.is_empty());
    view["smtp"]["password"] = json!("");
    for name in ["github", "google"] {
        let provider = if name == "github" {
            &config.github
        } else {
            &config.google
        };
        view[name]["client_secret_set"] = json!(!provider.client_secret.is_empty());
        view[name]["client_secret"] = json!("");
        view[name]["callback_url"] = json!(callback_url(state, name).await?);
    }
    Ok(view)
}

fn validate(config: &IdentityConfig) -> ServiceResult<()> {
    let smtp = &config.smtp;
    if !["tls", "starttls", "plain"].contains(&smtp.security.as_str()) || smtp.port == 0 {
        return Err(err(
            ErrorKind::InvalidInput,
            "请选择有效的 SMTP 端口和加密方式",
        ));
    }
    if smtp.enabled
        && (smtp.host.trim().is_empty()
            || smtp.host.contains(['/', '\r', '\n'])
            || smtp.from_address.parse::<lettre::Address>().is_err()
            || smtp.from_name.contains(['\r', '\n'])
            || (!smtp.username.is_empty() && smtp.password.is_empty()))
    {
        return Err(err(
            ErrorKind::InvalidInput,
            "SMTP 配置不完整，请检查服务器、发件邮箱及认证信息",
        ));
    }
    for provider in [&config.github, &config.google] {
        if provider.enabled
            && (provider.client_id.trim().is_empty() || provider.client_secret.is_empty())
        {
            return Err(err(
                ErrorKind::InvalidInput,
                "启用第三方登录前，请填写 Client ID 和 Client Secret",
            ));
        }
    }
    Ok(())
}

pub(crate) async fn update(state: &AppState, input: IdentityUpdate) -> ServiceResult<Value> {
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    let row = transaction
        .query_one(
            "SELECT encrypted_config FROM identity_settings WHERE singleton FOR UPDATE",
            &[],
        )
        .await
        .map_err(AppError::internal)?;
    let mut config = decode(state, row.get(0))?;
    if let Some(mut smtp) = input.smtp {
        if smtp.password.is_empty() {
            smtp.password = config.smtp.password;
        }
        config.smtp = smtp;
    }
    if let Some(mut provider) = input.github {
        if provider.client_secret.is_empty() {
            provider.client_secret = config.github.client_secret;
        }
        config.github = provider;
    }
    if let Some(mut provider) = input.google {
        if provider.client_secret.is_empty() {
            provider.client_secret = config.google.client_secret;
        }
        config.google = provider;
    }
    validate(&config)?;
    let data = state
        .client_key_cipher
        .encrypt(
            CONFIG_OWNER,
            &serde_json::to_string(&config).map_err(AppError::internal)?,
        )
        .map_err(AppError::internal)?;
    transaction
        .execute(
            "UPDATE identity_settings SET encrypted_config=$1 WHERE singleton",
            &[&data],
        )
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    public_admin_view(state, &config).await
}
