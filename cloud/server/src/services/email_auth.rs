use super::{auth, identity_settings, mail, site_settings};
use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    state::AppState,
};
use rand::Rng;
use ring::hmac;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct EmailCodeRequest {
    pub email: String,
    pub purpose: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PasswordReset {
    pub email: String,
    pub code: String,
    pub new_password: String,
}

pub(crate) fn normalize_email(email: &str) -> ServiceResult<String> {
    let email = email.trim().to_lowercase();
    if email.len() > 254
        || email.parse::<lettre::Address>().is_err()
        || email.contains(['\r', '\n'])
    {
        return Err(err(ErrorKind::InvalidInput, "请输入有效的邮箱地址"));
    }
    Ok(email)
}

fn code_message(email: &str, purpose: &str, code: &str) -> String {
    format!("ai-detect/email-code/v1\0{email}\0{purpose}\0{code}")
}

fn key(state: &AppState) -> hmac::Key {
    hmac::Key::new(hmac::HMAC_SHA256, state.jwt_secret.as_bytes())
}

pub(crate) async fn send_code(state: &AppState, input: EmailCodeRequest) -> ServiceResult<Value> {
    let email = normalize_email(&input.email)?;
    if !["register", "reset"].contains(&input.purpose.as_str()) {
        return Err(err(ErrorKind::InvalidInput, "验证码用途不正确"));
    }
    if input.purpose == "register" && !site_settings::get(state).await?.registration_enabled {
        return Err(err(ErrorKind::Forbidden, "注册已关闭，请联系管理员"));
    }
    let config = identity_settings::load(state).await?;
    if !config.smtp.enabled {
        return Err(err(
            ErrorKind::InvalidInput,
            "邮件服务尚未配置，请联系管理员",
        ));
    }
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    transaction
        .query_one(
            "SELECT pg_advisory_xact_lock(hashtextextended($1,812711))",
            &[&email],
        )
        .await
        .map_err(AppError::internal)?;
    let row = transaction.query_one(
        "SELECT count(*),count(*) FILTER(WHERE requested_at>clock_timestamp()-interval '60 seconds')
         FROM email_delivery_attempts WHERE email=$1 AND requested_at>clock_timestamp()-interval '1 hour'", &[&email],
    ).await.map_err(AppError::internal)?;
    if row.get::<_, i64>(0) >= 5 || row.get::<_, i64>(1) > 0 {
        return Err(err(
            ErrorKind::QuotaExceeded,
            "验证码发送过于频繁，请一分钟后重试；每小时最多 5 次",
        ));
    }
    transaction
        .execute(
            "DELETE FROM email_delivery_attempts WHERE requested_at<now()-interval '1 day'",
            &[],
        )
        .await
        .map_err(AppError::internal)?;
    transaction
        .execute(
            "INSERT INTO email_delivery_attempts(email) VALUES($1)",
            &[&email],
        )
        .await
        .map_err(AppError::internal)?;
    let account = transaction
        .query_opt("SELECT disabled FROM users WHERE email=$1", &[&email])
        .await
        .map_err(AppError::internal)?;
    // Reset requests intentionally have one response for unknown and disabled accounts.
    let deliver = match input.purpose.as_str() {
        "reset" => account.is_some_and(|row| !row.get::<_, bool>(0)),
        _ => account.is_none(),
    };
    if deliver {
        let code = format!("{:06}", rand::rng().random_range(0..1000000u32));
        let hash = hmac::sign(
            &key(state),
            code_message(&email, &input.purpose, &code).as_bytes(),
        )
        .as_ref()
        .to_vec();
        transaction.execute(
            "INSERT INTO email_challenges(email,purpose,code_hash,expires_at) VALUES($1,$2,$3,clock_timestamp()+interval '15 minutes')
             ON CONFLICT(email,purpose) DO UPDATE SET code_hash=excluded.code_hash,expires_at=excluded.expires_at,attempts=0",
            &[&email,&input.purpose,&hash],
        ).await.map_err(AppError::internal)?;
        let purpose = if input.purpose == "reset" {
            "重置密码"
        } else {
            "注册账号"
        };
        mail::send(&config.smtp, &email, &format!("AI质量检测 · {purpose}验证码"),
            &format!("您正在{purpose}。\n\n验证码：{code}\n\n15 分钟内有效，仅可使用一次，请勿向他人透露。\n如果不是您本人操作，请忽略此邮件。"),
        ).await?;
    }
    transaction.commit().await.map_err(AppError::internal)?;
    Ok(json!({"ok":true,"message":"若该邮箱可用于此操作，验证码已发送，请检查收件箱。"}))
}

// The caller commits failed attempts, and commits successful consumption with the account mutation.
pub(crate) async fn consume_code(
    transaction: &deadpool_postgres::Transaction<'_>,
    state: &AppState,
    email: &str,
    purpose: &str,
    code: &str,
) -> ServiceResult<bool> {
    let row = transaction.query_opt(
        "SELECT code_hash FROM email_challenges WHERE email=$1 AND purpose=$2 AND attempts<5 AND expires_at>clock_timestamp() FOR UPDATE",
        &[&email,&purpose],
    ).await.map_err(AppError::internal)?;
    let Some(row) = row else { return Ok(false) };
    let hash: Vec<u8> = row.get(0);
    let matches = hmac::verify(
        &key(state),
        code_message(email, purpose, code.trim()).as_bytes(),
        &hash,
    )
    .is_ok();
    if matches {
        transaction
            .execute(
                "DELETE FROM email_challenges WHERE email=$1 AND purpose=$2",
                &[&email, &purpose],
            )
            .await
            .map_err(AppError::internal)?;
    } else {
        transaction
            .execute(
                "UPDATE email_challenges SET attempts=attempts+1 WHERE email=$1 AND purpose=$2",
                &[&email, &purpose],
            )
            .await
            .map_err(AppError::internal)?;
    }
    Ok(matches)
}

pub(crate) async fn reset_password(state: &AppState, input: PasswordReset) -> ServiceResult<Value> {
    let email = normalize_email(&input.email)?;
    auth::validate_password(&input.new_password)?;
    let hash = auth::hash_password(&input.new_password).map_err(AppError::internal)?;
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    if !consume_code(&transaction, state, &email, "reset", &input.code).await? {
        transaction.commit().await.map_err(AppError::internal)?;
        return Err(err(
            ErrorKind::InvalidInput,
            "邮箱验证码无效、已使用或已过期",
        ));
    }
    let count = transaction.execute(
        "UPDATE users SET password_hash=$1,auth_version=auth_version+1,email_verified=TRUE WHERE email=$2 AND NOT disabled", &[&hash,&email],
    ).await.map_err(AppError::internal)?;
    if count != 1 {
        return Err(err(ErrorKind::InvalidInput, "无法重置此账号的密码"));
    }
    transaction.commit().await.map_err(AppError::internal)?;
    Ok(json!({"ok":true}))
}
