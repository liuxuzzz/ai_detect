mod providers;

use super::{auth, email_auth, identity_settings, site_settings};
use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    state::AppState,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::digest::{digest, SHA256};
use serde::Deserialize;
use serde_json::{json, Value};

pub(crate) fn hash(value: &str) -> Vec<u8> {
    digest(&SHA256, value.as_bytes()).as_ref().to_vec()
}

pub(crate) fn cookie_name(state: &str) -> String {
    format!("aij_oauth_{}", state.chars().take(12).collect::<String>())
}

pub(crate) struct Authorization {
    pub url: String,
    pub cookie: String,
}

pub(crate) async fn start(state: &AppState, name: &str) -> ServiceResult<Authorization> {
    let config = identity_settings::load(state).await?;
    let provider = identity_settings::provider(&config, name)?;
    if site_settings::get(state).await?.site_url.is_empty() {
        return Err(err(ErrorKind::InvalidInput, "请先在管理中心保存站点地址"));
    }
    let redirect_uri = identity_settings::callback_url(state, name).await?;
    let token = auth::random_token(48);
    let browser = auth::random_token(48);
    let verifier = auth::random_token(64);
    let challenge = URL_SAFE_NO_PAD.encode(hash(&verifier));
    let encrypted = state
        .client_key_cipher
        .encrypt(-2, &verifier)
        .map_err(AppError::internal)?;
    let fingerprint = config_hash(provider);
    let db = state.connection().await?;
    db.execute("DELETE FROM oauth_states WHERE expires_at<now()", &[])
        .await
        .map_err(AppError::internal)?;
    db.execute(
        "INSERT INTO oauth_states(state_hash,browser_hash,provider,verifier,config_hash,expires_at) VALUES($1,$2,$3,$4,$5,clock_timestamp()+interval '10 minutes')",
        &[&hash(&token),&hash(&browser),&name,&encrypted,&fingerprint],
    ).await.map_err(AppError::internal)?;
    let mut url = reqwest::Url::parse(match name {
        "github" => "https://github.com/login/oauth/authorize",
        "google" => "https://accounts.google.com/o/oauth2/v2/auth",
        _ => return Err(err(ErrorKind::NotFound, "登录方式不存在")),
    })
    .map_err(AppError::internal)?;
    url.query_pairs_mut().extend_pairs([
        ("client_id", provider.client_id.as_str()),
        ("redirect_uri", redirect_uri.as_str()),
        ("response_type", "code"),
        (
            "scope",
            if name == "github" {
                "read:user user:email"
            } else {
                "openid email profile"
            },
        ),
        ("state", token.as_str()),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
    ]);
    let secure = if redirect_uri.starts_with("https://") {
        "; Secure"
    } else {
        ""
    };
    // Host-only cookie; state remains bound to the browser that began this login.
    let cookie = format!(
        "{}={browser}; HttpOnly; SameSite=Lax; Path=/; Max-Age=600{secure}",
        cookie_name(&token)
    );
    Ok(Authorization {
        url: url.to_string(),
        cookie,
    })
}

fn config_hash(provider: &identity_settings::ProviderConfig) -> Vec<u8> {
    hash(&format!(
        "{}\0{}",
        provider.client_id, provider.client_secret
    ))
}

#[derive(Deserialize)]
pub(crate) struct Callback {
    pub code: Option<String>,
    pub state: Option<String>,
    pub error: Option<String>,
}

pub(crate) async fn callback(
    state: &AppState,
    name: &str,
    input: Callback,
    cookies: &str,
) -> ServiceResult<String> {
    let token = input
        .state
        .ok_or_else(|| err(ErrorKind::InvalidInput, "登录状态缺失，请重新登录"))?;
    let cookie_name = cookie_name(&token);
    let browser = cookies
        .split(';')
        .filter_map(|part| part.trim().split_once('='))
        .find(|(key, _)| *key == cookie_name)
        .map(|(_, value)| value)
        .ok_or_else(|| err(ErrorKind::InvalidInput, "登录浏览器校验失败，请重新登录"))?;
    let row = state.connection().await?.query_opt(
        "DELETE FROM oauth_states WHERE state_hash=$1 AND browser_hash=$2 AND provider=$3 AND expires_at>clock_timestamp()
         RETURNING verifier,config_hash", &[&hash(&token),&hash(browser),&name],
    ).await.map_err(AppError::internal)?
        .ok_or_else(||err(ErrorKind::InvalidInput,"登录已过期或已使用，请重新登录"))?;
    if input.error.is_some() {
        return Err(err(ErrorKind::InvalidInput, "第三方登录已取消"));
    }
    let code = input
        .code
        .filter(|code| !code.is_empty())
        .ok_or_else(|| err(ErrorKind::InvalidInput, "登录授权码缺失"))?;
    let config = identity_settings::load(state).await?;
    let provider = identity_settings::provider(&config, name)?;
    if config_hash(provider) != row.get::<_, Vec<u8>>(1) {
        return Err(err(ErrorKind::InvalidInput, "登录配置已更新，请重新登录"));
    }
    let verifier = state
        .client_key_cipher
        .decrypt(-2, row.get(0))
        .map_err(AppError::internal)?;
    let redirect_uri = identity_settings::callback_url(state, name).await?;
    let identity = providers::exchange(name, provider, &redirect_uri, &code, &verifier).await?;
    let user = resolve_account(state, name, &identity).await?;
    create_ticket(state, user).await
}

async fn resolve_account(
    state: &AppState,
    name: &str,
    identity: &providers::Identity,
) -> ServiceResult<i64> {
    let email = email_auth::normalize_email(&identity.email)?;
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    auth::lock_registration(&transaction).await?;
    let existing = transaction.query_opt(
        "SELECT u.id,u.disabled FROM oauth_identities i JOIN users u ON u.id=i.user_id WHERE i.provider=$1 AND i.subject=$2 FOR UPDATE OF u",
        &[&name,&identity.subject],
    ).await.map_err(AppError::internal)?;
    let id = if let Some(row) = existing {
        if row.get::<_, bool>(1) {
            return Err(err(ErrorKind::Forbidden, "账号已禁用"));
        }
        row.get::<_, i64>(0)
    } else {
        let existing = transaction
            .query_opt(
                "SELECT id,email_verified,disabled FROM users WHERE email=$1 FOR UPDATE",
                &[&email],
            )
            .await
            .map_err(AppError::internal)?;
        let id = if let Some(row) = existing {
            if row.get::<_, bool>(2) {
                return Err(err(ErrorKind::Forbidden, "账号已禁用"));
            }
            if !row.get::<_, bool>(1) {
                return Err(err(
                    ErrorKind::Conflict,
                    "该邮箱已有未验证账号，请先通过邮箱找回密码完成验证，再使用第三方登录",
                ));
            }
            row.get::<_, i64>(0)
        } else {
            site_settings::require_registration(&transaction).await?;
            let first: bool = transaction
                .query_one("SELECT NOT EXISTS(SELECT 1 FROM users)", &[])
                .await
                .map_err(AppError::internal)?
                .get(0);
            transaction.query_one("INSERT INTO users(email,password_hash,is_admin,is_superadmin,email_verified) VALUES($1,'',$2,$2,TRUE) RETURNING id",&[&email,&first])
                .await.map_err(AppError::internal)?.get(0)
        };
        transaction
            .execute(
                "INSERT INTO oauth_identities(provider,subject,user_id) VALUES($1,$2,$3)",
                &[&name, &identity.subject, &id],
            )
            .await
            .map_err(AppError::internal)?;
        id
    };
    transaction.commit().await.map_err(AppError::internal)?;
    Ok(id)
}

async fn create_ticket(state: &AppState, id: i64) -> ServiceResult<String> {
    let ticket = auth::random_token(48);
    let db = state.connection().await?;
    db.execute("DELETE FROM oauth_tickets WHERE expires_at<now()", &[])
        .await
        .map_err(AppError::internal)?;
    let count=db.execute(
        "INSERT INTO oauth_tickets(token_hash,user_id,auth_version,expires_at)
         SELECT $1,id,auth_version,clock_timestamp()+interval '60 seconds' FROM users WHERE id=$2 AND NOT disabled",
        &[&hash(&ticket),&id],
    ).await.map_err(AppError::internal)?;
    if count != 1 {
        return Err(err(ErrorKind::Forbidden, "账号已禁用"));
    }
    Ok(ticket)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TicketExchange {
    pub code: String,
}

pub(crate) async fn exchange_ticket(
    state: &AppState,
    input: TicketExchange,
) -> ServiceResult<Value> {
    let row=state.connection().await?.query_opt(
        "DELETE FROM oauth_tickets t USING users u WHERE t.token_hash=$1 AND t.user_id=u.id AND NOT u.disabled
         AND t.auth_version=u.auth_version AND t.expires_at>clock_timestamp() RETURNING t.user_id,t.auth_version",&[&hash(&input.code)],
    ).await.map_err(AppError::internal)?
        .ok_or_else(||err(ErrorKind::Unauthenticated,"登录凭据已过期或已使用，请重新登录"))?;
    auth::session_for_user(state, row.get(0), row.get(1)).await
}

pub(crate) async fn options(state: &AppState) -> ServiceResult<Value> {
    let config = identity_settings::load(state).await?;
    let bootstrap: bool = state
        .connection()
        .await?
        .query_one("SELECT NOT EXISTS(SELECT 1 FROM users)", &[])
        .await
        .map_err(AppError::internal)?
        .get(0);
    Ok(
        json!({"registration_enabled":site_settings::get(state).await?.registration_enabled,
        "bootstrap_required":bootstrap,"email_verification":config.smtp.enabled && !bootstrap,
        "password_reset":config.smtp.enabled,
        "github":identity_settings::provider(&config,"github").is_ok(),
        "google":identity_settings::provider(&config,"google").is_ok()}),
    )
}

#[cfg(test)]
mod tests;
