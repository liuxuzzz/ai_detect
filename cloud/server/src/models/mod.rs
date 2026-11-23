use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

mod site_settings;
pub(crate) use site_settings::{RegistrationSettings, SiteSettings, SiteSettingsUpdate};

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
pub(crate) struct PublicQuery {
    pub(crate) period: String,
    pub(crate) search: String,
    pub(crate) api_domain: String,
    pub(crate) model: String,
    pub(crate) facet: String,
    pub(crate) page: i64,
}

#[derive(Serialize)]
pub(crate) struct ReportDetails {
    pub(crate) id: i64,
    pub(crate) slug: String,
    pub(crate) api_domain: String,
    pub(crate) model: String,
    pub(crate) prompt_name: String,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) metrics: Map<String, Value>,
    pub(crate) data: ReportData,
    pub(crate) average_score: Option<f64>,
    pub(crate) rating_count: i64,
    pub(crate) my_score: Option<i16>,
}

#[derive(Serialize)]
pub(crate) struct RatingResult {
    pub(crate) ok: bool,
    pub(crate) score: i16,
    pub(crate) average_score: f64,
    pub(crate) rating_count: i64,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Claims {
    pub sub: i64,
    pub email: String,
    pub admin: bool,
    pub exp: usize,
    #[serde(default)]
    pub auth_version: i64,
}

#[derive(Deserialize)]
pub struct Credentials {
    pub email: String,
    pub password: String,
    #[serde(default)]
    pub email_code: String,
}

#[derive(Deserialize)]
pub(crate) struct PasswordChange {
    pub(crate) current_password: String,
    pub(crate) new_password: String,
}

#[derive(Serialize)]
pub(crate) struct ClientKeyInfo {
    pub(crate) id: i64,
    pub(crate) prefix: String,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) revoked_at: Option<DateTime<Utc>>,
    pub(crate) can_reveal: bool,
}

#[derive(Serialize)]
pub(crate) struct CreatedClientKey {
    #[serde(flatten)]
    pub(crate) info: ClientKeyInfo,
    pub(crate) key: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Upload {
    pub api_domain: String,
    pub model: String,
    #[serde(default)]
    pub prompt_name: String,
    #[serde(default = "empty_metadata")]
    pub metadata: Value,
    pub data: ReportData,
}

fn empty_metadata() -> Value {
    Value::Object(Map::new())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ReportData {
    pub version: u32,
    pub source: String,
    pub upstream_name: String,
    pub prompt: String,
    pub output: String,
    pub started_at: String,
    pub error: String,
    pub detection_mode: String,
    pub reasoning_effort: String,
    pub samples: Vec<ReportSample>,
    pub activities: Vec<ReportActivity>,
    pub retries: Vec<ReportRetry>,
}

impl Default for ReportData {
    fn default() -> Self {
        Self {
            version: 1,
            source: "client".into(),
            upstream_name: String::new(),
            prompt: String::new(),
            output: String::new(),
            started_at: String::new(),
            error: String::new(),
            detection_mode: "single".into(),
            reasoning_effort: "default".into(),
            samples: Vec::new(),
            activities: Vec::new(),
            retries: Vec::new(),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ReportSample {
    pub seconds: f64,
    pub tps: f64,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ReportActivity {
    pub kind: String,
    pub content: String,
    pub name: String,
    pub id: String,
    pub elapsed_ms: i64,
    pub attempt: i32,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ReportRetry {
    pub at: String,
    pub reason: String,
    pub attempt: i32,
    pub elapsed_ms: Option<i64>,
}

#[derive(Deserialize)]
pub struct ShareInput {
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub allow_any_iframe: bool,
    pub allowed_domain: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct DashboardQuery {
    #[serde(default)]
    pub period: String,
    #[serde(default)]
    pub api_domain: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub page: i64,
    #[serde(default = "default_limit")]
    pub limit: i64,
    pub min_ttft_ms: Option<f64>,
    pub max_ttft_ms: Option<f64>,
    pub min_tps: Option<f64>,
    pub max_tps: Option<f64>,
    #[serde(default)]
    pub sort: String,
}

#[derive(Deserialize, Default)]
pub struct PageQuery {
    #[serde(default)]
    pub page: i64,
    #[serde(default = "default_limit")]
    pub limit: i64,
}

fn default_limit() -> i64 {
    50
}

#[derive(Deserialize)]
pub struct RatingInput {
    pub score: i16,
}

#[derive(Deserialize)]
pub struct CommentInput {
    pub content: String,
}

#[derive(Deserialize)]
pub struct UpstreamInput {
    pub name: String,
    pub base_url: String,
    pub api_key: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub models: Vec<String>,
    #[serde(default)]
    pub prompt: String,
    pub schedule: Option<String>,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub provider_type: String,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Deserialize)]
pub struct ModelDiscoveryInput {
    pub channel_id: Option<i64>,
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
}

#[derive(Serialize)]
pub struct ModelDiscovery {
    pub models: Vec<String>,
}

#[derive(Serialize)]
pub struct ChannelTestResult {
    pub ok: bool,
    pub status: u16,
    pub latency_ms: u128,
    pub model: String,
}

#[derive(Deserialize)]
pub struct TaskInput {
    pub upstream_id: i64,
    pub model: Option<String>,
    pub prompt_kind: Option<String>,
    pub prompt_id: Option<i64>,
    pub prompt_text: Option<String>,
    pub reasoning_effort: Option<String>,
    pub execution_mode: Option<String>,
    pub delay_ms: Option<i32>,
    pub scheduled_for: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
pub(crate) struct PromptInput {
    pub(crate) name: String,
    pub(crate) content: String,
    #[serde(default = "prompt_enabled")]
    pub(crate) enabled: bool,
}

fn prompt_enabled() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TaskAction {
    Pause,
    Resume,
    Stop,
}

#[derive(Deserialize)]
pub(crate) struct TaskControl {
    pub(crate) action: TaskAction,
}

#[derive(Deserialize)]
pub struct UserPatch {
    pub disabled: Option<bool>,
    pub is_admin: Option<bool>,
}
