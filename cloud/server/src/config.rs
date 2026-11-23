use anyhow::Context;
use serde::Deserialize;
use std::{env, net::SocketAddr};

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
            database_url: required("DATABASE_URL")?,
            database_pool_size: env::var("DATABASE_POOL_SIZE")
                .ok()
                .map(|value| value.parse::<usize>())
                .transpose()
                .context("DATABASE_POOL_SIZE 无效")?
                .unwrap_or(defaults.database_pool_size),
            jwt_secret: optional("JWT_SECRET", "change-me"),
            client_key_encryption_secret: env::var("CLIENT_KEY_ENCRYPTION_SECRET")
                .ok()
                .filter(|secret| !secret.is_empty()),
            api_public_url: public_url(
                "WEB_API_BASE_URL",
                &optional(
                    "API_PUBLIC_BASE_URL",
                    &optional("WEB_API_BASE_URL", "http://127.0.0.1:8081"),
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

fn required(name: &str) -> anyhow::Result<String> {
    env::var(name).map_err(|_| anyhow::anyhow!("缺少环境变量 {name}"))
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
mod tests {
    use super::public_url;
    #[test]
    fn public_addresses_preserve_domains_without_container_ports() {
        assert_eq!(
            public_url("api", "https://api.example.com/").unwrap(),
            "https://api.example.com"
        );
        assert_eq!(
            public_url("api", "http://127.0.0.1:8081").unwrap(),
            "http://127.0.0.1:8081"
        );
        assert!(public_url("api", "javascript:alert(1)").is_err());
        assert!(public_url("api", "https://user:password@api.example.com").is_err());
    }
}

fn optional(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn optional_i64(name: &str, default: i64) -> i64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}
