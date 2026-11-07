use super::AiError;
use crate::accounts::Secret;
use futures_util::{SinkExt, StreamExt};
use reqwest::{Client, Url};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::{net::TcpStream, sync::Mutex, time::Instant};
use tokio_tungstenite::{
    tungstenite::{client::IntoClientRequest, Message},
    MaybeTlsStream, WebSocketStream,
};
use tokio_util::sync::CancellationToken;

const MAX_RESPONSE: usize = 1024 * 1024;
const MAX_STREAM: usize = 16 * 1024 * 1024;
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct CachedSocket {
    credential: [u8; 32],
    socket: Socket,
}
#[derive(Clone)]
pub struct Endpoints {
    pub anthropic: Url,
    pub openai: Url,
    pub websocket: Url,
}
impl Default for Endpoints {
    fn default() -> Self {
        Self {
            anthropic: Url::parse("https://api.anthropic.com/v1/messages").unwrap(),
            openai: Url::parse("https://api.openai.com/v1/responses").unwrap(),
            websocket: Url::parse("wss://api.openai.com/v1/responses").unwrap(),
        }
    }
}
pub struct HttpAi {
    client: Client,
    endpoints: Endpoints,
    socket: Mutex<Option<CachedSocket>>,
}
impl HttpAi {
    pub fn new() -> Result<Self, AiError> {
        Self::with_endpoints(Endpoints::default())
    }
    /// Native-host configuration for fixtures/proxy integrations; never expose
    /// arbitrary endpoint changes through a renderer command.
    pub fn with_endpoints(endpoints: Endpoints) -> Result<Self, AiError> {
        for url in [
            &endpoints.anthropic,
            &endpoints.openai,
            &endpoints.websocket,
        ] {
            let secure = matches!(url.scheme(), "https" | "wss");
            let local = matches!(url.host_str(), Some("127.0.0.1" | "[::1]" | "localhost"));
            if !secure && !local {
                return Err(AiError::Transport);
            }
        }
        Ok(Self {
            client: Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(5))
                .build()
                .map_err(|_| AiError::Transport)?,
            endpoints,
            socket: Mutex::new(None),
        })
    }
    pub async fn invalidate(&self) {
        self.socket.lock().await.take();
    }
    async fn connect(&self, credential: &Secret) -> Result<CachedSocket, AiError> {
        let mut request = self
            .endpoints
            .websocket
            .as_str()
            .into_client_request()
            .map_err(|_| AiError::Transport)?;
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {}", credential.expose())
                .parse()
                .map_err(|_| AiError::InvalidCredential)?,
        );
        let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(MAX_RESPONSE))
            .max_frame_size(Some(MAX_RESPONSE));
        let (socket, _) =
            tokio_tungstenite::connect_async_with_config(request, Some(config), false)
                .await
                .map_err(|e| match e {
                    tokio_tungstenite::tungstenite::Error::Http(response) => {
                        AiError::Http(response.status().as_u16())
                    }
                    _ => AiError::Transport,
                })?;
        Ok(CachedSocket {
            credential: crate::sha256(credential.expose().as_bytes()),
            socket,
        })
    }
    pub async fn warm_up(
        &self,
        credential: &Secret,
        cancel: &CancellationToken,
    ) -> Result<(), AiError> {
        let Ok(mut slot) = self.socket.try_lock() else {
            return Ok(());
        };
        let mut cached = slot.take();
        let work = async {
            if cached
                .as_ref()
                .is_none_or(|c| c.credential != crate::sha256(credential.expose().as_bytes()))
            {
                cached = Some(self.connect(credential).await?);
            }
            let socket = &mut cached.as_mut().unwrap().socket;
            let ping = b"pressay-transport-check";
            socket
                .send(Message::Ping(ping.to_vec().into()))
                .await
                .map_err(|_| AiError::Transport)?;
            while let Some(message) = socket.next().await {
                match message.map_err(|_| AiError::Transport)? {
                    Message::Pong(data) if data.as_ref() == ping => return Ok(()),
                    Message::Ping(data) => socket
                        .send(Message::Pong(data))
                        .await
                        .map_err(|_| AiError::Transport)?,
                    _ => return Err(AiError::Transport),
                }
            }
            Err(AiError::Transport)
        };
        let result = tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout(Duration::from_secs(3),work)=>result.unwrap_or(Err(AiError::Timeout))};
        if result.is_ok() {
            *slot = cached;
        }
        result
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn claude(
        &self,
        system: &str,
        user: &str,
        model: &str,
        effort: &str,
        max_tokens: u32,
        credential: &Secret,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<String, AiError> {
        let body = claude_body(system, user, model, effort, max_tokens);
        let work = async {
            let response = self
                .client
                .post(self.endpoints.anthropic.clone())
                .header("x-api-key", credential.expose())
                .header("anthropic-version", "2023-06-01")
                .json(&body)
                .send()
                .await
                .map_err(|_| AiError::Transport)?;
            let status = response.status().as_u16();
            let data = read_body(response).await?;
            if status != 200 {
                return Err(AiError::Http(status));
            }
            parse_claude(&serde_json::from_slice(&data).map_err(|_| AiError::BadResponse)?)
        };
        tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout(timeout,work)=>result.unwrap_or(Err(AiError::Timeout))}
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn openai(
        &self,
        system: &str,
        user: &str,
        model: &str,
        effort: &str,
        priority: bool,
        credential: &Secret,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<String, AiError> {
        let deadline = Instant::now() + timeout;
        let body = openai_body(system, user, model, effort, priority, false);
        // A concurrent caller uses its own HTTP reader, never shares the socket.
        if priority {
            if let Ok(mut slot) = self.socket.try_lock() {
                let mut cached = slot.take();
                let work = async {
                    if cached.as_ref().is_none_or(|c| {
                        c.credential != crate::sha256(credential.expose().as_bytes())
                    }) {
                        cached = Some(self.connect(credential).await?);
                    }
                    let socket = &mut cached.as_mut().unwrap().socket;
                    let request = openai_body(system, user, model, effort, priority, true);
                    socket
                        .send(Message::Text(request.to_string().into()))
                        .await
                        .map_err(|_| AiError::Transport)?;
                    let mut reader = ResponseReader::default();
                    let mut received = 0;
                    while let Some(message) = socket.next().await {
                        let message = message.map_err(|_| AiError::Transport)?;
                        received += message.len();
                        if received > MAX_STREAM {
                            return Err(AiError::BadResponse);
                        }
                        match message {
                            Message::Text(text) => {
                                let event = serde_json::from_str(&text)
                                    .map_err(|_| AiError::BadResponse)?;
                                if let Some(text) = reader.event(&event)? {
                                    return Ok(text);
                                }
                            }
                            Message::Binary(bytes) => {
                                let event = serde_json::from_slice(&bytes)
                                    .map_err(|_| AiError::BadResponse)?;
                                if let Some(text) = reader.event(&event)? {
                                    return Ok(text);
                                }
                            }
                            Message::Ping(data) => socket
                                .send(Message::Pong(data))
                                .await
                                .map_err(|_| AiError::Transport)?,
                            Message::Pong(_) => {}
                            _ => return Err(AiError::Transport),
                        }
                    }
                    Err(AiError::Transport)
                };
                let result = tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout_at(deadline,work)=>result.unwrap_or(Err(AiError::Timeout))};
                match result {
                    Ok(text) => {
                        *slot = cached;
                        return Ok(text);
                    }
                    Err(AiError::Transport) => {}
                    Err(error) => return Err(error),
                }
            }
        }
        // Only transport failure retries. A refusal, usage limit, invalid edit or
        // exhausted deadline never causes another billable model request.
        if Instant::now() >= deadline {
            return Err(AiError::Timeout);
        }
        let work = self.http_openai(&body, credential);
        tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout_at(deadline,work)=>result.unwrap_or(Err(AiError::Timeout))}
    }
    async fn http_openai(&self, body: &Value, credential: &Secret) -> Result<String, AiError> {
        let response = self
            .client
            .post(self.endpoints.openai.clone())
            .bearer_auth(credential.expose())
            .header("accept", "text/event-stream")
            .json(body)
            .send()
            .await
            .map_err(|_| AiError::Transport)?;
        let status = response.status().as_u16();
        if status != 200 {
            let bytes = read_body(response).await?;
            let body: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            return Err(provider_error(&body, status));
        }
        let mut stream = response.bytes_stream();
        let mut pending = Vec::new();
        let mut data = String::new();
        let mut reader = ResponseReader::default();
        let mut received = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| AiError::Transport)?;
            received += chunk.len();
            if received > MAX_STREAM {
                return Err(AiError::BadResponse);
            }
            pending.extend_from_slice(&chunk);
            if pending.len() > MAX_RESPONSE {
                return Err(AiError::BadResponse);
            }
            while let Some(index) = pending.iter().position(|b| *b == b'\n') {
                let line = String::from_utf8(pending.drain(..=index).collect())
                    .map_err(|_| AiError::BadResponse)?;
                if let Some(text) =
                    sse_line(line.trim_end_matches(['\r', '\n']), &mut data, &mut reader)?
                {
                    return Ok(text);
                }
            }
        }
        if !pending.is_empty() {
            let line = std::str::from_utf8(&pending).map_err(|_| AiError::BadResponse)?;
            if let Some(text) = sse_line(line.trim_end_matches('\r'), &mut data, &mut reader)? {
                return Ok(text);
            }
        }
        if let Some(text) = sse_line("", &mut data, &mut reader)? {
            return Ok(text);
        }
        Err(AiError::Incomplete)
    }
}
pub fn claude_body(system: &str, user: &str, model: &str, effort: &str, max_tokens: u32) -> Value {
    json!({"model":model,"max_tokens":max_tokens,"thinking":{"type":"adaptive"},"output_config":{"effort":effort},"system":[{"type":"text","text":system,"cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":user}]})
}
pub fn openai_body(
    system: &str,
    user: &str,
    model: &str,
    effort: &str,
    priority: bool,
    websocket: bool,
) -> Value {
    let mut body = json!({"model":model,"instructions":system,"input":[{"role":"user","content":user}],"store":false,"reasoning":{"effort":effort}});
    if priority {
        body["service_tier"] = json!("priority");
    }
    if websocket {
        body["type"] = json!("response.create");
    } else {
        body["stream"] = json!(true);
    }
    body
}
fn parse_clude_text(content: &[Value]) -> String {
    content
        .iter()
        .filter(|c| c["type"] == "text")
        .filter_map(|c| c["text"].as_str())
        .collect::<String>()
        .trim()
        .into()
}
pub fn parse_claude(reply: &Value) -> Result<String, AiError> {
    if reply["stop_reason"] != "end_turn" {
        return Err(AiError::Incomplete);
    }
    let content = reply["content"].as_array().ok_or(AiError::BadResponse)?;
    let text = parse_clude_text(content);
    if text.is_empty() {
        Err(AiError::BadResponse)
    } else {
        Ok(text)
    }
}
async fn read_body(mut response: reqwest::Response) -> Result<Vec<u8>, AiError> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| AiError::Transport)? {
        if bytes.len() + chunk.len() > MAX_RESPONSE {
            return Err(AiError::BadResponse);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
fn provider_error(event: &Value, status: u16) -> AiError {
    let code = event
        .pointer("/response/error/code")
        .or_else(|| event.pointer("/error/code"))
        .and_then(Value::as_str)
        .unwrap_or("");
    match code {
        "subscription_sharing_usage_limit_exceeded" => AiError::UsageLimit,
        "subscription_sharing_user_not_eligible" => AiError::NotEligible,
        _ => {
            if status > 0 {
                AiError::Http(status)
            } else {
                AiError::BadResponse
            }
        }
    }
}
#[derive(Default)]
struct ResponseReader {
    text: String,
}
impl ResponseReader {
    fn event(&mut self, event: &Value) -> Result<Option<String>, AiError> {
        let kind = event["type"].as_str().ok_or(AiError::BadResponse)?;
        if kind.starts_with("response.refusal.") {
            return Err(AiError::Refusal);
        }
        match kind {
            "response.output_text.delta" => {
                let delta = event["delta"].as_str().ok_or(AiError::BadResponse)?;
                if self.text.len() + delta.len() > MAX_RESPONSE {
                    return Err(AiError::BadResponse);
                }
                self.text.push_str(delta);
            }
            "response.completed" => {
                if event
                    .pointer("/response/status")
                    .and_then(Value::as_str)
                    .is_some_and(|s| s != "completed")
                {
                    return Err(AiError::Incomplete);
                }
                if event
                    .pointer("/response/output")
                    .and_then(Value::as_array)
                    .is_some_and(|items| {
                        items.iter().any(|item| {
                            item["content"]
                                .as_array()
                                .is_some_and(|parts| parts.iter().any(|p| p["type"] == "refusal"))
                        })
                    })
                {
                    return Err(AiError::Refusal);
                }
                let text = self.text.trim();
                if text.is_empty() {
                    return Err(AiError::BadResponse);
                }
                return Ok(Some(text.into()));
            }
            "response.incomplete" => return Err(AiError::Incomplete),
            "response.failed" | "error" => return Err(provider_error(event, 0)),
            _ => {}
        }
        Ok(None)
    }
}
fn sse_line(
    line: &str,
    data: &mut String,
    reader: &mut ResponseReader,
) -> Result<Option<String>, AiError> {
    if line.is_empty() {
        if data.is_empty() {
            return Ok(None);
        }
        let payload = std::mem::take(data);
        if payload.trim() == "[DONE]" {
            return Ok(None);
        }
        let event = serde_json::from_str(payload.trim()).map_err(|_| AiError::BadResponse)?;
        return reader.event(&event);
    }
    if let Some(payload) = line.strip_prefix("data:") {
        if data.len() + payload.len() > MAX_RESPONSE {
            return Err(AiError::BadResponse);
        }
        data.push_str(payload.strip_prefix(' ').unwrap_or(payload));
        data.push('\n');
    }
    Ok(None)
}
