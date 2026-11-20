use std::io::{self, BufRead, Write};
use serde_json::{json, Value};

#[cfg(windows)]
#[path = "../agent_transport.rs"]
mod agent_transport;

#[cfg(windows)]
fn send(request: Value) -> Result<Value, String> {
    use std::io::Read;
    let path = agent_transport::pipe_name();
    let mut pipe = None;
    for _ in 0..20 {
        match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
            Ok(value) => { pipe = Some(value); break; }
            Err(error) if error.raw_os_error() == Some(231) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(error) => return Err(format!("无法连接 Orbit Agent 网关：{error}")),
        }
    }
    let mut pipe = pipe.ok_or("Agent 网关忙，请稍后重试")?;
    let mut data = serde_json::to_vec(&request).map_err(|error| error.to_string())?; data.push(b'\n');
    pipe.write_all(&data).map_err(|error| error.to_string())?;
    let mut response = Vec::new();
    io::BufReader::new(pipe.take(2 * 1024 * 1024)).read_until(b'\n', &mut response).map_err(|error| error.to_string())?;
    serde_json::from_slice(&response).map_err(|error| error.to_string())
}

#[cfg(not(windows))]
fn send(_: Value) -> Result<Value, String> { Err("此 CLI 适用于 Windows；macOS 请使用原生 orbit-cli".into()) }

#[cfg(windows)]
fn credentials(client: &str, write: Option<&Value>) -> Result<Value, String> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::{CredReadW, CredWriteW, CredFree, CREDENTIALW, CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE};
    let mut target: Vec<u16> = format!("com.orbit.windows.agent.cli/{client}").encode_utf16().chain(Some(0)).collect();
    if let Some(value) = write {
        let data = serde_json::to_vec(value).map_err(|error| error.to_string())?;
        let credential = CREDENTIALW { Type: CRED_TYPE_GENERIC, TargetName: target.as_mut_ptr(), CredentialBlobSize: data.len() as u32, CredentialBlob: data.as_ptr() as *mut u8, Persist: CRED_PERSIST_LOCAL_MACHINE, ..Default::default() };
        if unsafe { CredWriteW(&credential, 0) } == 0 { return Err(io::Error::last_os_error().to_string()); }
        return Ok(value.clone());
    }
    let mut credential = std::ptr::null_mut();
    if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) } == 0 {
        if unsafe { GetLastError() } == ERROR_NOT_FOUND { return Ok(Value::Null); }
        return Err(io::Error::last_os_error().to_string());
    }
    let value = unsafe {
        if (*credential).CredentialBlobSize == 0 { Ok(Value::Null) } else { serde_json::from_slice(std::slice::from_raw_parts((*credential).CredentialBlob, (*credential).CredentialBlobSize as usize)).map_err(|error| error.to_string()) }
    };
    unsafe { CredFree(credential.cast()); }
    value
}

#[cfg(not(windows))]
fn credentials(_: &str, _: Option<&Value>) -> Result<Value, String> { Err("此 CLI 适用于 Windows".into()) }

fn exchange(op: &str, args: Value, session: &Value, tool: Option<&str>) -> Result<Value, String> {
    send(json!({"id":uuid::Uuid::new_v4().to_string(),"op":op,"args":args,"sessionId":session["sessionId"],"token":session["token"],"tool":tool}))
}

fn auth(client: &str) -> Result<Value, String> {
    let mut stored = credentials(client, None)?;
    if stored["sessionId"].is_string() { return Ok(stored); }
    if let Some(id) = stored["requestId"].as_str() {
        let response = exchange("admission_status", json!({"requestId":id}), &Value::Null, None)?;
        if response["result"]["status"] == "approved" {
            stored = response["result"]["session"].clone(); credentials(client, Some(&stored))?; return Ok(stored);
        }
        if response["result"]["status"] == "pending" { return Ok(json!({"status":"pending_approval","requestId":id,"message":"请在 Orbit 中批准客户端连接后重试"})); }
        if response["result"]["status"] == "denied" { credentials(client, Some(&Value::Null))?; return Err("用户拒绝了客户端连接".into()); }
    }
    let response = exchange("hello", json!({"clientName":client,"clientVersion":env!("CARGO_PKG_VERSION"),"bridgeVersion":"1","parentPid":std::process::id(),"parentPath":std::env::current_exe().ok()}), &Value::Null, None)?;
    if response["ok"] != true { return Err(response["error"].to_string()); }
    let result = response["result"].clone(); credentials(client, Some(&result))?; Ok(result)
}

fn call(client: &str, tool: &str, args: Value) -> Result<Value, String> {
    let session = auth(client)?;
    if !session["sessionId"].is_string() { return Ok(session); }
    let response = exchange("call", args, &session, Some(tool))?;
    if response["error"]["code"] == "unauthorized" || response["error"]["code"] == "session_expired" { credentials(client, Some(&Value::Null))?; }
    Ok(response)
}

fn catalog() -> Value {
    let definitions = [
        ("orbit_list_servers", "List explicitly exposed servers", json!({}), vec![]),
        ("orbit_exec", "Execute an SSH command; writes require approval in Orbit", json!({"server":{"type":"string"},"command":{"type":"string"},"mode":{"type":"string","enum":["read","write"]},"timeoutMs":{"type":"integer","minimum":1,"maximum":300000},"waitMs":{"type":"integer","minimum":0,"maximum":30000},"maxOutputBytes":{"type":"integer","minimum":1024,"maximum":1048576},"idempotencyKey":{"type":"string"}}), vec!["server","command"]),
        ("orbit_shell_open", "Open a persistent SSH shell with explicit write approval", json!({"server":{"type":"string"}}), vec!["server"]),
        ("orbit_shell_exec", "Run a command in this session's persistent shell", json!({"shellId":{"type":"string"},"command":{"type":"string"},"timeoutMs":{"type":"integer","minimum":1,"maximum":50000}}), vec!["shellId","command"]),
        ("orbit_shell_close", "Close this session's persistent shell", json!({"shellId":{"type":"string"}}), vec!["shellId"]),
        ("orbit_job_status", "Read the status of a job owned by this session", json!({"jobId":{"type":"string"}}), vec!["jobId"]),
        ("orbit_job_output", "Read incremental output of this session's job", json!({"jobId":{"type":"string"},"cursor":{"type":"integer","minimum":0}}), vec!["jobId"]),
        ("orbit_job_cancel", "Cancel this session's job", json!({"jobId":{"type":"string"}}), vec!["jobId"]),
        ("orbit_approval_status", "Check write approval status", json!({"requestId":{"type":"string"}}), vec!["requestId"]),
    ];
    json!({"tools":definitions.into_iter().map(|(name, description, properties, required)| json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false}})).collect::<Vec<_>>()})
}

fn mcp(client: &str) -> Result<(), String> {
    let mut input = io::stdin().lock(); let mut output = io::stdout().lock();
    loop {
        let mut line = String::new();
        if input.read_line(&mut line).map_err(|error| error.to_string())? == 0 { break; }
        if line.len() > 256 * 1024 { return Err("MCP 请求过长".into()); }
        let request: Value = match serde_json::from_str(&line) { Ok(value) => value, Err(_) => { writeln!(output,"{}",json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}})).map_err(|error|error.to_string())?; output.flush().map_err(|error|error.to_string())?; continue; } };
        if request.get("id").is_none() { continue; }
        let result = match request["method"].as_str().unwrap_or_default() {
            "initialize" => Ok(json!({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"orbit-windows","version":env!("CARGO_PKG_VERSION")}})),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(catalog()),
            "tools/call" => {
                let tool = request["params"]["name"].as_str().unwrap_or_default();
                match call(client, tool, request["params"]["arguments"].clone()) {
                    Ok(value) => Ok(json!({"content":[{"type":"text","text":value.to_string()}],"isError":value["ok"] == false})),
                    Err(error) => Ok(json!({"content":[{"type":"text","text":error}],"isError":true})),
                }
            }
            _ => Err(json!({"code":-32601,"message":"Method not found"})),
        };
        let response = match result { Ok(result) => json!({"jsonrpc":"2.0","id":request["id"],"result":result}), Err(error) => json!({"jsonrpc":"2.0","id":request["id"],"error":error}) };
        writeln!(output, "{response}").map_err(|error| error.to_string())?; output.flush().map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn main() {
    let result = run();
    if let Err(error) = result { println!("{}",json!({"ok":false,"error":{"code":"client_error","message":error}})); std::process::exit(1); }
}

fn run() -> Result<(), String> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut client = "Codex".to_string();
    if let Some(index) = args.iter().position(|arg| arg == "--client") { if index + 1 >= args.len() { return Err("--client 缺少值".into()); } client = args.remove(index + 1); args.remove(index); }
    if client.trim().is_empty() || client.len() > 128 { return Err("客户端名称无效".into()); }
    let command = args.first().map(String::as_str).unwrap_or("help");
    if command == "mcp" { return mcp(&client); }
    let option = |name: &str| args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1)).cloned();
    let number = |name: &str, default: u64| -> Result<u64, String> { option(name).map(|value| value.parse().map_err(|_| format!("{name} 必须为非负整数"))).unwrap_or(Ok(default)) };
    let value = match command {
        "auth" => { let result = auth(&client)?; if result["sessionId"].is_string() { json!({"ok":true,"status":"authenticated","sessionId":result["sessionId"]}) } else { result } },
        "servers" => call(&client, "orbit_list_servers", json!({}))?,
        "exec" => {
            let server = option("--server").ok_or("缺少 --server")?;
            let index = args.iter().position(|arg| arg == "--").ok_or("命令必须放在 -- 后")?;
            let text = args[index + 1..].join(" ");
            call(&client, "orbit_exec", json!({"server":server,"command":text,"mode":option("--mode").unwrap_or("read".into()),"timeoutMs":number("--timeout-ms",30000)?,"waitMs":number("--wait-ms",1000)?,"maxOutputBytes":number("--max-output-bytes",262144)?,"idempotencyKey":option("--idempotency-key").unwrap_or_else(|| uuid::Uuid::new_v4().to_string())}))?
        }
        "job" => { let operation = args.get(1).map(String::as_str).ok_or("缺少 job 操作")?; let id = args.get(2).ok_or("缺少 job ID")?; let tool = match operation { "status"=>"orbit_job_status", "output"=>"orbit_job_output", "cancel"=>"orbit_job_cancel", _=>return Err("未知 job 操作".into()) }; call(&client, tool, json!({"jobId":id,"cursor":number("--cursor",0)?}))? },
        "revoke" => { let session = credentials(&client, None)?; let response = exchange("revoke", json!({}), &session, None)?; credentials(&client, Some(&Value::Null))?; response },
        "call" => { let tool = args.get(1).ok_or("缺少工具名")?; let input: Value = serde_json::from_str(args.get(2).map(String::as_str).unwrap_or("{}")).map_err(|error|error.to_string())?; call(&client, tool, input)? },
        _ => { println!("orbit-cli auth|servers|exec|job|revoke|call|mcp [--client NAME]\nexec --server ID --mode read|write --timeout-ms 30000 --wait-ms 1000 -- COMMAND\njob status|output|cancel JOB_ID [--cursor N]"); return Ok(()); }
    };
    println!("{value}"); Ok(())
}
