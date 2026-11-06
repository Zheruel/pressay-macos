//! Private-bus contract test. Exercises production portal serialization, early
//! responses, activation/release, Unicode key pairs and session revocation.
use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
};
use zbus::{interface, message::Header, object_server::SignalEmitter};
struct Bus(Child);
impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Session;
#[interface(name = "org.freedesktop.portal.Session")]
impl Session {
    async fn close(&self) {}
}
struct Request;
#[interface(name = "org.freedesktop.portal.Request")]
impl Request {
    async fn close(&self) {}
}
#[derive(Clone, Default)]
struct Portal {
    keys: Arc<Mutex<Vec<(i32, u32)>>>,
    sessions: Arc<Mutex<Vec<OwnedObjectPath>>>,
}
async fn respond(
    connection: &Connection,
    header: &Header<'_>,
    options: &Results,
    values: HashMap<&str, Value<'_>>,
) -> zbus::fdo::Result<OwnedObjectPath> {
    let sender = header
        .sender()
        .unwrap()
        .as_str()
        .trim_start_matches(':')
        .replace('.', "_");
    let handle = <&str>::try_from(options.get("handle_token").unwrap()).unwrap();
    let path = OwnedObjectPath::try_from(format!(
        "/org/freedesktop/portal/desktop/request/{sender}/{handle}"
    ))
    .unwrap();
    connection.object_server().at(path.clone(), Request).await?;
    // Deliberately respond before returning the method handle. This used to
    // race clients that subscribe only after the method reply.
    connection
        .emit_signal(
            None::<&str>,
            path.clone(),
            "org.freedesktop.portal.Request",
            "Response",
            &(0u32, values),
        )
        .await?;
    Ok(path)
}
async fn session(
    portal: &Portal,
    options: Results,
    connection: &Connection,
    header: &Header<'_>,
) -> zbus::fdo::Result<OwnedObjectPath> {
    let token = <&str>::try_from(options.get("session_handle_token").unwrap()).unwrap();
    let path = OwnedObjectPath::try_from(format!(
        "/org/freedesktop/portal/desktop/session/test/{token}"
    ))
    .unwrap();
    connection.object_server().at(path.clone(), Session).await?;
    portal.sessions.lock().unwrap().push(path.clone());
    respond(
        connection,
        header,
        &options,
        HashMap::from([("session_handle", Value::from(path.as_str()))]),
    )
    .await
}
#[interface(name = "org.freedesktop.portal.GlobalShortcuts")]
impl Portal {
    async fn create_session(
        &self,
        options: Results,
        #[zbus(connection)] connection: &Connection,
        #[zbus(header)] header: Header<'_>,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        session(self, options, connection, &header).await
    }
    async fn bind_shortcuts(
        &self,
        session: OwnedObjectPath,
        shortcuts: Vec<(String, Results)>,
        parent: String,
        options: Results,
        #[zbus(connection)] connection: &Connection,
        #[zbus(header)] header: Header<'_>,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        assert!(parent.is_empty());
        assert_eq!(shortcuts.len(), 2);
        assert_eq!(
            <&str>::try_from(shortcuts[0].1.get("preferred_trigger").unwrap()).unwrap(),
            "CTRL+SHIFT+space"
        );
        let grants = vec![
            (
                "dictation",
                HashMap::from([("trigger_description", Value::from("Ctrl + Shift + Space"))]),
            ),
            (
                "cancel",
                HashMap::from([("trigger_description", Value::from("Ctrl + Shift + Esc"))]),
            ),
        ];
        let handle = respond(
            connection,
            &header,
            &options,
            HashMap::from([("shortcuts", Value::new(grants))]),
        )
        .await?;
        connection
            .emit_signal(
                None::<&str>,
                DESKTOP,
                SHORTCUTS,
                "Activated",
                &(&session, "dictation", 1u64, Results::new()),
            )
            .await?;
        connection
            .emit_signal(
                None::<&str>,
                DESKTOP,
                SHORTCUTS,
                "Deactivated",
                &(&session, "dictation", 2u64, Results::new()),
            )
            .await?;
        Ok(handle)
    }
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        2
    }
}
struct Remote(Portal);
#[interface(name = "org.freedesktop.portal.RemoteDesktop")]
impl Remote {
    async fn create_session(
        &self,
        options: Results,
        #[zbus(connection)] connection: &Connection,
        #[zbus(header)] header: Header<'_>,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        session(&self.0, options, connection, &header).await
    }
    async fn select_devices(
        &self,
        _session: OwnedObjectPath,
        options: Results,
        #[zbus(connection)] connection: &Connection,
        #[zbus(header)] header: Header<'_>,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        assert_eq!(u32::try_from(options.get("types").unwrap()).unwrap(), 1);
        assert_eq!(
            u32::try_from(options.get("persist_mode").unwrap()).unwrap(),
            2
        );
        respond(connection, &header, &options, HashMap::new()).await
    }
    async fn start(
        &self,
        _session: OwnedObjectPath,
        parent: String,
        options: Results,
        #[zbus(connection)] connection: &Connection,
        #[zbus(header)] header: Header<'_>,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        assert!(parent.is_empty());
        respond(
            connection,
            &header,
            &options,
            HashMap::from([("devices", Value::from(1u32))]),
        )
        .await
    }
    async fn notify_keyboard_keysym(
        &self,
        _session: OwnedObjectPath,
        _options: Results,
        keysym: i32,
        state: u32,
    ) {
        self.0.keys.lock().unwrap().push((keysym, state));
    }
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        2
    }
}
#[tokio::test]
async fn portal_contract_early_responses_shortcuts_unicode_and_revocation() {
    let mut daemon = Command::new("dbus-daemon")
        .args(["--session", "--nofork", "--print-address=1"])
        .stdout(Stdio::piped())
        .spawn()
        .expect("Install dbus-daemon to run portal contract tests");
    let mut address = String::new();
    BufReader::new(daemon.stdout.take().unwrap())
        .read_line(&mut address)
        .unwrap();
    let _bus = Bus(daemon);
    let portal = Portal::default();
    let server = zbus::connection::Builder::address(address.trim())
        .unwrap()
        .name(DESTINATION)
        .unwrap()
        .serve_at(DESKTOP, portal.clone())
        .unwrap()
        .serve_at(DESKTOP, Remote(portal.clone()))
        .unwrap()
        .build()
        .await
        .unwrap();
    let client = zbus::connection::Builder::address(address.trim())
        .unwrap()
        .build()
        .await
        .unwrap();
    let (send, mut events) = tokio::sync::mpsc::unbounded_channel();
    let callback: Callback = Arc::new(move |event| {
        let _ = send.send(event);
    });
    let cancel = CancellationToken::new();
    let task_cancel = cancel.clone();
    let shortcut_client = client.clone();
    let task = tokio::spawn(async move {
        run_shortcuts_on(
            shortcut_client,
            "Control+Shift+Space",
            &callback,
            &task_cancel,
        )
        .await
    });
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap(),
        Some(Event::Availability {
            available: true,
            ..
        })
    ));
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap(),
        Some(Event::Pressed)
    ));
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap(),
        Some(Event::Released)
    ));
    cancel.cancel();
    task.await.unwrap().unwrap();
    set_current_cursor(true);
    let keyboard = Arc::new(
        prepare_keyboard_on(client, CancellationToken::new())
            .await
            .unwrap(),
    );
    *output().keyboard.lock().unwrap() = Some(keyboard.clone());
    *output().permission.lock().unwrap() = (Permission::Granted, None);
    let token = target();
    tokio::task::spawn_blocking(move || insert("Aé日本🙂", token))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        *portal.keys.lock().unwrap(),
        vec![
            (65, 1),
            (65, 0),
            (233, 1),
            (233, 0),
            (0x010065e5, 1),
            (0x010065e5, 0),
            (0x0100672c, 1),
            (0x0100672c, 0),
            (0x0101f642, 1),
            (0x0101f642, 0)
        ]
    );
    assert!(insert("first\nsecond", token).is_err());
    assert_eq!(portal.keys.lock().unwrap().len(), 10);
    // Verify revocation changes the permission and prevents subsequent events.
    let watcher = tokio::spawn(watch_keyboard(keyboard.clone()));
    let emitter = SignalEmitter::new(&server, keyboard.session.clone()).unwrap();
    emitter
        .emit("org.freedesktop.portal.Session", "Closed", &Results::new())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), watcher)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status().0, Permission::Denied);
    assert!(insert("late", token).is_err());
    assert_eq!(portal.keys.lock().unwrap().len(), 10);
    set_current_cursor(false);
}
