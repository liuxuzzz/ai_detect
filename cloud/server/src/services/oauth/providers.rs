use super::super::identity_settings::ProviderConfig;
use crate::error::{err, ErrorKind, ServiceResult};
use serde_json::Value;
use std::time::Duration;

pub(super) struct Identity {
    pub subject: String,
    pub email: String,
}

fn invalid() -> crate::error::AppError {
    err(
        ErrorKind::Upstream,
        "第三方登录失败，请重试或联系管理员检查配置",
    )
}

fn google_identity(value: &Value) -> ServiceResult<Identity> {
    if value["email_verified"] != true {
        return Err(err(ErrorKind::Forbidden, "第三方账号未提供已验证的邮箱"));
    }
    Ok(Identity {
        subject: value["sub"]
            .as_str()
            .filter(|v| !v.is_empty())
            .ok_or_else(invalid)?
            .to_owned(),
        email: value["email"].as_str().ok_or_else(invalid)?.to_owned(),
    })
}

fn github_identity(profile: &Value, emails: &Value) -> ServiceResult<Identity> {
    let emails = emails.as_array().ok_or_else(invalid)?;
    let email = emails
        .iter()
        .find(|email| email["verified"] == true && email["primary"] == true)
        .or_else(|| emails.iter().find(|email| email["verified"] == true))
        .and_then(|email| email["email"].as_str())
        .ok_or_else(|| err(ErrorKind::Forbidden, "GitHub 账号未提供已验证的邮箱"))?;
    Ok(Identity {
        subject: profile["id"].as_u64().ok_or_else(invalid)?.to_string(),
        email: email.to_owned(),
    })
}

pub(super) async fn exchange(
    name: &str,
    config: &ProviderConfig,
    callback: &str,
    code: &str,
    verifier: &str,
) -> ServiceResult<Identity> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("ai-detect/0.1.0")
        .build()
        .map_err(|_| invalid())?;
    let endpoint = match name {
        "github" => "https://github.com/login/oauth/access_token",
        "google" => "https://oauth2.googleapis.com/token",
        _ => return Err(invalid()),
    };
    let token: Value = client
        .post(endpoint)
        .header("Accept", "application/json")
        .form(&[
            ("client_id", config.client_id.as_str()),
            ("client_secret", config.client_secret.as_str()),
            ("redirect_uri", callback),
            ("code", code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
        ])
        .send()
        .await
        .map_err(|_| invalid())?
        .error_for_status()
        .map_err(|_| invalid())?
        .json()
        .await
        .map_err(|_| invalid())?;
    let token = token["access_token"].as_str().ok_or_else(invalid)?;
    let get = |url: &str| {
        client
            .get(url)
            .bearer_auth(token)
            .header("Accept", "application/json")
    };
    if name == "google" {
        let profile: Value = get("https://openidconnect.googleapis.com/v1/userinfo")
            .send()
            .await
            .map_err(|_| invalid())?
            .error_for_status()
            .map_err(|_| invalid())?
            .json()
            .await
            .map_err(|_| invalid())?;
        google_identity(&profile)
    } else {
        let profile: Value = get("https://api.github.com/user")
            .send()
            .await
            .map_err(|_| invalid())?
            .error_for_status()
            .map_err(|_| invalid())?
            .json()
            .await
            .map_err(|_| invalid())?;
        let emails: Value = get("https://api.github.com/user/emails")
            .send()
            .await
            .map_err(|_| invalid())?
            .error_for_status()
            .map_err(|_| invalid())?
            .json()
            .await
            .map_err(|_| invalid())?;
        github_identity(&profile, &emails)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_verified_provider_emails_can_identify_accounts() {
        assert!(google_identity(
            &json!({"sub":"123","email":"user@example.test","email_verified":false})
        )
        .is_err());
        let value = google_identity(
            &json!({"sub":"123","email":"user@example.test","email_verified":true}),
        )
        .unwrap();
        assert_eq!(value.subject, "123");
        assert!(github_identity(
            &json!({"id":42}),
            &json!([{"email":"unverified@example.test","primary":true,"verified":false}])
        )
        .is_err());
        let value = github_identity(
            &json!({"id":42}),
            &json!([
                {"email":"unverified@example.test","primary":true,"verified":false},
                {"email":"verified@example.test","primary":false,"verified":true}
            ]),
        )
        .unwrap();
        assert_eq!(value.email, "verified@example.test");
    }
}
