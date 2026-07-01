use anyhow::{anyhow, Result};
use serde_json::Value;

use crate::db::Database;
use crate::models::{DockerContainer, DockerContainerStats, Server};
use crate::ssh;
use crate::transport;

pub struct DockerManager;

impl DockerManager {
    pub fn list_containers(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
    ) -> Result<Vec<DockerContainer>> {
        let output = run_docker(pool, server, db, "ps -a --no-trunc --format '{{json .}}'")?;

        parse_json_lines(&output, |value| DockerContainer {
            id: string_field(value, "ID"),
            name: string_field(value, "Names"),
            image: string_field(value, "Image"),
            command: string_field(value, "Command"),
            status: string_field(value, "Status"),
            state: string_field(value, "State"),
            ports: string_field(value, "Ports"),
            created: string_field(value, "CreatedAt"),
            running_for: string_field(value, "RunningFor"),
            size: string_field(value, "Size"),
        })
    }

    pub fn stats(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
    ) -> Result<Vec<DockerContainerStats>> {
        let output = run_docker(pool, server, db, "stats --no-stream --format '{{json .}}'")?;

        parse_json_lines(&output, |value| DockerContainerStats {
            id: string_field(value, "ID"),
            name: string_field(value, "Name"),
            cpu_percent: string_field(value, "CPUPerc"),
            memory_usage: string_field(value, "MemUsage"),
            memory_percent: string_field(value, "MemPerc"),
            network_io: string_field(value, "NetIO"),
            block_io: string_field(value, "BlockIO"),
            pids: string_field(value, "PIDs"),
        })
    }

    pub fn logs(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        container_id: &str,
        tail: u32,
    ) -> Result<String> {
        let id = shell_quote(container_id);
        let cmd = format!("logs --tail {} --timestamps {}", tail.min(5000), id);
        run_docker(pool, server, db, &cmd)
    }

    pub fn action(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        container_id: &str,
        action: &str,
    ) -> Result<String> {
        let verb = match action {
            "start" | "stop" | "restart" | "pause" | "unpause" | "kill" => action,
            "remove" => "rm",
            _ => return Err(anyhow!("不支持的 Docker 操作: {}", action)),
        };
        let id = shell_quote(container_id);
        run_docker(pool, server, db, &format!("{} {}", verb, id))
    }
}

fn run_docker(
    pool: &transport::SessionPool,
    server: &Server,
    db: &Database,
    docker_args: &str,
) -> Result<String> {
    let command = format!(
        "if command -v docker >/dev/null 2>&1; then docker {}; else echo '__ORBIT_DOCKER_ERROR__:docker_not_found'; exit 127; fi 2>&1",
        docker_args
    );
    let output = ssh::SshManager::exec_command(pool, server, db, &command)?;
    if output.contains("__ORBIT_DOCKER_ERROR__:docker_not_found") {
        return Err(anyhow!("远端未安装 Docker 或 docker 不在 PATH 中"));
    }
    Ok(output)
}

fn parse_json_lines<T, F>(output: &str, map: F) -> Result<Vec<T>>
where
    F: Fn(&Value) -> T,
{
    let mut items = Vec::new();
    let mut parse_errors = Vec::new();

    for line in output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        match serde_json::from_str::<Value>(line) {
            Ok(value) => items.push(map(&value)),
            Err(_) => parse_errors.push(line.to_string()),
        }
    }

    if items.is_empty() && !parse_errors.is_empty() {
        return Err(anyhow!(parse_errors.join("\n")));
    }

    Ok(items)
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}
