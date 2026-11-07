//! Local-only provider fixtures. No live credentials or billable requests.
use crate::accounts::{Secret, SecretStore};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

#[derive(Default)]
pub struct MemorySecrets(pub Mutex<HashMap<String, Secret>>);
impl SecretStore for MemorySecrets {
    fn get(&self, key: &str) -> Result<Option<Secret>, String> {
        Ok(self.0.lock().unwrap().get(key).cloned())
    }
    fn set(&self, key: &str, value: &Secret) -> Result<(), String> {
        self.0.lock().unwrap().insert(key.into(), value.clone());
        Ok(())
    }
    fn delete(&self, key: &str) -> Result<(), String> {
        self.0.lock().unwrap().remove(key);
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct Request {
    pub path: String,
    pub headers: String,
    pub body: Vec<u8>,
}
pub struct Reply {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub delay: Duration,
    pub fragment: usize,
}
impl Reply {
    pub fn json(value: serde_json::Value) -> Self {
        Self {
            status: 200,
            content_type: "application/json",
            body: value.to_string().into_bytes(),
            delay: Duration::ZERO,
            fragment: usize::MAX,
        }
    }
    pub fn sse(events: &[serde_json::Value]) -> Self {
        Self {
            status: 200,
            content_type: "text/event-stream",
            body: events
                .iter()
                .map(|e| format!("data: {e}\n\n"))
                .collect::<String>()
                .into_bytes(),
            delay: Duration::ZERO,
            fragment: usize::MAX,
        }
    }
}
pub struct Fixture {
    pub url: String,
    pub requests: Arc<Mutex<Vec<Request>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fixture {
    pub async fn new(handler: impl Fn(&Request, &str) -> Reply + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let base = url.clone();
        let requests = Arc::new(Mutex::new(vec![]));
        let captured = requests.clone();
        let handler = Arc::new(handler);
        let task = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                let handler = handler.clone();
                let requests = captured.clone();
                let base = base.clone();
                tokio::spawn(async move {
                    let mut bytes = vec![];
                    let mut chunk = [0u8; 4096];
                    let header_end = loop {
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                        if let Some(i) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                            break i + 4;
                        }
                        if bytes.len() > 32_768 {
                            return;
                        }
                    };
                    let headers = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
                    let path = headers
                        .lines()
                        .next()
                        .unwrap()
                        .split_whitespace()
                        .nth(1)
                        .unwrap()
                        .to_owned();
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_lowercase()
                                .strip_prefix("content-length:")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if length > 2 * 1024 * 1024 {
                        return;
                    }
                    while bytes.len() < header_end + length {
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                    }
                    let request = Request {
                        path,
                        headers,
                        body: bytes[header_end..header_end + length].to_vec(),
                    };
                    requests.lock().unwrap().push(request.clone());
                    let reply = handler(&request, &base);
                    tokio::time::sleep(reply.delay).await;
                    let headers=format!("HTTP/1.1 {} OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",reply.status,reply.content_type,reply.body.len());
                    if socket.write_all(headers.as_bytes()).await.is_err() {
                        return;
                    }
                    for part in reply.body.chunks(reply.fragment.max(1)) {
                        if socket.write_all(part).await.is_err() {
                            return;
                        }
                        tokio::task::yield_now().await;
                    }
                });
            }
        });
        Self {
            url,
            requests,
            task,
        }
    }
    pub fn endpoints(&self) -> super::Endpoints {
        super::Endpoints {
            anthropic: format!("{}/messages", self.url).parse().unwrap(),
            openai: format!("{}/responses", self.url).parse().unwrap(),
            websocket: format!("{}/socket", self.url.replacen("http:", "ws:", 1))
                .parse()
                .unwrap(),
        }
    }
    pub async fn wait_requests(&self, count: usize) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while self.requests.lock().unwrap().len() < count {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }
}
