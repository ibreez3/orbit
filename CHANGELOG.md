# Changelog

## [Unreleased]

## [v0.0.9-pre] - 2026-11-09

### Changed
- Rotated the Sparkle EdDSA update signing key and enabled signed DMG and appcast publishing in the release workflow.
- Existing installations need one manual install of this build; automatic updates resume after that.

## [v0.0.8-pre] - 2026-11-08

### Fixed
- Splitting a local terminal now opens a second local shell pane instead of failing with an SSH channel error; each pane keeps its own shell, and closing a pane or tab terminates only its shell.
- The workspace window supports the standard title-bar behaviors again: double-clicking the title bar or an empty part of the global bar zooms the window (or minimizes it, following the system double-click preference), and the window can be dragged by its title bar.
- The settings window is resizable and supports title-bar double-click zoom.
- Every control in the settings window now takes effect: SSH timeout, keepalive, auto-reconnect interval, AI enable gating, all customizable keybindings, database query timeout and auto-`LIMIT`, custom theme selection, window background blur, and the select-to-copy default.
- Settings that change live UI state (AI dock availability, keybinding rows, status-bar shortcut hints) refresh immediately instead of waiting for an unrelated redraw.
- Keybinding rows are now clickable across the full row, and key recording no longer depends on which control owns keyboard focus.
- Removed the non-functional Metal GPU renderer toggle.

## [v0.0.7-pre] - 2026-11-08

### Added
- Server-first homepage with a single quick-connect input, recent connections, and compact secondary actions.
- Server folders up to three levels, multi-tag classification, drag-and-drop organization, and tag filtering.
- Temporary SSH connections with inline authentication and optional promotion into saved assets.
- Command palette on `⌘⇧P`; quick connect on `⌘K`; resizable and collapsible asset sidebar.
- Connection attempt and result metadata persisted by the Rust core.
- XCTest unit suite, XCUITest UI suite, and environment-gated real-server smoke tests.

### Changed
- Spotlight is now a command-only palette; server search lives in the global input.
- Server organization uses folder and tag tables with transactional legacy group migration.
- Window minimum size is 1024×640; the right tool dock keeps its 52pt width.

### Fixed
- Reconnect for saved, temporary, and local terminals, including split-pane teardown and orphan session cleanup.
- Temporary connection panel layout collapse, port formatting, focus restoration, and `Esc` priority.
- Quick terminal input routing, `Ctrl+\`` hotkey under IME, and menu entry.
- Status bar session count and database dock entry.
- SSH TCP and handshake timeouts; proxy bind failures return errors instead of panicking.
- Partial server updates no longer wipe omitted credentials.
- Monitor process CPU/memory parsing and SFTP percent escaping.
- User-facing API error text no longer exposes internal error codes.

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
