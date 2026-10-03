use std::env;

/// The process's settings, all from the environment, as Railway provides them.
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
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
        Ok(Config { database_url, port })
    }
}
