use super::{Secret, SecretStore};
use crate::ai::AiError;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use rand::{rngs::OsRng, RngCore};
use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Mutex,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

pub const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
const ISSUER: &str = "https://auth.openai.com";
const RESOURCE: &str = "https://api.openai.com/v1";
const SCOPES: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
const TOKEN_KEY: &str = "chatgpt-credentials";
const REGISTRATION_KEY: &str = "chatgpt-registration";
const HOST_KEY: &str = "chatgpt-host-id";
const MAX_BODY: usize = 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
struct Credentials {
    email: Option<String>,
    subject: String,
    client_id: String,
    id_token: String,
    access_token: String,
    refresh_token: String,
    expires_at: f64,
    scopes: Vec<String>,
}
impl Drop for Credentials {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.id_token.zeroize();
        self.access_token.zeroize();
        self.refresh_token.zeroize();
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Registration {
    client_id: String,
    subject: Option<String>,
    email: Option<String>,
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct AccountStatus {
    pub signed_in: bool,
    pub email: Option<String>,
    pub plan_usage_granted: bool,
    pub error: Option<String>,
}

struct Session {
    loaded: bool,
    credentials: Option<Credentials>,
    registration: Option<Registration>,
    host_id: String,
}
#[derive(Clone)]
struct Endpoints {
    authorize: Url,
    token: Url,
    discovery: Url,
}
impl Default for Endpoints {
    fn default() -> Self {
        Self {
            authorize: Url::parse("https://auth.openai.com/api/accounts/authorize").unwrap(),
            token: Url::parse("https://auth.openai.com/api/accounts/oauth/token").unwrap(),
            discovery: Url::parse("https://auth.openai.com/.well-known/openid-configuration")
                .unwrap(),
        }
    }
}

#[derive(Default)]
struct RefreshTasks {
    state: std::sync::Mutex<(bool, usize)>,
    changed: tokio::sync::Notify,
}
struct RefreshLease(Arc<RefreshTasks>);
impl RefreshTasks {
    fn begin(self: &Arc<Self>) -> Result<RefreshLease, AiError> {
        let mut state = self.state.lock().unwrap();
        if state.0 {
            return Err(AiError::Cancelled);
        }
        state.1 += 1;
        Ok(RefreshLease(self.clone()))
    }
    async fn shutdown(&self) {
        self.state.lock().unwrap().0 = true;
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.state.lock().unwrap().1 == 0 {
                return;
            }
            notified.await;
        }
    }
}
impl Drop for RefreshLease {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().1 -= 1;
        self.0.changed.notify_waiters();
    }
}

/// Owns registration, token rotation and loopback login. Concurrent refreshes
/// serialize under the session mutex. Tokens never appear in AccountStatus.
#[derive(Clone)]
pub struct ChatGptAccount {
    store: Arc<dyn SecretStore>,
    client: Client,
    session: Arc<Mutex<Session>>,
    login: Arc<Mutex<()>>,
    generation: Arc<AtomicU64>,
    endpoints: Endpoints,
    refreshes: Arc<RefreshTasks>,
}
impl ChatGptAccount {
    pub fn new(store: Arc<dyn SecretStore>) -> Result<Self, AiError> {
        Ok(Self {
            store,
            client: Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(20))
                .build()
                .map_err(|_| AiError::Transport)?,
            session: Arc::new(Mutex::new(Session {
                loaded: false,
                credentials: None,
                registration: None,
                host_id: String::new(),
            })),
            login: Arc::new(Mutex::new(())),
            generation: Arc::new(AtomicU64::new(0)),
            endpoints: Endpoints::default(),
            refreshes: Arc::new(RefreshTasks::default()),
        })
    }
    fn load(&self, session: &mut Session) -> Result<(), AiError> {
        if session.loaded {
            return Ok(());
        }
        let read = |key| self.store.get(key).map_err(|_| AiError::CredentialStore);
        let credentials: Option<Credentials> = read(TOKEN_KEY)?
            .map(|s| serde_json::from_str(s.expose()).map_err(|_| AiError::InvalidCredential))
            .transpose()?;
        let registration = read(REGISTRATION_KEY)?
            .map(|s| serde_json::from_str(s.expose()).map_err(|_| AiError::InvalidCredential))
            .transpose()?
            .or_else(|| {
                credentials.as_ref().map(|c| Registration {
                    client_id: c.client_id.clone(),
                    subject: Some(c.subject.clone()),
                    email: c.email.clone(),
                })
            });
        session.credentials = credentials;
        session.registration = registration;
        session.loaded = true;
        Ok(())
    }
    fn host_id(&self, session: &mut Session) -> Result<String, AiError> {
        if session.host_id.is_empty() {
            session.host_id = if let Some(host) = self
                .store
                .get(HOST_KEY)
                .map_err(|_| AiError::CredentialStore)?
            {
                host.expose().to_owned()
            } else {
                let host = format!("urn:uuid:{}", uuid::Uuid::new_v4());
                self.store
                    .set(HOST_KEY, &Secret::new(host.clone()))
                    .map_err(|_| AiError::CredentialStore)?;
                host
            };
        }
        Ok(session.host_id.clone())
    }
    pub async fn status(&self) -> AccountStatus {
        let mut session = self.session.lock().await;
        if let Err(error) = self.load(&mut session) {
            return AccountStatus {
                error: Some(error.to_string()),
                ..Default::default()
            };
        }
        let granted = session
            .credentials
            .as_ref()
            .is_some_and(|c| c.scopes.iter().any(|s| s == PLAN_SCOPE));
        AccountStatus {
            signed_in: granted,
            email: session
                .credentials
                .as_ref()
                .and_then(|c| c.email.clone())
                .or_else(|| session.registration.as_ref().and_then(|r| r.email.clone())),
            plan_usage_granted: granted,
            error: None,
        }
    }
    /// `open_browser` must be a native system-browser call, not an IPC response.
    /// It receives a sign-in URL containing state/nonce and possibly an ID hint.
    pub async fn sign_in(
        &self,
        open_browser: impl FnOnce(&str) -> Result<(), String>,
        cancel: &CancellationToken,
    ) -> Result<AccountStatus, AiError> {
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        let _login = self.login.try_lock().map_err(|_| AiError::SignInBusy)?;
        let generation = self.generation.load(Ordering::Acquire);
        let listener = match TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 1455)).await {
            Ok(l) => l,
            Err(_) => TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
                .await
                .map_err(|_| AiError::Callback)?,
        };
        let redirect = format!(
            "http://127.0.0.1:{}/auth/callback",
            listener.local_addr().map_err(|_| AiError::Callback)?.port()
        );
        let (registration, previous, host) = {
            let mut session = self.session.lock().await;
            self.load(&mut session)?;
            let host = self.host_id(&mut session)?;
            (
                session.registration.clone(),
                session.credentials.clone(),
                host,
            )
        };
        let attempt = Attempt::new(redirect, registration.as_ref().map(|r| r.client_id.clone()));
        let authorize = attempt.authorize(&self.endpoints.authorize, &host, previous.as_ref());
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        open_browser(authorize.as_str()).map_err(|_| AiError::Browser)?;
        let result = async {
            let fields = receive_callback(&listener, &attempt, cancel).await?;
            let issued = attempt.callback(&fields)?;
            // Retain a newly issued registration even if this one-time code expires.
            let pending = Registration {
                client_id: issued.clone(),
                subject: registration.as_ref().and_then(|r| r.subject.clone()),
                email: registration.as_ref().and_then(|r| r.email.clone()),
            };
            {
                let mut session = self.session.lock().await;
                if self.generation.load(Ordering::Acquire) != generation {
                    return Err(AiError::Cancelled);
                }
                self.save_registration(&pending)?;
                session.registration = Some(pending);
            }
            let token = self
                .post(
                    &self.endpoints.token,
                    &[
                        ("grant_type", "authorization_code"),
                        ("client_id", &issued),
                        ("code", fields.get("code").unwrap()),
                        ("code_verifier", attempt.verifier.expose()),
                        ("redirect_uri", &attempt.redirect),
                        ("resource", RESOURCE),
                    ],
                )
                .await?;
            let id = required(&token, "id_token")?;
            let claims = self
                .verify_identity(
                    id,
                    &issued,
                    Some(attempt.nonce.expose()),
                    registration.as_ref().and_then(|r| r.subject.as_deref()),
                )
                .await?;
            let credentials = Credentials {
                email: claims
                    .get("email")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                subject: required(&claims, "sub")?.into(),
                client_id: issued,
                id_token: id.into(),
                access_token: required(&token, "access_token")?.into(),
                refresh_token: required(&token, "refresh_token")?.into(),
                expires_at: expiry(&token)?,
                scopes: scopes(&token).ok_or(AiError::PlanNotGranted)?,
            };
            if !credentials.scopes.iter().any(|s| s == PLAN_SCOPE) {
                return Err(AiError::PlanNotGranted);
            }
            let mut session = self.session.lock().await;
            if self.generation.load(Ordering::Acquire) != generation {
                return Err(AiError::Cancelled);
            }
            self.persist(&credentials)?;
            let registration = Registration {
                client_id: credentials.client_id.clone(),
                subject: Some(credentials.subject.clone()),
                email: credentials.email.clone(),
            };
            self.save_registration(&registration)?;
            session.registration = Some(registration);
            session.credentials = Some(credentials);
            Ok::<(), AiError>(())
        };
        tokio::select! { biased; _=cancel.cancelled()=>return Err(AiError::Cancelled), result=tokio::time::timeout(Duration::from_secs(300),result)=>result.map_err(|_|AiError::Timeout)?? };
        Ok(self.status().await)
    }
    pub async fn access_token(&self, cancel: &CancellationToken) -> Result<Secret, AiError> {
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        // Token rotation must finish and persist even when its requesting
        // dictation is cancelled. The owned task has a bounded HTTP timeout.
        let owned = self.clone();
        let generation = self.generation.load(Ordering::Acquire);
        let lease = self.refreshes.begin()?;
        let task = tokio::spawn(async move {
            let _lease = lease;
            owned.refresh_access_token(generation).await
        });
        tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=task=>result.map_err(|_|AiError::Transport)?}
    }
    /// After cancelling interactive login, drain already-started token rotations.
    /// Each network phase is bounded by the 20-second client timeout.
    pub async fn shutdown(&self) {
        self.refreshes.shutdown().await;
    }
    async fn refresh_access_token(&self, generation: u64) -> Result<Secret, AiError> {
        let mut session = self.session.lock().await;
        self.load(&mut session)?;
        if self.generation.load(Ordering::Acquire) != generation {
            return Err(AiError::Cancelled);
        }
        let mut current = session
            .credentials
            .as_ref()
            .ok_or(AiError::NotConfigured)?
            .clone();
        if current.expires_at - now() < 120.0 {
            if let Some(stored) = self
                .store
                .get(TOKEN_KEY)
                .map_err(|_| AiError::CredentialStore)?
            {
                let latest: Credentials = serde_json::from_str(stored.expose())
                    .map_err(|_| AiError::InvalidCredential)?;
                if latest.client_id == current.client_id
                    && latest.subject == current.subject
                    && latest.expires_at > current.expires_at
                {
                    session.credentials = Some(latest.clone());
                    current = latest;
                }
            }
        }
        if !current.scopes.iter().any(|s| s == PLAN_SCOPE) {
            return Err(AiError::PlanNotGranted);
        }
        if current.expires_at - now() >= 120.0 {
            return Ok(Secret::new(current.access_token.clone()));
        }
        let result = self
            .post(
                &self.endpoints.token,
                &[
                    ("grant_type", "refresh_token"),
                    ("client_id", &current.client_id),
                    ("refresh_token", &current.refresh_token),
                    ("resource", RESOURCE),
                ],
            )
            .await;
        if self.generation.load(Ordering::Acquire) != generation {
            return Err(AiError::Cancelled);
        }
        let token = match result {
            Err(AiError::RefreshExpired) => {
                self.store
                    .delete(TOKEN_KEY)
                    .map_err(|_| AiError::CredentialStore)?;
                session.credentials = None;
                return Err(AiError::RefreshExpired);
            }
            other => other?,
        };
        let mut refreshed = current.clone();
        refreshed.access_token = required(&token, "access_token")?.into();
        if let Some(value) = token.get("refresh_token").and_then(Value::as_str) {
            if value.is_empty() {
                return Err(AiError::InvalidCredential);
            }
            refreshed.refresh_token = value.into();
        }
        if let Some(value) = scopes(&token) {
            refreshed.scopes = value;
        }
        if !refreshed.scopes.iter().any(|s| s == PLAN_SCOPE) {
            self.store
                .delete(TOKEN_KEY)
                .map_err(|_| AiError::CredentialStore)?;
            session.credentials = None;
            return Err(AiError::PlanNotGranted);
        }
        if let Some(id) = token.get("id_token").and_then(Value::as_str) {
            self.verify_identity(id, &current.client_id, None, Some(&current.subject))
                .await?;
            refreshed.id_token = id.into();
        }
        refreshed.expires_at = expiry(&token)?;
        if self.generation.load(Ordering::Acquire) != generation {
            return Err(AiError::Cancelled);
        }
        self.persist(&refreshed)?;
        let access = Secret::new(refreshed.access_token.clone());
        session.credentials = Some(refreshed);
        Ok(access)
    }
    /// Revocation is best effort; tokens are cleared locally even when offline.
    /// Keep client/account mapping and the host ID for future reauthorization.
    pub async fn sign_out(&self) -> Result<bool, AiError> {
        self.generation.fetch_add(1, Ordering::AcqRel);
        let mut session = self.session.lock().await;
        let _ = self.load(&mut session);
        let current = session.credentials.take();
        self.store
            .delete(TOKEN_KEY)
            .map_err(|_| AiError::CredentialStore)?;
        drop(session);
        let Some(current) = current else {
            return Ok(true);
        };
        let revoke = async {
            let config = self.get(&self.endpoints.discovery).await?;
            let endpoint = self.trusted_endpoint(required(&config, "revocation_endpoint")?)?;
            let response = self
                .client
                .post(endpoint)
                .form(&[
                    ("token", current.refresh_token.as_str()),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", current.client_id.as_str()),
                ])
                .send()
                .await
                .map_err(|_| AiError::Transport)?;
            Ok::<_, AiError>(response.status().as_u16() == 200)
        };
        Ok(tokio::time::timeout(Duration::from_secs(10), revoke)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false))
    }
    fn persist(&self, c: &Credentials) -> Result<(), AiError> {
        let json =
            Zeroizing::new(serde_json::to_string(c).map_err(|_| AiError::InvalidCredential)?);
        self.store
            .set(TOKEN_KEY, &Secret::new(json.to_string()))
            .map_err(|_| AiError::CredentialStore)
    }
    fn save_registration(&self, r: &Registration) -> Result<(), AiError> {
        self.store
            .set(
                REGISTRATION_KEY,
                &Secret::new(serde_json::to_string(r).map_err(|_| AiError::InvalidCredential)?),
            )
            .map_err(|_| AiError::CredentialStore)
    }
    fn trusted_endpoint(&self, value: &str) -> Result<Url, AiError> {
        let url = Url::parse(value).map_err(|_| AiError::InvalidCredential)?;
        if url.origin() != self.endpoints.discovery.origin() {
            return Err(AiError::InvalidCredential);
        }
        Ok(url)
    }
    async fn get(&self, url: &Url) -> Result<Value, AiError> {
        let response = self
            .client
            .get(url.clone())
            .send()
            .await
            .map_err(|_| AiError::Transport)?;
        if !response.status().is_success() {
            return Err(AiError::InvalidCredential);
        }
        bounded_json(response).await
    }
    async fn post(&self, url: &Url, fields: &[(&str, &str)]) -> Result<Value, AiError> {
        let response = self
            .client
            .post(url.clone())
            .form(fields)
            .send()
            .await
            .map_err(|_| AiError::Transport)?;
        let status = response.status().as_u16();
        let value = bounded_json(response).await?;
        if status != 200 {
            let code = value.get("error").and_then(Value::as_str).unwrap_or("");
            if (400..=401).contains(&status)
                && [
                    "invalid_grant",
                    "invalid_refresh_token",
                    "token_expired",
                    "refresh_token_expired",
                    "refresh_token_invalidated",
                    "refresh_token_reused",
                ]
                .contains(&code)
            {
                return Err(AiError::RefreshExpired);
            }
            return Err(AiError::Http(status));
        }
        Ok(value)
    }
    async fn verify_identity(
        &self,
        token: &str,
        client: &str,
        nonce: Option<&str>,
        subject: Option<&str>,
    ) -> Result<Value, AiError> {
        let header = decode_header(token).map_err(|_| AiError::InvalidCredential)?;
        if header.alg != Algorithm::RS256 {
            return Err(AiError::InvalidCredential);
        }
        let kid = header.kid.ok_or(AiError::InvalidCredential)?;
        let config = self.get(&self.endpoints.discovery).await?;
        if config.get("issuer").and_then(Value::as_str) != Some(ISSUER) {
            return Err(AiError::InvalidCredential);
        }
        let jwks = self
            .get(&self.trusted_endpoint(required(&config, "jwks_uri")?)?)
            .await?;
        let jwk = jwks["keys"]
            .as_array()
            .and_then(|keys| {
                keys.iter()
                    .find(|key| key["kid"].as_str() == Some(&kid) && key["kty"] == "RSA")
            })
            .ok_or(AiError::InvalidCredential)?;
        let key = DecodingKey::from_rsa_components(required(jwk, "n")?, required(jwk, "e")?)
            .map_err(|_| AiError::InvalidCredential)?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_audience(&[client]);
        validation.set_issuer(&[ISSUER]);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.leeway = 60;
        let claims = decode::<Value>(token, &key, &validation)
            .map_err(|_| AiError::InvalidCredential)?
            .claims;
        if nonce.is_some_and(|n| claims["nonce"].as_str() != Some(n))
            || subject.is_some_and(|s| claims["sub"].as_str() != Some(s))
            || claims["sub"].as_str().is_none_or(str::is_empty)
        {
            return Err(AiError::InvalidCredential);
        }
        Ok(claims)
    }
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn required<'a>(value: &'a Value, key: &str) -> Result<&'a str, AiError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or(AiError::InvalidCredential)
}
fn scopes(value: &Value) -> Option<Vec<String>> {
    value
        .get("scope")
        .and_then(Value::as_str)
        .map(|s| s.split_whitespace().map(str::to_owned).collect())
}
fn expiry(value: &Value) -> Result<f64, AiError> {
    let seconds = value
        .get("expires_in")
        .and_then(Value::as_f64)
        .unwrap_or(3600.0);
    if !seconds.is_finite() || seconds <= 0.0 || seconds > 86400.0 * 365.0 {
        return Err(AiError::InvalidCredential);
    }
    Ok(now() + seconds)
}
async fn bounded_json(mut response: reqwest::Response) -> Result<Value, AiError> {
    let mut data = Zeroizing::new(Vec::new());
    while let Some(chunk) = response.chunk().await.map_err(|_| AiError::Transport)? {
        if data.len() + chunk.len() > MAX_BODY {
            return Err(AiError::InvalidCredential);
        }
        data.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&data).map_err(|_| AiError::InvalidCredential)
}

struct Attempt {
    state: Secret,
    nonce: Secret,
    verifier: Secret,
    redirect: String,
    client: String,
}
impl Attempt {
    fn new(redirect: String, client: Option<String>) -> Self {
        fn random(n: usize) -> Secret {
            let mut bytes = Zeroizing::new(vec![0; n]);
            OsRng.fill_bytes(&mut bytes);
            Secret::new(URL_SAFE_NO_PAD.encode(&bytes))
        }
        Self {
            state: random(32),
            nonce: random(32),
            verifier: random(48),
            redirect,
            client: client.unwrap_or("dynamic_agent_client".into()),
        }
    }
    fn authorize(&self, endpoint: &Url, host: &str, previous: Option<&Credentials>) -> Url {
        let mut url = endpoint.clone();
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(self.verifier.expose().as_bytes()));
        {
            let mut q = url.query_pairs_mut();
            q.extend_pairs([
                ("client_id", self.client.as_str()),
                ("ext_agent_host_id", host),
                ("response_type", "code"),
                ("redirect_uri", &self.redirect),
                ("scope", SCOPES),
                ("resource", RESOURCE),
                ("state", self.state.expose()),
                ("nonce", self.nonce.expose()),
                ("code_challenge_method", "S256"),
                ("code_challenge", &challenge),
            ]);
            if self.client == "dynamic_agent_client" {
                q.append_pair("agent_name_hint", "Pressay");
            } else if let Some(previous) = previous {
                q.append_pair("id_token_hint", &previous.id_token);
                if let Some(email) = &previous.email {
                    q.append_pair("login_hint", email);
                }
            }
        }
        url
    }
    fn callback(&self, fields: &HashMap<String, String>) -> Result<String, AiError> {
        if fields.get("state").map(String::as_str) != Some(self.state.expose()) {
            return Err(AiError::Callback);
        }
        if fields.contains_key("error") {
            return Err(AiError::SignInDenied);
        }
        if fields.get("code").is_none_or(String::is_empty) {
            return Err(AiError::Callback);
        }
        if self.client == "dynamic_agent_client" {
            fields
                .get("client_id")
                .filter(|id| !id.is_empty() && id.as_str() != "dynamic_agent_client")
                .cloned()
                .ok_or(AiError::Callback)
        } else if fields.get("client_id").is_some_and(|id| id != &self.client) {
            Err(AiError::Callback)
        } else {
            Ok(self.client.clone())
        }
    }
}
async fn receive_callback(
    listener: &TcpListener,
    attempt: &Attempt,
    cancel: &CancellationToken,
) -> Result<HashMap<String, String>, AiError> {
    loop {
        let (mut socket, address) = tokio::select! {biased;_=cancel.cancelled()=>return Err(AiError::Cancelled),result=listener.accept()=>result.map_err(|_|AiError::Callback)?};
        if !address.ip().is_loopback() {
            continue;
        }
        let result =
            tokio::time::timeout(Duration::from_secs(5), read_callback(&mut socket, attempt)).await;
        let (valid, fields) = match result {
            Ok(Ok(fields)) => (true, Some(fields)),
            _ => (false, None),
        };
        let body = if valid {
            "Sign-in received. Return to Pressay to finish verifying your account."
        } else {
            "Invalid callback. Return to Pressay and try again."
        };
        let response=format!("HTTP/1.1 {}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",if valid{"200 OK"}else{"400 Bad Request"},body.len(),body);
        let _ = socket.write_all(response.as_bytes()).await;
        if let Some(fields) = fields {
            return Ok(fields);
        }
    }
}
async fn read_callback(
    socket: &mut TcpStream,
    attempt: &Attempt,
) -> Result<HashMap<String, String>, AiError> {
    let mut data = Zeroizing::new(Vec::new());
    let mut chunk = [0u8; 1024];
    loop {
        let n = socket
            .read(&mut chunk)
            .await
            .map_err(|_| AiError::Callback)?;
        if n == 0 {
            return Err(AiError::Callback);
        }
        data.extend_from_slice(&chunk[..n]);
        if data.len() > 16_384 {
            return Err(AiError::Callback);
        }
        if data.windows(4).any(|s| s == b"\r\n\r\n") {
            break;
        }
    }
    let text = std::str::from_utf8(&data).map_err(|_| AiError::Callback)?;
    let parts: Vec<_> = text
        .lines()
        .next()
        .ok_or(AiError::Callback)?
        .split_whitespace()
        .collect();
    if parts.len() != 3 || parts[0] != "GET" || !parts[1].starts_with("/auth/callback?") {
        return Err(AiError::Callback);
    }
    let url =
        Url::parse(&format!("http://127.0.0.1{}", parts[1])).map_err(|_| AiError::Callback)?;
    if url.path() != "/auth/callback" {
        return Err(AiError::Callback);
    }
    let mut fields = HashMap::new();
    for (k, v) in url.query_pairs() {
        if fields.insert(k.into_owned(), v.into_owned()).is_some() {
            return Err(AiError::Callback);
        }
    }
    if fields.get("state").map(String::as_str) != Some(attempt.state.expose()) {
        return Err(AiError::Callback);
    }
    Ok(fields)
}

#[cfg(test)]
#[path = "oauth_tests.rs"]
mod tests;
