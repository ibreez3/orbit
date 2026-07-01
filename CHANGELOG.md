# Changelog

## [Unreleased]

## [v0.0.5-pre.2] - 2026-07-01

### Added
- Docker management panel for remote servers over the existing Orbit SSH connection.
- Container list with status, image, CPU, memory, ports, metadata, and search.
- Container lifecycle actions: start, stop, restart, and remove.
- One-click streaming terminal actions for `docker exec -it` shell access and `docker logs -f`.
- Docker log loading with keyword filtering and matched-line counts.

### Changed
- Docker tabs now preserve their current view state when switching between tabs.
- Docker refresh keeps the previous container list visible while new data is loading.
- Docker panel state is cleaned up when its tab or parent server is removed.

### Added
- Spotlight command palette (⌘K) for quick server/database access
- Safari-style tab bar with connection status indicators
- SFTP bottom drawer with dual-pane local/remote file browsing
- Database 3-panel view (tables / SQL editor / results)
- Theme system with 8 built-in themes (Dark, Light, Nord, Dracula, Catppuccin Mocha, Gruvbox Dark, Solarized Dark, Tokyo Night)
- Quick Terminal (Ctrl+`) — floating dropdown terminal
- Local shell support (no SSH required)
- Terminal split panes (⌘D / ⌘⇧D) with draggable dividers
- Multi-line paste protection (confirms when >3 lines)
- Settings panel with font, cursor, theme, scrollback, and keybinding display
- Configurable scrollback buffer (1K–50K lines, default 10K)
- Enhanced font ligatures (liga + dlig + calt) for programming fonts
- Frame-batched terminal output for better rendering throughput
- Key binding configuration model with JSON persistence
- Server monitoring with CPU, memory, disk, and process charts
- SSH jump host (bastion) support
- AES-256-GCM encrypted credential storage

### Known limitations
- Database panel uses mock data (backend integration pending)
- Metal GPU rendering temporarily disabled (SwiftTerm compatibility)
- Monitoring scripts require Linux server (macOS/BSD not supported)
- Application is unsigned — requires right-click → Open or `xattr -cr` on first launch
- macOS 13.0 minimum deployment target
