use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{SiteSettings, SiteSettingsUpdate},
    state::AppState,
};

pub(crate) async fn get(state: &AppState) -> ServiceResult<SiteSettings> {
    let row = state
        .connection()
        .await?
        .query_one(
            "SELECT registration_enabled,upload_limit,upload_window_seconds,site_url FROM site_settings WHERE singleton",
            &[],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(SiteSettings {
        site_url: row.get(3),
        registration_enabled: row.get(0),
        upload_limit: row.get(1),
        upload_window_seconds: row.get(2),
    })
}

pub(crate) async fn update(
    state: &AppState,
    settings: SiteSettingsUpdate,
) -> ServiceResult<SiteSettings> {
    if settings.registration_enabled.is_none()
        && settings.upload_limit.is_none()
        && settings.upload_window_seconds.is_none()
        && settings.site_url.is_none()
    {
        return Err(err(ErrorKind::InvalidInput, "请至少修改一项站点设置"));
    }
    if settings
        .upload_limit
        .is_some_and(|value| !(1..=1000000).contains(&value))
        || settings
            .upload_window_seconds
            .is_some_and(|value| !(1..=31536000).contains(&value))
    {
        return Err(err(
            ErrorKind::InvalidInput,
            "上传次数须为 1–1000000，时间窗口须为 1 秒–365 天",
        ));
    }
    let site_url = settings
        .site_url
        .as_deref()
        .map(normalize_site_url)
        .transpose()?;
    let row = state.connection().await?
        .query_one(
            "UPDATE site_settings SET registration_enabled=COALESCE($1,registration_enabled),
                upload_limit=COALESCE($2,upload_limit),upload_window_seconds=COALESCE($3,upload_window_seconds),site_url=COALESCE($4,site_url)
             WHERE singleton RETURNING registration_enabled,upload_limit,upload_window_seconds,site_url",
            &[&settings.registration_enabled, &settings.upload_limit, &settings.upload_window_seconds, &site_url],
        )
        .await.map_err(AppError::internal)?;
    Ok(SiteSettings {
        site_url: row.get(3),
        registration_enabled: row.get(0),
        upload_limit: row.get(1),
        upload_window_seconds: row.get(2),
    })
}

fn normalize_site_url(value: &str) -> ServiceResult<String> {
    let url = reqwest::Url::parse(value.trim())
        .map_err(|_| err(ErrorKind::InvalidInput, "请输入完整的 http/https 站点地址"))?;
    if !["http", "https"].contains(&url.scheme())
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(err(
            ErrorKind::InvalidInput,
            "站点地址不能包含账号密码、查询参数或片段",
        ));
    }
    Ok(url.to_string().trim_end_matches('/').to_owned())
}

pub(crate) async fn remember_frontend(
    state: &AppState,
    admin: i64,
    origin: &str,
) -> ServiceResult<()> {
    let Ok(url) = normalize_site_url(origin) else {
        return Ok(());
    };
    state
        .connection()
        .await?
        .execute(
            "UPDATE site_settings SET site_url=$1 WHERE singleton AND site_url=''
         AND EXISTS(SELECT 1 FROM users WHERE id=$2 AND is_admin AND NOT disabled)",
            &[&url, &admin],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(())
}

pub(crate) async fn page_url(state: &AppState, path: &str) -> ServiceResult<String> {
    Ok(format!("{}{path}", get(state).await?.site_url))
}

pub(crate) async fn require_registration(
    transaction: &deadpool_postgres::Transaction<'_>,
) -> ServiceResult<()> {
    // Registrations share the row lock until their insert commits. Closing
    // registration waits for those inserts, then blocks every later request.
    let row = transaction
        .query_one(
            "SELECT registration_enabled FROM site_settings WHERE singleton FOR SHARE",
            &[],
        )
        .await
        .map_err(AppError::internal)?;
    if !row.get::<_, bool>(0) {
        return Err(err(ErrorKind::Forbidden, "注册已关闭，请联系管理员"));
    }
    Ok(())
}
