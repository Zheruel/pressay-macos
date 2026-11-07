use super::test_support::{Fixture, MemorySecrets, Reply};
use super::*;
use crate::accounts::{Secret, SecretStore};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};

fn source() -> &'static str {
    "please keep the API stable and do not change the database"
}
fn reply(text: &str) -> Value {
    json!({"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"never display this"},{"type":"text","text":text}]})
}
fn events(text: &str) -> Vec<Value> {
    vec![
        json!({"type":"response.output_text.delta","delta":text}),
        json!({"type":"response.completed","response":{"status":"completed"}}),
    ]
}
fn service(fixture: &Fixture) -> AiService {
    let store = Arc::new(MemorySecrets::default());
    store
        .set("claude-api-key", &Secret::new("fixture-claude-key".into()))
        .unwrap();
    store
        .set("openai-api-key", &Secret::new("fixture-openai-key".into()))
        .unwrap();
    AiService {
        accounts: Arc::new(Accounts::new(store).unwrap()),
        claude_code: claude_code::ClaudeCodeClient::unavailable(),
        http: HttpAi::with_endpoints(fixture.endpoints()).unwrap(),
    }
}

#[test]
fn shipping_policy_models_and_prompts_are_preserved() {
    assert!(!should_clean(
        "one two three four five six seven eight nine",
        false
    ));
    assert!(should_clean(source(), false));
    assert!(!should_clean(source(), true));
    assert_eq!(
        cleanup_timeout(source(), CleanupConfig::default()),
        Duration::from_secs_f64(3.11)
    );
    assert_eq!(
        cleanup_timeout(
            source(),
            CleanupConfig {
                connection: Connection::Subscription,
                ..Default::default()
            }
        ),
        Duration::from_secs_f64(8.11)
    );
    assert!(!plausible(source(), "Yes"));
    assert!(plausible(
        source(),
        "Keep the API stable and do not change the database."
    ));
    for prompt in [
        prompts::CLEANUP,
        prompts::MEETING,
        prompts::USER_NOTES,
        prompts::ASK,
    ] {
        assert!(!prompt.trim().is_empty());
    }
}
#[tokio::test]
async fn cleanup_sends_raw_text_exact_model_and_never_audio() {
    let fixture = Fixture::new(|_, _| {
        Reply::json(reply("Keep the API stable and do not change the database."))
    })
    .await;
    let ai = service(&fixture);
    let outcome = ai
        .cleanup(
            source(),
            "local fallback",
            Some("com.apple.Notes"),
            &[],
            CleanupConfig::default(),
            None,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(outcome.used_language_model);
    assert!(outcome.warning.is_none());
    assert_eq!(
        outcome.text,
        "Keep the API stable and do not change the database."
    );
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    let request = &requests[0];
    let body: Value = serde_json::from_slice(&request.body).unwrap();
    assert_eq!(body["model"], CLAUDE_DICTATION_MODEL);
    assert_eq!(body["output_config"]["effort"], "low");
    assert_eq!(body["max_tokens"], 4000);
    assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");
    assert!(body["messages"][0]["content"]
        .as_str()
        .unwrap()
        .contains(source()));
    assert!(!String::from_utf8_lossy(&request.body).contains("local fallback"));
    assert!(request.headers.contains("x-api-key: fixture-claude-key"));
}
#[tokio::test]
async fn malformed_truncated_implausible_and_http_failure_keep_local_text_exactly() {
    for response in [
        json!({"stop_reason":"max_tokens","content":[{"type":"text","text":"Partial"}]}),
        json!({"stop_reason":"end_turn","content":[]}),
        reply("Yes"),
        json!("provider-private-error"),
    ] {
        let fixture = Fixture::new(move |_, _| Reply::json(response.clone())).await;
        let ai = service(&fixture);
        let local = "Čuvaj API; don't delete customer_id or José.";
        let result = ai
            .cleanup(
                source(),
                local,
                None,
                &[],
                CleanupConfig::default(),
                None,
                &CancellationToken::new(),
            )
            .await
            .unwrap();
        assert_eq!(result.text, local);
        assert!(!result.used_language_model);
        assert!(!result.warning.unwrap().contains("provider-private-error"));
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
    }
}
#[tokio::test]
async fn short_terminal_disabled_and_cancelled_requests_do_not_infer() {
    let fixture = Fixture::new(|_, _| panic!("bypassed cleanup must not call provider")).await;
    let ai = service(&fixture);
    let cancel = CancellationToken::new();
    for (raw, target, enabled) in [
        ("quick note", None, true),
        (source(), Some("com.apple.Terminal"), true),
        (source(), Some("powershell.exe"), true),
        (source(), None, false),
    ] {
        let out = ai
            .cleanup(
                raw,
                "local",
                target,
                &[],
                CleanupConfig {
                    enabled,
                    ..Default::default()
                },
                None,
                &cancel,
            )
            .await
            .unwrap();
        assert_eq!(out.text, "local");
        assert!(!out.used_language_model);
        assert!(out.warning.is_none());
    }
    cancel.cancel();
    assert!(matches!(
        ai.cleanup(
            source(),
            "local",
            None,
            &[],
            Default::default(),
            None,
            &cancel
        )
        .await,
        Err(AiError::Cancelled)
    ));
    assert!(fixture.requests.lock().unwrap().is_empty());
}
#[tokio::test]
async fn cancellation_and_deadline_abort_http_without_retry() {
    let fixture = Fixture::new(|_, _| {
        let mut response = Reply::json(reply(source()));
        response.delay = Duration::from_secs(1);
        response
    })
    .await;
    let ai = Arc::new(service(&fixture));
    let cancel = CancellationToken::new();
    let task = {
        let ai = ai.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            ai.cleanup(
                source(),
                "fallback",
                None,
                &[],
                Default::default(),
                None,
                &cancel,
            )
            .await
        })
    };
    fixture.wait_requests(1).await;
    cancel.cancel();
    assert!(matches!(task.await.unwrap(), Err(AiError::Cancelled)));
    assert!(matches!(
        ai.http
            .claude(
                "s",
                "u",
                CLAUDE_DICTATION_MODEL,
                "low",
                4000,
                &Secret::new("test".into()),
                Duration::from_millis(30),
                &CancellationToken::new()
            )
            .await,
        Err(AiError::Timeout)
    ));
    assert_eq!(fixture.requests.lock().unwrap().len(), 2);
}
#[tokio::test]
async fn fragmented_sse_handles_unicode_and_refuses_incomplete_or_refusal() {
    let fixture = Fixture::new(|_, _| {
        let mut response = Reply::sse(&events("Živjeli, José 🎉"));
        response.fragment = 1;
        response
    })
    .await;
    let ai = service(&fixture);
    let text = ai
        .http
        .openai(
            "system",
            "user",
            OPENAI_NOTES_MODEL,
            "medium",
            false,
            &Secret::new("fixture".into()),
            Duration::from_secs(2),
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(text, "Živjeli, José 🎉");
    {
        let requests = fixture.requests.lock().unwrap();
        let body: Value = serde_json::from_slice(&requests[0].body).unwrap();
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
        assert!(body.get("service_tier").is_none());
    }
    for event in [
        json!({"type":"response.incomplete"}),
        json!({"type":"response.refusal.delta","delta":"no"}),
        json!({"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}),
    ] {
        let fixture = Fixture::new(move |_, _| Reply::sse(std::slice::from_ref(&event))).await;
        let ai = service(&fixture);
        assert!(ai
            .http
            .openai(
                "s",
                "u",
                OPENAI_NOTES_MODEL,
                "medium",
                false,
                &Secret::new("fixture".into()),
                Duration::from_secs(1),
                &CancellationToken::new()
            )
            .await
            .is_err());
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
    }
}
#[tokio::test]
async fn websocket_warmup_only_pings_and_reuses_socket_for_stateless_requests() {
    use tokio_tungstenite::tungstenite::Message;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
        let first = ws.next().await.unwrap().unwrap();
        let Message::Ping(data) = first else {
            panic!("warmup must never infer")
        };
        ws.send(Message::Pong(data)).await.unwrap();
        for user in ["first request", "second request"] {
            let request = loop {
                match ws.next().await.unwrap().unwrap() {
                    Message::Text(text) => break text,
                    _ => continue,
                }
            };
            let json: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(json["type"], "response.create");
            assert_eq!(json["input"][0]["content"], user);
            assert_eq!(json["store"], false);
            assert!(json.get("stream").is_none());
            assert!(json.get("previous_response_id").is_none());
            for event in events(user) {
                ws.send(Message::Text(event.to_string().into()))
                    .await
                    .unwrap();
            }
        }
    });
    let fixture = Fixture::new(|_, _| panic!("healthy socket must not fall back to HTTP")).await;
    let mut endpoints = fixture.endpoints();
    endpoints.websocket = format!("ws://{address}").parse().unwrap();
    let http = HttpAi::with_endpoints(endpoints).unwrap();
    let key = Secret::new("fixture-key".into());
    let cancel = CancellationToken::new();
    http.warm_up(&key, &cancel).await.unwrap();
    for user in ["first request", "second request"] {
        assert_eq!(
            http.openai(
                "system",
                user,
                OPENAI_DICTATION_MODEL,
                "medium",
                true,
                &key,
                Duration::from_secs(2),
                &cancel
            )
            .await
            .unwrap(),
            user
        );
    }
    server.await.unwrap();
}
#[tokio::test]
async fn websocket_transport_failure_falls_back_once_but_terminal_refusal_does_not() {
    use tokio_tungstenite::tungstenite::Message;
    for refusal in [false, true] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
            let _ = ws.next().await;
            let event = if refusal {
                Message::Text(
                    json!({"type":"response.refusal.delta","delta":"private provider body"})
                        .to_string()
                        .into(),
                )
            } else {
                Message::Close(None)
            };
            ws.send(event).await.unwrap();
        });
        let fixture = Fixture::new(|_, _| Reply::sse(&events("fallback succeeded"))).await;
        let mut endpoints = fixture.endpoints();
        endpoints.websocket = format!("ws://{address}").parse().unwrap();
        let http = HttpAi::with_endpoints(endpoints).unwrap();
        let result = http
            .openai(
                "s",
                "u",
                OPENAI_DICTATION_MODEL,
                "medium",
                true,
                &Secret::new("fixture".into()),
                Duration::from_secs(2),
                &CancellationToken::new(),
            )
            .await;
        if refusal {
            assert!(matches!(result, Err(AiError::Refusal)));
            assert!(fixture.requests.lock().unwrap().is_empty());
        } else {
            assert_eq!(result.unwrap(), "fallback succeeded");
            assert_eq!(fixture.requests.lock().unwrap().len(), 1);
        }
        server.await.unwrap();
    }
}
#[test]
fn notes_preserve_source_model_selection_title_and_context_rules() {
    use notes::*;
    assert_eq!(
        NotesModel::resolve(None, false, true, true),
        Some(NotesModel::ClaudeHaiku)
    );
    assert_eq!(
        NotesModel::resolve(None, true, true, true),
        Some(NotesModel::OpenAi(OPENAI_NOTES_MODEL.into()))
    );
    assert_eq!(
        NotesModel::resolve(Some("claude:sonnet55"), true, true, true),
        Some(NotesModel::ClaudeSonnet)
    );
    let parsed = NoteDraft::parse("## \"Weekly roadmap\".\n\n- [ ] Next task").unwrap();
    assert_eq!(parsed.title, "Weekly roadmap\"");
    assert_eq!(parsed.body, "- [ ] Next task");
    assert!(NoteDraft::parse(" \n ").is_err());
    let meeting = MeetingInput {
        duration_seconds: 3600.0,
        transcript: "[0:01] Me: Please ask Ana.".into(),
        user_notes: "Clarify owner".into(),
        participants: vec!["Ana".into()],
        has_separated_voices: false,
        line_count: 10,
        has_others: false,
    };
    let (system, user) = meeting_prompts(&meeting, &[]);
    assert!(system.contains(prompts::USER_NOTES));
    assert!(user.contains("No call audio was recorded"));
    assert!(user.contains("every \"Others\" line is them"));
    assert!(user.contains("<my_notes>\nClarify owner"));
    let question = AskInput {
        question: "Who owns it?".into(),
        today: "2026-11-06 (Friday)".into(),
        history: vec![Exchange {
            question: "What changed?".into(),
            answer: "The owner.".into(),
        }],
        meetings: vec![AskMeeting {
            title: "<Roadmap> \"Review\"".into(),
            date: "2026-11-05".into(),
            time: "09:00".into(),
            people: String::new(),
            notes: "Ana owns it.".into(),
            my_notes: "Check Friday".into(),
            transcript: "Too much transcript".into(),
        }],
    };
    let user = ask_user(&question, 2);
    assert!(!user.contains("<transcript>"));
    assert!(user.contains("Ana owns it."));
    assert!(user.contains("<conversation>"));
    assert!(user.contains("2026-11-06 (Friday)"));
}

#[tokio::test]
async fn response_size_and_malformed_duration_are_rejected_before_insertion_or_network() {
    let fixture = Fixture::new(|_, _| Reply::json(reply(&"x".repeat(1024 * 1024)))).await;
    let ai = service(&fixture);
    let out = ai
        .cleanup(
            source(),
            "preserved words",
            None,
            &[],
            Default::default(),
            None,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(!out.used_language_model);
    assert_eq!(out.text, "preserved words");
    let fixture = Fixture::new(|_, _| panic!("invalid duration must not make a request")).await;
    let ai = service(&fixture);
    for duration in [f64::NAN, -1.0, f64::MAX] {
        let input = notes::MeetingInput {
            duration_seconds: duration,
            transcript: "Text".into(),
            user_notes: String::new(),
            participants: vec![],
            has_separated_voices: false,
            line_count: 1,
            has_others: false,
        };
        assert!(matches!(
            ai.write_note(
                &input,
                &[],
                &notes::NotesModel::ClaudeHaiku,
                Connection::ApiKey,
                &CancellationToken::new()
            )
            .await,
            Err(AiError::BadResponse)
        ));
    }
}

#[test]
fn ask_search_terms_stem_and_long_transcripts_are_excerpted() {
    use notes::*;
    assert_eq!(
        search_terms("What did Sam say about pricing?"),
        ["sam", "pric"]
    );
    assert_eq!(
        term_hits("We changed the prices again", &search_terms("pricing")),
        1
    );
    let transcript = (0..400)
        .map(|i| {
            if i == 200 {
                "[3:20] Others: The pricing goes up in March.".to_owned()
            } else {
                format!("[{i}:00] Me: Unrelated filler line number {i}.")
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let input = AskInput {
        question: "What about pricing?".into(),
        today: "2026-11-06 (Friday)".into(),
        history: vec![],
        meetings: vec![AskMeeting {
            title: "Sales".into(),
            date: "2026-11-05".into(),
            time: "09:00".into(),
            people: "Sam".into(),
            notes: String::new(),
            my_notes: String::new(),
            transcript,
        }],
    };
    let user = ask_user(&input, 2_000);
    assert!(user.contains("<meeting n=\"1\""));
    assert!(user.contains("people=\"Sam\""));
    assert!(user.contains("excerpt=\"true\""));
    assert!(user.contains("pricing goes up in March"));
    assert!(user.contains("filler line number 199"));
    assert!(!user.contains("filler line number 50."));
}
