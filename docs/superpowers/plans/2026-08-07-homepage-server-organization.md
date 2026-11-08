# Orbit Homepage and Server Organization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Orbit's welcome homepage with a server-first quick-connect workspace, add user-defined 1–3 level server folders and tags, and provide a complete non-persistent temporary SSH connection path through Rust and FFI.

**Architecture:** Rust remains authoritative for SQLite persistence, migration, connection-result metadata, SSH session pooling, temporary-session validation, and promotion into a saved server. Swift owns parsing and presentation, keeps temporary secrets only in per-tab memory, and consumes explicit JSON FFI DTOs. Existing database, credential-group, snippet, SFTP, monitor, Docker, and terminal behavior remains unchanged unless a saved `serverId` is required and therefore unavailable to a temporary tab.

**Tech Stack:** Rust 2021, rusqlite, ssh2, serde, cbindgen, Swift 5.9, SwiftUI, AppKit, XCTest, XcodeGen, macOS 13+.

## Global Constraints

- Implement only the approved design in `docs/superpowers/specs/2026-08-07-homepage-server-organization-design.md`.
- Server folders have 1–3 levels; each server belongs to zero or one folder and zero or more tags.
- Database `group_name`, credential groups, and command snippets keep their existing data models and behavior.
- The asset sidebar is resizable from 180pt through 360pt, collapses to 48pt, and restores both width and collapsed state.
- The right session tool dock remains 52pt wide.
- The minimum window is 1024×640 and the reference size is 1280×800.
- `⌘K` focuses the server input; `⌘⇧P` opens the command panel.
- Status colors mean active session, last attempt failed, and unknown/disconnected; they do not claim live reachability.
- Rust is the sole writer of saved-server connection metadata.
- Temporary credentials stay in memory, never enter SQLite, UserDefaults, logs, errors, or recent-server history.
- Temporary sessions are never returned to `idle_pool`; promotion does not make the current transport poolable.
- Keep `group_name` in the server table for rollback compatibility, but new server organization UI and mutations use `folder_id` and tag links.
- Deleting a folder treats its descendants as content: move mode flattens all servers in the subtree into the selected destination before deleting the subtree; delete mode deletes all servers and folders in the subtree after explicit confirmation.
- Do not add dependencies. Do not manually edit `Orbit.xcodeproj/project.pbxproj`; regenerate it from `orbit-app/project.yml`.
- Do not stage `.superpowers/`, the revision draft, build products, static libraries, DerivedData, or unrelated user changes.
- Every production change starts with a failing focused test where the behavior can be isolated.

## File Structure

Rust persistence and connection core:

- Create: `orbit-rs/src/server_organization.rs` — folder/tag DTOs, normalization, tree validation, and database operations.
- Modify: `orbit-rs/src/models.rs` — extend server DTOs and add temporary connection/promotion DTOs.
- Modify: `orbit-rs/src/db.rs` — transactional migration, server columns, connection metadata, and atomic promotion.
- Modify: `orbit-rs/src/ssh.rs` — optional pool key and temporary-session descriptor.
- Modify: `orbit-rs/src/ffi.rs` — organization CRUD, saved connection metadata, temporary connect, and promotion C ABI.
- Modify: `orbit-rs/src/lib.rs` — register the new module.
- Regenerate: `orbit-rs/include/orbit.h` — cbindgen output.

Swift domain and bridge:

- Create: `orbit-app/Orbit/Models/ServerWorkspaceModels.swift` — folders, tags, connection target, parser results, drafts, and recent-row projection.
- Modify: `orbit-app/Orbit/Models/Models.swift` — server fields and mutable tab connection target.
- Modify: `orbit-app/Orbit/OrbitBridge.swift` — JSON FFI wrappers.
- Modify: `orbit-app/Orbit/ViewModels/InventoryState.swift` — folder/tag collections.
- Modify: `orbit-app/Orbit/ViewModels/UIState.swift` — top input, tree, sidebar, and command-panel UI state.
- Modify: `orbit-app/Orbit/ViewModels/TabState.swift` — per-tab temporary drafts.
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift` — orchestration and lifecycle.

SwiftUI:

- Create: `orbit-app/Orbit/Views/ServerQuickConnectView.swift` — single global input and result menu.
- Create: `orbit-app/Orbit/Views/TemporaryConnectionPanel.swift` — inline authentication and save controls.
- Create: `orbit-app/Orbit/Views/RecentConnectionsView.swift` — compact single-column recent list.
- Create: `orbit-app/Orbit/Views/ServerTreeSection.swift` — server-only folders, system views, tags, context menus, and drag/drop.
- Modify: `orbit-app/Orbit/Views/HomeView.swift` — homepage composition and centered secondary actions.
- Modify: `orbit-app/Orbit/Views/MainView.swift` — global bar, resizing/collapse, escape priority, minimum size, and temporary tab gating.
- Modify: `orbit-app/Orbit/Views/AssetTreeView.swift` — embed the new server section while leaving other asset sections intact.
- Modify: `orbit-app/Orbit/Views/ServerDialog.swift` — folder and tag editing.
- Modify: `orbit-app/Orbit/Views/SpotlightView.swift` — command-only results.
- Modify: `orbit-app/Orbit/Views/TerminalView.swift` — saved versus temporary connect dispatch.
- Modify: `orbit-app/Orbit/Views/TabBarView.swift`, `StatusBarView.swift`, `SessionToolDockView.swift`, `SettingsView.swift` — names, shortcuts, state text, tool accessibility.
- Modify: `orbit-app/Orbit/Models/KeyBindings.swift`, `orbit-app/Orbit/OrbitApp.swift` — shortcut migration and menus.

Tests and project generation:

- Create: `orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift`.
- Create: `orbit-app/OrbitTests/ServerWorkspaceStateTests.swift`.
- Modify: `orbit-app/project.yml` — add the XCTest target and test action.
- Regenerate: `orbit-app/Orbit.xcodeproj/project.pbxproj` through XcodeGen.

---

### Task 1: Transactional Server Organization Schema and Migration

**Files:**
- Create: `orbit-rs/src/server_organization.rs`
- Modify: `orbit-rs/src/models.rs`
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/lib.rs`

**Interfaces:**
- Produces: `ServerFolder`, `ServerTag`, `ServerTagLink`, `ServerOrganizationSnapshot`.
- Produces: `normalize_name(&str) -> Result<String>` and `Database::server_organization() -> Result<ServerOrganizationSnapshot>`.
- Extends: `Server` with `folder_id`, pin fields, and connection-result fields; `ServerInput` with `folder_id`. Tag membership remains authoritative in `ServerOrganizationSnapshot.tag_links`.

- [ ] **Step 1: Write migration and normalization tests**

Add tests to `orbit-rs/src/server_organization.rs` and `orbit-rs/src/db.rs`:

```rust
#[test]
fn normalized_names_trim_and_fold_case() {
    assert_eq!(normalize_name("  Production  ").unwrap(), "production");
    assert!(normalize_name("   ").is_err());
}

#[test]
fn legacy_groups_migrate_once_without_touching_connection_fields() {
    let path = std::env::temp_dir().join(format!("orbit-migration-{}.db", uuid::Uuid::new_v4()));
    create_legacy_database(&path, "s1", "Prod", "10.0.0.1", "jump-1");
    let db = Database::new(path.to_str().unwrap()).unwrap();
    let snapshot = db.server_organization().unwrap();
    let server = db.get_server("s1").unwrap();
    assert_eq!(snapshot.folders.len(), 1);
    assert_eq!(server.host, "10.0.0.1");
    assert_eq!(server.jump_server_id, "jump-1");
    assert_eq!(server.folder_id.as_deref(), Some(snapshot.folders[0].id.as_str()));
    drop(db);
    let reopened = Database::new(path.to_str().unwrap()).unwrap();
    assert_eq!(reopened.server_organization().unwrap().folders.len(), 1);
    drop(reopened);
    std::fs::remove_file(path).unwrap();
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `cd orbit-rs && cargo test server_organization -- --nocapture`

Expected: FAIL because the module, DTOs, columns, and migration do not exist.

- [ ] **Step 3: Add DTOs and schema transaction**

Define the exact public DTO shape:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerFolder {
    pub id: String,
    pub name: String,
    pub normalized_name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerTag {
    pub id: String,
    pub name: String,
    pub normalized_name: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerOrganizationSnapshot {
    pub folders: Vec<ServerFolder>,
    pub tags: Vec<ServerTag>,
    pub tag_links: Vec<ServerTagLink>,
}
```

Enable `PRAGMA foreign_keys = ON`. In one `unchecked_transaction`, create `server_folders`, `server_tags`, and `server_tag_links`; add the seven server columns; create a root-safe unique index using `COALESCE(parent_id, '')`; then migrate each trimmed non-empty legacy `group_name` into a root folder and reuse the normalized sibling if present. Treat duplicate-column errors as already-applied state, but roll back every other error. The test helper `create_legacy_database` must create the pre-migration `servers` table directly with rusqlite and insert encrypted empty secret fields, so the test exercises `Database::new` rather than a post-migration helper.

- [ ] **Step 4: Update server row mapping without changing secret handling**

Extend `SERVER_COLUMNS`, `row_to_server`, `add_server`, and `update_server` with:

```rust
pub folder_id: Option<String>,
pub is_pinned: bool,
pub pin_order: Option<i64>,
pub last_connected_at: Option<String>,
pub last_attempted_at: Option<String>,
pub last_connection_result: Option<String>,
pub last_connection_error: Option<String>,
```

Continue encrypting password, private key, and key passphrase through the existing `crypto` module.

- [ ] **Step 5: Verify migration GREEN and the full Rust baseline**

Run: `cd orbit-rs && cargo test server_organization -- --nocapture`

Expected: PASS, including idempotence and rollback assertions.

Run: `cd orbit-rs && cargo test`

Expected: all existing and new tests PASS.

- [ ] **Step 6: Commit**

```bash
git add orbit-rs/src/server_organization.rs orbit-rs/src/models.rs orbit-rs/src/db.rs orbit-rs/src/lib.rs
git commit -m "feat: add server organization schema"
```

---

### Task 2: Folder, Tag, Move, Delete, and Pin Database Operations

**Files:**
- Modify: `orbit-rs/src/server_organization.rs`
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/ffi.rs`

**Interfaces:**
- Consumes: schema and DTOs from Task 1.
- Produces: `create_folder`, `rename_folder`, `move_folder`, `delete_folder`, `create_tag`, `delete_tag`, `set_server_tags`, `move_server`, and `set_server_pin` database methods.
- Produces: corresponding JSON C ABI functions consumed by Task 6.

- [ ] **Step 1: Write failing tree and tag mutation tests**

```rust
#[test]
fn rejects_fourth_level_and_descendant_move() {
    let db = test_db();
    let a = db.create_server_folder(folder("a", None)).unwrap();
    let b = db.create_server_folder(folder("b", Some(&a.id))).unwrap();
    let c = db.create_server_folder(folder("c", Some(&b.id))).unwrap();
    assert!(db.create_server_folder(folder("d", Some(&c.id))).is_err());
    assert!(db.move_server_folder(&a.id, Some(&c.id), 0).is_err());
}

#[test]
fn nonempty_delete_moves_servers_atomically() {
    let db = seeded_server_db();
    let source = db.create_server_folder(folder("source", None)).unwrap();
    let target = db.create_server_folder(folder("target", None)).unwrap();
    db.move_server("s1", Some(&source.id)).unwrap();
    db.delete_server_folder(&source.id, Some(&target.id), false).unwrap();
    assert_eq!(db.get_server("s1").unwrap().folder_id, Some(target.id));
}

#[test]
fn tags_are_global_and_server_links_are_replaced() {
    let db = seeded_server_db();
    let prod = db.create_server_tag("Prod").unwrap();
    assert!(db.create_server_tag(" prod ").is_err());
    db.set_server_tags("s1", &[prod.id.clone()]).unwrap();
    assert_eq!(db.server_tag_ids("s1").unwrap(), vec![prod.id]);
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-rs && cargo test server_organization::tests -- --nocapture`

Expected: FAIL because mutation methods do not exist.

- [ ] **Step 3: Implement validated transactional mutations**

Use explicit request types:

```rust
pub struct FolderInput { pub name: String, pub parent_id: Option<String>, pub sort_order: Option<i64> }
pub struct FolderMoveInput { pub parent_id: Option<String>, pub sort_order: i64 }
pub struct FolderDeleteInput { pub destination_folder_id: Option<String>, pub delete_servers: bool }
pub struct ServerTagsInput { pub tag_ids: Vec<String> }
pub struct ServerMoveInput { pub folder_id: Option<String> }
pub struct ServerPinInput { pub is_pinned: bool, pub pin_order: Option<i64> }
```

For every folder create/move, load the ancestor chain and descendant maximum depth before writing. For non-empty deletion, require exactly one of destination move or `delete_servers = true`; in move mode assign every server in the subtree to the destination and delete the subtree, while delete mode deletes all subtree servers. Execute server move/delete, tag-link cleanup, descendant-folder deletion, and root-folder deletion in one transaction. Pinning assigns `MAX(pin_order) + 1` when no explicit order is supplied and clears `pin_order` when unpinned.

- [ ] **Step 4: Export explicit FFI operations**

Add:

```rust
orbit_list_server_organization(app, out_json)
orbit_create_server_folder(app, json_input, out_json)
orbit_rename_server_folder(app, folder_id, json_input, out_json)
orbit_move_server_folder(app, folder_id, json_input, out_json)
orbit_delete_server_folder(app, folder_id, json_input)
orbit_create_server_tag(app, json_input, out_json)
orbit_delete_server_tag(app, tag_id)
orbit_set_server_tags(app, server_id, json_input)
orbit_move_server(app, server_id, json_input)
orbit_set_server_pin(app, server_id, json_input, out_json)
```

Each function clears `last_error`, parses UTF-8/JSON with existing helpers, sets a user-displayable error on failure, and returns JSON through `json_to_out`.

- [ ] **Step 5: Verify GREEN**

Run: `cd orbit-rs && cargo test server_organization::tests -- --nocapture`

Expected: PASS for sibling uniqueness, depth, cycles, delete transactions, tag replacement, and pin ordering.

- [ ] **Step 6: Commit**

```bash
git add orbit-rs/src/server_organization.rs orbit-rs/src/db.rs orbit-rs/src/ffi.rs
git commit -m "feat: add server folder and tag operations"
```

---

### Task 3: Saved-Server Connection Result Persistence

**Files:**
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/ffi.rs`

**Interfaces:**
- Produces: `Database::mark_connection_attempt`, `mark_connection_success`, `mark_connection_failure`.
- Changes: `orbit_connect_ssh` writes metadata but retains its C signature.

- [ ] **Step 1: Write failing metadata and sanitization tests**

```rust
#[test]
fn connection_failure_is_sanitized_and_success_clears_it() {
    let db = seeded_server_db();
    db.mark_connection_attempt("s1").unwrap();
    db.mark_connection_failure("s1", "password=hunter2 authentication failed").unwrap();
    let failed = db.get_server("s1").unwrap();
    assert_eq!(failed.last_connection_result.as_deref(), Some("failed"));
    assert!(!failed.last_connection_error.unwrap().contains("hunter2"));
    db.mark_connection_success("s1").unwrap();
    let success = db.get_server("s1").unwrap();
    assert_eq!(success.last_connection_result.as_deref(), Some("success"));
    assert_eq!(success.last_connection_error, None);
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-rs && cargo test connection_failure_is_sanitized -- --nocapture`

Expected: FAIL because metadata methods do not exist.

- [ ] **Step 3: Implement authoritative write points**

At the start of `orbit_connect_ssh`, call `mark_connection_attempt`. Route every TCP/handshake/authentication/channel/PTY/shell/reader error through one helper that stores `failed` and a sanitized bounded summary. Call `mark_connection_success` only after the reader is registered and `out_session_id` is ready. Metadata-write errors emit `tracing::warn!` without changing the SSH result.

- [ ] **Step 4: Verify GREEN and regression behavior**

Run: `cd orbit-rs && cargo test connection_ -- --nocapture`

Expected: PASS; errors do not expose password, private key, passphrase, or request JSON.

- [ ] **Step 5: Commit**

```bash
git add orbit-rs/src/db.rs orbit-rs/src/ffi.rs
git commit -m "feat: persist ssh connection results"
```

---

### Task 4: Poolable and Non-Poolable SSH Session Lifecycles

**Files:**
- Modify: `orbit-rs/src/ssh.rs`
- Modify: `orbit-rs/src/ffi.rs`

**Interfaces:**
- Produces: `SessionPoolKey = Option<String>` and `TemporarySessionDescriptor`.
- Changes: `SshManager::register_session(..., pool_key: Option<String>, temporary: Option<TemporarySessionDescriptor>)`.
- Produces: shared internal `connect_server_session` used by saved and temporary C entry points.

- [ ] **Step 1: Extract a testable disconnect decision and write RED tests**

```rust
#[test]
fn saved_session_is_poolable_but_temporary_session_is_not() {
    assert_eq!(disconnect_disposition(Some("server-1")), DisconnectDisposition::Pool);
    assert_eq!(disconnect_disposition(None), DisconnectDisposition::Close);
}

#[test]
fn temporary_descriptor_contains_no_secret_fields() {
    let descriptor = TemporarySessionDescriptor::new("host", 22, "alice", "password", None, None);
    let debug = format!("{descriptor:?}");
    assert!(!debug.contains("password_value"));
    assert!(!debug.contains("private_key"));
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-rs && cargo test saved_session_is_poolable -- --nocapture`

Expected: FAIL because the optional pool key and disposition do not exist.

- [ ] **Step 3: Implement lifecycle distinction**

Replace `SharedSession.server_id: String` with:

```rust
pool_key: Option<String>,
temporary: Option<TemporarySessionDescriptor>,
```

When the final channel closes, insert into `idle_pool` only for `Some(pool_key)`; for `None`, set blocking, disconnect, and drop the guard. Keep `spawn_channel` available for both session kinds.

- [ ] **Step 4: Extract one connection pipeline**

Create an internal function with the exact boundary:

```rust
fn connect_server_session(
    app: &OrbitApp,
    server: Server,
    pool_key: Option<String>,
    temporary: Option<TemporarySessionDescriptor>,
    data_cb: OrbitDataCallback,
    closed_cb: OrbitClosedCallback,
    userdata: *mut c_void,
) -> anyhow::Result<String>
```

Saved connections pass `Some(server.id.clone())`; temporary connections pass `None`. Keep PTY, shell, callback, and reader registration in this shared path. Each public FFI wrapper converts the returned session ID into `out_session_id`, maps invalid argument/UTF-8/JSON errors before calling the helper, and maps helper failure to the existing connection error code after setting `last_error`.

- [ ] **Step 5: Verify GREEN**

Run: `cd orbit-rs && cargo test ssh::tests -- --nocapture`

Expected: PASS and saved session pool behavior remains unchanged.

- [ ] **Step 6: Commit**

```bash
git add orbit-rs/src/ssh.rs orbit-rs/src/ffi.rs
git commit -m "refactor: support non-poolable ssh sessions"
```

---

### Task 5: Temporary Connection and Atomic Promotion FFI

**Files:**
- Modify: `orbit-rs/src/models.rs`
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/ssh.rs`
- Modify: `orbit-rs/src/ffi.rs`
- Regenerate: `orbit-rs/include/orbit.h`

**Interfaces:**
- Produces: `TemporaryConnectionInput`, `PromoteTemporaryServerInput`.
- Produces: `orbit_connect_ssh_temporary` and `orbit_promote_temporary_server`.
- Consumes: Task 2 organization operations and Task 4 non-poolable sessions.

- [ ] **Step 1: Write failing request-validation and promotion tests**

```rust
#[test]
fn temporary_input_rejects_invalid_or_ambiguous_auth() {
    assert!(temporary_input("", 22, "alice").validate().is_err());
    assert!(temporary_input("host", 0, "alice").validate().is_err());
    let mut input = temporary_input("host", 22, "alice");
    input.credential_group_id = Some("cg-1".into());
    input.password = Some("secret".into());
    assert!(input.validate().is_err());
}

#[test]
fn promotion_is_atomic_and_requires_matching_descriptor() {
    let db = seeded_server_db();
    let descriptor = descriptor("host", 22, "alice");
    let mismatched = promotion("other-host", 22, "alice");
    assert!(db.promote_temporary_server(&descriptor, &mismatched).is_err());
    assert_eq!(db.list_servers().unwrap().len(), 1);
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-rs && cargo test temporary_ -- --nocapture`

Expected: FAIL because DTO validation and promotion do not exist.

- [ ] **Step 3: Add request DTOs with explicit auth validation**

```rust
#[derive(Debug, Clone, Deserialize)]
pub struct TemporaryConnectionInput {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: String,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub key_source: Option<String>,
    pub key_file_path: Option<String>,
    pub key_passphrase: Option<String>,
    pub credential_group_id: Option<String>,
    pub jump_server_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PromoteTemporaryServerInput {
    pub connection: TemporaryConnectionInput,
    pub name: String,
    pub folder_id: Option<String>,
    pub tag_ids: Vec<String>,
}
```

Validation requires non-empty host and username, port 1–65535, a supported auth type, existing referenced credential/jump IDs, and mutually exclusive direct-secret versus credential-group modes.

- [ ] **Step 4: Implement both C ABI functions**

```c
int32_t orbit_connect_ssh_temporary(OrbitApp *, const char *, OrbitDataCallback, OrbitClosedCallback, void *, char **);
int32_t orbit_promote_temporary_server(OrbitApp *, const char *, const char *, char **);
```

Create a runtime ID `temporary:<uuid>`, build an in-memory `Server`, and call Task 4's shared pipeline with no pool key. Promotion loads the active temporary descriptor, compares host/port/username/auth type/credential-group/jump IDs, then atomically inserts the encrypted server, folder reference, tag links, and success metadata. It returns the saved `Server` JSON and leaves the current connection non-poolable.

- [ ] **Step 5: Regenerate and verify the header**

Run: `cd orbit-rs && cargo test temporary_ -- --nocapture`

Expected: PASS for request validation, descriptor matching, rollback, and secret redaction.

Run: `./scripts/build-rust.sh`

Expected: arm64 static libraries build and `orbit-rs/include/orbit.h` contains both new functions.

- [ ] **Step 6: Commit**

```bash
git add orbit-rs/src/models.rs orbit-rs/src/db.rs orbit-rs/src/ssh.rs orbit-rs/src/ffi.rs orbit-rs/include/orbit.h
git commit -m "feat: add temporary ssh ffi pathway"
```

---

### Task 6: Swift Workspace Models, XCTest Target, and FFI Wrappers

**Files:**
- Create: `orbit-app/Orbit/Models/ServerWorkspaceModels.swift`
- Create: `orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift`
- Modify: `orbit-app/Orbit/Models/Models.swift`
- Modify: `orbit-app/Orbit/OrbitBridge.swift`
- Modify: `orbit-app/Orbit/ViewModels/InventoryState.swift`
- Modify: `orbit-app/project.yml`
- Regenerate: `orbit-app/Orbit.xcodeproj/project.pbxproj`

**Interfaces:**
- Mirrors: all Task 1, 2, and 5 JSON DTOs.
- Produces: `ServerConnectionTarget`, `TemporaryConnectionDraft`, `ServerWorkspaceBridge`, and all synchronous/async bridge methods.

- [ ] **Step 1: Add the unit-test target and failing Codable tests**

Add an `OrbitTests` unit-test target depending on `Orbit`, and include it in the Orbit scheme test action. Write:

```swift
func testServerDecodesOrganizationAndConnectionFields() throws {
    let server = try JSONDecoder().decode(Server.self, from: Data(serverJSON.utf8))
    XCTAssertEqual(server.folder_id, "folder-1")
    XCTAssertTrue(server.is_pinned)
    XCTAssertEqual(server.last_connection_result, "failed")
}

func testOrganizationSnapshotDecodesTagLinks() throws {
    let snapshot = try JSONDecoder().decode(ServerOrganizationSnapshot.self, from: Data(snapshotJSON.utf8))
    XCTAssertEqual(snapshot.tag_links, [.init(server_id: "s1", tag_id: "tag-1")])
}

func testTemporaryDraftClearsSecrets() {
    var draft = TemporaryConnectionDraft.fixture(password: "secret", privateKey: "key", passphrase: "phrase")
    draft.clearSecrets()
    XCTAssertEqual(draft.password, "")
    XCTAssertEqual(draft.privateKey, "")
    XCTAssertEqual(draft.keyPassphrase, "")
}
```

- [ ] **Step 2: Generate the project and verify RED**

Run: `cd orbit-app && xcodegen generate`

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Expected: FAIL because the new models and server fields do not exist.

- [ ] **Step 3: Implement exact Swift model boundaries**

```swift
enum ServerConnectionTarget: Equatable {
    case saved(serverId: String)
    case temporary(tabId: String)
    case local
}

struct TemporaryConnectionDraft: Equatable {
    var host: String
    var port: UInt16
    var username: String
    var authType: String
    var password = ""
    var privateKey = ""
    var keySource = "content"
    var keyFilePath = ""
    var keyPassphrase = ""
    var credentialGroupId: String?
    var jumpServerId: String?
    var saveToAssets = false
    var displayName = ""
    var folderId: String?
    var tagIds: [String] = []
    mutating func clearSecrets() { password = ""; privateKey = ""; keyPassphrase = "" }
}
```

Make `TabItem.serverId` optional and mutable, add `connectionTarget`, and keep local tabs explicit instead of using a fake persisted ID. Extend `Server` and `ServerInput` with Task 1 fields.

- [ ] **Step 4: Add bridge wrappers with existing memory ownership rules**

Implement list/mutation wrappers for Task 2 plus:

```swift
func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot
func createServerFolderAsync(input: FolderInput) async throws -> ServerFolder
func renameServerFolderAsync(id: String, input: FolderInput) async throws -> ServerFolder
func moveServerFolderAsync(id: String, input: FolderMoveInput) async throws -> ServerFolder
func deleteServerFolderAsync(id: String, input: FolderDeleteInput) async throws
func createServerTagAsync(name: String) async throws -> ServerTag
func deleteServerTagAsync(id: String) async throws
func setServerTagsAsync(serverId: String, tagIds: [String]) async throws
func moveServerAsync(serverId: String, folderId: String?) async throws
func setServerPinAsync(serverId: String, isPinned: Bool, pinOrder: Int64?) async throws -> Server
func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String
func promoteTemporaryServerAsync(sessionId: String, input: PromoteTemporaryServerInput) async throws -> Server
```

Encode through `JSONEncoder`, free returned C strings with `orbit_free_string`, and retrieve detailed errors through the existing `OrbitError` path.

Expose a narrow injectable boundary for state tests:

```swift
protocol ServerWorkspaceBridge {
    func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot
    func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String
    func promoteTemporaryServerAsync(sessionId: String, input: PromoteTemporaryServerInput) async throws -> Server
}

extension OrbitBridge: ServerWorkspaceBridge {}
```

- [ ] **Step 5: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Expected: PASS for Codable compatibility and secret clearing.

- [ ] **Step 6: Commit**

```bash
git add orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj orbit-app/Orbit/Models/Models.swift orbit-app/Orbit/Models/ServerWorkspaceModels.swift orbit-app/Orbit/OrbitBridge.swift orbit-app/Orbit/ViewModels/InventoryState.swift orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift
git commit -m "feat: bridge server workspace models"
```

---

### Task 7: Temporary Tab State and Terminal Dispatch

**Files:**
- Create: `orbit-app/OrbitTests/ServerWorkspaceStateTests.swift`
- Modify: `orbit-app/Orbit/ViewModels/TabState.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Modify: `orbit-app/Orbit/Views/TerminalView.swift`
- Modify: `orbit-app/Orbit/Views/MainView.swift`
- Modify: `orbit-app/Orbit/Views/SplitPaneView.swift`

**Interfaces:**
- Consumes: Task 6 `ServerConnectionTarget` and temporary bridge methods.
- Produces: `addTemporaryTerminalTab`, `temporaryDraft(for:)`, `promoteTemporaryTab`, and target-aware terminal connection.

- [ ] **Step 1: Write failing lifecycle tests**

```swift
@MainActor
func testClosingTemporaryTabDeletesDraftSecrets() {
    let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())
    let tabId = state.addTemporaryTerminalTab(draft: .fixture(password: "secret"))
    state.removeTab(tabId)
    XCTAssertNil(state.tabState.temporaryDrafts[tabId])
}

@MainActor
func testPromotionRebindsTabToSavedServer() async throws {
    let bridge = FakeServerWorkspaceBridge(promotedServer: .fixture(id: "saved-1"))
    let state = AppState(workspaceBridge: bridge)
    let tabId = state.addTemporaryTerminalTab(draft: .fixture())
    try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")
    XCTAssertEqual(state.tabState.tab(id: tabId)?.connectionTarget, .saved(serverId: "saved-1"))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Expected: FAIL because per-tab drafts and promotion do not exist.

- [ ] **Step 3: Implement per-tab in-memory ownership**

Add `@Published var temporaryDrafts: [String: TemporaryConnectionDraft] = [:]`. `addTemporaryTerminalTab` creates `.temporary(tabId:)`; `performRemoveTab` clears secrets before removing the draft; successful promotion updates the tab to `.saved(serverId:)`, updates its title/name, reloads inventory, and then clears the draft. Failed promotion leaves both session and draft intact.

Add `workspaceBridge: any ServerWorkspaceBridge` to `AppState.init`, defaulting to `OrbitBridge.shared`; keep the existing concrete bridge for unrelated APIs.

- [ ] **Step 4: Dispatch terminal connection by target**

```swift
switch connectionTarget {
case .saved(let serverId):
    sid = try await bridge.connectSSHAsync(serverId: serverId)
case .temporary(let tabId):
    guard let draft = appState.temporaryDraft(for: tabId) else { throw WorkspaceError.missingTemporaryDraft }
    sid = try await bridge.connectTemporarySSHAsync(input: draft.connectionInput)
case .local:
    connectLocal()
    return
}
```

Allow split channels after the first temporary session exists. Disable SFTP, monitor, Docker, port forwarding, and batch commands for `.temporary` because they require a persisted server ID.

- [ ] **Step 5: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Expected: PASS for close, failed save, successful promotion, and target gating.

- [ ] **Step 6: Commit**

```bash
git add orbit-app/OrbitTests/ServerWorkspaceStateTests.swift orbit-app/Orbit/ViewModels/TabState.swift orbit-app/Orbit/ViewModels/AppState.swift orbit-app/Orbit/Views/TerminalView.swift orbit-app/Orbit/Views/MainView.swift orbit-app/Orbit/Views/SplitPaneView.swift
git commit -m "feat: add temporary terminal lifecycle"
```

---

### Task 8: Single Server Input, Address Parser, and Inline Authentication

**Files:**
- Modify: `orbit-app/Orbit/Models/ServerWorkspaceModels.swift`
- Modify: `orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift`
- Modify: `orbit-app/Orbit/ViewModels/UIState.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Create: `orbit-app/Orbit/Views/ServerQuickConnectView.swift`
- Create: `orbit-app/Orbit/Views/TemporaryConnectionPanel.swift`
- Modify: `orbit-app/Orbit/Views/MainView.swift`

**Interfaces:**
- Produces: `ServerAddressParser.parse(_:) -> Result<ParsedServerAddress, ServerAddressError>`.
- Produces: `ServerSearchResult` and one top-level input used for both saved search and temporary addresses.

- [ ] **Step 1: Write parser and search RED tests**

```swift
func testAddressParserSupportsDefaultsAndBracketedIPv6() throws {
    XCTAssertEqual(try ServerAddressParser.parse("host").get(), .init(host: "host", port: 22, username: nil))
    XCTAssertEqual(try ServerAddressParser.parse("alice@host:2202").get(), .init(host: "host", port: 2202, username: "alice"))
    XCTAssertEqual(try ServerAddressParser.parse("alice@[2001:db8::10]:22").get(), .init(host: "2001:db8::10", port: 22, username: "alice"))
    XCTAssertThrowsError(try ServerAddressParser.parse("2001:db8::10:22").get())
}

func testServerSearchUsesNameHostFolderAndTagOnly() {
    let results = ServerSearchIndex(fixtures).search("prod")
    XCTAssertEqual(results.map(\.server.id), ["s1"])
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Expected: FAIL because parser and search index do not exist.

- [ ] **Step 3: Implement deterministic parsing and search ranking**

Reject whitespace-only hosts, ports outside `1...65535`, unbracketed IPv6-with-port ambiguity, and empty usernames before `@`. Rank exact server name, name prefix, host prefix, then folder/tag substring; stabilize ties by case-insensitive name. Model results only as `.saved(ServerSearchMatch)`, `.temporary(ParsedServerAddress)`, and `.newServer(query: String)`, so command results cannot enter this pipeline.

- [ ] **Step 4: Build the single global input and inline panel**

`ServerQuickConnectView` owns focus through `@FocusState`, shows saved results plus “新建服务器”, and opens `TemporaryConnectionPanel` only for a valid address that is not a selected saved server. Place it in the 40pt global bar between the weak “SSH 工作台” title and existing add/settings controls; hide title/helper text before shrinking the input. The panel binds every field in `TemporaryConnectionDraft`, defaults to “仅本次连接”, never defaults to root, hides save fields until requested, disables duplicate submission, preserves the draft after authentication failure, and clears secrets on dismissal.

- [ ] **Step 5: Implement Esc priority and focus return**

Route `Esc` through `AppState.handleEscape()` returning a consumed flag in this order: temporary panel, search results, input focus, existing overlay behavior. Do not intercept when all input state is closed. Restore the active terminal view through the existing terminal cache when available.

- [ ] **Step 6: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Expected: PASS for parser, search fields, ranking, and invalid input.

- [ ] **Step 7: Commit**

```bash
git add orbit-app/Orbit/Models/ServerWorkspaceModels.swift orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift orbit-app/Orbit/ViewModels/UIState.swift orbit-app/Orbit/ViewModels/AppState.swift orbit-app/Orbit/Views/ServerQuickConnectView.swift orbit-app/Orbit/Views/TemporaryConnectionPanel.swift orbit-app/Orbit/Views/MainView.swift
git commit -m "feat: add global server quick connect"
```

---

### Task 9: Recent Connection Projection and Homepage Layout

**Files:**
- Modify: `orbit-app/Orbit/Models/ServerWorkspaceModels.swift`
- Modify: `orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Create: `orbit-app/Orbit/Views/RecentConnectionsView.swift`
- Modify: `orbit-app/Orbit/Views/HomeView.swift`

**Interfaces:**
- Produces: `RecentConnectionProjector.rows(servers:activeServerIds:legacyIds:)`.
- Consumes: persisted result fields from Task 3 and inventory data from Task 6.

- [ ] **Step 1: Write failing sorting and status tests**

```swift
func testRecentRowsSortPinsThenDatabaseAttemptsThenLegacy() {
    let rows = RecentConnectionProjector.rows(servers: recentFixtures, activeServerIds: [], legacyIds: ["legacy"])
    XCTAssertEqual(rows.map(\.server.id), ["pinned", "newest", "older", "legacy"])
    XCTAssertEqual(rows.last?.relativeTime, "历史记录")
}

func testActiveSessionOverridesPersistedFailure() {
    let row = RecentConnectionProjector.row(server: .failedFixture(), activeServerIds: ["s1"], isLegacy: false)
    XCTAssertEqual(row.status, .active)
    XCTAssertEqual(row.statusLabel, "活动中")
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Expected: FAIL because the projector does not exist.

- [ ] **Step 3: Implement projection and legacy fallback**

Eligible rows are servers with `last_attempted_at` or an ID in the legacy UserDefaults array. Sort eligible pinned rows first by `pin_order`, followed by timestamped rows in descending `last_attempted_at`, then legacy-only rows in stored order labeled “历史记录”. Stop calling `trackRecentServer` for new connections; keep legacy reads only until each server gains a database attempt timestamp.

- [ ] **Step 4: Replace cards with a compact single-column list**

Render at most eight 56pt rows with status marker, name, optional folder/tag, monospaced `host:port`, relative time, and hover menu. Make the entire row activate a saved terminal. Give status markers tooltip/accessibility values “活动中”, “上次连接失败”, or “未检测”; never display “在线/离线”. Add pin, edit, move, and delete actions through Task 2 APIs. “查看全部” selects the server system view rather than introducing another connection list.

- [ ] **Step 5: Recompose the homepage**

Remove logo/title/explanation and the duplicate connection field. Put recent connections first inside an 800pt centered content column. Place natural-width centered buttons for 本地终端, 添加服务器, 命令面板 in a 360–420pt group; remove AI from the homepage. Preserve the defined empty state.

- [ ] **Step 6: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceModelsTests`

Then manually inspect at 1280×800 and 1024×640.

Expected: eight rows fit at reference size, core operations remain visible at minimum size, and no unconditional green marker exists.

- [ ] **Step 7: Commit**

```bash
git add orbit-app/Orbit/Models/ServerWorkspaceModels.swift orbit-app/OrbitTests/ServerWorkspaceModelsTests.swift orbit-app/Orbit/ViewModels/AppState.swift orbit-app/Orbit/Views/RecentConnectionsView.swift orbit-app/Orbit/Views/HomeView.swift
git commit -m "feat: redesign recent connections homepage"
```

---

### Task 10: Server Folder Tree, Tags, Dialog, and Resizable Sidebar

**Files:**
- Modify: `orbit-app/Orbit/ViewModels/InventoryState.swift`
- Modify: `orbit-app/Orbit/ViewModels/UIState.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Create: `orbit-app/Orbit/Views/ServerTreeSection.swift`
- Modify: `orbit-app/Orbit/Views/AssetTreeView.swift`
- Modify: `orbit-app/Orbit/Views/ServerDialog.swift`
- Modify: `orbit-app/Orbit/Views/MainView.swift`
- Modify: `orbit-app/OrbitTests/ServerWorkspaceStateTests.swift`

**Interfaces:**
- Consumes: Task 2 CRUD bridge and Task 6 organization snapshot.
- Produces: recursive tree projection, one-tag filter, folder context actions, server/folder drop validation, and persisted sidebar presentation state.

- [ ] **Step 1: Write failing tree-projection and sidebar tests**

```swift
func testTreeBuildsThreeLevelsAndSearchPreservesPath() {
    let tree = ServerTreeProjection(snapshot: .threeLevelFixture(), servers: [.fixture(folderId: "leaf")])
    XCTAssertEqual(tree.path(forServerId: "s1"), "客户 / 生产 / Web")
    XCTAssertEqual(tree.search("web").first?.path, "客户 / 生产 / Web")
}

func testSidebarWidthClampsAndRestoresCollapse() {
    XCTAssertEqual(SidebarPresentation.clampedWidth(120), 180)
    XCTAssertEqual(SidebarPresentation.clampedWidth(420), 360)
    XCTAssertEqual(SidebarPresentation(collapsed: true, width: 240).displayWidth, 48)
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Expected: FAIL because tree projection and presentation types do not exist.

- [ ] **Step 3: Implement server-only recursive tree and system views**

Show “全部服务器” always; show “置顶”, “最近连接”, and “未分类” only when non-empty. Render user folders recursively to depth three. The existing database, credential, and snippet sections remain below and retain their own models. Search filters only the sidebar and includes server name, host, full folder path, and tags.

- [ ] **Step 4: Add folder and server interactions**

Use Task 2 bridge calls for create child, rename, delete, reorder, move folder, move server, set tags, and pin. Hide “新建子目录” at depth three. Provide explicit confirmation for empty deletion and require destination-or-delete choice for non-empty deletion. Reject illegal drops before calling Rust, then surface the Rust error if state changed concurrently.

- [ ] **Step 5: Update ServerDialog**

Replace the server `group_name` editor with one folder picker and multi-tag selector with inline tag creation. Submit `folder_id` in `ServerInput`, then replace membership through `setServerTags(serverId:tagIds:)`; leave `group_name` absent for new writes. If tag replacement fails after the server update, keep the dialog open, reload the saved server and organization snapshot, and show the Rust error so the UI cannot claim an unsaved tag selection. Do not change credential-group or jump-server selection.

- [ ] **Step 6: Implement sidebar sizing and persistence**

Clamp the drag handle to 180...360, add a collapse control, render 48pt collapsed mode, and persist `assetTreeWidth` plus `assetTreeCollapsed` in UserDefaults. Use cumulative drag start width rather than repeatedly adding total translation.

- [ ] **Step 7: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Expected: PASS for paths, search, depth, system-view visibility, width clamping, and collapse restoration.

- [ ] **Step 8: Commit**

```bash
git add orbit-app/Orbit/ViewModels/InventoryState.swift orbit-app/Orbit/ViewModels/UIState.swift orbit-app/Orbit/ViewModels/AppState.swift orbit-app/Orbit/Views/ServerTreeSection.swift orbit-app/Orbit/Views/AssetTreeView.swift orbit-app/Orbit/Views/ServerDialog.swift orbit-app/Orbit/Views/MainView.swift orbit-app/OrbitTests/ServerWorkspaceStateTests.swift
git commit -m "feat: add hierarchical server organization"
```

---

### Task 11: Command Boundary, Shortcuts, Dock, Status Bar, and Accessibility

**Files:**
- Modify: `orbit-app/Orbit/Views/SpotlightView.swift`
- Modify: `orbit-app/Orbit/Models/KeyBindings.swift`
- Modify: `orbit-app/Orbit/OrbitApp.swift`
- Modify: `orbit-app/Orbit/Views/TabBarView.swift`
- Modify: `orbit-app/Orbit/Views/StatusBarView.swift`
- Modify: `orbit-app/Orbit/Views/SessionToolDockView.swift`
- Modify: `orbit-app/Orbit/Views/SettingsView.swift`
- Modify: `orbit-app/Orbit/Views/MainView.swift`
- Modify: `orbit-app/OrbitTests/ServerWorkspaceStateTests.swift`

**Interfaces:**
- Produces: separate `quickConnect` and `commandPalette` actions.
- Consumes: Task 8 server input focus action.

- [ ] **Step 1: Write failing shortcut migration tests**

```swift
func testShortcutDefaultsSeparateServersAndCommands() {
    XCTAssertEqual(KeyBindings.defaultBindings["quickConnect"]?.displayString, "⌘K")
    XCTAssertEqual(KeyBindings.defaultBindings["commandPalette"]?.displayString, "⇧⌘P")
}

func testLegacySpotlightOverrideMigratesToCommandPalette() {
    let store = MemoryKeyBindingStore(["spotlight": .init(key: "j", command: true)])
    let bindings = KeyBindings(store: store)
    XCTAssertEqual(bindings.binding(for: "commandPalette").key, "j")
}
```

Introduce an internal `KeyBindingStore` protocol backed by UserDefaults in production and `MemoryKeyBindingStore` in tests; make `defaultBindings` internal so `@testable import Orbit` can assert the defaults.

- [ ] **Step 2: Run and verify RED**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Expected: FAIL because the two actions and migration do not exist.

- [ ] **Step 3: Convert Spotlight into a command-only panel**

Remove server and credential result sections. Keep command snippets and application actions such as adding assets, opening settings, and theme changes. Rename user-facing text from “Spotlight” to “命令面板”.

- [ ] **Step 4: Migrate shortcuts and menus**

Map the old persisted `spotlight` override to `commandPalette` once when the new key is absent. Set defaults to `quickConnect = ⌘K` and `commandPalette = ⌘⇧P`. Update the app menu, tab bar help, Settings labels, and notification names consistently. The bottom status bar shows the active-session count on the left and “⌘K 快速连接 · ⌘⇧P 命令面板” on the right.

- [ ] **Step 5: Finish dock and accessibility rules**

Keep the dock at 52pt, place AI beside other tools, and add `.help` plus `.accessibilityLabel` to every icon. Ensure folder toggles, row menus, and dock buttons have at least 28×28pt hit areas. Set the window minimum to 1024×640 in both `OrbitApp` and `MainView`.

- [ ] **Step 6: Verify GREEN**

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests/ServerWorkspaceStateTests`

Then exercise `⌘K`, `⌘⇧P`, and layered `Esc` with a terminal active and with no terminal.

Expected: server input and command panel never open for the same shortcut; Esc closes only the highest-priority layer.

- [ ] **Step 7: Commit**

```bash
git add orbit-app/Orbit/Views/SpotlightView.swift orbit-app/Orbit/Models/KeyBindings.swift orbit-app/Orbit/OrbitApp.swift orbit-app/Orbit/Views/TabBarView.swift orbit-app/Orbit/Views/StatusBarView.swift orbit-app/Orbit/Views/SessionToolDockView.swift orbit-app/Orbit/Views/SettingsView.swift orbit-app/Orbit/Views/MainView.swift orbit-app/OrbitTests/ServerWorkspaceStateTests.swift
git commit -m "feat: separate server and command entry points"
```

---

### Task 12: Full Migration, Build, and UI Acceptance Verification

**Files:**
- Modify only files required by failures found in this task.
- Do not add feature scope during verification.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified release-build and acceptance evidence.

- [ ] **Step 1: Run complete Rust tests**

Run: `cd orbit-rs && cargo test`

Expected: all tests PASS, including migration idempotence, organization constraints, metadata, non-poolable sessions, and promotion rollback.

- [ ] **Step 2: Rebuild Rust artifacts and verify generated ABI**

Run: `./scripts/build-rust.sh`

Expected: success for `aarch64-apple-darwin`; generated header exposes organization CRUD, temporary connect, and promotion functions.

- [ ] **Step 3: Regenerate and run all Swift tests**

Run: `cd orbit-app && xcodegen generate`

Run: `cd orbit-app && xcodebuild test -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS'`

Expected: all OrbitTests PASS.

- [ ] **Step 4: Build the release app**

Run: `make build-app`

Expected: Release app builds, signature and entitlement verification pass, and no generated binary is staged.

- [ ] **Step 5: Perform migration safety checks on disposable database copies**

Create disposable fixtures for empty, legacy grouped, duplicate-normalized-group, and already-migrated databases. Launch the Rust database initializer twice for each copy and compare server count, host, username, auth type, credential-group ID, jump-server ID, folder relationships, and tag links.

Expected: values remain stable; no duplicate folders/links; a forced migration error leaves the pre-migration schema/data intact.

- [ ] **Step 6: Perform UI acceptance checks**

At 1280×800 and 1024×640 verify: one server input; eight recent rows at reference size; centered three-button group; no homepage AI card; 180–360pt resize and 48pt collapse restore; three-level folders; tag filtering; legal and illegal drops; tooltip and keyboard access; status wording; quick saved connection; temporary password/key/credential-group/jump connection; save promotion; failed-save retry; temporary tab close cleanup; command-only panel.

Expected: every item in design sections 11–13 passes without changing database, credential-group, or snippet grouping behavior.

- [ ] **Step 7: Inspect repository hygiene**

Run: `git status --short`

Expected: only intended source, generated Xcode project, generated C header, tests, and this plan are tracked changes; `.superpowers/`, revision drafts, static libraries, app bundles, and DerivedData remain untracked or ignored.

- [ ] **Step 8: Close verification failures at their owning task boundary**

If a check fails, return to the task that owns the behavior, add a regression test there, make the minimal fix, rerun that task's focused command and Steps 1–7 above, then commit only that task's explicit file list using its commit message. If all checks pass, create no verification-only commit.
