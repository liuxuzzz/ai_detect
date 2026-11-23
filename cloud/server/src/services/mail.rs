use super::identity_settings::SmtpConfig;
use crate::error::{err, ErrorKind, ServiceResult};
use lettre::{
    message::Mailbox, transport::smtp::authentication::Credentials, AsyncSmtpTransport,
    AsyncTransport, Message, Tokio1Executor,
};
use std::time::Duration;

pub(crate) async fn send(
    config: &SmtpConfig,
    email: &str,
    subject: &str,
    text: &str,
) -> ServiceResult<()> {
    if !config.enabled {
        return Err(err(
            ErrorKind::InvalidInput,
            "邮件服务尚未配置，请联系管理员",
        ));
    }
    let invalid = || err(ErrorKind::InvalidInput, "邮箱或 SMTP 配置格式不正确");
    let message = Message::builder()
        .from(Mailbox::new(
            Some(config.from_name.clone()),
            config.from_address.parse().map_err(|_| invalid())?,
        ))
        .to(email.parse().map_err(|_| invalid())?)
        .subject(subject)
        .body(text.to_owned())
        .map_err(|_| invalid())?;
    let builder = match config.security.as_str() {
        "tls" => {
            AsyncSmtpTransport::<Tokio1Executor>::relay(&config.host).map_err(|_| invalid())?
        }
        "starttls" => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&config.host)
            .map_err(|_| invalid())?,
        "plain" => AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&config.host),
        _ => return Err(invalid()),
    };
    let mut builder = builder
        .port(config.port)
        .timeout(Some(Duration::from_secs(15)));
    if !config.username.is_empty() {
        builder = builder.credentials(Credentials::new(
            config.username.clone(),
            config.password.clone(),
        ));
    }
    let transport = builder.build();
    transport
        .send(message)
        .await
        .map_err(|_| err(ErrorKind::Upstream, "邮件发送失败，请管理员检查 SMTP 配置"))?;
    Ok(())
}
