import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import type { Tab } from "../../types";
import { useAppStore } from "../../stores/useAppStore";

const THEME = {
  background: "#1e1e2e",
  foreground: "#cdd6f4",
  cursor: "#f5e0dc",
  selectionBackground: "#585b70",
  black: "#45475a",
  red: "#f38ba8",
  green: "#a6e3a1",
  yellow: "#f9e2af",
  blue: "#89b4fa",
  magenta: "#f5c2e7",
  cyan: "#94e2d5",
  white: "#bac2de",
};

interface Props {
  tab: Tab;
}

export default function TerminalTab({ tab }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<XTerm | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const unlistenRef = useRef<UnlistenFn[]>([]);
  const updateTabSessionId = useAppStore((s) => s.updateTabSessionId);
  const aliveRef = useRef(false);

  useEffect(() => {
    if (!containerRef.current) return;
    aliveRef.current = true;

    const term = new XTerm({
      theme: THEME,
      fontSize: 14,
      fontFamily: "'JetBrainsMono Nerd Font', 'FiraCode Nerd Font', Menlo, Monaco, monospace",
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 10000,
      convertEol: true,
    });

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();
    term.loadAddon(fitAddon);
    term.loadAddon(webLinksAddon);
    term.open(containerRef.current);

    try {
      const webglAddon = new WebglAddon();
      webglAddon.onContextLoss(() => {
        webglAddon.dispose();
      });
      term.loadAddon(webglAddon);
    } catch {}

    fitAddon.fit();

    xtermRef.current = term;
    fitAddonRef.current = fitAddon;

    const safeWrite = (data: string | Uint8Array) => {
      if (!aliveRef.current) return;
      try {
        term.write(data);
      } catch {}
    };

    const attachSession = async (sessionId: string) => {
      if (!aliveRef.current) return;

      term.onData((data) => {
        if (!aliveRef.current) return;
        invoke("write_ssh", {
          sessionId,
          data: Array.from(new TextEncoder().encode(data)),
        }).catch(() => {});
      });

      term.onResize(({ cols, rows }) => {
        if (!aliveRef.current) return;
        invoke("resize_ssh", { sessionId, cols, rows }).catch(() => {});
      });

      const unlistenData = await listen<number[]>(
        `ssh-data-${sessionId}`,
        (event) => {
          safeWrite(new Uint8Array(event.payload));
        }
      );

      const unlistenClosed = await listen(
        `ssh-closed-${sessionId}`,
        () => {
          safeWrite("\r\n\x1b[31m--- 连接已关闭 ---\x1b[0m\r\n");
        }
      );

      if (!aliveRef.current) {
        unlistenData();
        unlistenClosed();
        return;
      }

      unlistenRef.current = [unlistenData, unlistenClosed];
      await invoke("resize_ssh", {
        sessionId,
        cols: term.cols,
        rows: term.rows,
      }).catch(() => {});
    };

    if (tab.sessionId) {
      attachSession(tab.sessionId);
    } else {
      invoke<string>("connect_ssh", { serverId: tab.serverId })
        .then((sessionId) => {
          if (!aliveRef.current) return;
          updateTabSessionId(tab.id, sessionId);
          return attachSession(sessionId);
        })
        .catch((e) => {
          safeWrite(`\r\n\x1b[31m连接失败: ${e}\x1b[0m\r\n`);
        });
    }

    const handleResize = () => {
      if (!aliveRef.current) return;
      if (fitAddonRef.current) {
        try {
          fitAddonRef.current.fit();
        } catch {}
      }
    };

    window.addEventListener("resize", handleResize);
    const observer = new ResizeObserver(handleResize);
    if (containerRef.current) {
      observer.observe(containerRef.current);
    }

    return () => {
      aliveRef.current = false;
      window.removeEventListener("resize", handleResize);
      observer.disconnect();
      unlistenRef.current.forEach((fn) => fn());
      unlistenRef.current = [];
      try {
        term.dispose();
      } catch {}
      xtermRef.current = null;
      fitAddonRef.current = null;
    };
  }, [tab.id]);

  return <div ref={containerRef} className="xterm-container w-full h-full" />;
}
