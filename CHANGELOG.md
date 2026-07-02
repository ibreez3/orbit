# Changelog

## [Unreleased]

## [v0.0.6-pre] - 2026-07-02

### Added
- Settings controls for SSH timeouts, reconnect behavior, monitor refresh, database defaults, keybinding recording, config import/export, and SFTP drag-and-drop uploads.
- Snippet template variables for host, user, port, server name, and group.
- Batch command execution with concurrency, timeout, cancellation, and result status.
- Local port forwarding rules backed by SSH tunnel start/stop APIs.

### Changed
- Split the previous monolithic AppState into focused state objects to reduce SwiftUI recomputation.
- Optimized SSH terminal hot paths with O(1) channel lookup, larger read buffers, batched terminal pumping, and lower idle CPU usage.
- Improved keyword highlighting with prefilters before UTF-8 decoding and regex injection.
- Reduced terminal settings, JSON decoding, connection-pool, SFTP, and terminal cache overhead.
- Updated packaging for Apple Silicon preview builds with consistent macOS deployment target and entitlement checks.

### Fixed
- Preserved required network and file entitlements in generated Xcode projects.
- Improved SSH error reporting for failed connection/channel setup paths.
- Reduced SFTP/exec connection-pool reference leaks by using scoped leases.

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
