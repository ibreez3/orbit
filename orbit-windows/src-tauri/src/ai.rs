use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{ipc::Channel, State};
use tokio::sync::oneshot;
use crate::{error, AppState};

#[derive(Default)]
pub struct Requests(pub Mutex<HashMap<String, oneshot::Sender<()>>>);

#[derive(Default, Serialize, Deserialize)]
pub struct Config {
    pub endpoint: String,
    pub model: String,
    #[serde(default)]
    pub api_key: String,
}

#[derive(Serialize, Deserialize)]
pub struct Message { role: String, content: String }

fn load(state: &AppState) -> Result<Config, String> {
    state.core.private_setting("ai.config").map_err(error)?.map(|value| serde_json::from_str(&value).map_err(error)).unwrap_or_else(|| Ok(Config::default()))
}

#[tauri::command]
pub fn ai_config(state: State<'_, AppState>) -> Result<Value, String> {
    let config = load(&state)?;
    Ok(json!({"endpoint":config.endpoint, "model":config.model, "has_key":!config.api_key.is_empty()}))
}

#[tauri::command]
pub fn ai_save_config(state: State<'_, AppState>, mut config: Config) -> Result<(), String> {
    endpoint(&config.endpoint)?;
    if config.model.trim().is_empty() { return Err("请填写模型名称".into()); }
    if config.api_key.is_empty() { config.api_key = load(&state)?.api_key; }
    state.core.save_private_setting("ai.config", &serde_json::to_string(&config).map_err(error)?).map_err(error)
}

fn endpoint(base: &str) -> Result<String, String> {
    let base = base.trim().trim_end_matches('/');
    let url = reqwest::Url::parse(base).map_err(|_| "API 地址无效")?;
    if !matches!(url.scheme(), "https" | "http") || url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() || url.query().is_some() || url.fragment().is_some() { return Err("请填写 HTTP(S) API 基础地址".into()); }
    Ok(if base.ends_with("/chat/completions") { base.into() } else if base.ends_with("/v1") { format!("{base}/chat/completions") } else { format!("{base}/v1/chat/completions") })
}

#[tauri::command]
pub fn ai_cancel(requests: State<'_, Requests>, id: String) -> Result<(), String> {
    if let Some(cancel) = requests.0.lock().map_err(error)?.remove(&id) { let _ = cancel.send(()); }
    Ok(())
}

#[tauri::command]
pub async fn ai_chat(state: State<'_, AppState>, requests: State<'_, Requests>, id: String, messages: Vec<Message>, output: Channel<String>) -> Result<String, String> {
    let config = load(&state)?;
    if config.model.trim().is_empty() { return Err("请先配置 AI 模型".into()); }
    if messages.len() > 32 || messages.iter().any(|message| !matches!(message.role.as_str(), "system" | "user" | "assistant") || message.content.len() > 256 * 1024) { return Err("对话上下文无效或过长".into()); }
    let (cancel, cancelled) = oneshot::channel();
    {
        let mut active = requests.0.lock().map_err(error)?;
        if active.contains_key(&id) { return Err("请求已存在".into()); }
        active.insert(id.clone(), cancel);
    }
    let result = tokio::select! {
        _ = cancelled => Err("已取消生成".into()),
        result = stream(config, messages, output) => result,
    };
    requests.0.lock().map_err(error)?.remove(&id);
    result
}

async fn stream(config: Config, messages: Vec<Message>, output: Channel<String>) -> Result<String, String> {
    let client = reqwest::Client::builder().connect_timeout(Duration::from_secs(15)).timeout(Duration::from_secs(120)).redirect(reqwest::redirect::Policy::none()).build().map_err(error)?;
    let mut request = client.post(endpoint(&config.endpoint)?).json(&json!({"model":config.model, "messages":messages, "temperature":0.3, "max_tokens":2000, "stream":true}));
    if !config.api_key.is_empty() { request = request.bearer_auth(config.api_key); }
    let mut response = request.send().await.map_err(error)?;
    if !response.status().is_success() { return Err(format!("AI 服务返回 HTTP {}", response.status())); }
    let is_stream = response.headers().get("content-type").and_then(|value| value.to_str().ok()).map(|value| value.contains("text/event-stream")).unwrap_or(false);
    let mut bytes = Vec::new(); let mut text = String::new(); let mut received = 0usize;
    while let Some(chunk) = response.chunk().await.map_err(error)? {
        received += chunk.len();
        if received > 4 * 1024 * 1024 { return Err("AI 响应超过 4 MB 限制".into()); }
        bytes.extend_from_slice(&chunk);
        if is_stream {
            while let Some(end) = bytes.iter().position(|byte| *byte == b'\n') {
                let line: Vec<_> = bytes.drain(..=end).collect();
                if let Some(delta) = parse_line(&line)? { output.send(delta.clone()).map_err(error)?; text.push_str(&delta); }
            }
        }
    }
    if is_stream {
        if !bytes.is_empty() { if let Some(delta) = parse_line(&bytes)? { output.send(delta.clone()).map_err(error)?; text.push_str(&delta); } }
    } else {
        let value: Value = serde_json::from_slice(&bytes).map_err(error)?;
        text = value["choices"][0]["message"]["content"].as_str().ok_or("AI 响应缺少内容")?.to_string();
        output.send(text.clone()).map_err(error)?;
    }
    Ok(text)
}

fn parse_line(line: &[u8]) -> Result<Option<String>, String> {
    let line = std::str::from_utf8(line).map_err(error)?.trim();
    let Some(data) = line.strip_prefix("data:") else { return Ok(None); };
    if data.trim() == "[DONE]" { return Ok(None); }
    let value: Value = serde_json::from_str(data.trim()).map_err(error)?;
    if value.get("error").is_some() { return Err("AI 服务返回流式错误".into()); }
    Ok(value["choices"][0]["delta"]["content"].as_str().map(str::to_string))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn streams_unicode_from_an_http_endpoint() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                let mut byte = [0]; socket.read_exact(&mut byte).unwrap(); header.push(byte[0]);
                assert!(header.len() < 16_384);
            }
            let header = String::from_utf8(header).unwrap();
            assert!(header.starts_with("POST /v1/chat/completions "));
            let length: usize = header.lines().find_map(|line| line.to_lowercase().strip_prefix("content-length:").map(|value| value.trim().parse().unwrap())).unwrap();
            let mut body = vec![0; length]; socket.read_exact(&mut body).unwrap();
            let request: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(request["model"], "fixture-model"); assert_eq!(request["stream"], true);
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"中文\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"输出\"}}]}\n\ndata: [DONE]\n\n";
            write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
            for chunk in body.as_bytes().chunks(3) { socket.write_all(chunk).unwrap(); }
        });
        let received = std::sync::Arc::new(Mutex::new(Vec::new()));
        let captured = received.clone();
        let output = Channel::new(move |body| {
            if let tauri::ipc::InvokeResponseBody::Json(text) = body { captured.lock().unwrap().push(serde_json::from_str::<String>(&text).unwrap()); }
            Ok(())
        });
        let result = stream(Config { endpoint: format!("http://{address}/v1"), model: "fixture-model".into(), api_key: String::new() }, vec![Message { role: "user".into(), content: "测试".into() }], output).await.unwrap();
        server.join().unwrap();
        assert_eq!(result, "中文输出"); assert_eq!(received.lock().unwrap().concat(), result);
    }

    #[test]
    fn parses_stream_events_and_rejects_errors() {
        assert_eq!(parse_line("data: {\"choices\":[{\"delta\":{\"content\":\"中文\"}}]}\r\n".as_bytes()).unwrap(), Some("中文".into()));
        assert_eq!(parse_line(b"data: [DONE]\n").unwrap(), None);
        assert_eq!(parse_line(b": heartbeat\n").unwrap(), None);
        assert!(parse_line(b"data: {\"error\":{}}\n").is_err());
        assert_eq!(endpoint("https://example.test/v1/").unwrap(), "https://example.test/v1/chat/completions");
        assert!(endpoint("file:///tmp/private").is_err());
    }
}
