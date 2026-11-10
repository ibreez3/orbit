# Orbit AI Agent Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let local AI agents (Claude Code, Codex, DeepSeek Harness) use Orbit's saved servers to execute commands and get results without ever receiving server credentials, with admission tokens, session-scoped write approval, and audit.

**Architecture:** A shared Swift `AgentKit` static library defines the wire protocol, MCP bridge, CLI, session/token logic, command guard, and socket transport. The Orbit app hosts an `AgentGateway` over a local Unix socket, exposes `orbit_list_servers` and generic `orbit_exec`/shell tools backed by the existing Rust SSH pool, and presents admission/write approvals. `orbit-mcp` and `orbit-cli` are thin executables embedded in the app bundle; both talk to the gateway and never touch credentials.

**Tech Stack:** Rust 2021, ssh2, rusqlite, serde, cbindgen; Swift 5.9, SwiftUI, AppKit, Foundation/POSIX sockets, XCTest, XcodeGen; macOS 13+, Apple Silicon arm64.

**Spec:** `docs/superpowers/specs/2026-11-09-orbit-agent-gateway-design.md`

## Global Constraints

- Implement only the approved design in the spec above.
- macOS 13.0 minimum; Swift 5.9; use `ObservableObject`, never `@Observable`.
- Do not manually edit `orbit-app/Orbit.xcodeproj/project.pbxproj`; edit `orbit-app/project.yml` and run `xcodegen generate`.
- Do not add third-party Swift dependencies.
- No TCP listener. Gateway socket: `~/Library/Application Support/Orbit/agent/agent.sock`; directory `0700`, socket `0600`.
- Every tool call requires a valid admission token. Writes require a per-`(session, server)` grant. Persistent shells require a write grant.
- Passwords, private keys, passphrases, and full tokens never appear in tool results, logs, audit records, errors, or test fixtures. Token logs may show at most the first 4 characters.
- Tool calls return within about 55 seconds. Approval tools wait at most 5 seconds before returning `pending_approval`. Long commands become jobs.
- `ping` is liveness only and must not extend the 30-minute idle timeout. Running jobs and open shells do extend session liveness.
- No dedicated Docker/container tools. `orbit_exec` runs arbitrary commands, including `docker ps`, `docker logs`, and `docker exec`; the read guard parses `docker exec`'s inner command.
- Active AI sessions keep Orbit alive after the last window closes. Explicit quit with active sessions must confirm and terminate them.
- Disabling the global AI gateway or a server's exposure is an immediate kill switch: revoke tokens/grants, cancel jobs, close shells, reject new calls.
- `orbit-mcp` and `orbit-cli` must be embedded at `Orbit.app/Contents/MacOS/` and remain ad-hoc signed; Developer ID/notarization is out of scope.
- Existing built-in AI panel, terminal, SFTP, monitor, database, Docker panel, and normal server management behavior must not change.
- Test commands assume `~/.cargo/bin` is on `PATH`. Swift test command:
  `xcodebuild test -project orbit-app/Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -derivedDataPath /tmp/orbit-agent-dd`
- Do not stage build products, DerivedData, `.superpowers/`, or unrelated changes.

## Review Focus

1. A tool call made before admission must return `pending_approval` or `unauthorized` within 5 seconds, must not open an SSH connection, and must succeed after the user approves and the agent retries.
2. An MCP client with a 60-second tool timeout must never wait on approval or a long command: approval returns pending, commands return a job, and a retried write with the same `idempotencyKey` must not execute twice.
3. Credentials and tokens must not leak through error paths, server listings, audit records, CLI output, or logs, including malformed/missing server cases.
4. Disabling the global switch or a server switch must terminate live shells and jobs and revoke grants immediately, not only hide the server from listings.
5. Closing the window, quitting, or updating Orbit during an AI session must produce a clear outcome (stay alive, confirm quit, or a bridge error), and `docker exec <container> cat ...` must not bypass the read guard.

## File Structure

**AgentKit (new Swift static library, shared by app and tools):**
- Create: `orbit-app/AgentKit/AgentModels.swift` — public DTOs and tool names.
- Create: `orbit-app/AgentKit/AgentProtocol.swift` — request/response envelopes and `AgentJSONValue`.
- Create: `orbit-app/AgentKit/AgentPaths.swift` — socket, CLI session, audit paths.
- Create: `orbit-app/AgentKit/AgentSocketServer.swift` — POSIX Unix socket server.
- Create: `orbit-app/AgentKit/AgentSocketClient.swift` — POSIX Unix socket client.
- Create: `orbit-app/AgentKit/AgentSessionStore.swift` — token/session/write-grant state.
- Create: `orbit-app/AgentKit/AgentServerDirectory.swift` — exposure + server resolution.
- Create: `orbit-app/AgentKit/AgentCommandGuard.swift` — read/write command classification.
- Create: `orbit-app/AgentKit/AgentMCP.swift` — MCP message types, tool catalog, bridge core.
- Create: `orbit-app/AgentKit/AgentCLI.swift` — CLI parser and runner.
- Create: `orbit-app/AgentKit/AgentSessionFiles.swift` — CLI session file persistence.
- Create: `orbit-app/AgentKit/AgentShellSentinel.swift` — shell completion marker parser.
- Create: `orbit-app/AgentKit/AgentGatewayProtocols.swift` — `AgentGatewayCalling`, `AgentCommandExecuting`, `AgentApprovalPresenting`, `AgentAuditRecording`.

**Orbit app agent layer:**
- Create: `orbit-app/Orbit/Agent/AgentGateway.swift` — socket dispatch, admission, tool routing.
- Create: `orbit-app/Orbit/Agent/AgentExecService.swift` — server summaries and Rust bridge exec.
- Create: `orbit-app/Orbit/Agent/AgentJobManager.swift` — job tracking/polling/cancel.
- Create: `orbit-app/Orbit/Agent/AgentShellManager.swift` — persistent SSH/container shells.
- Create: `orbit-app/Orbit/Agent/AgentApprovalController.swift` — approval queue and AppKit window.
- Create: `orbit-app/Orbit/Agent/AgentApprovalView.swift` — SwiftUI approval panel.
- Create: `orbit-app/Orbit/Agent/AgentAuditStore.swift` — audit persistence and UI feed.
- Create: `orbit-app/AgentKit/AgentExposureStore.swift` — per-server AI exposure defaults.
- Create: `orbit-app/Orbit/Agent/AgentActivityView.swift` — AI activity panel.
- Modify: `orbit-app/Orbit/AppDelegate.swift` — gateway lifecycle and quit confirmation.
- Modify: `orbit-app/Orbit/OrbitBridge.swift` — new agent exec/job FFI wrappers.
- Modify: `orbit-app/Orbit/Views/SettingsView.swift` — AI Agent settings category/pane.
- Modify: `orbit-app/Orbit/Views/ServerDialog.swift` — “允许 AI 访问” toggle.
- Modify: `orbit-app/Orbit.xcodeproj` via `orbit-app/project.yml` — AgentKit target, tool targets, embed script, test dependency.

**Executables:**
- Create: `orbit-app/OrbitMCP/main.swift` — stdio MCP entrypoint.
- Create: `orbit-app/OrbitCLI/main.swift` — CLI entrypoint.

**Rust:**
- Create: `orbit-rs/src/agent/mod.rs` — agent exec DTO, output truncation, job registry, FFI helpers.
- Modify: `orbit-rs/src/lib.rs` — register `agent` module.
- Modify: `orbit-rs/src/ffi.rs` — `orbit_agent_exec` and job C ABI.
- Regenerate: `orbit-rs/include/orbit.h` via `./scripts/build-rust.sh`.

**Tests:**
- Create: `orbit-app/OrbitTests/AgentProtocolTests.swift`
- Create: `orbit-app/OrbitTests/AgentSocketTests.swift`
- Create: `orbit-app/OrbitTests/AgentSessionStoreTests.swift`
- Create: `orbit-app/OrbitTests/AgentServerDirectoryTests.swift`
- Create: `orbit-app/OrbitTests/AgentGatewayTests.swift`
- Create: `orbit-app/OrbitTests/AgentExecServiceTests.swift`
- Create: `orbit-app/OrbitTests/AgentMCPTests.swift`
- Create: `orbit-app/OrbitTests/AgentCLITests.swift`
- Create: `orbit-app/OrbitTests/AgentCommandGuardTests.swift`
- Create: `orbit-app/OrbitTests/AgentJobManagerTests.swift`
- Create: `orbit-app/OrbitTests/AgentShellSentinelTests.swift`
- Create: `orbit-app/OrbitTests/AgentAuditStoreTests.swift`
- Create: `orbit-app/OrbitTests/AgentExposureStoreTests.swift`
- Create: `orbit-app/OrbitTests/AgentLifecycleTests.swift`
- Modify: `orbit-app/OrbitUITests/OrbitUITests.swift` — approval/settings/activity UI coverage.

## Shared Interfaces

These are the names and signatures every task must use. Bodies are omitted.

```swift
// AgentModels.swift
public enum AgentExecMode: String, Codable, Sendable { case read, write }
public enum AgentExecStatus: String, Codable, Sendable {
    case completed, running, timedOut = "timed_out", failed, cancelled
}
public struct AgentExecResult: Codable, Equatable, Sendable {
    public var status: AgentExecStatus
    public var serverId: String
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int32?
    public var durationMs: UInt64
    public var truncated: Bool
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var jobId: String?
    public var mode: AgentExecMode
    public var escalated: Bool
}
public struct AgentServerSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var folder: String?
    public var tags: [String]
    public var aiEnabled: Bool
}
public enum AgentErrorCode: String, Codable, Sendable {
    case unauthorized, admissionDenied = "admission_denied", approvalTimeout = "approval_timeout"
    case serverNotFound = "server_not_found", serverNotExposed = "server_not_exposed"
    case writeGrantRequired = "write_grant_required", writeDenied = "write_denied"
    case commandTimeout = "command_timeout", sessionExpired = "session_expired"
    case orbitUnavailable = "orbit_unavailable", invalidRequest = "invalid_request"
    case shellNotFound = "shell_not_found", shellTimeout = "shell_timeout"
}
public struct AgentErrorBody: Codable, Equatable, Sendable { public var code: AgentErrorCode; public var message: String }
public struct AgentSessionCredential: Codable, Equatable, Sendable { public var sessionId: String; public var token: String }
public struct AgentHello: Codable, Equatable, Sendable {
    public var clientName: String
    public var clientVersion: String
    public var bridgeVersion: String
    public var parentPid: Int32
    public var parentPath: String
}
public enum AgentApprovalState: String, Codable, Sendable { case pending, approved, denied, expired }
public struct AgentApprovalStatus: Codable, Equatable, Sendable {
    public var requestId: String
    public var status: AgentApprovalState
    public var session: AgentSessionCredential?
    public var error: AgentErrorBody?
}
public enum AgentAdmissionResult: Equatable, Sendable {
    case approved(AgentSessionCredential)
    case pending(requestId: String)
    case denied(AgentErrorBody)
}
public struct AgentJobStatus: Codable, Equatable, Sendable {
    public var jobId: String
    public var status: AgentExecStatus
    public var exitCode: Int32?
    public var durationMs: UInt64
    public var truncated: Bool
}
public struct AgentJobOutput: Codable, Equatable, Sendable {
    public var jobId: String
    public var chunk: String
    public var nextCursor: Int
    public var eof: Bool
    public var truncated: Bool
}
public struct AgentActiveSession: Codable, Equatable, Sendable {
    public var sessionId: String
    public var agentName: String
    public var createdAt: Date
    public var lastActivityAt: Date
    public var openJobCount: Int
    public var openShellCount: Int
}
public enum AgentToolName {
    public static let listServers = "orbit_list_servers"
    public static let exec = "orbit_exec"
    public static let jobStatus = "orbit_job_status"
    public static let jobOutput = "orbit_job_output"
    public static let jobCancel = "orbit_job_cancel"
    public static let approvalStatus = "orbit_approval_status"
    public static let shellOpen = "orbit_shell_open"
    public static let shellExec = "orbit_shell_exec"
    public static let shellClose = "orbit_shell_close"
}
```

```swift
// AgentProtocol.swift
public enum AgentJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([AgentJSONValue]), object([String: AgentJSONValue])
    public var jsonString: String? { get } // compact JSON for MCP text content
}
public enum AgentOp: String, Codable, Sendable {
    case hello, admissionStatus = "admission_status", call, revoke, ping
}
public struct AgentRequest: Codable, Equatable, Sendable {
    public var id: String
    public var op: AgentOp
    public var sessionId: String?
    public var token: String?
    public var tool: String?
    public var args: AgentJSONValue?
}
public struct AgentResponse: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: AgentJSONValue?
    public var error: AgentErrorBody?
}
```

```swift
// AgentGatewayProtocols.swift
public protocol AgentGatewayCalling {
    func hello(_ hello: AgentHello) throws -> AgentAdmissionResult
    func approvalStatus(requestId: String) throws -> AgentApprovalStatus
    func call(tool: String, args: AgentJSONValue, session: AgentSessionCredential) throws -> AgentJSONValue
    func revoke(_ session: AgentSessionCredential) throws
}
public struct AgentExecRequest: Sendable {
    public var serverQuery: String
    public var command: String
    public var mode: AgentExecMode
    public var timeoutMs: UInt32
    public var waitMs: UInt32
    public var maxOutputBytes: UInt32
    public var idempotencyKey: String?
}
public protocol AgentCommandExecuting {
    func listServers() -> [AgentServerSummary]
    func exec(_ request: AgentExecRequest) async throws -> AgentExecResult
    func jobStatus(jobId: String) async throws -> AgentJobStatus
    func jobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput
    func jobCancel(jobId: String) async throws
    func cancelJobs(serverId: String)
}
public struct AgentAdmissionRequest: Sendable {
    public var requestId: String
    public var agentName: String
    public var clientVersion: String
    public var parentPath: String
    public var parentPid: Int32
}
public struct AgentWriteRequest: Sendable {
    public var requestId: String
    public var agentName: String
    public var serverId: String
    public var serverName: String
    public var command: String
}
public protocol AgentApprovalPresenting {
    func requestAdmission(_ request: AgentAdmissionRequest) async -> Bool
    func requestWrite(_ request: AgentWriteRequest) async -> Bool
}
public struct AgentAuditEvent: Codable, Equatable, Sendable { /* exact fields in Task 7 */ }
public protocol AgentAuditRecording { func record(_ event: AgentAuditEvent) }
```

```swift
// Orbit/Agent/AgentGateway.swift (Orbit module)
public final class AgentGateway {
    public static let shared: AgentGateway
    public init() // shared instance; configure before start
    public init(execService: AgentCommandExecuting,
                approval: AgentApprovalPresenting,
                sessions: AgentSessionStore = AgentSessionStore(),
                audit: AgentAuditRecording,
                approvalWait: TimeInterval = 5,
                socketPath: String = AgentPaths.socketPath)
    public func configure(execService: AgentCommandExecuting,
                          approval: AgentApprovalPresenting,
                          audit: AgentAuditRecording)
    public func start() throws
    public func stop()
    public func handle(_ request: AgentRequest) async -> AgentResponse
    public var hasActiveSessions: Bool { get }
    public var activeSessions: [AgentActiveSession] { get }
    public func applyServerExposureChange(serverId: String, enabled: Bool)
}
```

```swift
// AgentSocketServer / Client
public final class AgentSocketServer {
    public init(socketPath: String)
    public var onRequest: ((AgentRequest, @escaping (AgentResponse) -> Void) -> Void)?
    public func start() throws
    public func stop()
}
public final class AgentSocketClient: AgentGatewayCalling {
    public init(socketPath: String)
    public func connect(timeout: TimeInterval) throws
    public func close()
    // AgentGatewayCalling methods send one request and wait for one response.
}
```

```swift
// AgentSessionStore
public enum AgentSessionValidation: Equatable, Sendable { case valid, unauthorized, expired }
public final class AgentSessionStore {
    public init(clock: @escaping () -> Date = Date.init,
                idleTimeout: TimeInterval = 1800,
                maxLifetime: TimeInterval = 8 * 3600)
    public func createSession(agentName: String) -> AgentSessionCredential
    public func touch(_ sessionId: String)
    public func validate(_ credential: AgentSessionCredential) -> AgentSessionValidation
    public func grantWrite(sessionId: String, serverId: String)
    public func hasWriteGrant(sessionId: String, serverId: String) -> Bool
    public func markJobActive(sessionId: String, jobId: String)
    public func markJobFinished(sessionId: String, jobId: String)
    public func markShellActive(sessionId: String, shellId: String)
    public func markShellClosed(sessionId: String, shellId: String)
    public func revoke(sessionId: String)
    public func revokeServer(serverId: String)
    public func revokeAll()
    public func activeSessions() -> [AgentActiveSession]
    public var hasActiveSessions: Bool { get }
}
```

```swift
// AgentServerDirectory
public enum AgentServerResolution: Equatable, Sendable {
    case resolved(AgentServerSummary), notFound, ambiguous([AgentServerSummary]), notExposed
}
public struct AgentServerDirectory {
    public init(servers: [AgentServerSummary])
    public func list() -> [AgentServerSummary]
    public func resolve(_ query: String) -> AgentServerResolution
}
```

```swift
// AgentCommandGuard (Task 13)
public enum AgentGuardDecision: Equatable, Sendable {
    case allowRead
    case requireWrite(reason: String)
}
public enum AgentCommandGuard {
    public static func evaluate(command: String, declaredMode: AgentExecMode) -> AgentGuardDecision
}
```

```swift
// AgentShellSentinel (Task 19)
public struct AgentShellCommandResult: Equatable, Sendable {
    public var output: String
    public var exitCode: Int32
}
public struct AgentShellSentinel {
    public init(uuid: String = UUID().uuidString)
    public var marker: String { get }
    public func commandSuffix() -> String
    public func consume(buffer: inout String) -> AgentShellCommandResult?
}
```

```c
/* orbit-rs/src/ffi.rs C ABI */
int32_t orbit_agent_exec(OrbitApp *app, const char *server_id, const char *command,
                         uint32_t timeout_ms, uint32_t wait_ms,
                         uint32_t max_output_bytes, char **out_json);
int32_t orbit_agent_job_status(OrbitApp *app, const char *job_id, char **out_json);
int32_t orbit_agent_job_output(OrbitApp *app, const char *job_id, uint64_t cursor, char **out_json);
int32_t orbit_agent_job_cancel(OrbitApp *app, const char *job_id);
```

---

## Phase 1: Admission and Read-Only Troubleshooting

### Task 1: Rust agent exec DTO, truncation, and FFI

**Files:**
- Create: `orbit-rs/src/agent/mod.rs`
- Modify: `orbit-rs/src/lib.rs`
- Modify: `orbit-rs/src/ffi.rs`
- Regenerate: `orbit-rs/include/orbit.h`
- Test: `orbit-rs/src/agent/mod.rs` (unit + ignored real-server test in `ffi.rs`)

**Interfaces:**
- Consumes: `crate::ssh::SshManager`, `crate::transport::SessionPool`, `crate::db::Database`, existing `SshCommandOutput`.
- Produces: `truncate_agent_output(input: &str, limit: usize) -> (String, bool)`; serde `AgentExecOutput` with camelCase JSON matching `AgentExecResult`; C ABI `orbit_agent_exec(..., wait_ms, ...)`.

- [ ] **Step 1: Write the failing unit test**

```rust
#[cfg(test)]
mod tests {
    use super::truncate_agent_output;

    #[test]
    fn truncates_output_and_reports_truncation() {
        let (text, truncated) = truncate_agent_output("abcdef", 4);
        assert_eq!(text, "abcd");
        assert!(truncated);
    }

    #[test]
    fn keeps_output_below_limit() {
        let (text, truncated) = truncate_agent_output("abc", 4);
        assert_eq!(text, "abc");
        assert!(!truncated);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd orbit-rs && ~/.cargo/bin/cargo test --lib agent::tests::truncates_output_and_reports_truncation`
Expected: FAIL because `agent`/`truncate_agent_output` does not exist.

- [ ] **Step 3: Implement the Rust module and FFI**

Create `AgentExecOutput` with `#[derive(Serialize)] #[serde(rename_all = "camelCase")]` fields `status`, `serverId`, `stdout`, `stderr`, `exitCode`, `durationMs`, `truncated`, `stdoutBytes`, `stderrBytes`, `jobId`, `mode`, `escalated`. `truncate_agent_output` must cut on a UTF-8 boundary. `exec_agent_command(pool, server, db, command, timeout_ms, max_bytes)` must execute over SSH using `exec_command_output_with_timeout`, read stdout and stderr without deadlocking when one stream fills, and return `status: "completed"` or `status: "timed_out"`. Add `orbit_agent_exec` to `ffi.rs` using the existing JSON/DTO and `orbit_free_string` conventions; `wait_ms` is accepted but ignored until Task 15 (always return a completed result). Register the module in `lib.rs` and run `./scripts/build-rust.sh` to regenerate `orbit.h`.

- [ ] **Step 4: Run the unit test and build to verify it passes**

Run: `cd orbit-rs && ~/.cargo/bin/cargo test --lib agent::tests`
Expected: PASS.
Run: `./scripts/build-rust.sh`
Expected: success; `grep orbit_agent_exec orbit-rs/include/orbit.h` prints the declaration.

- [ ] **Step 5: Add the ignored real-server test**

In `orbit-rs/src/ffi.rs` `real_server_ffi_tests`, add:

```rust
#[test]
#[ignore]
fn agent_exec_captures_stdout_stderr_and_exit_code() {
    let host = std::env::var("ORBIT_TEST_HOST").expect("ORBIT_TEST_HOST");
    let user = std::env::var("ORBIT_TEST_USER").expect("ORBIT_TEST_USER");
    let password = std::env::var("ORBIT_TEST_PASSWORD").expect("ORBIT_TEST_PASSWORD");
    let app = Box::into_raw(Box::new(OrbitApp::new(":memory:").unwrap()));
    let saved = unsafe { &*app }.db
        .add_server(&server_input(&host, &user, &password)).unwrap();
    let sid = CString::new(saved.id).unwrap();
    let cmd = CString::new("printf out; printf err >&2; exit 7").unwrap();
    let mut out: *mut c_char = ptr::null_mut();
    let rc = orbit_agent_exec(app, sid.as_ptr(), cmd.as_ptr(), 10_000, 10_000, 1_048_576, &mut out);
    assert_eq!(rc, 0);
    let json = unsafe { CStr::from_ptr(out).to_string_lossy().into_owned() };
    assert!(json.contains("\"stdout\":\"out\""));
    assert!(json.contains("\"exitCode\":7"));
    unsafe { orbit_free_string(out); drop(Box::from_raw(app)); }
}
```

Run with the env vars and `--ignored` after Phase 1 wiring is complete; this test is a build-time placeholder until `orbit_agent_exec` is callable.

- [ ] **Step 6: Commit**

```bash
git add orbit-rs/src/agent orbit-rs/src/lib.rs orbit-rs/src/ffi.rs orbit-rs/include/orbit.h
git commit -m "feat: add agent exec bridge"
```

### Task 2: AgentKit target and shared wire models

**Files:**
- Create: `orbit-app/AgentKit/AgentModels.swift`
- Create: `orbit-app/AgentKit/AgentProtocol.swift`
- Create: `orbit-app/AgentKit/AgentPaths.swift`
- Modify: `orbit-app/project.yml`
- Test: `orbit-app/OrbitTests/AgentProtocolTests.swift`

**Interfaces:**
- Produces: all public types in Shared Interfaces (`AgentExecResult`, `AgentServerSummary`, `AgentJSONValue`, `AgentRequest`, `AgentResponse`, `AgentPaths`).
- Project target: `AgentKit` (`library.static`), `OrbitTests` depends on it.

- [ ] **Step 1: Add the AgentKit target and test dependency**

In `project.yml` add:

```yaml
  AgentKit:
    type: library.static
    platform: macOS
    sources:
      - path: AgentKit
    settings:
      base:
        PRODUCT_NAME: AgentKit
        PRODUCT_BUNDLE_IDENTIFIER: com.orbit.agentkit
        MACOSX_DEPLOYMENT_TARGET: "13.0"
        SWIFT_VERSION: "5.9"
```

Add `- target: AgentKit` to `OrbitTests.dependencies` and to the `Orbit` app target dependencies. Run `cd orbit-app && xcodegen generate`.

- [ ] **Step 2: Write the failing protocol tests**

```swift
import XCTest
@testable import AgentKit

final class AgentProtocolTests: XCTestCase {
    func testAgentRequestRoundTripsThroughJSON() throws {
        let request = AgentRequest(id: "1", op: .call, sessionId: "s", token: "t",
                                   tool: AgentToolName.listServers,
                                   args: .object(["server": .string("10.1.101.132")]))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(AgentRequest.self, from: data), request)
    }

    func testJSONValueSupportsNestedObjects() throws {
        let value = AgentJSONValue.object(["a": .array([.number(1), .bool(true), .null])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSONValue.self, from: data), value)
    }

    func testAgentPathsUseApplicationSupport() {
        XCTAssertTrue(AgentPaths.socketPath.hasSuffix("/agent/agent.sock"))
        XCTAssertTrue(AgentPaths.socketPath.contains("Library/Application Support/Orbit"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentProtocolTests`
Expected: FAIL because `AgentKit`/types do not exist.

- [ ] **Step 4: Implement the models, protocol, and paths**

Implement the exactly named types from Shared Interfaces. `AgentJSONValue` must encode `.object` deterministically enough for equality; use `JSONSerialization` or a custom decoder. `AgentPaths.supportDirectory` must create no directories by itself; callers create with `0700`. `AgentPaths.cliSessionsDirectory` is `supportDirectory/cli-sessions`; `auditLogURL` is `supportDirectory/audit.log`.

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentProtocolTests`
Expected: PASS.

```bash
git add orbit-app/AgentKit orbit-app/OrbitTests/AgentProtocolTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add AgentKit wire models"
```

### Task 3: Unix socket server and client

**Files:**
- Create: `orbit-app/AgentKit/AgentSocketServer.swift`
- Create: `orbit-app/AgentKit/AgentSocketClient.swift`
- Test: `orbit-app/OrbitTests/AgentSocketTests.swift`

**Interfaces:**
- Consumes: `AgentRequest`, `AgentResponse`, `AgentPaths`.
- Produces: `AgentSocketServer(socketPath:)`, `onRequest`, `start()/stop()`; `AgentSocketClient(socketPath:)`, `connect(timeout:)`, `close()`, and `AgentGatewayCalling` conformance.

- [ ] **Step 1: Write the failing socket test**

```swift
import XCTest
@testable import AgentKit

final class AgentSocketTests: XCTestCase {
    func testPingRoundTripAndSocketPermissions() throws {
        let path = NSTemporaryDirectory() + "orbit-agent-\(UUID().uuidString).sock"
        let server = AgentSocketServer(socketPath: path)
        server.onRequest = { request, respond in
            respond(AgentResponse(id: request.id, ok: true,
                                  result: .object(["pong": .bool(true)]), error: nil))
        }
        try server.start()
        defer { server.stop() }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let client = AgentSocketClient(socketPath: path)
        try client.connect(timeout: 2)
        defer { client.close() }
        let response = try client.send(
            AgentRequest(id: "1", op: .ping, sessionId: nil, token: nil, tool: nil, args: nil),
            timeout: 2
        )
        XCTAssertEqual(response.result, .object(["pong": .bool(true)]))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentSocketTests`
Expected: FAIL because the socket classes do not exist.

- [ ] **Step 3: Implement the server and client**

Use POSIX `socket(AF_UNIX, SOCK_STREAM, 0)`, `bind`, `listen`, `accept`, and a `DispatchSourceRead`/serial queue. Unlink a stale socket before binding, create the parent directory with `0700`, and `chmod` the socket to `0600`. Frame messages as newline-delimited JSON; keep a per-connection read buffer. `AgentSocketClient.send` writes one JSON line and reads one response with a deadline. `AgentGatewayCalling` maps `hello/approval_status/call/revoke` to the corresponding `AgentRequest` ops; `hello` and `admission_status` send no token.

- [ ] **Step 4: Run the socket test**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentSocketTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/AgentKit/AgentSocketServer.swift orbit-app/AgentKit/AgentSocketClient.swift orbit-app/OrbitTests/AgentSocketTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent Unix socket transport"
```

### Task 4: Session store, tokens, grants, and expiry

**Files:**
- Create: `orbit-app/AgentKit/AgentSessionStore.swift`
- Test: `orbit-app/OrbitTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Produces: `AgentSessionStore`, `AgentSessionValidation`, `AgentActiveSession` exactly as in Shared Interfaces.

- [ ] **Step 1: Write the failing session tests**

```swift
import XCTest
@testable import AgentKit

final class AgentSessionStoreTests: XCTestCase {
    func testTokenIsBoundToSessionAndPingDoesNotRefreshIdle() {
        var now = Date(timeIntervalSince1970: 0)
        let store = AgentSessionStore(clock: { now }, idleTimeout: 30, maxLifetime: 100)
        let session = store.createSession(agentName: "Claude Code")
        now += 31
        XCTAssertEqual(store.validate(session), .expired)
    }

    func testActiveJobKeepsSessionAliveAndWriteGrantIsPerServer() {
        var now = Date(timeIntervalSince1970: 0)
        let store = AgentSessionStore(clock: { now }, idleTimeout: 30, maxLifetime: 100)
        let session = store.createSession(agentName: "Codex")
        store.markJobActive(sessionId: session.sessionId, jobId: "job-1")
        now += 31
        XCTAssertEqual(store.validate(session), .valid)
        store.grantWrite(sessionId: session.sessionId, serverId: "a")
        XCTAssertTrue(store.hasWriteGrant(sessionId: session.sessionId, serverId: "a"))
        XCTAssertFalse(store.hasWriteGrant(sessionId: session.sessionId, serverId: "b"))
        store.markJobFinished(sessionId: session.sessionId, jobId: "job-1")
        now += 31
        XCTAssertEqual(store.validate(session), .expired)
    }

    func testRevokeAllInvalidatesTokens() {
        let store = AgentSessionStore()
        let session = store.createSession(agentName: "Claude Code")
        store.revokeAll()
        XCTAssertEqual(store.validate(session), .unauthorized)
        XCTAssertFalse(store.hasActiveSessions)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentSessionStoreTests`
Expected: FAIL because the store does not exist.

- [ ] **Step 3: Implement the store**

Store sessions in memory keyed by session ID; generate a 32-byte `SecRandomCopyBytes` token and base64url-encode it. `validate` compares the token in constant time, then checks max lifetime, then idle expiration (idle = now - lastActivity; jobs/shells keep `lastActivity` fresh). `touch` updates lastActivity. `revokeServer` removes write grants for that server. `activeSessions` returns sessions sorted by creation time. Do not log tokens.

- [ ] **Step 4: Run and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentSessionStoreTests`
Expected: PASS.

```bash
git add orbit-app/AgentKit/AgentSessionStore.swift orbit-app/OrbitTests/AgentSessionStoreTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent session and token store"
```

### Task 5: Server directory and exposure store

**Files:**
- Create: `orbit-app/AgentKit/AgentServerDirectory.swift`
- Create: `orbit-app/AgentKit/AgentExposureStore.swift`
- Test: `orbit-app/OrbitTests/AgentServerDirectoryTests.swift`
- Test: `orbit-app/OrbitTests/AgentExposureStoreTests.swift`

**Interfaces:**
- Produces: `AgentServerResolution`, `AgentServerDirectory`, `AgentExposureStore`.
- `AgentExposureStore` reads/writes a `UserDefaults` suite key `agentDisabledServerIds` (array of strings); default is all exposed.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AgentKit

final class AgentServerDirectoryTests: XCTestCase {
    func testResolvesByIdThenUniqueNameThenHostAndRejectsAmbiguous() {
        let a = AgentServerSummary(id: "id-a", name: "api", host: "10.0.0.1",
                                   port: 22, username: "u", folder: nil,
                                   tags: [], aiEnabled: true)
        let b = AgentServerSummary(id: "id-b", name: "api", host: "10.0.0.2",
                                   port: 22, username: "u", folder: nil,
                                   tags: [], aiEnabled: true)
        let dir = AgentServerDirectory(servers: [a, b])
        XCTAssertEqual(dir.resolve("id-a"), .resolved(a))
        XCTAssertEqual(dir.resolve("10.0.0.1"), .resolved(a))
        guard case .ambiguous(let candidates) = dir.resolve("api") else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(dir.resolve("missing"), .notFound)
    }
}
```

```swift
final class AgentExposureStoreTests: XCTestCase {
    func testDisabledServerIsNotExposedAndDefaultsToEnabled() {
        let suite = "AgentExposureStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentExposureStore(defaults: defaults)
        let server = AgentServerSummary(id: "id-a", name: "api", host: "h",
                                        port: 22, username: "u", folder: nil,
                                        tags: [], aiEnabled: true)
        XCTAssertTrue(store.isEnabled(serverId: "id-a"))
        store.setEnabled(false, serverId: "id-a")
        XCTAssertFalse(store.isEnabled(serverId: "id-a"))
        let dir = AgentServerDirectory(servers: [server])
        XCTAssertEqual(dir.resolve("id-a"), .resolved(server))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentServerDirectoryTests -only-testing:OrbitTests/AgentExposureStoreTests`
Expected: FAIL because the types do not exist.

- [ ] **Step 3: Implement directory and exposure store**

`AgentServerDirectory.list` returns exposed servers only. Resolution order: exact id, unique name, unique host; ambiguous results return all candidates. `AgentExposureStore` defaults to enabled; disabled ids are persisted; `enabledServers(from:)` filters. Add `AgentExposureStore.shared = AgentExposureStore(defaults: .standard)`. Keep all values in UserDefaults, not the server database.

- [ ] **Step 4: Run and commit**

Run the same tests; expect PASS.

```bash
git add orbit-app/AgentKit/AgentServerDirectory.swift orbit-app/AgentKit/AgentExposureStore.swift orbit-app/OrbitTests/AgentServerDirectoryTests.swift orbit-app/OrbitTests/AgentExposureStoreTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent server exposure model"
```

### Task 6: Gateway core, admission, and dispatch

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentGateway.swift`
- Create: `orbit-app/AgentKit/AgentGatewayProtocols.swift`
- Test: `orbit-app/OrbitTests/AgentGatewayTests.swift`

**Interfaces:**
- Consumes: `AgentSocketServer`, `AgentSessionStore`, `AgentServerDirectory`, `AgentCommandExecuting`, `AgentApprovalPresenting`, `AgentAuditRecording`.
- Produces: `AgentGateway.init(socketPath:execService:approval:sessions:directory:audit:approvalWait:)`, `start()`, `stop()`, `handle(_:) async -> AgentResponse`, `hasActiveSessions`.
- Approval wait is injected (default 5 seconds; tests use 0.01).

- [ ] **Step 1: Write the failing gateway tests**

```swift
import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentGatewayTests: XCTestCase {
    func testCallWithoutTokenIsUnauthorized() async {
        let gateway = makeGateway(approver: FakeApprover(result: true))
        let response = await gateway.handle(
            AgentRequest(id: "1", op: .call, sessionId: nil, token: nil,
                         tool: AgentToolName.listServers, args: nil)
        )
        XCTAssertEqual(response.error?.code, .unauthorized)
    }

    func testHelloApprovalIssuesTokenAndCallSucceeds() async throws {
        let approver = FakeApprover(result: true)
        let gateway = makeGateway(approver: approver)
        let hello = await gateway.handle(
            AgentRequest(id: "1", op: .hello, sessionId: nil, token: nil, tool: nil,
                         args: .object(["clientName": .string("Claude Code")]))
        )
        guard case .object(let object)? = hello.result,
              case .string(let sessionId)? = object["sessionId"],
              case .string(let token)? = object["token"] else {
            return XCTFail("expected approved session")
        }
        let response = await gateway.handle(
            AgentRequest(id: "2", op: .call, sessionId: sessionId, token: token,
                         tool: AgentToolName.listServers, args: nil)
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(approver.admissionCount, 1)
    }

    func testSlowApprovalReturnsPendingWithoutExecuting() async {
        let approver = FakeApprover(result: true, delayMs: 100)
        let gateway = makeGateway(approver: approver, approvalWait: 0.01)
        let response = await gateway.handle(
            AgentRequest(id: "1", op: .hello, sessionId: nil, token: nil, tool: nil,
                         args: .object(["clientName": .string("Codex")]))
        )
        guard case .object(let object)? = response.result else { return XCTFail() }
        XCTAssertEqual(object["status"], .string("pending_approval"))
        XCTAssertNotNil(object["requestId"])
    }

    private func makeGateway(approver: AgentApprovalPresenting,
                             approvalWait: TimeInterval = 5,
                             servers: [AgentServerSummary] = []) -> AgentGateway {
        AgentGateway(
            execService: FakeExecService(servers: servers),
            approval: approver,
            sessions: AgentSessionStore(),
            audit: FakeAudit(),
            approvalWait: approvalWait,
            socketPath: NSTemporaryDirectory() + "test-\(UUID().uuidString).sock"
        )
    }
}

final class FakeApprover: AgentApprovalPresenting {
    let result: Bool
    let delayMs: UInt64
    private(set) var admissionCount = 0
    private(set) var writeCount = 0
    init(result: Bool, delayMs: UInt64 = 0) { self.result = result; self.delayMs = delayMs }
    func requestAdmission(_ request: AgentAdmissionRequest) async -> Bool {
        admissionCount += 1
        if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        return result
    }
    func requestWrite(_ request: AgentWriteRequest) async -> Bool {
        writeCount += 1
        return result
    }
}

// Define in the same test file:
// FakeExecService(servers:) stores the servers and listServers() returns them;
// exec(...) returns a completed AgentExecResult with stdout "ok";
// jobStatus/jobOutput/jobCancel return empty successful values;
// cancelJobs(serverId:) is a no-op.
// FakeAudit.record(_:) appends to an in-memory array.
// Add an AgentServerSummary.fixture(id:name:host:) helper for tests.
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests`
Expected: FAIL because `AgentGateway` and the protocols do not exist.

- [ ] **Step 3: Implement the gateway core**

Add the protocols to AgentKit. `AgentGateway` starts an `AgentSocketServer` and routes `handle`:
- `.hello`: validate `clientName`, create an approval request with a UUID, call `approval.requestAdmission` with a timeout of `approvalWait`; on approved, `sessions.createSession`, return `{status:"approved", sessionId, token}`; on timeout, return `{status:"pending_approval", requestId}` and keep the approval task running; on denied, return `admission_denied`.
- `.admission_status`: return the pending/approved/denied status for the request id.
- `.call`: require a valid session+token; dispatch `orbit_list_servers` to `execService.listServers()` and `orbit_exec` to `execService.exec(_:)`; unknown tools return `invalid_request`. This phase only implements those two tools; write mode returns `write_grant_required`.
- `.ping`: return `{"alive":true,"sessionExpired":false}` without touching the session.
- `.revoke`: revoke the session.
- Record an audit event for admission and tool calls via `audit`.
- On `stop`, close the socket and `sessions.revokeAll()`.

- [ ] **Step 4: Run tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/AgentKit/AgentGatewayProtocols.swift orbit-app/OrbitTests/AgentGatewayTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent gateway admission and dispatch"
```

### Task 7: Audit store and approval window

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentAuditStore.swift`
- Create: `orbit-app/Orbit/Agent/AgentApprovalController.swift`
- Create: `orbit-app/Orbit/Agent/AgentApprovalView.swift`
- Test: `orbit-app/OrbitTests/AgentAuditStoreTests.swift`
- Modify: `orbit-app/Orbit/AppDelegate.swift` (start/stop gateway in a later task)

**Interfaces:**
- Produces: `AgentAuditEvent` exact fields: `id`, `timestamp`, `type`, `sessionId?`, `agent?`, `serverId?`, `tool?`, `command?`, `mode?`, `exitCode?`, `durationMs?`, `stdoutBytes?`, `stderrBytes?`, `result?`.
- `AgentAuditStore.record(_:)`, `recent(limit:)`, `flush()`.
- `AgentApprovalController` conforms to `AgentApprovalPresenting`, queues requests, and presents a SwiftUI panel in an `NSPanel`; `NSApp.activate(ignoringOtherApps: true)` before showing.
- Panel buttons: “允许” / “拒绝” for admission; “允许本会话写操作” / “拒绝” for writes.

- [ ] **Step 1: Write the failing audit test**

```swift
final class AgentAuditStoreTests: XCTestCase {
    func testAuditEventEncodesWithoutSecretsAndAppendsJSONLine() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentAuditStore(logURL: dir.appendingPathComponent("audit.log"))
        store.record(AgentAuditEvent(
            id: "e1", timestamp: Date(timeIntervalSince1970: 0), type: "tool.call",
            sessionId: "s", agent: "Claude Code", serverId: "srv",
            tool: "orbit_exec", command: "docker ps", mode: "read",
            exitCode: 0, durationMs: 12, stdoutBytes: 3, stderrBytes: 0, result: "ok"
        ))
        store.flush()
        let text = try String(contentsOf: dir.appendingPathComponent("audit.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"tool\":\"orbit_exec\""))
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertFalse(text.contains("token"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentAuditStoreTests`
Expected: FAIL because the store does not exist.

- [ ] **Step 3: Implement the audit store and approval controller**

Audit events are Codable; append one JSON line at a time with a serial queue; keep the last 500 in memory for the UI. Add `AgentAuditStore.shared` with `AgentPaths.auditLogURL`. Never include token/credential values. The approval controller keeps a dictionary of pending continuations keyed by request id, shows the panel on the main actor, resumes exactly one continuation per decision, and times out after 120 seconds. Add `AgentApprovalController.shared`. The panel shows the agent name, parent path, server, command preview, and a risk note. Do not block the socket handler; the gateway's 5-second wait is separate.

- [ ] **Step 4: Run the audit test and build the app**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentAuditStoreTests`
Expected: PASS.
Run: `xcodebuild build -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/orbit-agent-dd`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/Orbit/Agent/AgentAuditStore.swift orbit-app/Orbit/Agent/AgentApprovalController.swift orbit-app/Orbit/Agent/AgentApprovalView.swift orbit-app/OrbitTests/AgentAuditStoreTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent audit and approval UI"
```

### Task 8: Exec service and the first read-only tools

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentExecService.swift`
- Test: `orbit-app/OrbitTests/AgentExecServiceTests.swift`
- Modify: `orbit-app/Orbit/OrbitBridge.swift`

**Interfaces:**
- Produces: `AgentExecService.init(transport:inventory:exposure:)` where `transport: AgentExecTransport`, `inventory: () -> [Server]`, `exposure: AgentExposureStore`.
- `AgentExecTransport.agentExec(serverId:command:timeoutMs:waitMs:maxOutputBytes:) async throws -> AgentExecResult`; `OrbitBridge` conforms.
- `AgentExecService.exec(_:)` resolves the server through `AgentServerDirectory`, maps `server_not_found`/`server_not_exposed`, and calls the transport with the resolved server id.

- [ ] **Step 1: Write the failing exec service tests**

```swift
final class AgentExecServiceTests: XCTestCase {
    func testListServersExcludesDisabledAndMapsFolders() {
        let server = Server.fixture(id: "srv", name: "api", host: "10.0.0.1")
        let exposure = AgentExposureStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let service = AgentExecService(
            transport: FakeExecTransport(),
            inventory: { [server] },
            exposure: exposure
        )
        XCTAssertEqual(service.listServers().map(\.id), ["srv"])
        exposure.setEnabled(false, serverId: "srv")
        XCTAssertTrue(service.listServers().isEmpty)
    }

    func testExecRejectsHiddenAndUnknownServers() async {
        let server = Server.fixture(id: "srv", name: "api", host: "10.0.0.1")
        let exposure = AgentExposureStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let service = AgentExecService(transport: FakeExecTransport(),
                                       inventory: { [server] }, exposure: exposure)
        let hidden = await service.exec(AgentExecRequest(serverQuery: "srv", command: "ls", mode: .read, timeoutMs: 1000, waitMs: 1000, maxOutputBytes: 1024, idempotencyKey: nil))
        XCTAssertEqual(hidden.status, .completed)
        exposure.setEnabled(false, serverId: "srv")
        do {
            _ = try await service.exec(AgentExecRequest(serverQuery: "srv", command: "ls", mode: .read, timeoutMs: 1000, waitMs: 1000, maxOutputBytes: 1024, idempotencyKey: nil))
            XCTFail("expected not exposed")
        } catch let error as AgentServiceError {
            XCTAssertEqual(error.code, .serverNotExposed)
        } catch { XCTFail("unexpected error") }
    }
}
```

(Define `Server.fixture` in the test file; define `FakeExecTransport` returning a completed result and `AgentServiceError` in `AgentExecService.swift`.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentExecServiceTests`
Expected: FAIL because the service does not exist.

- [ ] **Step 3: Implement the service and bridge wrapper**

`AgentExecService` builds `AgentServerSummary` from `Server` (`id`, name, host, port, username, folder name/path, tags, `aiEnabled`). `OrbitBridge.agentExec` calls `orbit_agent_exec`, decodes JSON via `AgentKit`, and throws `AgentServiceError` with the correct code on FFI failure. The gateway's `orbit_exec` handler creates an `AgentExecRequest`, calls `exec`, and returns the result JSON. Read mode is allowed; write mode returns `write_grant_required` until Task 14.

- [ ] **Step 4: Run tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentExecServiceTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentExecService.swift orbit-app/Orbit/OrbitBridge.swift orbit-app/OrbitTests/AgentExecServiceTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent exec service and server listing"
```

### Task 9: MCP bridge, tool catalog, and app embedding

**Files:**
- Create: `orbit-app/AgentKit/AgentMCP.swift`
- Create: `orbit-app/OrbitMCP/main.swift`
- Modify: `orbit-app/project.yml` (OrbitMCP target, scheme build, app copy script)
- Test: `orbit-app/OrbitTests/AgentMCPTests.swift`

**Interfaces:**
- Produces: `MCPID`, `MCPRequest`, `MCPResponse`, `MCPToolDefinition`, `AgentToolCatalog.phase1Tools`, `MCPBridgeCore.init(client:)`, `handle(_:) -> MCPResponse?`.
- `orbit-mcp` main reads stdin lines, calls `MCPBridgeCore`, writes responses to stdout.

- [ ] **Step 1: Write the failing MCP tests**

```swift
final class AgentMCPTests: XCTestCase {
    func testToolsListContainsOnlyGenericReadTools() {
        let core = MCPBridgeCore(client: FakeGatewayClient())
        let response = core.handle(MCPRequest(jsonrpc: "2.0", id: .string("1"),
                                              method: "tools/list", params: nil))
        let names = toolNames(response)
        XCTAssertTrue(names.contains(AgentToolName.listServers))
        XCTAssertTrue(names.contains(AgentToolName.exec))
        XCTAssertFalse(names.contains("orbit_list_containers"))
        XCTAssertFalse(names.contains("orbit_docker_logs"))
    }

    func testToolsCallWithoutAdmissionReturnsPending() {
        let client = FakeGatewayClient(admission: .pending(requestId: "req-1"))
        let core = MCPBridgeCore(client: client)
        let response = core.handle(MCPRequest(
            jsonrpc: "2.0", id: .string("2"), method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(response?.result?.jsonString?.contains("pending_approval") == true)
    }

    func testToolsCallAfterApprovalReturnsServerList() {
        let client = FakeGatewayClient(admission: .approved(.init(sessionId: "s", token: "t")))
        let core = MCPBridgeCore(client: client)
        let response = core.handle(MCPRequest(
            jsonrpc: "2.0", id: .string("3"), method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(response?.result?.jsonString?.contains("servers") == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentMCPTests`
Expected: FAIL because the MCP bridge does not exist.

- [ ] **Step 3: Implement the MCP core and target**

`MCPBridgeCore` implements `initialize` (`serverInfo`, capabilities.tools), `notifications/initialized` (no response), `tools/list` (phase 1: list_servers, exec), `tools/call` (hello on first call, pending passthrough, call the gateway, wrap JSON), and `ping`. Tool schemas describe `server`, `command`, `mode`, `timeoutMs`, `waitMs`, `maxOutputBytes`, `idempotencyKey`. The bridge must not expose `orbit_list_containers`, `orbit_docker_logs`, or container-specific tools.

Add the OrbitMCP tool target and app copy phase:

```yaml
  OrbitMCP:
    type: tool
    platform: macOS
    sources: [{ path: OrbitMCP }]
    dependencies: [{ target: AgentKit }]
    settings: { base: { PRODUCT_NAME: orbit-mcp, MACOSX_DEPLOYMENT_TARGET: "13.0" } }
```

Add the app target dependency and copy phase exactly:

```yaml
    dependencies:
      - target: AgentKit
      - target: OrbitMCP
        link: false
        embed: false
    postBuildScripts:
      - name: Embed Agent tools
        basedOnDependencyAnalysis: false
        script: |
          set -euo pipefail
          mkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS"
          cp "$BUILT_PRODUCTS_DIR/orbit-mcp" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/orbit-mcp"
          chmod +x "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/orbit-mcp"
```

Add `OrbitMCP: [build]` to the Orbit scheme. The `link: false` dependency guarantees the tool is built before the app's post-build script without linking it into the app.

- [ ] **Step 4: Run tests, build, and inspect the embedded binary**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentMCPTests`
Expected: PASS.
Run: `xcodebuild build -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/orbit-agent-dd`
Expected: BUILD SUCCEEDED.
Run: `test -x /tmp/orbit-agent-dd/Build/Products/Debug/Orbit.app/Contents/MacOS/orbit-mcp && echo embedded`
Expected: `embedded`.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/AgentKit/AgentMCP.swift orbit-app/OrbitMCP orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj orbit-app/OrbitTests/AgentMCPTests.swift
git commit -m "feat: add MCP bridge and tool catalog"
```

### Task 10: CLI skeleton

**Files:**
- Create: `orbit-app/AgentKit/AgentCLI.swift`
- Create: `orbit-app/AgentKit/AgentSessionFiles.swift`
- Create: `orbit-app/OrbitCLI/main.swift`
- Modify: `orbit-app/project.yml` (OrbitCLI target, scheme build, app copy script)
- Test: `orbit-app/OrbitTests/AgentCLITests.swift`

**Interfaces:**
- Produces: `AgentCLI.run(arguments:client:sessions:stdout:stderr:) throws`; `AgentSessionFileStore(directory:)` with `save/load/list/remove`; `orbit-cli` supports `auth`, `servers`, `exec` in Phase 1.
- `auth` creates a fresh session and writes a per-session file; `exec` requires a selected session.

- [ ] **Step 1: Write the failing CLI tests**

```swift
final class AgentCLITests: XCTestCase {
    func testServersPrintsJSONAfterAuth() throws {
        let client = FakeGatewayClient(admission: .approved(.init(sessionId: "s", token: "t")))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = AgentSessionFileStore(directory: dir)
        var out: [String] = []
        try AgentCLI.run(arguments: ["auth", "--client", "Claude Code"],
                         client: client, sessions: files,
                         stdout: { out.append($0) }, stderr: { _ in })
        try AgentCLI.run(arguments: ["servers", "--session", "s"],
                         client: client, sessions: files,
                         stdout: { out.append($0) }, stderr: { _ in })
        XCTAssertTrue(out.joined().contains("servers"))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("s.json").path
        )
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExecRequiresASession() throws {
        var err: [String] = []
        XCTAssertThrowsError(try AgentCLI.run(
            arguments: ["exec", "--server", "srv", "--", "ls"],
            client: FakeGatewayClient(), sessions: AgentSessionFileStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
            stdout: { _ in }, stderr: { err.append($0) }
        ))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentCLITests`
Expected: FAIL because the CLI does not exist.

- [ ] **Step 3: Implement the CLI**

`AgentCLI` parses `auth`, `servers`, `exec`; `auth` calls `client.hello`, writes `sessionId.json` containing credential+client name, prints the session id and `export ORBIT_AGENT_SESSION=...` (never the token); `servers` and `exec` load the selected session (or `--session`), call the client, and print JSON. Errors are human-readable on stderr and exit non-zero. Add the OrbitCLI target, add `OrbitCLI: [build]` to the Orbit scheme, add an app dependency with `link: false`, and add a copy line for `orbit-cli` to the Task 9 post-build script. Ensure the script fails if either tool is missing. Define `FakeGatewayClient` in the test file with the configured admission result and fixed JSON call results.

- [ ] **Step 4: Run tests, build, and inspect**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentCLITests`
Expected: PASS.
Run the Debug build and `test -x .../Orbit.app/Contents/MacOS/orbit-cli`.
Expected: both tools exist.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/AgentKit/AgentCLI.swift orbit-app/AgentKit/AgentSessionFiles.swift orbit-app/OrbitCLI orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj orbit-app/OrbitTests/AgentCLITests.swift
git commit -m "feat: add orbit agent CLI"
```

### Task 11: Settings pane, server exposure toggle, and app lifecycle

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentActivityView.swift`
- Modify: `orbit-app/Orbit/Agent/AgentGateway.swift` (add `shared`, `configure`)
- Modify: `orbit-app/Orbit/Views/MainView.swift` (configure/start the shared gateway)
- Modify: `orbit-app/Orbit/Views/SettingsView.swift`
- Modify: `orbit-app/Orbit/Views/ServerDialog.swift`
- Modify: `orbit-app/Orbit/AppDelegate.swift`
- Test: `orbit-app/OrbitTests/AgentLifecycleTests.swift`
- Modify: `orbit-app/OrbitUITests/OrbitUITests.swift`

**Interfaces:**
- Consumes: `AgentGateway.shared`, `AgentExposureStore.shared`, `AgentAuditStore.shared`, `AgentApprovalController.shared`.
- Produces: `AgentGateway.shared`, `AgentGateway.configure(execService:approval:audit:)`, `shouldTerminateAfterLastWindowClosed(activeAgentSessions: Int) -> Bool` pure helper; `SettingsCategory.agent`; `AgentPane`.

- [ ] **Step 1: Write the failing lifecycle test**

```swift
final class AgentLifecycleTests: XCTestCase {
    func testWindowCloseKeepsOrbitAliveOnlyWithActiveAgentSessions() {
        XCTAssertFalse(shouldTerminateAfterLastWindowClosed(activeAgentSessions: 1))
        XCTAssertTrue(shouldTerminateAfterLastWindowClosed(activeAgentSessions: 0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentLifecycleTests`
Expected: FAIL because the helper does not exist.

- [ ] **Step 3: Implement the settings and lifecycle**

Add the shared instances:
- `AgentGateway.shared` as a static singleton with no dependencies; `configure(execService:approval:audit:)` installs the real dependencies.
- `AgentExposureStore.shared = AgentExposureStore(defaults: .standard)`, `AgentAuditStore.shared = AgentAuditStore(logURL: AgentPaths.auditLogURL)`, `AgentApprovalController.shared = AgentApprovalController()`.

In `MainView.onAppear`, build `AgentExecService(transport: OrbitBridge.shared, inventory: { appState.servers }, exposure: AgentExposureStore.shared)` and call `AgentGateway.shared.configure(execService:approval:audit:)`; if `UserDefaults.standard.bool(forKey: "agentGatewayEnabled")` (default true when absent), call `start()`. On disappear/quit, call `stop()`.

Add `case agent` to `SettingsCategory` with an icon and a pane showing:
- master toggle `@AppStorage("agentGatewayEnabled")` that calls `start()`/`stop()`, with `.accessibilityIdentifier("agentGatewayEnabledToggle")`
- exposed server list with per-server toggles backed by `AgentExposureStore.shared`
- active sessions from `AgentGateway.shared.activeSessions` with a revoke button
- AI activity events from `AgentAuditStore.shared`
- MCP/CLI setup instructions with the bundled paths.

Add a `Toggle("允许 AI 访问", isOn:)` to `ServerDialog`, backed by `AgentExposureStore.shared` for the server being edited; for a new server, default on.

Add the pure lifecycle helper to `AppDelegate.swift`; change `applicationShouldTerminateAfterLastWindowClosed` to return the helper with `AgentGateway.shared.hasActiveSessions ? 1 : 0`. Implement `applicationShouldTerminate` to show an `NSAlert` when active sessions exist, returning `.terminateCancel` on cancel.

- [ ] **Step 4: Run tests and build**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentLifecycleTests`
Expected: PASS.
Run the Debug build; open Settings and verify the new category renders (manual screenshot or UI test in Task 12).

- [ ] **Step 5: Commit**

```bash
git add orbit-app/Orbit/Agent/AgentActivityView.swift orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/Orbit/Views/MainView.swift orbit-app/Orbit/Views/SettingsView.swift orbit-app/Orbit/Views/ServerDialog.swift orbit-app/Orbit/AppDelegate.swift orbit-app/OrbitTests/AgentLifecycleTests.swift orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent settings and lifecycle"
```

### Task 12: Phase 1 integration and verification

**Files:**
- Modify: `orbit-app/OrbitUITests/OrbitUITests.swift`
- Possibly create: `docs/agent-mcp-setup.md`
- No new production code unless an integration defect is found.

**Interfaces:**
- Consumes all Phase 1 components.

- [ ] **Step 1: Add a UI test for agent access settings**

```swift
func testAgentSettingsExposeGatewayControls() {
    let settings = openSettingsWindow()
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    XCTAssertTrue(settings.buttons["AI Agent"].waitForExistence(timeout: 5))
    settings.buttons["AI Agent"].click()
    XCTAssertTrue(app.switches["agentGatewayEnabledToggle"].waitForExistence(timeout: 5))
}
```

Add the `agentGatewayEnabledToggle` identifier in the settings pane.

- [ ] **Step 2: Run the UI test**

Run: `xcodebuild test -project orbit-app/Orbit.xcodeproj -scheme OrbitUITests -destination 'platform=macOS' -derivedDataPath /tmp/orbit-agent-dd -only-testing:OrbitUITests/OrbitUITests/testAgentSettingsExposeGatewayControls`
Expected: PASS.

- [ ] **Step 3: Run the end-to-end read-only smoke test**

Use the built Debug app and the embedded CLI:

```bash
APP=/tmp/orbit-agent-dd/Build/Products/Debug/Orbit.app
open "$APP"
"$APP/Contents/MacOS/orbit-cli" auth --client "Manual Check"
"$APP/Contents/MacOS/orbit-cli" servers --session <sessionId>
"$APP/Contents/MacOS/orbit-cli" exec --session <sessionId> --server 10.1.101.132 --mode read -- "docker ps"
```

Approve the admission in Orbit when prompted. Expected: `servers` lists the exposed server; `exec` returns `docker ps` output. Then run `orbit_exec` for `docker logs --tail 20 <container>` and verify the result. Configure Claude Code with `claude mcp add orbit -- "$APP/Contents/MacOS/orbit-mcp"` and verify `tools/list` includes only `orbit_list_servers` and `orbit_exec`.

- [ ] **Step 4: Run the full unit suite and Rust tests**

Run: `xcodebuild test -project orbit-app/Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -derivedDataPath /tmp/orbit-agent-dd`
Run: `cd orbit-rs && ~/.cargo/bin/cargo test --lib`
Run the real-server ignored tests with env vars:
`ORBIT_TEST_HOST=... ORBIT_TEST_USER=... ORBIT_TEST_PASSWORD=... ~/.cargo/bin/cargo test --lib -- --ignored --test-threads=1`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/OrbitUITests/OrbitUITests.swift docs/agent-mcp-setup.md
git commit -m "test: verify phase 1 agent gateway"
```

---

## Phase 2: Write Approval, Jobs, and Kill Switches

### Task 13: Read/write command guard

**Files:**
- Create: `orbit-app/AgentKit/AgentCommandGuard.swift`
- Test: `orbit-app/OrbitTests/AgentCommandGuardTests.swift`

**Interfaces:**
- Produces: `AgentGuardDecision`, `AgentCommandGuard.evaluate(command:declaredMode:)`.

- [ ] **Step 1: Write the failing guard tests**

```swift
final class AgentCommandGuardTests: XCTestCase {
    func testReadOnlyCommandsAreAllowed() {
        XCTAssertEqual(AgentCommandGuard.evaluate(command: "docker logs --tail 20 api", declaredMode: .read), .allowRead)
        XCTAssertEqual(AgentCommandGuard.evaluate(command: "grep ERROR /var/log/api.log | head -20", declaredMode: .read), .allowRead)
        XCTAssertEqual(AgentCommandGuard.evaluate(command: "systemctl status nginx", declaredMode: .read), .allowRead)
        XCTAssertEqual(AgentCommandGuard.evaluate(command: "docker exec api cat /app/config.yml", declaredMode: .read), .allowRead)
    }

    func testWritePatternsRequireWriteGrant() {
        for command in ["rm -rf /tmp/x", "echo x > /tmp/y", "sed -i s/a/b/ f", "docker restart api", "bash -c 'rm x'"] {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
    }

    func testWriteDeclaredAlwaysRequiresGrant() {
        guard case .requireWrite = AgentCommandGuard.evaluate(command: "ls", declaredMode: .write) else {
            return XCTFail("declared write must require grant")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentCommandGuardTests`
Expected: FAIL because the guard does not exist.

- [ ] **Step 3: Implement the guard**

Implement the rules from the spec: declared `.write` always requires a grant; `.read` allows only commands whose segments do not contain write redirections or mutating binaries; `docker exec` parses the inner command after the container argument; `docker exec -it` requires write; unknown/unparseable commands require write. Reasons must be short and safe to show in the approval panel.

- [ ] **Step 4: Run and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentCommandGuardTests`
Expected: PASS.

```bash
git add orbit-app/AgentKit/AgentCommandGuard.swift orbit-app/OrbitTests/AgentCommandGuardTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent read/write command guard"
```

### Task 14: Write grant flow and approval UI

**Files:**
- Modify: `orbit-app/Orbit/Agent/AgentGateway.swift`
- Modify: `orbit-app/Orbit/Agent/AgentApprovalController.swift`
- Modify: `orbit-app/Orbit/Agent/AgentApprovalView.swift`
- Test: `orbit-app/OrbitTests/AgentGatewayTests.swift`

**Interfaces:**
- Gateway now accepts `orbit_exec` with `mode: write`; on the first write for `(sessionId, serverId)`, calls `approval.requestWrite` (5s wait), then returns `pending_approval` or executes.
- `orbit_approval_status` returns pending/approved/denied.

- [ ] **Step 1: Write the failing write-grant test**

```swift
func testFirstWriteRequiresApprovalThenReusesGrant() async throws {
    let approver = FakeApprover(result: true)
    let gateway = makeGateway(approver: approver)
    let session = try await approveSession(gateway)
    let first = await gateway.handle(callRequest(id: "1", session: session,
        args: ["server": .string("srv"), "command": .string("rm x"), "mode": .string("write")]))
    XCTAssertTrue(first.ok)
    let second = await gateway.handle(callRequest(id: "2", session: session,
        args: ["server": .string("srv"), "command": .string("rm y"), "mode": .string("write")]))
    XCTAssertTrue(second.ok)
    XCTAssertEqual(approver.writeCount, 1)
}
```

Define `approveSession(_:)` (hello + approved session) and `callRequest(id:session:args:)` helpers in `AgentGatewayTests`; Task 17 reuses them. `FakeExecService.listServers()` must return a server with id `srv`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests/testFirstWriteRequiresApprovalThenReusesGrant`
Expected: FAIL because write mode is not implemented.

- [ ] **Step 3: Implement the write flow**

Before executing a write, resolve the server, check `sessions.hasWriteGrant`. If absent, create a write approval request, call `approval.requestWrite` with a 5-second wait; on timeout return `pending_approval`; on deny return `write_denied`; on approve store the grant, touch the session, execute, and audit. The approval panel shows the command and the server; the same session's later writes to that server skip the prompt. The guard applies to read-mode calls before dispatch; a guard escalation triggers the same write path.

- [ ] **Step 4: Run the gateway tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/Orbit/Agent/AgentApprovalController.swift orbit-app/Orbit/Agent/AgentApprovalView.swift orbit-app/OrbitTests/AgentGatewayTests.swift
git commit -m "feat: add session-scoped write approval"
```

### Task 15: Rust job registry and FFI

**Files:**
- Modify: `orbit-rs/src/agent/mod.rs`
- Modify: `orbit-rs/src/ffi.rs`
- Regenerate: `orbit-rs/include/orbit.h`
- Test: `orbit-rs/src/agent/mod.rs` (unit + ignored real-server)

**Interfaces:**
- `AgentJob` stores status, output buffer, cursor, exit code, timestamps.
- FFI: `orbit_agent_job_status`, `orbit_agent_job_output`, `orbit_agent_job_cancel`.
- `orbit_agent_exec` now honors `wait_ms`: if the command is still running, returns `status: "running"` + `jobId`.

- [ ] **Step 1: Write the failing job buffer test**

```rust
#[test]
fn job_output_cursor_returns_only_new_bytes() {
    let mut buf = AgentOutputBuffer::new(16);
    buf.push(b"hello");
    buf.push(b" world");
    let (chunk, cursor) = buf.read(from: 0);
    assert_eq!(chunk, "hello world");
    let (tail, _) = buf.read(from: cursor);
    assert_eq!(tail, "");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd orbit-rs && ~/.cargo/bin/cargo test --lib agent::tests::job_output_cursor_returns_only_new_bytes`
Expected: FAIL because the buffer does not exist.

- [ ] **Step 3: Implement the job registry and FFI**

Start a worker thread per job that acquires a session and runs the command, appends stdout/stderr to a capped buffer, and records completion. `orbit_agent_exec` starts the job, waits up to `wait_ms`, and returns either the completed result or a running status with the job id. Job output uses a byte cursor and respects the same truncation limit. Cancel closes the channel and marks the status. Store jobs in `OrbitApp`; clean up on cancel/session shutdown.

- [ ] **Step 4: Run unit tests and the ignored real-server job test**

Run: `cd orbit-rs && ~/.cargo/bin/cargo test --lib agent::tests`
Run: `ORBIT_TEST_HOST=... ORBIT_TEST_USER=... ORBIT_TEST_PASSWORD=... ~/.cargo/bin/cargo test --lib -- --ignored --test-threads=1`
Expected: PASS, including a `sleep 2; echo done` job that is polled to completion.

- [ ] **Step 5: Commit**

```bash
git add orbit-rs/src/agent orbit-rs/src/ffi.rs orbit-rs/include/orbit.h
git commit -m "feat: add agent job registry"
```

### Task 16: Swift job manager, idempotency, and job tools

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentJobManager.swift`
- Modify: `orbit-app/Orbit/Agent/AgentExecService.swift`
- Modify: `orbit-app/Orbit/OrbitBridge.swift`
- Modify: `orbit-app/Orbit/Agent/AgentGateway.swift`
- Modify: `orbit-app/AgentKit/AgentMCP.swift`
- Test: `orbit-app/OrbitTests/AgentJobManagerTests.swift`
- Modify: `orbit-app/OrbitTests/AgentMCPTests.swift`

**Interfaces:**
- `AgentJobManager` tracks `jobId -> AgentJobStatus` and calls the transport for polls/cancel.
- `AgentExecService` keeps a per-session `idempotencyKey -> jobId` map with a 60-second window; repeated write calls return the existing job.
- MCP catalog adds `orbit_job_status`, `orbit_job_output`, `orbit_job_cancel`, `orbit_approval_status`.

- [ ] **Step 1: Write the failing job/idempotency tests**

```swift
func testDuplicateWriteWithSameIdempotencyKeyDoesNotStartSecondJob() async throws {
    let transport = FakeExecTransport()
    let service = AgentExecService(transport: transport, inventory: { [.fixture(id: "srv")] },
                                   exposure: AgentExposureStore(defaults: UserDefaults(suiteName: "job-\(UUID())")!))
    let request = AgentExecRequest(serverQuery: "srv", command: "sleep 5",
                                   mode: .write, timeoutMs: 60_000, waitMs: 1,
                                   maxOutputBytes: 1024, idempotencyKey: "k1")
    let first = try await service.exec(request)
    let second = try await service.exec(request)
    XCTAssertEqual(first.jobId, second.jobId)
    XCTAssertEqual(transport.startCount, 1)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentJobManagerTests`
Expected: FAIL because the job manager/idempotency does not exist.

- [ ] **Step 3: Implement job dispatch and tools**

`OrbitBridge` exposes async wrappers for the job FFI. `AgentJobManager` polls on demand (no background timer required) and returns JSON. The gateway routes the four new tools with token validation and job ownership checks. The MCP catalog adds the tool definitions; `orbit_exec` now passes `waitMs` and returns running jobs. Write jobs require the write grant before starting; approval status is returned by `orbit_approval_status`.

- [ ] **Step 4: Run tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentJobManagerTests -only-testing:OrbitTests/AgentMCPTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentJobManager.swift orbit-app/Orbit/Agent/AgentExecService.swift orbit-app/Orbit/OrbitBridge.swift orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/AgentKit/AgentMCP.swift orbit-app/OrbitTests/AgentJobManagerTests.swift orbit-app/OrbitTests/AgentMCPTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add agent job polling and idempotency"
```

### Task 17: Kill switches and active session management

**Files:**
- Modify: `orbit-app/Orbit/Agent/AgentGateway.swift`
- Modify: `orbit-app/AgentKit/AgentExposureStore.swift`
- Modify: `orbit-app/Orbit/Views/SettingsView.swift`
- Modify: `orbit-app/Orbit/Agent/AgentExecService.swift`
- Test: `orbit-app/OrbitTests/AgentGatewayTests.swift` (add kill-switch tests)

**Interfaces:**
- `AgentGateway.stop()` revokes all sessions and stops the socket.
- `AgentGateway.applyServerExposureChange(serverId:enabled:)` calls `execService.cancelJobs(serverId:)`, closes shells, and `sessions.revokeServer(serverId:)` when disabled.
- Settings master toggle off calls `AgentGateway.shared.stop()`; on calls `start()`.

- [ ] **Step 1: Write the failing kill-switch tests**

```swift
func testDisablingServerRevokesWriteGrantAndRejectsCalls() async throws {
    let gateway = makeGateway(approver: FakeApprover(result: true), servers: [.fixture(id: "srv")])
    let session = try await approveSession(gateway)
    _ = await gateway.handle(callRequest(id: "1", session: session,
        args: ["server": .string("srv"), "command": .string("rm x"), "mode": .string("write")]))
    gateway.applyServerExposureChange(serverId: "srv", enabled: false)
    let response = await gateway.handle(callRequest(id: "2", session: session,
        args: ["server": .string("srv"), "command": .string("ls"), "mode": .string("read")]))
    XCTAssertEqual(response.error?.code, .serverNotExposed)
    XCTAssertFalse(gateway.sessions.hasWriteGrant(sessionId: session.sessionId, serverId: "srv"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests/testDisablingServerRevokesWriteGrantAndRejectsCalls`
Expected: FAIL because exposure changes do not notify the gateway.

- [ ] **Step 3: Implement kill switches and session UI**

Wire the settings master toggle and per-server toggles to the gateway. On global off: stop the gateway, revoke all sessions, cancel all jobs, close all shells, clear approval windows. On server off: immediate job cancel + shell close + grant revoke; keep other servers alive. The settings pane lists active sessions with agent name, created time, and a revoke button. Audit each switch action.

- [ ] **Step 4: Run tests and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentGatewayTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/AgentKit/AgentExposureStore.swift orbit-app/Orbit/Views/SettingsView.swift orbit-app/Orbit/Agent/AgentExecService.swift orbit-app/OrbitUITests/OrbitUITests.swift
git commit -m "feat: add agent kill switches and session revocation"
```

### Task 18: Phase 2 integration and write smoke test

**Files:**
- Modify: `orbit-app/OrbitUITests/OrbitUITests.swift`
- Docs: `docs/agent-mcp-setup.md`

- [ ] **Step 1: Add a UI test for the write approval panel**

Use the QA-only `orbit-cli` flow: launch the app, run `orbit-cli exec --mode write` via `Process`, wait for the approval panel, click “允许本会话写操作”, and assert the command result appears in the CLI process output. Use a harmless command (`echo write-ok`).

- [ ] **Step 2: Run the UI test and full suites**

Run: `xcodebuild test -project orbit-app/Orbit.xcodeproj -scheme OrbitUITests ... -only-testing:OrbitUITests/OrbitUITests/testAgentWriteApproval`
Run: the full Swift unit suite and Rust unit + ignored real-server tests.
Expected: all pass.

- [ ] **Step 3: Real-server write smoke test**

With env-provided credentials, run `docker ps`, then `docker restart` on a disposable test container only after approval, then verify `docker ps`; run a `sleep 3; echo done` write as a job and poll it. Do not run destructive commands on shared servers.

- [ ] **Step 4: Commit**

```bash
git add orbit-app/OrbitUITests/OrbitUITests.swift docs/agent-mcp-setup.md
git commit -m "test: verify phase 2 agent writes and jobs"
```

---

## Phase 3: Persistent Shells

### Task 19: Shell sentinel parser

**Files:**
- Create: `orbit-app/AgentKit/AgentShellSentinel.swift`
- Test: `orbit-app/OrbitTests/AgentShellSentinelTests.swift`

- [ ] **Step 1: Write the failing sentinel tests**

```swift
final class AgentShellSentinelTests: XCTestCase {
    func testParsesOutputAndExitCodeAcrossChunks() {
        let sentinel = AgentShellSentinel(uuid: "abc")
        var buffer = "line1\nline2\n"
        XCTAssertNil(sentinel.consume(buffer: &buffer))
        buffer += "__ORBIT_DONE_abc__7\n"
        let result = sentinel.consume(buffer: &buffer)
        XCTAssertEqual(result, AgentShellCommandResult(output: "line1\nline2", exitCode: 7))
        XCTAssertEqual(buffer, "")
    }

    func testMarkerInsideOutputDoesNotCollideWithFullLine() {
        let sentinel = AgentShellSentinel(uuid: "abc")
        var buffer = "prefix __ORBIT_DONE_abc__0 suffix\n__ORBIT_DONE_abc__3\n"
        XCTAssertEqual(sentinel.consume(buffer: &buffer)?.exitCode, 3)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentShellSentinelTests`
Expected: FAIL because the sentinel does not exist.

- [ ] **Step 3: Implement `AgentShellSentinel`**

`commandSuffix()` returns `printf '\n__ORBIT_DONE_<uuid>__%s\n' "$?"`. `consume` removes everything through the marker line, trims the leading newline inserted by the suffix, and returns the output plus exit code. Only a full-line marker matches.

- [ ] **Step 4: Run and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentShellSentinelTests`
Expected: PASS.

```bash
git add orbit-app/AgentKit/AgentShellSentinel.swift orbit-app/OrbitTests/AgentShellSentinelTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add shell completion sentinel"
```

### Task 20: Shell manager and gateway shell tools

**Files:**
- Create: `orbit-app/Orbit/Agent/AgentShellManager.swift`
- Modify: `orbit-app/Orbit/Agent/AgentGateway.swift`
- Modify: `orbit-app/AgentKit/AgentMCP.swift`
- Test: `orbit-app/OrbitTests/AgentShellManagerTests.swift`
- Test: `orbit-app/OrbitTests/AgentGatewayTests.swift` (shell tool routing)

**Interfaces:**
- `AgentShellManager` uses a protocol `AgentShellTransport`:
  ```swift
  protocol AgentShellTransport {
      func connect(serverId: String) async throws -> String // base session id
      func openShell(baseSessionId: String) async throws -> String
      func write(shellId: String, data: Data) throws
      func close(shellId: String) async
      func setOutputHandler(shellId: String, handler: @escaping (Data) -> Void)
  }
  ```
  `OrbitBridge` conforms using `connectSSHAsync`, `spawnChannelAsync`, `writeSSH`, `disconnectSSHAsync`, and `setSSHHandlers`.
- `AgentShellManager.init(transport:sessions:)`, `public var sessions: AgentSessionStore`, `open(serverId:sessionId:)` (requires a write grant; returns `shellId`), `exec(shellId:command:timeout:)` (writes the sentinel suffix and waits for the parser), and `close(shellId:)` (disconnects the channel).

- [ ] **Step 1: Write the failing shell manager test**

```swift
func testShellExecReturnsOutputAndExitCode() async throws {
    let transport = FakeShellTransport()
    let manager = AgentShellManager(transport: transport, sessions: AgentSessionStore())
    let session = manager.sessions.createSession(agentName: "Claude Code")
    manager.sessions.grantWrite(sessionId: session.sessionId, serverId: "srv")
    let shellId = try await manager.open(serverId: "srv", sessionId: session.sessionId)
    let result = try await manager.exec(shellId: shellId, command: "echo hi", timeout: 2)
    XCTAssertEqual(result.output, "hi")
    XCTAssertEqual(result.exitCode, 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentShellManagerTests`
Expected: FAIL because the manager does not exist.

- [ ] **Step 3: Implement the shell manager and tools**

Open a base SSH session per server via `connectSSHAsync`, then `spawnChannelAsync` for the shell; register an output handler that appends to a per-shell buffer. `exec` writes `command + "\n" + sentinel.commandSuffix()`, waits for the marker up to 50 seconds, returns output/exit code, and updates session activity. `close` disconnects the shell channel; on session revoke/kill switch/app quit, close all shells and disconnect base sessions. Gateway tools: `orbit_shell_open` (write grant required), `orbit_shell_exec`, `orbit_shell_close`. MCP catalog adds them. Shell IDs are per-session and checked for ownership.

- [ ] **Step 4: Run tests, build, and commit**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentShellManagerTests -only-testing:OrbitTests/AgentGatewayTests`
Expected: PASS.

```bash
git add orbit-app/Orbit/Agent/AgentShellManager.swift orbit-app/Orbit/Agent/AgentGateway.swift orbit-app/AgentKit/AgentMCP.swift orbit-app/OrbitTests/AgentShellManagerTests.swift orbit-app/OrbitTests/AgentGatewayTests.swift orbit-app/project.yml orbit-app/Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add persistent agent shells"
```

### Task 21: CLI shell subcommands and final verification

**Files:**
- Modify: `orbit-app/AgentKit/AgentCLI.swift`
- Modify: `orbit-app/OrbitCLI/main.swift`
- Test: `orbit-app/OrbitTests/AgentCLITests.swift`
- Docs: `docs/agent-mcp-setup.md`

- [ ] **Step 1: Write the failing CLI shell test**

```swift
func testShellOpenExecCloseWritesJSON() throws {
    let client = FakeGatewayClient()
    // Fake returns shell ids; assert CLI parses --server/--session and prints JSON.
    try AgentCLI.run(arguments: ["shell", "open", "--server", "srv", "--session", "s"],
                     client: client, sessions: fakeSessions,
                     stdout: { out.append($0) }, stderr: { _ in })
    XCTAssertTrue(out.joined().contains("shellId"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:OrbitTests/AgentCLITests`
Expected: FAIL because the shell subcommands do not exist.

- [ ] **Step 3: Implement CLI shell subcommands and docs**

Add `orbit-cli shell open --server <q>`, `shell exec --shell <id> -- <command>`, and `shell close --shell <id>`. Update `docs/agent-mcp-setup.md` with Claude Code, Codex, and DeepSeek Harness configuration, the admission flow, and troubleshooting. Ensure CLI errors never print tokens.

- [ ] **Step 4: Run all verification**

Run: the full Swift unit suite, OrbitUITests (including real-server tests), Rust unit + ignored real-server tests, `make build-app`, and a manual Claude Code/Codex smoke test:
1. Approve admission.
2. `orbit_exec` `docker ps`, `docker logs`.
3. Write approval for `echo done`.
4. Long job `sleep 3; echo done` polled to completion.
5. `orbit_shell_open` + `orbit_shell_exec` `docker exec -it <container> sh` (or a `pwd`/`ls` check) and close.
6. Disable the server toggle and confirm the next call is rejected and the shell is gone.
Expected: all pass; no credentials/token in output or audit.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/AgentKit/AgentCLI.swift orbit-app/OrbitCLI/main.swift orbit-app/OrbitTests/AgentCLITests.swift docs/agent-mcp-setup.md
git commit -m "feat: add CLI shells and agent setup docs"
```

---

## Self-Review Checklist

- Every spec section has a task: admission/token (Tasks 4, 6, 7), server exposure (5, 11, 17), generic exec (1, 8), no container tools (9 catalog test, 13 guard), jobs (15, 16), lifecycle (11), audit (7), CLI (10, 21), shells (19, 20), kill switches (17), trust/signing (Task 9/10 packaging + Task 7 path display), idle/ping (Task 4).
- All task interfaces use the Shared Interfaces names.
- Every task starts with a failing test (or a concrete verification for integration tasks) and ends with a commit.
- The plan deliberately has no dedicated `orbit_list_containers`, `orbit_docker_logs`, or container-shell tools.
