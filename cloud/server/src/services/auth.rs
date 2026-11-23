use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{Claims, ClientKeyInfo, CreatedClientKey, Credentials, PasswordChange},
    services::{db::user, site_settings},
    state::AppState,
};
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use chrono::{Duration, Utc};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use rand::{distr::Alphanumeric, Rng};
use rand_core::OsRng;
use serde_json::{json, Value};
use tokio_postgres::Row;

pub(crate) async fn register(state: &AppState, credentials: Credentials) -> ServiceResult<Value> {
    let email = super::email_auth::normalize_email(&credentials.email)?;
    validate_password(&credentials.password)?;
    let config = super::identity_settings::load(state).await?;
    let hash = hash_password(&credentials.password).map_err(AppError::internal)?;
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    lock_registration(&transaction).await?;
    site_settings::require_registration(&transaction).await?;
    let first: bool = transaction
        .query_one("SELECT NOT EXISTS(SELECT 1 FROM users)", &[])
        .await
        .map_err(AppError::internal)?
        .get(0);
    let verified = if config.smtp.enabled && !first {
        if !super::email_auth::consume_code(
            &transaction,
            state,
            &email,
            "register",
            &credentials.email_code,
        )
        .await?
        {
            transaction.commit().await.map_err(AppError::internal)?;
            return Err(err(
                ErrorKind::InvalidInput,
                "邮箱验证码无效、已使用或已过期",
            ));
        }
        true
    } else {
        false
    };
    let row = transaction.query_one(
        "INSERT INTO users(email,password_hash,is_admin,is_superadmin,email_verified) VALUES($1,$2,$3,$3,$4) RETURNING id,email,is_superadmin",
        &[&email, &hash, &first, &verified],
    ).await.map_err(|error| {
        if error.code() == Some(&tokio_postgres::error::SqlState::UNIQUE_VIOLATION) {
            err(ErrorKind::Conflict, "邮箱已注册")
        } else { AppError::internal(error) }
    })?;
    transaction.commit().await.map_err(AppError::internal)?;
    Ok(
        json!({"id": row.get::<_, i64>(0), "email": row.get::<_, String>(1), "is_superadmin": row.get::<_, bool>(2)}),
    )
}

pub(crate) async fn lock_registration(
    transaction: &deadpool_postgres::Transaction<'_>,
) -> ServiceResult<()> {
    // One transaction elects the first account, including concurrent provider signups.
    transaction
        .query_one("SELECT pg_advisory_xact_lock(684731926)", &[])
        .await
        .map_err(AppError::internal)?;
    Ok(())
}

pub(crate) fn validate_password(password: &str) -> ServiceResult<()> {
    if password.chars().count() < 8 || password.len() > 1024 {
        return Err(err(
            ErrorKind::InvalidInput,
            "密码至少 8 个字符，最多 1024 字节",
        ));
    }
    Ok(())
}

pub(crate) async fn login(state: &AppState, credentials: Credentials) -> ServiceResult<Value> {
    let email = super::email_auth::normalize_email(&credentials.email)?;
    let row = state
        .connection()
        .await?
        .query_opt(
            "SELECT id,password_hash,disabled,email,is_admin,auth_version,is_superadmin FROM users WHERE email=$1",
            &[&email],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::Unauthenticated, "邮箱或密码错误"))?;
    if row.get::<_, bool>(2) || !verify_password(row.get(1), &credentials.password) {
        return Err(err(ErrorKind::Unauthenticated, "邮箱或密码错误"));
    }
    // Sign the same account snapshot whose password was verified. A concurrent
    // reset increments its version and invalidates this session normally.
    session_response(
        Claims {
            sub: row.get(0),
            email: row.get(3),
            admin: row.get(4),
            auth_version: row.get(5),
            exp: (Utc::now() + Duration::days(30)).timestamp() as usize,
        },
        &state.jwt_secret,
        row.get(6),
    )
}

pub(crate) async fn session_for_user(
    state: &AppState,
    id: i64,
    expected_version: i64,
) -> ServiceResult<Value> {
    let row = user(state, id)
        .await
        .ok_or_else(|| err(ErrorKind::Unauthenticated, "用户不存在"))?;
    if row.get::<_, bool>(3) {
        return Err(err(ErrorKind::Forbidden, "账号已禁用"));
    }
    if row.get::<_, i64>(4) != expected_version {
        return Err(err(
            ErrorKind::Unauthenticated,
            "账号凭据已更新，请重新登录",
        ));
    }
    session_response(
        Claims {
            sub: id,
            email: row.get(1),
            admin: row.get(2),
            auth_version: row.get(4),
            exp: (Utc::now() + Duration::days(30)).timestamp() as usize,
        },
        &state.jwt_secret,
        row.get(5),
    )
}

fn session_response(claims: Claims, secret: &str, is_superadmin: bool) -> ServiceResult<Value> {
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .map_err(AppError::internal)?;
    Ok(json!({"token": token, "user": {
        "id": claims.sub, "email": claims.email, "is_admin": claims.admin, "is_superadmin": is_superadmin
    }}))
}

pub(crate) async fn change_password(
    state: &AppState,
    claims: &Claims,
    input: PasswordChange,
) -> ServiceResult<Value> {
    if input.new_password.chars().count() < 8 || input.new_password.len() > 1024 {
        return Err(err(
            ErrorKind::InvalidInput,
            "新密码至少 8 个字符，最多 1024 字节",
        ));
    }
    if input.current_password == input.new_password {
        return Err(err(ErrorKind::InvalidInput, "新密码不能与当前密码相同"));
    }
    let db = state.connection().await?;
    let row = db
        .query_one(
            "SELECT password_hash FROM users WHERE id=$1",
            &[&claims.sub],
        )
        .await
        .map_err(AppError::internal)?;
    let old_hash: String = row.get(0);
    if !verify_password(&old_hash, &input.current_password) {
        return Err(err(ErrorKind::InvalidInput, "当前密码错误"));
    }
    let new_hash = hash_password(&input.new_password).map_err(AppError::internal)?;
    // Compare the hash and session version so concurrent changes cannot overwrite a newer password.
    let updated = db
        .query_opt(
            "UPDATE users SET password_hash=$1,auth_version=auth_version+1
             WHERE id=$2 AND password_hash=$3 AND auth_version=$4 AND NOT disabled
             RETURNING email,is_admin,auth_version,is_superadmin",
            &[&new_hash, &claims.sub, &old_hash, &claims.auth_version],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::Conflict, "账号状态已变化，请重新登录后再修改"))?;
    session_response(
        Claims {
            sub: claims.sub,
            email: updated.get(0),
            admin: updated.get(1),
            auth_version: updated.get(2),
            exp: (Utc::now() + Duration::days(30)).timestamp() as usize,
        },
        &state.jwt_secret,
        updated.get(3),
    )
}

pub(crate) async fn me(state: &AppState, claims: &Claims) -> ServiceResult<Value> {
    let row = user(state, claims.sub)
        .await
        .ok_or_else(|| err(ErrorKind::NotFound, "用户不存在"))?;
    Ok(json!({
        "id": row.get::<_, i64>(0), "email": row.get::<_, String>(1),
        "is_admin": row.get::<_, bool>(2), "disabled": row.get::<_, bool>(3), "is_superadmin": row.get::<_, bool>(5)
    }))
}

const CLIENT_KEY_PREFIX_LEN: usize = 12;

fn client_key_info(row: Row) -> ClientKeyInfo {
    ClientKeyInfo {
        id: row.get("id"),
        prefix: row.get("key_prefix"),
        created_at: row.get("created_at"),
        revoked_at: row.get("revoked_at"),
        can_reveal: row.get("can_reveal"),
    }
}

pub(crate) async fn list_keys(state: &AppState, user_id: i64) -> ServiceResult<Vec<ClientKeyInfo>> {
    let rows = state
        .connection()
        .await?
        .query(
            "SELECT id, key_prefix, created_at, revoked_at,
                encrypted_secret IS NOT NULL AND revoked_at IS NULL AS can_reveal FROM client_keys
             WHERE user_id = $1 ORDER BY id DESC",
            &[&user_id],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(rows.into_iter().map(client_key_info).collect())
}

pub(crate) async fn create_key(state: &AppState, user_id: i64) -> ServiceResult<CreatedClientKey> {
    let key = format!("aij_{}", random_token(40));
    let hash = hash_password(&key).map_err(AppError::internal)?;
    let encrypted = state
        .client_key_cipher
        .encrypt(user_id, &key)
        .map_err(AppError::internal)?;
    let prefix = &key[..CLIENT_KEY_PREFIX_LEN];
    let row = state
        .connection()
        .await?
        .query_one(
            "INSERT INTO client_keys(user_id,key_hash,key_prefix,encrypted_secret) VALUES($1,$2,$3,$4)
             RETURNING id, key_prefix, created_at, revoked_at, true AS can_reveal",
            &[&user_id, &hash, &prefix, &encrypted],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(CreatedClientKey {
        info: client_key_info(row),
        key,
    })
}

pub(crate) async fn reveal_key(state: &AppState, user_id: i64, id: i64) -> ServiceResult<String> {
    let row = state.connection().await?.query_opt(
        "SELECT encrypted_secret FROM client_keys WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
        &[&id, &user_id],
    ).await.map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "Client Key 不存在或已撤销"))?;
    let encrypted = row.get::<_, Option<Vec<u8>>>(0).ok_or_else(|| {
        err(
            ErrorKind::Conflict,
            "旧版 Key 只能验证，无法显示，请创建新 Key",
        )
    })?;
    state
        .client_key_cipher
        .decrypt(user_id, encrypted)
        .map_err(AppError::internal)
}

pub(crate) async fn revoke_key(state: &AppState, user_id: i64, id: i64) -> ServiceResult<()> {
    let updated = state
        .connection()
        .await?
        .execute(
            "UPDATE client_keys SET revoked_at = COALESCE(revoked_at, now()), encrypted_secret = NULL
             WHERE id = $1 AND user_id = $2",
            &[&id, &user_id],
        )
        .await
        .map_err(AppError::internal)?;
    if updated == 0 {
        return Err(err(ErrorKind::NotFound, "Client Key 不存在"));
    }
    Ok(())
}

pub fn random_token(length: usize) -> String {
    rand::rng()
        .sample_iter(&Alphanumeric)
        .take(length)
        .map(char::from)
        .collect()
}

pub fn hash_password(value: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(value.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|error| anyhow::anyhow!(error.to_string()))
}

pub fn verify_password(hash: &str, value: &str) -> bool {
    PasswordHash::new(hash)
        .ok()
        .map(|parsed| {
            Argon2::default()
                .verify_password(value.as_bytes(), &parsed)
                .is_ok()
        })
        .unwrap_or(false)
}

pub async fn authenticate(state: &AppState, raw: &str) -> ServiceResult<Claims> {
    let mut claims = decode::<Claims>(
        raw,
        &DecodingKey::from_secret(state.jwt_secret.as_bytes()),
        &Validation::default(),
    )
    .map(|decoded| decoded.claims)
    .map_err(|_| err(ErrorKind::Unauthenticated, "登录令牌无效"))?;
    let user = user(state, claims.sub)
        .await
        .ok_or_else(|| err(ErrorKind::Unauthenticated, "用户不存在"))?;
    if user.get::<_, bool>(3) {
        return Err(err(ErrorKind::Forbidden, "账户已禁用"));
    }
    if user.get::<_, i64>(4) != claims.auth_version {
        return Err(err(ErrorKind::Unauthenticated, "密码已修改，请重新登录"));
    }
    claims.email = user.get(1);
    claims.admin = user.get(2);
    Ok(claims)
}

pub async fn key_owner(state: &AppState, raw: &str) -> Result<i64, AppError> {
    let invalid = || err(ErrorKind::Unauthenticated, "Client Key 无效");
    let prefix = raw.get(..CLIENT_KEY_PREFIX_LEN).ok_or_else(invalid)?;
    let rows = state
        .connection()
        .await?
        .query(
            "SELECT client_keys.user_id, client_keys.key_hash
             FROM client_keys JOIN users ON users.id = client_keys.user_id
             WHERE key_prefix = $1 AND revoked_at IS NULL AND NOT users.disabled",
            &[&prefix],
        )
        .await
        .map_err(AppError::internal)?;
    for row in rows {
        if verify_password(row.get(1), raw) {
            return Ok(row.get(0));
        }
    }
    Err(invalid())
}
