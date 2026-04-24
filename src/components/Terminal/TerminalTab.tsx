import { useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import type { Tab } from "../../types";
import { useAppStore } from "../../stores/useAppStore";

interface Props {
  tab: Tab;
}

export default function TerminalTab({ tab }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<XTerm | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const sessionIdRef = useRef<string | null>(null);
  const unlistenRef = useRef<UnlistenFn[]>([]);
  const connectedRef = useRef(false);
  const updateTabSessionId = useAppStore((s) => s.updateTabSessionId);

  const connect = useCallback(async () => {
    if (connectedRef.current || !containerRef.current) return;

    const term = new XTerm({
      theme: {
        background: "#1a1b26",
        foreground: "#c0caf5",
        cursor: "#c0caf5",
        cursorAccent: "#1a1b26",
        selectionBackground: "#33467c",
        black: "#15161e",
        red: "#f7768e",
        green: "#9ece6a",
        yellow: "#e0af68",
        blue: "#7aa2f7",
        magenta: "#bb9af7",
        cyan: "#7dcfff",
        white: "#a9b1d6",
        brightBlack: "#414868",
        brightRed: "#f7768e",
        brightGreen: "#9ece6a",
        brightYellow: "#e0af68",
        brightBlue: "#7aa2f7",
        brightMagenta: "#bb9af7",
        brightCyan: "#7dcfff",
        brightWhite: "#c0caf5",
      },
      fontSize: 14,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      cursorBlink: true,
      scrollback: 10000,
      convertEol: true,
    });

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();

    term.loadAddon(fitAddon);
    term.loadAddon(webLinksAddon);
    term.open(containerRef.current);

    fitAddon.fit();
    xtermRef.current = term;
    fitAddonRef.current = fitAddon;

    try {
      const sessionId = await invoke<string>("connect_ssh", {
        serverId: tab.serverId,
      });
      sessionIdRef.current = sessionId;
      connectedRef.current = true;
      updateTabSessionId(tab.id, sessionId);

      term.onData((data) => {
        if (sessionIdRef.current) {
          invoke("write_ssh", {
            sessionId: sessionIdRef.current,
            data: Array.from(new TextEncoder().encode(data)),
          });
        }
      });

      term.onResize(({ cols, rows }) => {
        if (sessionIdRef.current) {
          invoke("resize_ssh", {
            sessionId: sessionIdRef.current,
            cols,
            rows,
          });
        }
      });

      const unlistenData = await listen<number[]>(
        `ssh-data-${sessionId}`,
        (event) => {
          const bytes = new Uint8Array(event.payload);
          term.write(bytes);
        }
      );

      const unlistenClosed = await listen(
        `ssh-closed-${sessionId}`,
        () => {
          term.write("\r\n\x1b[31m--- 连接已关闭 ---\x1b[0m\r\n");
          connectedRef.current = false;
        }
      );

      unlistenRef.current = [unlistenData, unlistenClosed];

      const rows = term.rows;
      const cols = term.cols;
      await invoke("resize_ssh", { sessionId, cols, rows });
    } catch (e) {
      term.write(`\r\n\x1b[31m连接失败: ${e}\x1b[0m\r\n`);
    }
  }, [tab.serverId]);

  useEffect(() => {
    connect();

    const handleResize = () => {
      if (fitAddonRef.current) {
        fitAddonRef.current.fit();
      }
    };

    window.addEventListener("resize", handleResize);
    const observer = new ResizeObserver(handleResize);
    if (containerRef.current) {
      observer.observe(containerRef.current);
    }

    return () => {
      window.removeEventListener("resize", handleResize);
      observer.disconnect();
      unlistenRef.current.forEach((fn) => fn());
      if (sessionIdRef.current) {
        invoke("disconnect_ssh", { sessionId: sessionIdRef.current });
      }
      xtermRef.current?.dispose();
    };
  }, [connect]);

  return <div ref={containerRef} className="xterm-container w-full h-full" />;
}
