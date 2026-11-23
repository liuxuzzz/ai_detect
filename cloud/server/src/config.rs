use anyhow::Context;
use serde::Deserialize;
use std::{env, fs, net::SocketAddr};

pub struct Settings {
    pub database_url: String,
    pub database_pool_size: usize,
    pub jwt_secret: String,
    pub client_key_encryption_secret: Option<String>,
    pub api_public_url: String,
    pub bind_address: SocketAddr,
    pub redis_url: String,
    pub task_daily_limit: i64,
}

impl Settings {
    pub fn from_environment() -> anyhow::Result<Self> {
        let defaults = FileSettings::load(&optional("APP_ENV", "local"))?;
        Ok(Self {
            database_url: database_url(&environment)?,
            database_pool_size: env::var("DATABASE_POOL_SIZE")
                .ok()
                .map(|value| value.parse::<usize>())
                .transpose()
                .context("DATABASE_POOL_SIZE 无效")?
                .unwrap_or(defaults.database_pool_size),
            jwt_secret: secret("JWT_SECRET", &environment)?
                .context("缺少 JWT_SECRET 或 JWT_SECRET_FILE")?,
            client_key_encryption_secret: secret("CLIENT_KEY_ENCRYPTION_SECRET", &environment)?,
            api_public_url: public_url(
                "WEB_API_BASE_URL",
                &optional(
                    "API_PUBLIC_BASE_URL",
                    &optional("WEB_API_BASE_URL", "http://127.0.0.1:6601"),
                ),
            )?,
            bind_address: optional("BIND_ADDRESS", &defaults.bind_address)
                .parse()
                .context("BIND_ADDRESS 无效")?,
            redis_url: optional("REDIS_URL", &defaults.redis_url),
            task_daily_limit: optional_i64("TASK_DAILY_LIMIT", defaults.task_daily_limit),
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileSettings {
    database_pool_size: usize,
    bind_address: String,
    redis_url: String,
    task_daily_limit: i64,
}

impl FileSettings {
    fn load(profile: &str) -> anyhow::Result<Self> {
        let mut values: toml::Table = toml::from_str(include_str!("../config/default.toml"))?;
        match profile {
            "local" => {}
            "prod" => {
                let overrides: toml::Table = toml::from_str(include_str!("../config/prod.toml"))?;
                values.extend(overrides);
            }
            _ => anyhow::bail!("APP_ENV 应为 local 或 prod"),
        }
        Ok(toml::Value::Table(values).try_into()?)
    }
}

fn environment(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.is_empty())
}

fn secret(name: &str, get: &impl Fn(&str) -> Option<String>) -> anyhow::Result<Option<String>> {
    if let Some(value) = get(name) {
        return Ok(Some(value));
    }
    let Some(path) = get(&format!("{name}_FILE")) else {
        return Ok(None);
    };
    let value = fs::read_to_string(path).with_context(|| format!("无法读取 {name}_FILE"))?;
    let value = value.trim_end_matches(['\r', '\n']).to_owned();
    anyhow::ensure!(!value.is_empty(), "{name}_FILE 不能为空");
    Ok(Some(value))
}

fn database_url(get: &impl Fn(&str) -> Option<String>) -> anyhow::Result<String> {
    if let Some(url) = get("DATABASE_URL") {
        return Ok(url);
    }
    let password =
        secret("POSTGRES_PASSWORD", get)?.context("缺少 DATABASE_URL 或 POSTGRES_PASSWORD_FILE")?;
    let parameters = [
        (
            "host",
            get("POSTGRES_HOST").unwrap_or_else(|| "postgres".into()),
        ),
        (
            "port",
            get("POSTGRES_PORT").unwrap_or_else(|| "5432".into()),
        ),
        (
            "user",
            get("POSTGRES_USER").unwrap_or_else(|| "aijiance".into()),
        ),
        (
            "dbname",
            get("POSTGRES_DB").unwrap_or_else(|| "aijiance".into()),
        ),
        ("password", password),
    ];
    // libpq's quoted format preserves passwords containing URL delimiters,
    // spaces, quotes or backslashes without changing their meaning.
    Ok(parameters
        .into_iter()
        .map(|(key, value)| {
            format!(
                "{key}='{}'",
                value.replace('\\', "\\\\").replace('\'', "\\'")
            )
        })
        .collect::<Vec<_>>()
        .join(" "))
}

fn public_url(name: &str, value: &str) -> anyhow::Result<String> {
    let url = reqwest::Url::parse(value.trim())
        .with_context(|| format!("{name} 必须是完整的 http/https 公网地址"))?;
    anyhow::ensure!(
        ["http", "https"].contains(&url.scheme())
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "{name} 必须是无账号密码、无查询参数的 http/https 地址"
    );
    Ok(url.to_string().trim_end_matches('/').to_owned())
}

#[cfg(test)]
mod tests;

fn optional(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn optional_i64(name: &str, default: i64) -> i64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}
