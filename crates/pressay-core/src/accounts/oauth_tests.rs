use super::*;
use crate::ai::test_support::{Fixture, MemorySecrets, Reply};
use jsonwebtoken::{EncodingKey, Header};
use serde_json::json;

fn token(claims: Value) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some("pressay-local-fixture-only".into());
    jsonwebtoken::encode(
        &header,
        &claims,
        &EncodingKey::from_rsa_pem(include_bytes!(
            "../../tests/fixtures/oauth-test-only-key.pem"
        ))
        .unwrap(),
    )
    .unwrap()
}
fn claims() -> Value {
    json!({"iss":ISSUER,"sub":"fixture-user","aud":"fixture-client","exp":now()as u64+3600,"iat":now()as u64,"nonce":"fixture-nonce","email":"test@example.invalid"})
}
fn credentials() -> Credentials {
    Credentials {
        email: Some("test@example.invalid".into()),
        subject: "fixture-user".into(),
        client_id: "fixture-client".into(),
        id_token: "fixture-id-token".into(),
        access_token: "old-access".into(),
        refresh_token: "old-refresh".into(),
        expires_at: now() - 1.0,
        scopes: vec![PLAN_SCOPE.into()],
    }
}
fn account(store: Arc<MemorySecrets>, fixture: &Fixture) -> ChatGptAccount {
    let mut account = ChatGptAccount::new(store).unwrap();
    account.endpoints = Endpoints {
        authorize: format!("{}/authorize", fixture.url).parse().unwrap(),
        token: format!("{}/token", fixture.url).parse().unwrap(),
        discovery: format!("{}/discovery", fixture.url).parse().unwrap(),
    };
    account
}
fn config(path: &str, base: &str) -> Reply {
    match path {
        "/discovery" => Reply::json(
            json!({"issuer":ISSUER,"jwks_uri":format!("{base}/jwks"),"revocation_endpoint":format!("{base}/revoke")}),
        ),
        "/jwks" => Reply::json(
            json!({"keys":[serde_json::from_str::<Value>(include_str!("../../tests/fixtures/oauth-test-only-jwk.json")).unwrap()]}),
        ),
        "/revoke" => Reply::json(json!({})),
        _ => panic!("unexpected path {path}"),
    }
}
async fn callback(authorize: &str) {
    let url = Url::parse(authorize).unwrap();
    let fields: HashMap<String, String> = url.query_pairs().into_owned().collect();
    let mut redirect = Url::parse(&fields["redirect_uri"]).unwrap();
    redirect.query_pairs_mut().extend_pairs([
        ("state", fields["state"].as_str()),
        ("code", "fixture-code"),
        ("client_id", "fixture-client"),
    ]);
    let response = Client::new().get(redirect).send().await.unwrap();
    assert!(response.status().is_success());
}

#[test]
fn pkce_state_registration_and_scope_boundaries() {
    let a = Attempt::new("http://127.0.0.1:1455/auth/callback".into(), None);
    let b = Attempt::new(a.redirect.clone(), None);
    assert_ne!(a.state.expose(), b.state.expose());
    assert_ne!(a.state.expose(), a.nonce.expose());
    let url = a.authorize(&Endpoints::default().authorize, "urn:uuid:fixture", None);
    let q: HashMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(q["client_id"], "dynamic_agent_client");
    assert_eq!(q["code_challenge_method"], "S256");
    assert_eq!(
        q["code_challenge"],
        URL_SAFE_NO_PAD.encode(Sha256::digest(a.verifier.expose()))
    );
    assert_eq!(q["resource"], RESOURCE);
    assert!(!url.as_str().contains(a.verifier.expose()));
    let mut fields = HashMap::from([
        ("state".into(), a.state.expose().into()),
        ("code".into(), "c".into()),
        ("client_id".into(), "fixture-client".into()),
    ]);
    assert_eq!(a.callback(&fields).unwrap(), "fixture-client");
    fields.insert("state".into(), "wrong".into());
    assert!(matches!(a.callback(&fields), Err(AiError::Callback)));
    fields.insert("state".into(), a.state.expose().into());
    fields.insert("error".into(), "access_denied".into());
    assert!(matches!(a.callback(&fields), Err(AiError::SignInDenied)));
    assert!(format!("{:?}", Secret::new("private-token".into())).contains("REDACTED"));
}
#[tokio::test]
async fn verifies_signature_issuer_audience_expiry_nonce_and_subject() {
    let fixture = Fixture::new(|request, base| config(&request.path, base)).await;
    let account = account(Arc::new(MemorySecrets::default()), &fixture);
    let good = token(claims());
    assert!(account
        .verify_identity(
            &good,
            "fixture-client",
            Some("fixture-nonce"),
            Some("fixture-user")
        )
        .await
        .is_ok());
    for (key, value) in [
        ("iss", json!("https://untrusted.invalid")),
        ("aud", json!("other-client")),
        ("exp", json!(now() as u64 - 3600)),
        ("nonce", json!("wrong")),
        ("sub", json!("different-user")),
    ] {
        let mut invalid = claims();
        invalid[key] = value;
        assert!(
            matches!(
                account
                    .verify_identity(
                        &token(invalid),
                        "fixture-client",
                        Some("fixture-nonce"),
                        Some("fixture-user")
                    )
                    .await,
                Err(AiError::InvalidCredential)
            ),
            "{key}"
        );
    }
    let mut parts: Vec<_> = good.split('.').map(str::to_owned).collect();
    let changed = if parts[2].starts_with('A') { "B" } else { "A" };
    parts[2].replace_range(..1, changed);
    assert!(account
        .verify_identity(&parts.join("."), "fixture-client", None, None)
        .await
        .is_err());
    assert!(account
        .verify_identity("garbage", "fixture-client", None, None)
        .await
        .is_err());
}
#[tokio::test]
async fn loopback_login_exchanges_verifier_and_keeps_tokens_out_of_status() {
    let nonce = Arc::new(std::sync::Mutex::new(String::new()));
    let captured = nonce.clone();
    let fixture=Fixture::new(move|request,base|if request.path=="/token"{let fields:HashMap<_,_>=url_fields(&request.body);assert_eq!(fields["grant_type"],"authorization_code");assert_eq!(fields["code"],"fixture-code");assert!(fields["code_verifier"].len()>=43);assert_eq!(fields["resource"],RESOURCE);let mut c=claims();c["nonce"]=json!(captured.lock().unwrap().clone());Reply::json(json!({"id_token":token(c),"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"scope":SCOPES}))}else{config(&request.path,base)}).await;
    let store = Arc::new(MemorySecrets::default());
    let account = account(store.clone(), &fixture);
    let status = account
        .sign_in(
            move |url| {
                let fields: HashMap<_, _> = Url::parse(url)
                    .unwrap()
                    .query_pairs()
                    .into_owned()
                    .collect();
                *nonce.lock().unwrap() = fields["nonce"].clone();
                let url = url.to_owned();
                tokio::spawn(async move {
                    callback(&url).await;
                });
                Ok(())
            },
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(status.signed_in);
    let serialized = serde_json::to_string(&status).unwrap();
    assert!(!serialized.contains("fixture-access"));
    assert!(!serialized.contains("fixture-refresh"));
    assert_eq!(
        account
            .access_token(&CancellationToken::new())
            .await
            .unwrap()
            .expose(),
        "fixture-access"
    );
    assert!(account.sign_out().await.unwrap());
    assert!(store.get(TOKEN_KEY).unwrap().is_none());
    assert!(store.get(REGISTRATION_KEY).unwrap().is_some());
    assert!(store.get(HOST_KEY).unwrap().is_some());
    assert!(!account.status().await.signed_in);
}
fn url_fields(body: &[u8]) -> HashMap<String, String> {
    Url::parse(&format!(
        "http://fixture/?{}",
        String::from_utf8_lossy(body)
    ))
    .unwrap()
    .query_pairs()
    .into_owned()
    .collect()
}
#[tokio::test]
async fn failed_exchange_retains_new_registration_for_next_attempt() {
    let fixture = Fixture::new(|_, _| {
        let mut response = Reply::json(json!({"error":"invalid_grant"}));
        response.status = 400;
        response
    })
    .await;
    let store = Arc::new(MemorySecrets::default());
    let account = account(store.clone(), &fixture);
    let result = account
        .sign_in(
            |url| {
                let url = url.to_owned();
                tokio::spawn(async move {
                    callback(&url).await;
                });
                Ok(())
            },
            &CancellationToken::new(),
        )
        .await;
    assert!(matches!(result, Err(AiError::RefreshExpired)));
    assert_eq!(
        account
            .session
            .lock()
            .await
            .registration
            .as_ref()
            .unwrap()
            .client_id,
        "fixture-client"
    );
    assert!(store.get(REGISTRATION_KEY).unwrap().is_some());
    assert!(store.get(TOKEN_KEY).unwrap().is_none());
}
#[tokio::test]
async fn concurrent_refresh_is_single_rotation_and_survives_request_cancellation() {
    let fixture=Fixture::new(|request,_|{assert_eq!(request.path,"/token");let mut reply=Reply::json(json!({"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}));reply.delay=Duration::from_millis(80);reply}).await;
    let store = Arc::new(MemorySecrets::default());
    store
        .set(
            TOKEN_KEY,
            &Secret::new(serde_json::to_string(&credentials()).unwrap()),
        )
        .unwrap();
    let account = Arc::new(account(store.clone(), &fixture));
    let cancel = CancellationToken::new();
    let first = {
        let account = account.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move { account.access_token(&cancel).await })
    };
    fixture.wait_requests(1).await;
    cancel.cancel();
    assert!(matches!(first.await.unwrap(), Err(AiError::Cancelled)));
    let a_cancel = CancellationToken::new();
    let b_cancel = CancellationToken::new();
    let (a, b) = tokio::join!(
        account.access_token(&a_cancel),
        account.access_token(&b_cancel)
    );
    assert_eq!(a.unwrap().expose(), "rotated-access");
    assert_eq!(b.unwrap().expose(), "rotated-access");
    assert_eq!(fixture.requests.lock().unwrap().len(), 1);
    let persisted: Credentials =
        serde_json::from_str(store.get(TOKEN_KEY).unwrap().unwrap().expose()).unwrap();
    assert_eq!(persisted.refresh_token, "rotated-refresh");
    assert_eq!(persisted.scopes, [PLAN_SCOPE]);
}
#[tokio::test]
async fn sign_out_cannot_be_undone_by_inflight_refresh() {
    let fixture=Fixture::new(|request,base|if request.path=="/token"{let mut reply=Reply::json(json!({"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600}));reply.delay=Duration::from_millis(80);reply}else{config(&request.path,base)}).await;
    let store = Arc::new(MemorySecrets::default());
    store
        .set(
            TOKEN_KEY,
            &Secret::new(serde_json::to_string(&credentials()).unwrap()),
        )
        .unwrap();
    let account = Arc::new(account(store.clone(), &fixture));
    let refresh = {
        let account = account.clone();
        tokio::spawn(async move { account.access_token(&CancellationToken::new()).await })
    };
    fixture.wait_requests(1).await;
    account.sign_out().await.unwrap();
    assert!(matches!(refresh.await.unwrap(), Err(AiError::Cancelled)));
    assert!(store.get(TOKEN_KEY).unwrap().is_none());
    assert!(!account.status().await.signed_in);
}
#[tokio::test]
async fn terminal_refresh_error_clears_tokens_and_scope_loss_is_not_hidden() {
    for response in [
        json!({"error":"refresh_token_reused"}),
        json!({"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"openid email"}),
    ] {
        let fixture = Fixture::new(move |_, _| {
            let mut reply = Reply::json(response.clone());
            if response.get("error").is_some() {
                reply.status = 400;
            }
            reply
        })
        .await;
        let store = Arc::new(MemorySecrets::default());
        store
            .set(
                TOKEN_KEY,
                &Secret::new(serde_json::to_string(&credentials()).unwrap()),
            )
            .unwrap();
        let account = account(store.clone(), &fixture);
        assert!(matches!(
            account.access_token(&CancellationToken::new()).await,
            Err(AiError::RefreshExpired | AiError::PlanNotGranted)
        ));
        assert!(store.get(TOKEN_KEY).unwrap().is_none());
        assert!(!account.status().await.signed_in);
    }
}

#[tokio::test]
async fn unavailable_secret_service_never_breaks_local_startup_or_leaks_adapter_errors() {
    struct Unavailable;
    impl SecretStore for Unavailable {
        fn get(&self, _: &str) -> Result<Option<Secret>, String> {
            Err("private DBus body secret-token".into())
        }
        fn set(&self, _: &str, _: &Secret) -> Result<(), String> {
            panic!("startup must never write credentials")
        }
        fn delete(&self, _: &str) -> Result<(), String> {
            Err("private DBus body secret-token".into())
        }
    }
    let accounts = crate::accounts::Accounts::new(Arc::new(Unavailable))
        .expect("AI vault is optional on startup");
    let status = accounts.chatgpt.status().await;
    assert!(!status.signed_in);
    assert_eq!(
        status.error.as_deref(),
        Some("Could not access the operating system credential store")
    );
    assert!(!serde_json::to_string(&status)
        .unwrap()
        .contains("secret-token"));
    let store = Arc::new(MemorySecrets::default());
    let accounts = crate::accounts::Accounts::new(store.clone()).unwrap();
    assert!(store.0.lock().unwrap().is_empty());
    accounts.chatgpt.status().await;
    assert!(store.0.lock().unwrap().is_empty());
    accounts
        .set_api_key(crate::accounts::ApiProvider::Claude, " fixture-key ")
        .unwrap();
    assert!(store.get(HOST_KEY).unwrap().is_none());
    assert_eq!(
        accounts
            .api_key(crate::accounts::ApiProvider::Claude)
            .unwrap()
            .unwrap()
            .expose(),
        "fixture-key"
    );
    accounts
        .set_api_key(crate::accounts::ApiProvider::Claude, "")
        .unwrap();
    assert!(accounts
        .api_key(crate::accounts::ApiProvider::Claude)
        .unwrap()
        .is_none());
    assert!(matches!(
        accounts.set_api_key(crate::accounts::ApiProvider::OpenAi, "bad\nheader"),
        Err(AiError::InvalidCredential)
    ));
}
#[tokio::test]
async fn callback_rejects_wrong_path_duplicate_parameters_and_state() {
    for path in [
        "/wrong?state=",
        "/auth/callback?state=wrong&code=x&unused=",
        "/auth/callback?state=wrong&state=",
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let attempt = Attempt::new(format!("http://{address}/auth/callback"), None);
        let request = format!(
            "GET {path}{} HTTP/1.1\r\nHost: {address}\r\n\r\n",
            attempt.state.expose()
        );
        let client = tokio::spawn(async move {
            let mut socket = TcpStream::connect(address).await.unwrap();
            socket.write_all(request.as_bytes()).await.unwrap();
            socket.shutdown().await.unwrap();
        });
        let (mut socket, _) = listener.accept().await.unwrap();
        assert!(matches!(
            read_callback(&mut socket, &attempt).await,
            Err(AiError::Callback)
        ));
        client.await.unwrap();
    }
}
#[tokio::test]
async fn signing_out_invalidates_a_late_browser_exchange() {
    let nonce = Arc::new(std::sync::Mutex::new(String::new()));
    let captured = nonce.clone();
    let fixture=Fixture::new(move|request,base|if request.path=="/token"{let mut c=claims();c["nonce"]=json!(captured.lock().unwrap().clone());let mut reply=Reply::json(json!({"id_token":token(c),"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600,"scope":SCOPES}));reply.delay=Duration::from_millis(80);reply}else{config(&request.path,base)}).await;
    let store = Arc::new(MemorySecrets::default());
    let account = Arc::new(account(store.clone(), &fixture));
    let login = {
        let account = account.clone();
        tokio::spawn(async move {
            account
                .sign_in(
                    move |url| {
                        let fields: HashMap<_, _> = Url::parse(url)
                            .unwrap()
                            .query_pairs()
                            .into_owned()
                            .collect();
                        *nonce.lock().unwrap() = fields["nonce"].clone();
                        let url = url.to_owned();
                        tokio::spawn(async move {
                            callback(&url).await;
                        });
                        Ok(())
                    },
                    &CancellationToken::new(),
                )
                .await
        })
    };
    fixture.wait_requests(1).await;
    account.sign_out().await.unwrap();
    assert!(matches!(login.await.unwrap(), Err(AiError::Cancelled)));
    assert!(store.get(TOKEN_KEY).unwrap().is_none());
    assert!(!account.status().await.signed_in);
}

#[tokio::test]
async fn shutdown_drains_cancelled_rotation_before_acknowledging_exit() {
    let fixture=Fixture::new(|_,_|{let mut response=Reply::json(json!({"access_token":"persist-before-exit","refresh_token":"rotated-before-exit","expires_in":3600}));response.delay=Duration::from_millis(80);response}).await;
    let store = Arc::new(MemorySecrets::default());
    store
        .set(
            TOKEN_KEY,
            &Secret::new(serde_json::to_string(&credentials()).unwrap()),
        )
        .unwrap();
    let account = Arc::new(account(store.clone(), &fixture));
    let token = CancellationToken::new();
    let task = {
        let account = account.clone();
        let token = token.clone();
        tokio::spawn(async move { account.access_token(&token).await })
    };
    fixture.wait_requests(1).await;
    token.cancel();
    assert!(matches!(task.await.unwrap(), Err(AiError::Cancelled)));
    account.shutdown().await;
    let saved: Credentials =
        serde_json::from_str(store.get(TOKEN_KEY).unwrap().unwrap().expose()).unwrap();
    assert_eq!(saved.refresh_token, "rotated-before-exit");
    assert!(matches!(
        account.access_token(&CancellationToken::new()).await,
        Err(AiError::Cancelled)
    ));
}
