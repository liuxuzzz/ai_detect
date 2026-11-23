use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RegistrationSettings {
    pub(crate) registration_enabled: bool,
}

#[derive(Serialize)]
pub(crate) struct SiteSettings {
    pub(crate) site_url: String,
    pub(crate) registration_enabled: bool,
    pub(crate) upload_limit: i64,
    pub(crate) upload_window_seconds: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SiteSettingsUpdate {
    pub(crate) site_url: Option<String>,
    pub(crate) registration_enabled: Option<bool>,
    pub(crate) upload_limit: Option<i64>,
    pub(crate) upload_window_seconds: Option<i64>,
}
