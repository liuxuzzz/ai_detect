use super::*;
use crate::{config::Settings, services::auth};

#[tokio::test]
#[ignore = "requires an isolated PostgreSQL database at TEST_DATABASE_URL"]
async fn provider_linking_and_one_time_tickets_respect_account_state() {
    let settings = Settings {
        database_url: std::env::var("TEST_DATABASE_URL").unwrap(),
        database_pool_size: 4,
        jwt_secret: "oauth-isolated-secret".into(),
        client_key_encryption_secret: None,
        api_public_url: "http://localhost:8081".into(),
        bind_address: "127.0.0.1:0".parse().unwrap(),
        redis_url: "disabled".into(),
        task_daily_limit: 20,
    };
    let state = AppState::from_settings(&settings).await.unwrap();
    let email = format!(
        "oauth-{}@example.test",
        auth::random_token(12).to_lowercase()
    );
    let db = state.connection().await.unwrap();
    let id: i64 = db
        .query_one(
            "INSERT INTO users(email,password_hash) VALUES($1,'') RETURNING id",
            &[&email],
        )
        .await
        .unwrap()
        .get(0);
    let identity = providers::Identity {
        subject: auth::random_token(20),
        email: email.clone(),
    };
    assert!(
        resolve_account(&state, "google", &identity).await.is_err(),
        "Unverified local emails must not be linked automatically"
    );
    db.execute("UPDATE users SET email_verified=TRUE WHERE id=$1", &[&id])
        .await
        .unwrap();
    assert_eq!(
        resolve_account(&state, "google", &identity).await.unwrap(),
        id
    );
    assert_eq!(
        resolve_account(&state, "google", &identity).await.unwrap(),
        id
    );
    let ticket = create_ticket(&state, id).await.unwrap();
    let session = exchange_ticket(
        &state,
        TicketExchange {
            code: ticket.clone(),
        },
    )
    .await
    .unwrap();
    assert_eq!(session["user"]["email"], email);
    assert!(exchange_ticket(&state, TicketExchange { code: ticket })
        .await
        .is_err());
    let ticket = create_ticket(&state, id).await.unwrap();
    db.execute(
        "UPDATE users SET auth_version=auth_version+1 WHERE id=$1",
        &[&id],
    )
    .await
    .unwrap();
    assert!(exchange_ticket(&state, TicketExchange { code: ticket })
        .await
        .is_err());
    let ticket = create_ticket(&state, id).await.unwrap();
    db.execute("UPDATE users SET disabled=TRUE WHERE id=$1", &[&id])
        .await
        .unwrap();
    assert!(exchange_ticket(&state, TicketExchange { code: ticket })
        .await
        .is_err());
    assert!(resolve_account(&state, "google", &identity).await.is_err());
    db.execute("DELETE FROM users WHERE id=$1", &[&id])
        .await
        .unwrap();
}
