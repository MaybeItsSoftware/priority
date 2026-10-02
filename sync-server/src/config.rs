use std::env;

/// The process's settings, all from the environment, as Railway provides them.
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    /// `None` disables everything the admin token unlocks: pairing the first
    /// device, and minting pairing codes without a paired device. Already
    /// paired devices keep working, so a deploy that loses the variable
    /// degrades rather than locks everyone out.
    pub admin_token: Option<String>,
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
        let admin_token = env::var("SYNC_ADMIN_TOKEN")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        Ok(Config {
            database_url,
            port,
            admin_token,
        })
    }
}
