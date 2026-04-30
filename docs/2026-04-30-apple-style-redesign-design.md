# Orbit Apple-Style UI Redesign

> Date: 2026-04-30
> Status: Approved
> Scope: Remove sidebar, add Spotlight, SFTP drawer, DB 3-panel, Apple visual style

## Overview

Redesign Orbit's UI from "sidebar + tabs" to a Spotlight-driven, terminal-first layout with Apple macOS Sonoma/Sequoia visual style. The terminal is the core; everything else is auxiliary.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Navigation | No persistent sidebar; Spotlight (⌘K) for all resource access |
| SSH Terminal | Main area 100%, double-click server to connect |
| SFTP | Bottom drawer, terminal still visible |
| Database | Independent tab, 3-panel: left tables / right-top SQL / right-bottom results |
| Credentials | Managed within Spotlight, not a standalone nav entry |
| Servers | Grouped; adding a server gives SSH + SFTP |
| Tab bar | Top, Safari-style with connection status dots |
| Empty state | Blank terminal + auto-popup Spotlight |
| Visual | Apple frosted glass, soft rounded corners, multi-theme |
| Status bar | 28px mini bar at bottom, frosted glass |

## Layout

```
Window (rounded 16px, frosted glass border)
┌─────────────────────────────────────────────────┐
│ Tab Bar (48px)                                   │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│ │SSH·api-02│ │SSH·web-01│ │DB·orders │  [+][●][⚙]│
│ └──────────┘ └──────────┘ └──────────┘          │
├─────────────────────────────────────────────────┤
│                                                  │
│              Main Area (terminal or DB)           │
│              flex-1, fills remaining space        │
│                                                  │
├─────────────────────────────────────────────────┤  ← SFTP drawer (collapsible)
│ SFTP · api-prod-02              [本地] [远端]     │
├─────────────────────────────────────────────────┤
│ ● 在线  |  api-prod-02  |  Prod  |  ⌘K         │  ← Status bar (28px)
└─────────────────────────────────────────────────┘
```

## Tab Bar

- Safari-style: capsule-shaped tabs, selected state with subtle background
- Server tab: small dot for connection status (green=online, yellow=high load, red=disconnected)
- Close button (×) appears on hover per tab
- `[+]` opens Spotlight
- `[●]` network/alert indicator, turns yellow/red with count on alerts
- `[⚙]` opens Settings tab

## SSH Terminal

- No toolbar. Maximize terminal area. Operations via shortcuts or right-click menu.
- Right-click menu: Copy / Paste / Select All / Clear / Search Output / Open SFTP / Reconnect
- Full ANSI 16-color support
- Multi-line paste protection: top bar appears briefly "Pasting N lines. Confirm? [Paste] [Cancel]"
- Disconnection: subtle inline prompt "Connection lost · [Reconnect]" in terminal
- Split pane: ⌘D (left-right), ⌘⇧D (top-bottom). Draggable divider.

## SFTP Drawer

- Trigger: Tab hover SFTP icon / ⌘⇧F / right-click menu
- Default height: ~280px, draggable resize (min 160px, max 60% of window)
- Collapse: [▼ Collapse] button or ⌘⇧F again
- Two panels: Local (left) + Remote (right)
- Transfer progress bar at bottom of drawer
- Shared connection with SSH (same server)

## Database Tab (3-Panel)

```
┌──────────┬───────────────────────────────────┐
│          │  SQL Editor                        │
│  Tables  │  SELECT ... FROM ... WHERE ...;    │
│          │                    [Format] [▶ Run] │
│  ▼ orders ├───────────────────────────────────│
│    ├ id   │  Results                          │
│    ├ user │  ┌────────┬────────┐              │
│    └ ...  │  │ status │  cnt   │  [Copy TSV]  │
│          │  │ PAID   │ 12042  │              │
│          │  └────────┴────────┘              │
│          │  3 rows · 18ms                     │
└──────────┴───────────────────────────────────┘
```

- Left panel (~220px, resizable): table list with search, grouped by type (tables/views/functions), expandable columns
- Right-top: SQL editor with syntax highlighting, ⌘Enter to execute
- Right-bottom: results table, sortable columns, row count + timing
- Safety: read-only/write indicator in status bar; UPDATE/DELETE/DROP on writable connections → confirmation dialog

## Spotlight (⌘K)

- Centered in window, ~15% from top, width 560px, max height 70vh
- Four sections: Servers (grouped, with status dots) / Databases / Credentials / Quick Actions
- Real-time filtering, keyboard navigation (↑↓, Enter, Tab between sections)
- Double-click server → close Spotlight → open SSH tab and connect
- Selected server shows [SFTP] button on right side
- Quick Actions: Add Server, Add Database, New Credential, Switch Theme, Open Settings
- Empty state: auto-popup Spotlight on launch

## Theme System

Three built-in themes with CSS variables:

### Light
```
Terminal bg: #ffffff, Window bg: #f5f5f7
Panel bg: rgba(255,255,255,0.72) + backdrop-filter: blur(20px)
Text primary: #1d1d1f, Text secondary: #86868b
Accent: #007AFF, Success: #34C759, Warn: #FF9500, Error: #FF3B30
Border: rgba(0,0,0,0.08)
```

### Dark
```
Terminal bg: #1c1c1e, Window bg: #000000
Panel bg: rgba(44,44,46,0.72) + backdrop-filter: blur(20px)
Text primary: #f5f5f7, Text secondary: #98989d
Accent: #0A84FF, Success: #30D158, Warn: #FF9F0A, Error: #FF453A
Border: rgba(255,255,255,0.08)
```

### Catppuccin Mocha
```
Terminal bg: #1e1e2e, Window bg: #11111b
Panel bg: rgba(49,50,68,0.72) + backdrop-filter: blur(20px)
Text primary: #cdd6f4, Text secondary: #a6adc8
Accent: #89b4fa, Success: #a6e3a1, Warn: #f9e2af, Error: #f38ba8
Border: rgba(205,214,244,0.1)
ANSI: Red #f38ba8, Green #a6e3a1, Yellow #f9e2af, Blue #89b4fa, Magenta #f5c2e7, Cyan #94e2d5
```

Frosted glass applies to: Spotlight, SFTP drawer header, status bar, tab bar, modals, context menus.

## Status Bar

- 28px height, frosted glass background
- Left: connection dot + current server name + environment tag
- Right: shortcut hints "⌘K Search  ⌘, Settings"
- 11px font, low contrast

## Shortcuts

| Action | Shortcut |
|--------|----------|
| Spotlight | ⌘K |
| New connection | ⌘N |
| Close tab | ⌘W |
| Settings | ⌘, |
| Split left-right | ⌘D |
| Split top-bottom | ⌘⇧D |
| Search terminal | ⌘F |
| Clear screen | ⌘L |
| Toggle SFTP drawer | ⌘⇧F |
| Execute SQL | ⌘Enter |

## Empty State

- No tabs, no sidebar
- Terminal area is completely blank (theme background color)
- No text or prompts in the terminal area
- Spotlight auto-pops up on first launch

## Settings Tab

- Opens as a tab via ⌘, or ⚙ button
- Simple form layout, sections separated by headings
- Sections: Appearance (theme cards), Terminal (font size/line height/cursor), Connection (defaults)
- Changes apply immediately, no save button
- Theme selection is color block cards with click-to-preview

## Implementation Impact on Existing Code

### Files to modify
- `MainView.swift` — remove sidebar, add Spotlight overlay, SFTP drawer
- `AppState.swift` — add Spotlight state, SFTP drawer state, theme management
- `Models.swift` — add `TabType.database`, Spotlight-related models, theme models
- `OrbitApp.swift` — register ⌘K shortcut
- `TerminalView.swift` — adapt to full-width, right-click menu enhancements

### Files to create
- `Views/SpotlightView.swift` — Spotlight popup
- `Views/SftpDrawerView.swift` — bottom drawer SFTP
- `Views/DatabaseView.swift` — 3-panel database tab
- `Views/SettingsView.swift` — settings tab
- `Views/StatusBarView.swift` — frosted glass status bar
- `Views/TabBarView.swift` — Safari-style tab bar

### Files to remove
- `Views/SidebarView.swift` — replaced by Spotlight
- `Views/MonitorView.swift` — removed from this redesign scope (not in 3 core modules)

### Rust layer
- No changes needed for UI redesign. SSH/SFTP/DB FFI already sufficient.
- Future: add DB profile CRUD if needed.
