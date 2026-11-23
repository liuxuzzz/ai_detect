use super::{database_url, public_url, secret};
use std::{collections::HashMap, fs};

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

#[test]
fn database_parameters_preserve_special_characters_and_external_urls() {
    let password = "space ' \\ : / @ ? # %40 $";
    let mut values = HashMap::from([
        ("POSTGRES_PASSWORD", password.to_owned()),
        ("POSTGRES_USER", "user'name".into()),
        ("POSTGRES_DB", "database name".into()),
    ]);
    let parsed: tokio_postgres::Config = database_url(&|key| values.get(key).cloned())
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(parsed.get_password(), Some(password.as_bytes()));
    assert_eq!(parsed.get_user(), Some("user'name"));
    assert_eq!(parsed.get_dbname(), Some("database name"));
    values.insert(
        "DATABASE_URL",
        "postgres://external.example.test/database".into(),
    );
    assert_eq!(
        database_url(&|key| values.get(key).cloned()).unwrap(),
        "postgres://external.example.test/database"
    );
    assert!(database_url(&|_| None).is_err());
}

#[test]
fn file_secrets_fail_closed_and_allow_explicit_environment_overrides() {
    let directory = std::env::temp_dir().join(format!(
        "aijiance-config-{}-{}",
        std::process::id(),
        rand::random::<u64>()
    ));
    fs::create_dir(&directory).unwrap();
    let path = directory.join("secret");
    let mut values = HashMap::from([("JWT_SECRET_FILE", path.to_string_lossy().into_owned())]);
    assert!(secret("JWT_SECRET", &|key| values.get(key).cloned()).is_err());
    fs::write(&path, "persisted secret\n").unwrap();
    assert_eq!(
        secret("JWT_SECRET", &|key| values.get(key).cloned())
            .unwrap()
            .as_deref(),
        Some("persisted secret")
    );
    fs::write(&path, "").unwrap();
    assert!(secret("JWT_SECRET", &|key| values.get(key).cloned()).is_err());
    values.insert("JWT_SECRET", "explicit secret".into());
    assert_eq!(
        secret("JWT_SECRET", &|key| values.get(key).cloned())
            .unwrap()
            .as_deref(),
        Some("explicit secret")
    );
    fs::remove_dir_all(directory).unwrap();
}
