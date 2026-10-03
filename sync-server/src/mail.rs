//! Sending email, through Resend.
//!
//! The only mail the server sends is a password reset link. Behind a trait so
//! the tests can read the link out of a message instead of sending one.

use std::future::Future;
use std::pin::Pin;

pub struct Message {
    pub to: String,
    pub subject: String,
    pub text: String,
    pub html: String,
}

pub type SendResult = Result<(), String>;

pub trait Mailer: Send + Sync {
    fn send(&self, message: Message) -> Pin<Box<dyn Future<Output = SendResult> + Send + '_>>;
}

/// Sends through Resend's HTTP API (<https://resend.com/docs/api-reference/emails/send-email>).
pub struct Resend {
    client: reqwest::Client,
    api_key: String,
    /// `"Priority <reset@example.com>"`, on a domain verified in Resend.
    from: String,
}

impl Resend {
    pub fn new(api_key: String, from: String) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .expect("a reqwest client with only a timeout builds");
        Resend {
            client,
            api_key,
            from,
        }
    }
}

impl Mailer for Resend {
    fn send(&self, message: Message) -> Pin<Box<dyn Future<Output = SendResult> + Send + '_>> {
        Box::pin(async move {
            let response = self
                .client
                .post("https://api.resend.com/emails")
                .bearer_auth(&self.api_key)
                .json(&serde_json::json!({
                    "from": self.from,
                    "to": [message.to],
                    "subject": message.subject,
                    "text": message.text,
                    "html": message.html,
                }))
                .send()
                .await
                .map_err(|error| error.to_string())?;
            let status = response.status();
            if status.is_success() {
                Ok(())
            } else {
                let body = response.text().await.unwrap_or_default();
                Err(format!("resend answered {status}: {body}"))
            }
        })
    }
}
