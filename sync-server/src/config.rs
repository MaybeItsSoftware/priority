use std::env;

/// The process's settings, all from the environment, as Railway provides them.
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    /// Resend's API key and sender, both needed for password reset; without
    /// either the server runs and the reset endpoint says it's not set up.
    pub resend_api_key: Option<String>,
    pub mail_from: Option<String>,
    /// Where the reset page is reachable, for the link in the email. Defaults
    /// to the Railway domain, which Railway sets as `RAILWAY_PUBLIC_DOMAIN`.
    pub public_url: Option<String>,
}

fn non_empty(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("DATABASE_URL is not set")]
    MissingDatabaseUrl,
    #[error("PORT is not a port number: {0}")]
    BadPort(String),
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let database_url = env::var("DATABASE_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .ok_or(ConfigError::MissingDatabaseUrl)?;
        let port = match env::var("PORT") {
            Ok(value) => value
                .trim()
                .parse()
                .map_err(|_| ConfigError::BadPort(value))?,
            Err(_) => 8080,
        };
        let public_url = non_empty("PUBLIC_URL")
            .or_else(|| {
                non_empty("RAILWAY_PUBLIC_DOMAIN").map(|domain| format!("https://{domain}"))
            })
            .map(|url| url.trim_end_matches('/').to_owned());
        Ok(Config {
            database_url,
            port,
            resend_api_key: non_empty("RESEND_API_KEY"),
            mail_from: non_empty("MAIL_FROM"),
            public_url,
        })
    }
}
