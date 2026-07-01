use anyhow::Result;
use crate::models::{ServerStats, ProcessInfo};

pub fn collect_stats(output: &str) -> Result<ServerStats> {
    let lines: Vec<&str> = output.lines().collect();
    let mut cpu_usage = 0.0;
    let mut mem_total_mb = 0u64;
    let mut mem_used_mb = 0u64;
    let mut mem_percent = 0.0;
    let mut disk_total = String::new();
    let mut disk_used = String::new();
    let mut disk_percent = 0.0;
    let mut net_rx_kbps = 0.0;
    let mut net_tx_kbps = 0.0;
    let mut net_interface = String::new();
    let mut uptime = String::new();
    let mut load_avg = String::new();

    for line in &lines {
        if line.starts_with("CPU:") {
            let parts: Vec<&str> = line.splitn(2, ':').collect();
            if parts.len() == 2 {
                cpu_usage = parts[1].trim().parse().unwrap_or(0.0);
            }
        } else if line.starts_with("MEM_TOTAL:") {
            mem_total_mb = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0);
        } else if line.starts_with("MEM_USED:") {
            mem_used_mb = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0);
        } else if line.starts_with("MEM_PERCENT:") {
            mem_percent = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0.0);
        } else if line.starts_with("DISK_TOTAL:") {
            disk_total = line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
        } else if line.starts_with("DISK_USED:") {
            disk_used = line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
        } else if line.starts_with("DISK_PERCENT:") {
            disk_percent = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0.0);
        } else if line.starts_with("NET_RX_KBPS:") {
            net_rx_kbps = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0.0);
        } else if line.starts_with("NET_TX_KBPS:") {
            net_tx_kbps = line.splitn(2, ':').nth(1).unwrap_or("0").trim().parse().unwrap_or(0.0);
        } else if line.starts_with("NET_IFACE:") {
            net_interface = line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
        } else if line.starts_with("UPTIME:") {
            uptime = line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
        } else if line.starts_with("LOAD:") {
            load_avg = line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
        }
    }

    Ok(ServerStats {
        cpu_usage,
        mem_total_mb,
        mem_used_mb,
        mem_percent,
        disk_total,
        disk_used,
        disk_percent,
        net_rx_kbps,
        net_tx_kbps,
        net_interface,
        uptime,
        load_avg,
    })
}

pub fn get_monitor_script() -> &'static str {
    r#"
#!/bin/bash
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
CPU_USAGE=$(echo "100 - $CPU_IDLE" | bc)
echo "CPU:$CPU_USAGE"

MEM_INFO=$(free -m | grep "Mem:")
MEM_TOTAL=$(echo $MEM_INFO | awk '{print $2}')
MEM_USED=$(echo $MEM_INFO | awk '{print $3}')
MEM_PERCENT=$(echo "scale=1; $MEM_USED * 100 / $MEM_TOTAL" | bc)
echo "MEM_TOTAL:$MEM_TOTAL"
echo "MEM_USED:$MEM_USED"
echo "MEM_PERCENT:$MEM_PERCENT"

DISK_INFO=$(df -h / | tail -1)
DISK_TOTAL=$(echo $DISK_INFO | awk '{print $2}')
DISK_USED=$(echo $DISK_INFO | awk '{print $3}')
DISK_PERCENT=$(echo $DISK_INFO | awk '{print $5}' | tr -d '%')
echo "DISK_TOTAL:$DISK_TOTAL"
echo "DISK_USED:$DISK_USED"
echo "DISK_PERCENT:$DISK_PERCENT"

NET_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -z "$NET_IFACE" ]; then
    NET_IFACE=$(awk '$1 != "Inter-|" && $1 != "face" {
        iface=$1; gsub(":", "", iface);
        if (iface != "lo") { print iface; exit }
    }' /proc/net/dev 2>/dev/null)
fi

read_net_bytes() {
    local iface="$1"
    if [ -n "$iface" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
        local tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
        echo "$rx $tx"
        return
    fi
    awk -v iface="$iface" -F'[: ]+' '$2 == iface { print $3, $11; exit }' /proc/net/dev 2>/dev/null
}

NET_SAMPLE_1=$(read_net_bytes "$NET_IFACE")
sleep 1
NET_SAMPLE_2=$(read_net_bytes "$NET_IFACE")
NET_RX_1=$(echo "$NET_SAMPLE_1" | awk '{print $1 + 0}')
NET_TX_1=$(echo "$NET_SAMPLE_1" | awk '{print $2 + 0}')
NET_RX_2=$(echo "$NET_SAMPLE_2" | awk '{print $1 + 0}')
NET_TX_2=$(echo "$NET_SAMPLE_2" | awk '{print $2 + 0}')
NET_RX_KBPS=$(awk -v a="$NET_RX_1" -v b="$NET_RX_2" 'BEGIN { if (b >= a) printf "%.1f", (b - a) / 1024; else printf "0.0" }')
NET_TX_KBPS=$(awk -v a="$NET_TX_1" -v b="$NET_TX_2" 'BEGIN { if (b >= a) printf "%.1f", (b - a) / 1024; else printf "0.0" }')
echo "NET_IFACE:$NET_IFACE"
echo "NET_RX_KBPS:$NET_RX_KBPS"
echo "NET_TX_KBPS:$NET_TX_KBPS"

UPTIME_STR=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
echo "UPTIME:$UPTIME_STR"

LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A")
echo "LOAD:$LOAD"
"#
}

pub fn get_process_script() -> &'static str {
    r#"
ps aux --sort=-%cpu 2>/dev/null | head -51 | tail -50 | awk -F' ' '{
    printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"vsz\":%s,\"rss\":%s,\"stat\":\"%s\",\"command\":\"",
        $2, $1, $3, $4, $5, $6, $8;
    for(i=11;i<=NF;i++) {
        if(i>11) printf " ";
        gsub(/"/, "\\\"", $i);
        printf "%s", $i;
    }
    printf "\"}\n"
}'
"#
}

pub fn parse_processes(output: &str) -> Vec<ProcessInfo> {
    let mut processes = Vec::new();
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() || !line.starts_with('{') {
            continue;
        }
        if let Ok(p) = serde_json::from_str::<serde_json::Value>(line) {
            processes.push(ProcessInfo {
                pid: p.get("pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                user: p.get("user").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                cpu: p.get("cpu").and_then(|v| v.as_str()).unwrap_or("0").parse().unwrap_or(0.0),
                mem: p.get("mem").and_then(|v| v.as_str()).unwrap_or("0").parse().unwrap_or(0.0),
                vsz: p.get("vsz").and_then(|v| v.as_u64()).unwrap_or(0),
                rss: p.get("rss").and_then(|v| v.as_u64()).unwrap_or(0),
                stat: p.get("stat").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                command: p.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            });
        }
    }
    processes
}
