# Changelog

## [Unreleased]

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
