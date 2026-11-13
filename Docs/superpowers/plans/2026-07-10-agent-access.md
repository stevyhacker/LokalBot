# Agent Access Surface (CLI + Skill + MCP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `Docs/superpowers/specs/2026-07-10-agent-access-design.md` (approved). **Branch:** `agent-access`.

**Goal:** Ship "one library, three doors": an MCP stdio server inside the existing `lokalbot-cli` (tools `list_meetings`, `get_meeting`, `search_meetings`, `ask_library`), gated by a new Privacy toggle, plus a rewritten agent skill with an `install-skill` subcommand and a `.mcpb` bundle for GUI clients.

**Architecture:** All protocol/tool logic lives in `LokalBot/CLISupport/` (compiled into BOTH the app and the CLI, so hosted unit tests reach it via `@testable import LokalBot`). Thin ArgumentParser commands live in `CLI/Commands/`. The MCP layer is hand-rolled minimal JSON-RPC 2.0 (three methods) behind a `LibraryToolProvider` seam. `ask_library` talks HTTP to the app's llama-server on `127.0.0.1:17872` and wakes it through marker files under `<storage root>/control/`, watched app-side by a new `AgentAccessManager`.

**Tech Stack:** Swift 5.10, Foundation only (no new dependencies), XCTest (hosted in the prod app binary), swift-argument-parser (already a CLI dependency), XcodeGen, bash for scripts.

## Global Constraints

- **Nothing leaves the Mac.** No new network listeners; the CLI only *connects* to `127.0.0.1:17872`. No telemetry, no cloud calls.
- **Read-only library invariant:** no tool writes into `meetings/`, `journal/`, or the SQLite DB. The only writes anywhere are the marker files under `<storage root>/control/`.
- **No new SPM dependencies** — especially not in the signed `lokalbot-cli` helper. The MCP layer is hand-rolled.
- **`LokalBot/CLISupport/` files may only import Foundation (+ os) and use the four shared Models files** (`Meeting.swift`, `Transcript.swift`, `AppIdentifiers.swift`, `AppDirectories.swift`) — anything else breaks the `lokalbot-cli` target build. App-only types (`LlamaServer`, `ModelCatalog`, `AppSettings`, `StorageManager`) are usable only under `LokalBot/` outside CLISupport.
- The `.xcodeproj` is generated: after ANY file add/move, run `xcodegen generate` before building. Never edit the `.xcodeproj` by hand.
- Unit tests: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/<ClassName>` (scheme **LokalBot**, not "LokalBot Dev"). Running tests regenerates `default.profraw` — it is gitignored; **never commit it**.
- Test files live flat in `LokalBotTests/` named `<Thing>Tests.swift`, XCTest style, `@testable import LokalBot`. Temp-library tests use the established `setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)` + `defer { unsetenv(...) }` pattern (see `ChatAgentTests.swift:304`).
- Exact protocol constants: main llama-server port **17872** (`LlamaServer.shared`; 17873 embedder, 17874 cotyping — don't touch). Marker files: `control/agent-access-enabled`, `control/agent-wake`, `control/agent-wake-error`. Wake poll: **60 × 1 s**. Snippet cap: **12**. serverInfo name **`lokalbot`**, version from the enclosing app bundle's `Contents/Info.plist` (two levels up from `Contents/Helpers/`), fallback `"dev"`.
- Toggle copy (verbatim, spec §6): **"Allow external agents to read your meeting library"** — default off.
- Error codes (spec §9): `access_disabled`, `app_not_running`, `engine_unavailable`, `model_loading_timeout`, `meeting_not_found`, `ambiguous_id` (plus internal `unknown_tool`, `invalid_arguments`).
- Commit style: imperative, no prefixes (match `git log`), each ending with the trailer line:
  `Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW`

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `LokalBot/CLISupport/MCPProtocol.swift` | create | `JSONValue`, `MCPRequest` (parse), `MCPResponse` (encode). Pure codec, no I/O |
| `LokalBot/CLISupport/LibraryToolProvider.swift` | create | `ToolDefinition`, `ToolResult`, `ToolErrorCode`, `protocol LibraryToolProvider` — the seam |
| `LokalBot/CLISupport/MCPDispatcher.swift` | create | Routes `initialize` / `tools/list` / `tools/call` / `ping`; JSON-RPC errors |
| `LokalBot/CLISupport/AgentAccessGate.swift` | create | Marker-file truth: access toggle, wake file, wake-error file |
| `LokalBot/CLISupport/LibrarySearch.swift` | create | The substring search walk, extracted from `SearchCommand` |
| `LokalBot/CLISupport/FileLibraryToolProvider.swift` | create | v1 provider: read tools over the on-disk library + gate + injected ask |
| `LokalBot/CLISupport/AskLibraryContext.swift` | create | Pure retrieval: search terms, context text, citations, prompt messages |
| `LokalBot/CLISupport/AskLibraryEngine.swift` | create | ask flow: gate → health → wake → poll → complete; `LlamaChatClient` seam |
| `LokalBot/CLISupport/HelperVersion.swift` | create | serverInfo version from `Contents/Info.plist` two levels up |
| `LokalBot/CLISupport/LokalBotCLIInstaller.swift` | move+extend | moved from `LokalBot/Services/`; gains `~/.claude/skills` link, copy mode, CLI factory |
| `CLI/Commands/MCPCommand.swift` | create | stdio read-eval loop |
| `CLI/Commands/InstallSkillCommand.swift` | create | `install-skill` / `--copy` / `--uninstall` |
| `CLI/LokalBotCLI.swift` | modify | register the two new subcommands |
| `CLI/Commands/SearchCommand.swift` | modify | delegate to `LibrarySearch` |
| `LokalBot/Services/AgentAccessManager.swift` | create | app-side toggle owner + `control/` wake watcher + `ensureRunning` |
| `LokalBot/LokalBotApp.swift` | modify | `AppState.agentAccess` property + `start()` at launch |
| `LokalBot/Views/SettingsView.swift` | modify | Privacy toggle row |
| `.agents/skills/lokalbot-cli/SKILL.md` | rewrite | fix stale bundle id, add MCP/ask_library guidance |
| `Scripts/release/build-mcpb.sh` | create | `.mcpb` bundle for releases |
| `Scripts/test/e2e.sh` | modify | T11: MCP session against the fixture library |
| `CLAUDE.md` | modify | one-line CLI paragraph update |
| `LokalBotTests/MeetingFixture.swift` + 9 test files | create | see tasks |

---

### Task 1: JSON-RPC wire codec (`MCPProtocol.swift`)

**Files:**
- Create: `LokalBot/CLISupport/MCPProtocol.swift`
- Test: `LokalBotTests/MCPProtocolTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `JSONValue` (enum: `.null/.bool/.number/.string/.array/.object`, `Codable`, `Equatable`, literal-expressible, accessors `stringValue`, `intValue`, `objectValue`, `subscript(key:)`); `MCPRequest` (`id: MCPRequest.ID?` where `ID` is `.number(Int)`/`.string(String)` with `var json: JSONValue`, `method: String`, `params: JSONValue?`, `static func parse(_ line: String) -> ParseOutcome` with `ParseOutcome` = `.request(MCPRequest)` / `.failure(code: Int, message: String, id: ID?)`); `MCPResponse.success(id:result:) -> String` and `MCPResponse.failure(id:code:message:) -> String` (single-line JSON, sorted keys).

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/MCPProtocolTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class MCPProtocolTests: XCTestCase {

    // MARK: - parsing

    func testParsesRequestWithNumberID() {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.id, .number(1))
        XCTAssertEqual(request.method, "tools/list")
        XCTAssertNil(request.params)
    }

    func testParsesRequestWithStringIDAndParams() {
        let line = #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"list_meetings"}}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.id, .string("abc"))
        XCTAssertEqual(request.params?["name"]?.stringValue, "list_meetings")
    }

    func testNotificationHasNilID() {
        let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertNil(request.id)
    }

    func testMalformedJSONIsParseError() {
        guard case .failure(let code, _, let id) = MCPRequest.parse("{nope") else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32700)
        XCTAssertNil(id)
    }

    func testMissingMethodIsInvalidRequestEchoingID() {
        guard case .failure(let code, _, let id) = MCPRequest.parse(#"{"jsonrpc":"2.0","id":7}"#) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32600)
        XCTAssertEqual(id, .number(7))
    }

    func testWrongJSONRPCVersionIsInvalidRequest() {
        guard case .failure(let code, _, _) = MCPRequest.parse(#"{"jsonrpc":"1.0","id":1,"method":"x"}"#) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32600)
    }

    // MARK: - encoding

    func testSuccessResponseIsSingleLineWithSortedKeys() {
        let line = MCPResponse.success(id: .number(3), result: .object(["ok": .bool(true)]))
        XCTAssertEqual(line, #"{"id":3,"jsonrpc":"2.0","result":{"ok":true}}"#)
        XCTAssertFalse(line.contains("\n"))
    }

    func testErrorResponseWithNullID() {
        let line = MCPResponse.failure(id: nil, code: -32700, message: "Parse error")
        XCTAssertEqual(line, #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
    }

    func testIntegersSurviveTheJSONValueRoundTrip() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"limit":12}"#.utf8))
        XCTAssertEqual(value["limit"]?.intValue, 12)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"limit":12}"#)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/MCPProtocolTests 2>&1 | tail -5
```

Expected: build FAILS with "cannot find 'MCPRequest' in scope" (compile error counts as the red step here — the types don't exist yet).

- [ ] **Step 3: Write the implementation**

Create `LokalBot/CLISupport/MCPProtocol.swift`:

```swift
import Foundation

/// Minimal JSON model for JSON-RPC params, results, and tool schemas.
/// Codable so a whole response tree encodes in one pass; the literal
/// conformances keep dispatcher code and tool schemas readable.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            // Whole numbers encode as integers so ids and limits round-trip
            // without a spurious ".0" on the wire.
            if n == n.rounded(), abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }
}

/// One decoded JSON-RPC 2.0 message from an MCP client.
struct MCPRequest: Equatable {
    enum ID: Equatable {
        case number(Int)
        case string(String)

        var json: JSONValue {
            switch self {
            case .number(let n): return .number(Double(n))
            case .string(let s): return .string(s)
            }
        }
    }

    /// nil = notification: the server must not answer it.
    var id: ID?
    var method: String
    var params: JSONValue?

    enum ParseOutcome: Equatable {
        case request(MCPRequest)
        /// Protocol-level failure to answer with a JSON-RPC error object.
        case failure(code: Int, message: String, id: ID?)
    }

    /// Decode one stdio line. JSON-RPC 2.0 error codes: -32700 parse error,
    /// -32600 invalid request (id echoed when it was readable).
    static func parse(_ line: String) -> ParseOutcome {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let object = raw.objectValue else {
            return .failure(code: -32700, message: "Parse error", id: nil)
        }
        let id: ID?
        switch object["id"] {
        case .some(.number(let n)): id = .number(Int(n))
        case .some(.string(let s)): id = .string(s)
        default: id = nil
        }
        guard case .some(.string("2.0")) = object["jsonrpc"],
              case .some(.string(let method)) = object["method"] else {
            return .failure(code: -32600, message: "Invalid Request", id: id)
        }
        return .request(MCPRequest(id: id, method: method, params: object["params"]))
    }
}

/// Encodes JSON-RPC 2.0 responses as single-line JSON — the newline-delimited
/// framing MCP stdio transport expects. Sorted keys keep golden-transcript
/// tests deterministic.
enum MCPResponse {
    static func success(id: MCPRequest.ID?, result: JSONValue) -> String {
        encode(.object(["jsonrpc": "2.0", "id": id?.json ?? .null, "result": result]))
    }

    static func failure(id: MCPRequest.ID?, code: Int, message: String) -> String {
        encode(.object(["jsonrpc": "2.0", "id": id?.json ?? .null,
                        "error": .object(["code": .number(Double(code)),
                                          "message": .string(message)])]))
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Regenerate the project and run the test**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/MCPProtocolTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (9 tests).

- [ ] **Step 5: Verify the CLI target still builds** (CLISupport compiles into it too)

```bash
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add LokalBot/CLISupport/MCPProtocol.swift LokalBotTests/MCPProtocolTests.swift
git commit -m "$(cat <<'EOF'
Add JSON-RPC 2.0 wire codec for the MCP server

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 2: Tool seam + method dispatcher

**Files:**
- Create: `LokalBot/CLISupport/LibraryToolProvider.swift`
- Create: `LokalBot/CLISupport/MCPDispatcher.swift`
- Test: `LokalBotTests/MCPDispatcherTests.swift`

**Interfaces:**
- Consumes: `JSONValue`, `MCPRequest`, `MCPResponse` (Task 1).
- Produces: `ToolDefinition{name, description, inputSchema, var json: JSONValue}`; `ToolErrorCode` (String enum, cases `accessDisabled="access_disabled"`, `appNotRunning="app_not_running"`, `engineUnavailable="engine_unavailable"`, `modelLoadingTimeout="model_loading_timeout"`, `meetingNotFound="meeting_not_found"`, `ambiguousID="ambiguous_id"`, `unknownTool="unknown_tool"`, `invalidArguments="invalid_arguments"`); `ToolResult{text, isError}` with `static func text(_:)`, `static func error(_ code:_ message:)` (text format `[code] message`), `var json: JSONValue`; `protocol LibraryToolProvider { var tools: [ToolDefinition] { get }; func call(name: String, arguments: JSONValue?) async -> ToolResult }`; `MCPDispatcher{provider, serverVersion, func handle(line: String) async -> String?}` (nil = notification), `MCPDispatcher.supportedProtocolVersions`.

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/MCPDispatcherTests.swift`:

```swift
import XCTest
@testable import LokalBot

private struct StubToolProvider: LibraryToolProvider {
    var tools: [ToolDefinition] {
        [ToolDefinition(name: "echo", description: "echoes text back",
                        inputSchema: .object(["type": "object"]))]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        guard name == "echo" else { return .error(.unknownTool, "no tool named \(name)") }
        return .text("echo:" + (arguments?["text"]?.stringValue ?? ""))
    }
}

final class MCPDispatcherTests: XCTestCase {
    private var dispatcher: MCPDispatcher {
        MCPDispatcher(provider: StubToolProvider(), serverVersion: "1.2.3")
    }

    func testInitializeEchoesKnownProtocolVersionAndServerInfo() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains(#""protocolVersion":"2024-11-05""#), response!)
        XCTAssertTrue(response!.contains(#""name":"lokalbot""#), response!)
        XCTAssertTrue(response!.contains(#""version":"1.2.3""#), response!)
        XCTAssertTrue(response!.contains(#""tools":{}"#), response!)
    }

    func testInitializeWithUnknownVersionAnswersOurNewest() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"9999-01-01"}}"#)
        XCTAssertTrue(response!.contains(#""protocolVersion":"2025-06-18""#), response!)
    }

    func testNotificationGetsNoResponse() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testToolsListIncludesProviderTools() async {
        let response = await dispatcher.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertTrue(response!.contains(#""name":"echo""#), response!)
        XCTAssertTrue(response!.contains(#""inputSchema""#), response!)
    }

    func testToolsCallRoutesToProvider() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        XCTAssertTrue(response!.contains("echo:hi"), response!)
        XCTAssertTrue(response!.contains(#""isError":false"#), response!)
    }

    func testToolErrorEncodesIsErrorTrueWithCode() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"missing"}}"#)
        XCTAssertTrue(response!.contains(#""isError":true"#), response!)
        XCTAssertTrue(response!.contains("[unknown_tool]"), response!)
    }

    func testToolsCallWithoutNameIsInvalidParams() async {
        let response = await dispatcher.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call"}"#)
        XCTAssertTrue(response!.contains("-32602"), response!)
    }

    func testUnknownMethodIsMethodNotFound() async {
        let response = await dispatcher.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertTrue(response!.contains("-32601"), response!)
    }

    func testMalformedLineGetsParseErrorResponse() async {
        let response = await dispatcher.handle(line: "not json")
        XCTAssertTrue(response!.contains("-32700"), response!)
    }

    func testPingAnswersEmptyResult() async {
        let response = await dispatcher.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        XCTAssertEqual(response, #"{"id":6,"jsonrpc":"2.0","result":{}}"#)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/MCPDispatcherTests 2>&1 | tail -5
```

Expected: build FAILS — "cannot find type 'LibraryToolProvider' in scope".

- [ ] **Step 3: Write the implementation**

Create `LokalBot/CLISupport/LibraryToolProvider.swift`:

```swift
import Foundation

/// One tool as advertised by `tools/list`.
struct ToolDefinition {
    var name: String
    var description: String
    /// JSON Schema for the tool's arguments.
    var inputSchema: JSONValue

    var json: JSONValue {
        .object(["name": .string(name),
                 "description": .string(description),
                 "inputSchema": inputSchema])
    }
}

/// Stable machine-readable failure codes (spec §9). The code leads the text
/// (`[code] message`) so both humans and agents can branch on it.
enum ToolErrorCode: String {
    case accessDisabled = "access_disabled"
    case appNotRunning = "app_not_running"
    case engineUnavailable = "engine_unavailable"
    case modelLoadingTimeout = "model_loading_timeout"
    case meetingNotFound = "meeting_not_found"
    case ambiguousID = "ambiguous_id"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
}

/// Outcome of a `tools/call`. Encodes to the MCP result shape:
/// `{"content":[{"type":"text","text":…}],"isError":…}`.
struct ToolResult {
    var text: String
    var isError: Bool

    static func text(_ text: String) -> ToolResult {
        ToolResult(text: text, isError: false)
    }

    static func error(_ code: ToolErrorCode, _ message: String) -> ToolResult {
        ToolResult(text: "[\(code.rawValue)] \(message)", isError: true)
    }

    var json: JSONValue {
        .object(["content": .array([.object(["type": "text", "text": .string(text)])]),
                 "isError": .bool(isError)])
    }
}

/// The seam between the MCP wire layer and whatever owns the meeting library.
/// v1: `FileLibraryToolProvider` reads the on-disk library in-process. A
/// future app-hosted server implements the same protocol behind an IPC shim
/// (spec §3), so nothing above this line has to change.
protocol LibraryToolProvider {
    var tools: [ToolDefinition] { get }
    func call(name: String, arguments: JSONValue?) async -> ToolResult
}
```

Create `LokalBot/CLISupport/MCPDispatcher.swift`:

```swift
import Foundation

/// Method routing for the MCP surface this server speaks: `initialize`,
/// `tools/list`, `tools/call`, `ping`. Pure — string in, optional string out
/// (nil = notification, nothing to write).
struct MCPDispatcher {
    /// MCP protocol revisions this server knows. Per the MCP lifecycle spec,
    /// we answer with the client's requested revision when we support it,
    /// otherwise with our newest.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    var provider: LibraryToolProvider
    var serverVersion: String

    func handle(line: String) async -> String? {
        switch MCPRequest.parse(line) {
        case .failure(let code, let message, let id):
            return MCPResponse.failure(id: id, code: code, message: message)
        case .request(let request):
            return await handle(request: request)
        }
    }

    private func handle(request: MCPRequest) async -> String? {
        // Notifications (no id) get no response — including
        // notifications/initialized and notifications/cancelled.
        guard let id = request.id else { return nil }
        switch request.method {
        case "initialize":
            let requested = request.params?["protocolVersion"]?.stringValue
            let version = Self.supportedProtocolVersions.contains(requested ?? "")
                ? requested!
                : Self.supportedProtocolVersions.last!
            return MCPResponse.success(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": "lokalbot", "version": .string(serverVersion)]),
            ]))
        case "tools/list":
            return MCPResponse.success(id: id, result: .object([
                "tools": .array(provider.tools.map(\.json)),
            ]))
        case "tools/call":
            guard case .some(.string(let name)) = request.params?["name"] else {
                return MCPResponse.failure(id: id, code: -32602,
                                           message: "tools/call requires params.name")
            }
            let result = await provider.call(name: name, arguments: request.params?["arguments"])
            return MCPResponse.success(id: id, result: result.json)
        case "ping":
            return MCPResponse.success(id: id, result: .object([:]))
        default:
            return MCPResponse.failure(id: id, code: -32601,
                                       message: "Method not found: \(request.method)")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/MCPDispatcherTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (10 tests).

- [ ] **Step 5: Commit**

```bash
git add LokalBot/CLISupport/LibraryToolProvider.swift LokalBot/CLISupport/MCPDispatcher.swift \
  LokalBotTests/MCPDispatcherTests.swift
git commit -m "$(cat <<'EOF'
Add MCP method dispatcher behind a LibraryToolProvider seam

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 3: AgentAccessGate (marker-file truth)

**Files:**
- Create: `LokalBot/CLISupport/AgentAccessGate.swift`
- Test: `LokalBotTests/AgentAccessGateTests.swift`

**Interfaces:**
- Consumes: `SessionLookup.storageRootURL`.
- Produces: `AgentAccessGate{ init(root: URL = SessionLookup.storageRootURL) }` with `controlDirectory/accessMarkerURL/wakeFileURL/wakeErrorURL: URL`, `isEnabled: Bool`, `enable() throws`, `disable()`, `touchWake() throws`, `consumeWake() -> Bool`, `pendingWake: Bool`, `writeWakeError(_ message: String)`, `clearWakeError()`, `readWakeError() -> String?`. Used by the provider (Task 5), the ask engine (Task 7), the app-side manager (Task 10), and the e2e step (Task 14).

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/AgentAccessGateTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class AgentAccessGateTests: XCTestCase {
    private func makeGate() -> (AgentAccessGate, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-\(UUID().uuidString)", isDirectory: true)
        return (AgentAccessGate(root: root), root)
    }

    func testDisabledByDefaultAndEnableDisableRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.isEnabled)
        try gate.enable()
        XCTAssertTrue(gate.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("control/agent-access-enabled").path))
        gate.disable()
        XCTAssertFalse(gate.isEnabled)
    }

    func testWakeTouchConsumeCycle() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.pendingWake)
        XCTAssertFalse(gate.consumeWake())
        try gate.touchWake()
        XCTAssertTrue(gate.pendingWake)
        XCTAssertTrue(gate.consumeWake())
        XCTAssertFalse(gate.pendingWake)
    }

    func testWakeErrorRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(gate.readWakeError())
        gate.writeWakeError("engine offline")
        XCTAssertEqual(gate.readWakeError(), "engine offline")
        gate.clearWakeError()
        XCTAssertNil(gate.readWakeError())
    }

    func testDefaultRootFollowsStorageRootOverride() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-env-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(AgentAccessGate().root.path, root.path)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AgentAccessGateTests 2>&1 | tail -5
```

Expected: build FAILS — "cannot find 'AgentAccessGate' in scope".

- [ ] **Step 3: Write the implementation**

Create `LokalBot/CLISupport/AgentAccessGate.swift`:

```swift
import Foundation

/// Cross-process truth for the external-agent access toggle and the llama
/// wake handshake (spec §5–6). Everything is plain marker files under
/// `<storage root>/control/`, so the app, the CLI, and hermetic tests
/// (LOKALBOT_STORAGE_ROOT) all see the same state — and a user can inspect
/// or clear it with Finder.
struct AgentAccessGate {
    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL { root.appendingPathComponent("control", isDirectory: true) }
    /// Present ⇔ the Privacy toggle "Allow external agents to read your
    /// meeting library" is ON.
    var accessMarkerURL: URL { controlDirectory.appendingPathComponent("agent-access-enabled") }
    /// Touched by the CLI to ask the app to start the Main LLM.
    var wakeFileURL: URL { controlDirectory.appendingPathComponent("agent-wake") }
    /// Written by the app when a wake can't be served (wrong engine, model
    /// missing); read by the CLI to report a precise error.
    var wakeErrorURL: URL { controlDirectory.appendingPathComponent("agent-wake-error") }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    func enable() throws {
        try FileManager.default.createDirectory(at: controlDirectory,
                                                withIntermediateDirectories: true)
        try Data().write(to: accessMarkerURL)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }

    func touchWake() throws {
        try FileManager.default.createDirectory(at: controlDirectory,
                                                withIntermediateDirectories: true)
        // Rewrite (not just create) so a leftover wake file still produces a
        // fresh directory-write event for the app's watcher.
        try Data().write(to: wakeFileURL)
    }

    /// Remove a pending wake, reporting whether there was one. The app calls
    /// this so each wake is handled exactly once.
    func consumeWake() -> Bool {
        guard FileManager.default.fileExists(atPath: wakeFileURL.path) else { return false }
        try? FileManager.default.removeItem(at: wakeFileURL)
        return true
    }

    var pendingWake: Bool {
        FileManager.default.fileExists(atPath: wakeFileURL.path)
    }

    func writeWakeError(_ message: String) {
        try? FileManager.default.createDirectory(at: controlDirectory,
                                                 withIntermediateDirectories: true)
        try? Data(message.utf8).write(to: wakeErrorURL)
    }

    func clearWakeError() {
        try? FileManager.default.removeItem(at: wakeErrorURL)
    }

    func readWakeError() -> String? {
        guard let data = try? Data(contentsOf: wakeErrorURL) else { return nil }
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AgentAccessGateTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (4 tests).

- [ ] **Step 5: Commit**

```bash
git add LokalBot/CLISupport/AgentAccessGate.swift LokalBotTests/AgentAccessGateTests.swift
git commit -m "$(cat <<'EOF'
Add marker-file gate for external agent access and llama wake

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 4: `LibrarySearch` extraction + `MeetingFixture` test helper

The MCP `search_meetings` tool must behave exactly like the CLI `search` verb (spec §4: "one behavior"). Extract the inline search walk out of `SearchCommand` into a shared `LibrarySearch` enum, and add a reusable on-disk meeting fixture writer for all following tests.

**Files:**
- Create: `LokalBot/CLISupport/LibrarySearch.swift`
- Create: `LokalBotTests/MeetingFixture.swift` (test helper, no own test class)
- Modify: `CLI/Commands/SearchCommand.swift` (replace the inline walk; delete its private `snippet`)
- Test: `LokalBotTests/LibrarySearchTests.swift`

**Interfaces:**
- Consumes: `SessionLookup.loadAllMeetings()/shortID(_:)/summaryMarkdown(for:)/transcript(for:)`, `SessionFormatter.SearchHit`, `Meeting` (memberwise init with `id,title,appName,startedAt,endedAt,relativePath`), `Transcript(segments:engine:speakerAliases:)` + `Transcript.Segment(start:end:speaker:text:confidence:)` — all pre-existing.
- Produces: `LibrarySearch.defaultLimit = 50`; `LibrarySearch.hits(query: String, limit: Int = defaultLimit, meetings: [Meeting]? = nil) throws -> [SessionFormatter.SearchHit]`; `MeetingFixture.Spec(id:title:startedAt:summary:transcriptLines:)` and `MeetingFixture.write(_ specs: [Spec], under root: URL) throws`. Tasks 5, 6, 7, 9 use these.

- [ ] **Step 1: Write the fixture helper**

`LokalBotTests/MeetingFixture.swift`:

```swift
import Foundation
@testable import LokalBot

/// Writes minimal on-disk meeting folders (meta.json + summary.md +
/// transcript.{json,md}) under a hermetic storage root so CLISupport code is
/// tested against real files, the same way ChatAgentTests seeds its library.
enum MeetingFixture {
    struct Spec {
        var id: UUID
        var title: String
        var startedAt: Date
        var summary: String?
        var transcriptLines: [String]

        init(id: UUID = UUID(), title: String, startedAt: Date,
             summary: String? = nil, transcriptLines: [String] = []) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.summary = summary
            self.transcriptLines = transcriptLines
        }
    }

    static func write(_ specs: [Spec], under root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for spec in specs {
            let short = SessionLookup.shortID(spec.id)
            let relative = "meetings/2026/07/\(short)-fixture"
            let folder = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let meeting = Meeting(id: spec.id, title: spec.title, appName: "Fixture",
                                  startedAt: spec.startedAt,
                                  endedAt: spec.startedAt.addingTimeInterval(1800),
                                  relativePath: relative)
            try encoder.encode(meeting).write(to: folder.appendingPathComponent("meta.json"))

            if let summary = spec.summary {
                try summary.write(to: folder.appendingPathComponent("summary.md"),
                                  atomically: true, encoding: .utf8)
            }
            if !spec.transcriptLines.isEmpty {
                let segments = spec.transcriptLines.enumerated().map { i, line in
                    Transcript.Segment(start: Double(i * 10), end: Double(i * 10 + 9),
                                       speaker: i.isMultiple(of: 2) ? "me" : "them",
                                       text: line, confidence: nil)
                }
                let transcript = Transcript(segments: segments, engine: "fixture")
                try encoder.encode(transcript)
                    .write(to: folder.appendingPathComponent("transcript.json"))
                try spec.transcriptLines.joined(separator: "\n")
                    .write(to: folder.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)
            }
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

`LokalBotTests/LibrarySearchTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class LibrarySearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarysearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)

        try MeetingFixture.write([
            .init(id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                  title: "Cache planning",
                  startedAt: Date(timeIntervalSince1970: 1_780_000_000),   // 2026-05-28
                  summary: "## TL;DR\nWe chose Redis for the caching layer.",
                  transcriptLines: ["Let us talk caching.", "Redis has pub sub support."]),
            .init(id: UUID(uuidString: "BBBBBBBB-1111-4222-8333-444444444444")!,
                  title: "Weekly planning",
                  startedAt: Date(timeIntervalSince1970: 1_770_000_000),   // 2026-02-02
                  summary: "## TL;DR\nStatus updates only.",
                  transcriptLines: ["Nothing about datastores here."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testFindsTitleSummaryAndTranscriptKinds() throws {
        let redis = try LibrarySearch.hits(query: "redis")
        XCTAssertEqual(Set(redis.map(\.match_kind)), ["summary", "transcript"])
        XCTAssertTrue(redis.allSatisfy { $0.meeting_title == "Cache planning" })

        let cache = try LibrarySearch.hits(query: "cache")
        XCTAssertEqual(cache.first?.match_kind, "title")
    }

    func testTranscriptHitCarriesTimestamp() throws {
        let hits = try LibrarySearch.hits(query: "pub sub")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].match_kind, "transcript")
        XCTAssertEqual(hits[0].timestamp, "00:00:10")
    }

    func testRecencyOrderAcrossMeetings() throws {
        let hits = try LibrarySearch.hits(query: "planning")
        XCTAssertEqual(hits.first?.meeting_title, "Cache planning")
        XCTAssertTrue(hits.contains { $0.meeting_title == "Weekly planning" })
    }

    func testLimitCapsHits() throws {
        let hits = try LibrarySearch.hits(query: "e", limit: 2)
        XCTAssertEqual(hits.count, 2)
    }

    func testNoMatchReturnsEmpty() throws {
        XCTAssertTrue(try LibrarySearch.hits(query: "zzzznotthere").isEmpty)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/LibrarySearchTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find 'LibrarySearch' in scope`.

- [ ] **Step 4: Write the implementation**

`LokalBot/CLISupport/LibrarySearch.swift` — the body is moved verbatim from `SearchCommand.run()`/`snippet` so CLI and MCP behavior stay identical:

```swift
import Foundation

/// The CLI's substring search over on-disk meeting artifacts, extracted from
/// `SearchCommand` so the MCP `search_meetings` tool shares one behavior with
/// the `search` verb. Case-insensitive, recency-ordered, capped at 50 hits.
enum LibrarySearch {
    static let defaultLimit = 50

    static func hits(query: String,
                     limit: Int = defaultLimit,
                     meetings: [Meeting]? = nil) throws -> [SessionFormatter.SearchHit] {
        let needle = query.lowercased()
        let all = try meetings ?? SessionLookup.loadAllMeetings()

        var hits: [SessionFormatter.SearchHit] = []
        for meeting in all {
            let short = SessionLookup.shortID(meeting.id)
            if meeting.title.lowercased().contains(needle) {
                hits.append(.init(meeting_id: short, meeting_title: meeting.title,
                                  match_kind: "title", snippet: meeting.title, timestamp: nil))
            }
            if let summary = SessionLookup.summaryMarkdown(for: meeting),
               let snippet = snippet(in: summary, around: needle) {
                hits.append(.init(meeting_id: short, meeting_title: meeting.title,
                                  match_kind: "summary", snippet: snippet, timestamp: nil))
            }
            if let transcript = SessionLookup.transcript(for: meeting) {
                for segment in transcript.segments where segment.text.lowercased().contains(needle) {
                    hits.append(.init(
                        meeting_id: short,
                        meeting_title: meeting.title,
                        match_kind: "transcript",
                        snippet: segment.text,
                        timestamp: Transcript.stamp(segment.start)))
                    if hits.count >= limit { break }
                }
            }
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    /// 80-char window around the first occurrence of `needle`, with leading/
    /// trailing ellipsis when truncated. Case-insensitive search; returns the
    /// original-case substring so the user reads what they wrote.
    static func snippet(in haystack: String, around needle: String) -> String? {
        guard let range = haystack.lowercased().range(of: needle) else { return nil }
        let start = haystack.index(range.lowerBound,
                                   offsetBy: -40, limitedBy: haystack.startIndex) ?? haystack.startIndex
        let end = haystack.index(range.upperBound,
                                 offsetBy: 40, limitedBy: haystack.endIndex) ?? haystack.endIndex
        var snippet = String(haystack[start..<end])
        if start != haystack.startIndex { snippet = "…" + snippet }
        if end != haystack.endIndex { snippet += "…" }
        return snippet
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/LibrarySearchTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (5 tests).

- [ ] **Step 6: Refactor SearchCommand to delegate**

Replace the whole body of `SearchCommand.run()` in `CLI/Commands/SearchCommand.swift` and delete the now-unused `private static func snippet` (lines 62–75). The `@Argument`/`@Option`/`@Flag` declarations and `configuration` stay untouched, except `limit`'s default now names the shared constant:

```swift
    @Option(name: .long, help: "Maximum number of hits to return.")
    var limit: Int = LibrarySearch.defaultLimit

    func run() async throws {
        let hits = try LibrarySearch.hits(query: query, limit: limit)
        print(table
            ? SessionFormatter.searchTable(hits)
            : SessionFormatter.searchJSON(hits))
    }
```

- [ ] **Step 7: Verify both targets still build and tests pass**

```bash
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli build 2>&1 | tail -3
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/LibrarySearchTests 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add LokalBot/CLISupport/LibrarySearch.swift LokalBotTests/MeetingFixture.swift \
        LokalBotTests/LibrarySearchTests.swift CLI/Commands/SearchCommand.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Extract shared library search from the search verb

The MCP search_meetings tool (next tasks) must match CLI search behavior
exactly; one implementation now serves both.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 5: `FileLibraryToolProvider` — the four tools

The v1 `LibraryToolProvider` implementation (spec §3–§4): serves `list_meetings`, `get_meeting`, `search_meetings` straight from the on-disk library, and delegates `ask_library` to an injected async closure so this task needs no LLM engine (Task 7 provides it; Task 8 wires them together).

**Files:**
- Create: `LokalBot/CLISupport/FileLibraryToolProvider.swift`
- Test: `LokalBotTests/FileLibraryToolProviderTests.swift`

**Interfaces:**
- Consumes: `LibraryToolProvider`, `ToolDefinition`, `ToolResult`, `ToolErrorCode`, `JSONValue` (Tasks 1–2); `AgentAccessGate` (Task 3); `LibrarySearch`, `MeetingFixture` (Task 4); `SessionLookup`, `SessionFormatter` (pre-existing, incl. `SessionFormatter.GetOptions.all`).
- Produces: `FileLibraryToolProvider(gate: AgentAccessGate, ask: @escaping (String) async -> ToolResult)` conforming to `LibraryToolProvider`; `FileLibraryToolProvider.accessDisabledMessage: String`. Task 8 constructs it; Task 9 exercises it through the spawned binary.

- [ ] **Step 1: Write the failing test**

`LokalBotTests/FileLibraryToolProviderTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class FileLibraryToolProviderTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!
    private var askedQuestions: [String] = []

    /// Provider whose ask_library records the question and returns a stub.
    private var provider: FileLibraryToolProvider {
        FileLibraryToolProvider(gate: gate) { question in
            self.askedQuestions.append(question)
            return .text("stub answer")
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolprovider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
        try gate.enable()
        askedQuestions = []

        // The two IDs share the short-id prefix "aaaaaaa" on purpose — the
        // ambiguity test below depends on it.
        try MeetingFixture.write([
            .init(id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                  title: "Cache planning",
                  startedAt: Date(timeIntervalSince1970: 1_780_000_000),   // 2026-05-28
                  summary: "## TL;DR\nWe chose Redis for the caching layer.",
                  transcriptLines: ["Let us decide on caching.", "Redis it is."]),
            .init(id: UUID(uuidString: "AAAAAAAB-2222-4333-8444-555555555555")!,
                  title: "Old sync",
                  startedAt: Date(timeIntervalSince1970: 1_770_000_000),   // 2026-02-02
                  summary: "## TL;DR\nAncient history.",
                  transcriptLines: ["Nothing to see."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAdvertisesExactlyTheFourTools() {
        XCTAssertEqual(provider.tools.map(\.name),
                       ["list_meetings", "get_meeting", "search_meetings", "ask_library"])
        for tool in provider.tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
    }

    func testEveryToolRefusedWhenGateDisabled() async {
        gate.disable()
        for name in ["list_meetings", "get_meeting", "search_meetings", "ask_library"] {
            let result = await provider.call(
                name: name,
                arguments: ["id": "latest", "query": "x", "question": "x"])
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.text.hasPrefix("[access_disabled]"), name)
        }
        XCTAssertTrue(askedQuestions.isEmpty, "ask_library must not run while disabled")
    }

    func testListMeetingsReturnsBothNewestFirst() async {
        let result = await provider.call(name: "list_meetings", arguments: nil)
        XCTAssertFalse(result.isError)
        guard let cache = result.text.range(of: "Cache planning"),
              let old = result.text.range(of: "Old sync") else {
            return XCTFail("both meetings expected in: \(result.text)")
        }
        XCTAssertLessThan(cache.lowerBound, old.lowerBound)
    }

    func testListMeetingsFiltersByQuerySinceAndLimit() async {
        let byQuery = await provider.call(name: "list_meetings",
                                          arguments: ["query": "cache"])
        XCTAssertTrue(byQuery.text.contains("Cache planning"))
        XCTAssertFalse(byQuery.text.contains("Old sync"))

        let bySince = await provider.call(name: "list_meetings",
                                          arguments: ["since": "2026-04-01"])
        XCTAssertTrue(bySince.text.contains("Cache planning"))
        XCTAssertFalse(bySince.text.contains("Old sync"))

        let badSince = await provider.call(name: "list_meetings",
                                           arguments: ["since": "April 1st"])
        XCTAssertTrue(badSince.isError)
        XCTAssertTrue(badSince.text.hasPrefix("[invalid_arguments]"))

        let capped = await provider.call(name: "list_meetings",
                                         arguments: ["limit": 1])
        XCTAssertTrue(capped.text.contains("Cache planning"))
        XCTAssertFalse(capped.text.contains("Old sync"))
    }

    func testGetMeetingLatestReturnsMarkdownSections() async {
        let result = await provider.call(name: "get_meeting",
                                         arguments: ["id": "latest"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("# Cache planning"))
        XCTAssertTrue(result.text.contains("Redis"))

        let summaryOnly = await provider.call(
            name: "get_meeting",
            arguments: ["id": "latest", "include": "summary"])
        XCTAssertTrue(summaryOnly.text.contains("Redis"))
        XCTAssertFalse(summaryOnly.text.contains("# Cache planning"))
    }

    func testGetMeetingErrorCodes() async {
        let missingID = await provider.call(name: "get_meeting", arguments: nil)
        XCTAssertTrue(missingID.text.hasPrefix("[invalid_arguments]"))

        let notFound = await provider.call(name: "get_meeting",
                                           arguments: ["id": "ffffffff"])
        XCTAssertTrue(notFound.text.hasPrefix("[meeting_not_found]"))

        let ambiguous = await provider.call(name: "get_meeting",
                                            arguments: ["id": "aaaaaaa"])
        XCTAssertTrue(ambiguous.text.hasPrefix("[ambiguous_id]"))
    }

    func testSearchMeetingsReturnsHitJSON() async {
        let result = await provider.call(name: "search_meetings",
                                         arguments: ["query": "redis"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("\"match_kind\""))
        XCTAssertTrue(result.text.contains("Cache planning"))

        let missing = await provider.call(name: "search_meetings", arguments: nil)
        XCTAssertTrue(missing.text.hasPrefix("[invalid_arguments]"))
    }

    func testAskLibraryDelegatesToClosure() async {
        let result = await provider.call(
            name: "ask_library",
            arguments: ["question": "What did we decide about caching?"])
        XCTAssertEqual(result.text, "stub answer")
        XCTAssertEqual(askedQuestions, ["What did we decide about caching?"])

        let empty = await provider.call(name: "ask_library",
                                        arguments: ["question": "   "])
        XCTAssertTrue(empty.text.hasPrefix("[invalid_arguments]"))
    }

    func testUnknownToolName() async {
        let result = await provider.call(name: "delete_everything", arguments: nil)
        XCTAssertTrue(result.text.hasPrefix("[unknown_tool]"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/FileLibraryToolProviderTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find 'FileLibraryToolProvider' in scope`.

- [ ] **Step 3: Write the implementation**

`LokalBot/CLISupport/FileLibraryToolProvider.swift`:

```swift
import Foundation

/// v1 `LibraryToolProvider`: serves the read tools straight from the on-disk
/// library (works with the app closed) and delegates `ask_library` to an
/// injected closure so the LLM engine stays swappable and this type stays
/// testable without HTTP. A future app-hosted MCP server implements the same
/// protocol — that seam is the point (spec §3).
struct FileLibraryToolProvider: LibraryToolProvider {
    var gate: AgentAccessGate
    /// Answers an `ask_library` question. `MCPCommand` wires this to
    /// `AskLibraryEngine.ask`; tests inject a recorder.
    var ask: (String) async -> ToolResult

    static let accessDisabledMessage =
        "External agent access is off. Enable it in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to read your meeting library\"."

    var tools: [ToolDefinition] {
        [
            ToolDefinition(
                name: "list_meetings",
                description: "List recorded meetings, newest first. Returns id, title, date, and duration for each.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Maximum meetings to return (default 20)."],
                        "since": ["type": "string", "description": "Only meetings on or after this UTC day, formatted YYYY-MM-DD."],
                        "query": ["type": "string", "description": "Case-insensitive title substring filter."],
                    ],
                ]),
            ToolDefinition(
                name: "get_meeting",
                description: "Fetch one meeting as markdown. Sections: metadata, summary, transcript.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Short id from list_meetings, full UUID, or \"latest\"."],
                        "include": ["type": "string", "description": "Comma-separated subset of metadata,summary,transcript. Default: all three."],
                    ],
                    "required": ["id"],
                ]),
            ToolDefinition(
                name: "search_meetings",
                description: "Case-insensitive substring search across meeting titles, summaries, and transcripts. Hits are recency-ordered with kind, snippet, and timestamp.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "limit": ["type": "integer", "description": "Maximum hits (default 50)."],
                    ],
                    "required": ["query"],
                ]),
            ToolDefinition(
                name: "ask_library",
                description: "Ask a question and get an answer synthesized by LokalBot's local model from the meeting library, with meeting citations — raw transcripts never leave the Mac. Needs the LokalBot app running; the first call may take up to a minute while the model loads.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "The question to answer from the user's meetings."],
                    ],
                    "required": ["question"],
                ]),
        ]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        guard gate.isEnabled else {
            return .error(.accessDisabled, Self.accessDisabledMessage)
        }
        switch name {
        case "list_meetings":
            return listMeetings(arguments)
        case "get_meeting":
            return getMeeting(arguments)
        case "search_meetings":
            return searchMeetings(arguments)
        case "ask_library":
            guard let question = arguments?["question"]?.stringValue?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else {
                return .error(.invalidArguments, "ask_library requires a non-empty \"question\" string.")
            }
            return await ask(question)
        default:
            return .error(.unknownTool,
                          "No tool named \"\(name)\". Available: list_meetings, get_meeting, search_meetings, ask_library.")
        }
    }

    // MARK: - Read tools

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func listMeetings(_ arguments: JSONValue?) -> ToolResult {
        do {
            var meetings = try SessionLookup.loadAllMeetings()
            if let query = arguments?["query"]?.stringValue, !query.isEmpty {
                let needle = query.lowercased()
                meetings = meetings.filter { $0.title.lowercased().contains(needle) }
            }
            if let since = arguments?["since"]?.stringValue {
                guard let day = Self.dayFormatter.date(from: since) else {
                    return .error(.invalidArguments,
                                  "\"since\" must be formatted YYYY-MM-DD, got \"\(since)\".")
                }
                meetings = meetings.filter { $0.startedAt >= day }
            }
            let limit = max(1, arguments?["limit"]?.intValue ?? 20)
            return .text(SessionFormatter.listJSON(Array(meetings.prefix(limit))))
        } catch {
            return .error(.meetingNotFound,
                          "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getMeeting(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .error(.invalidArguments,
                          "get_meeting requires an \"id\" string (short id, full UUID, or \"latest\").")
        }
        do {
            let meetings = try SessionLookup.loadAllMeetings()
            // SessionLookup.find returns nil for both "no match" and
            // "ambiguous short id"; disambiguate first so the code is honest.
            let needle = id.lowercased()
            if needle != "latest", UUID(uuidString: needle) == nil {
                let matches = meetings.filter { SessionLookup.shortID($0.id).hasPrefix(needle) }
                if matches.count > 1 {
                    let ids = matches.map { SessionLookup.shortID($0.id) }.joined(separator: ", ")
                    return .error(.ambiguousID,
                                  "\"\(id)\" matches several meetings (\(ids)). Use a longer id.")
                }
            }
            guard let meeting = try SessionLookup.find(id: id, in: meetings) else {
                return .error(.meetingNotFound,
                              "No meeting matches \"\(id)\". Use list_meetings or search_meetings to find ids.")
            }
            return .text(SessionFormatter.getMarkdown(meeting, options: parseInclude(arguments?["include"]?.stringValue)))
        } catch {
            return .error(.meetingNotFound,
                          "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func parseInclude(_ include: String?) -> SessionFormatter.GetOptions {
        guard let include, !include.isEmpty else { return .all }
        let parts = Set(include.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return .init(includeSummary: parts.contains("summary"),
                     includeTranscript: parts.contains("transcript"),
                     includeMetadata: parts.contains("metadata"))
    }

    private func searchMeetings(_ arguments: JSONValue?) -> ToolResult {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return .error(.invalidArguments, "search_meetings requires a non-empty \"query\" string.")
        }
        do {
            let limit = max(1, arguments?["limit"]?.intValue ?? LibrarySearch.defaultLimit)
            return .text(SessionFormatter.searchJSON(try LibrarySearch.hits(query: query, limit: limit)))
        } catch {
            return .error(.meetingNotFound,
                          "Could not read the meeting library: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/FileLibraryToolProviderTests 2>&1 | tail -5
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli build 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **` (9 tests), then `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/CLISupport/FileLibraryToolProvider.swift \
        LokalBotTests/FileLibraryToolProviderTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add file-backed MCP tool provider for the meeting library

list_meetings, get_meeting, and search_meetings run against the on-disk
library; ask_library delegates to an injected closure until the engine
lands. Every call is refused with access_disabled while the Privacy
toggle is off.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 6: `AskLibraryContext` — retrieval + prompt + citations

The pure half of `ask_library` (spec §5): pick search terms from the question, gather up to 12 snippets (recency-ordered, deduped), inline full summaries for meetings the question names by title, produce the citations array, and build the chat messages. No HTTP, no gate — fully unit-testable.

**Files:**
- Create: `LokalBot/CLISupport/AskLibraryContext.swift`
- Test: `LokalBotTests/AskLibraryContextTests.swift`

**Interfaces:**
- Consumes: `LibrarySearch.hits(query:limit:meetings:)`, `MeetingFixture` (Task 4); `SessionLookup.shortID(_:)/summaryMarkdown(for:)`, `Meeting` (pre-existing).
- Produces: `AskLibraryContext.maxSnippets = 12`; `Citation{meeting_id, title, date}` (`Encodable`, `Equatable`); `ContextBundle{contextText: String, citations: [Citation]}` (`Equatable`); `searchTerms(from: String) -> [String]`; `build(question: String, meetings: [Meeting]) -> ContextBundle`; `messages(question: String, contextText: String) -> [[String: String]]`. Task 7 consumes all of these.

- [ ] **Step 1: Write the failing test**

`LokalBotTests/AskLibraryContextTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class AskLibraryContextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askcontext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)

        try MeetingFixture.write([
            .init(id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                  title: "Cache planning",
                  startedAt: Date(timeIntervalSince1970: 1_780_000_000),   // 2026-05-28
                  summary: "We chose Redis for the caching layer.",
                  transcriptLines: ["Let us decide on caching today.",
                                    "Redis wins because of pub sub."]),
            .init(id: UUID(uuidString: "BBBBBBBB-1111-4222-8333-444444444444")!,
                  title: "Standup",
                  startedAt: Date(timeIntervalSince1970: 1_770_000_000),   // 2026-02-02
                  summary: "Daily status.",
                  transcriptLines: ["Shipping the caching benchmark tomorrow."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSearchTermsDropStopwordsAndShortWords() {
        XCTAssertEqual(AskLibraryContext.searchTerms(from: "What did we decide about caching?"),
                       ["decide", "caching"])
        XCTAssertEqual(AskLibraryContext.searchTerms(from: "Tell me about it"), [])
        XCTAssertEqual(AskLibraryContext.searchTerms(from: "Caching CACHING caching"), ["caching"])
    }

    func testBuildGathersSnippetsForContentTerms() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(question: "What did we decide about caching?",
                                             meetings: meetings)
        XCTAssertTrue(bundle.contextText.contains("## Snippets"))
        XCTAssertTrue(bundle.contextText.contains("Redis"))
        XCTAssertTrue(bundle.contextText.contains("- [transcript @00:00:00] Cache planning:"))
    }

    func testBuildInlinesFullSummaryWhenQuestionNamesMeeting() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(question: "Summarize the Cache planning meeting",
                                             meetings: meetings)
        XCTAssertTrue(bundle.contextText.contains("## Cache planning — 2026-05-28 — full summary"))
        XCTAssertTrue(bundle.contextText.contains("We chose Redis for the caching layer."))
        XCTAssertEqual(bundle.citations.first?.title, "Cache planning")
    }

    func testCitationsNewestFirstWithDayDates() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        // "caching" hits both meetings (summary+transcript vs. benchmark line).
        let bundle = AskLibraryContext.build(question: "caching", meetings: meetings)
        XCTAssertEqual(bundle.citations.map(\.title), ["Cache planning", "Standup"])
        XCTAssertTrue(bundle.citations.allSatisfy { $0.date.hasPrefix("2026-") })
        XCTAssertEqual(bundle.citations.first?.meeting_id, "aaaaaaaa")
    }

    func testSnippetCapAtTwelve() throws {
        try MeetingFixture.write([
            .init(id: UUID(), title: "Zephyr readout",
                  startedAt: Date(timeIntervalSince1970: 1_781_000_000),
                  transcriptLines: (0..<20).map { "zephyr milestone number \($0) update" }),
        ], under: root)
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(question: "zephyr milestone", meetings: meetings)
        let lines = bundle.contextText.split(separator: "\n").filter { $0.hasPrefix("- [") }
        XCTAssertEqual(lines.count, AskLibraryContext.maxSnippets)
    }

    func testSnippetsDedupeAcrossTerms() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        // Both terms window the same short summary → identical snippet text,
        // which must appear once, not once per term.
        let bundle = AskLibraryContext.build(question: "redis caching", meetings: meetings)
        let summaryLines = bundle.contextText.split(separator: "\n")
            .filter { $0.hasPrefix("- [summary] Cache planning:") }
        XCTAssertEqual(summaryLines.count, 1)
    }

    func testEmptyBundleWhenNothingMatches() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(question: "quantum blockchain synergy",
                                             meetings: meetings)
        XCTAssertEqual(bundle, AskLibraryContext.ContextBundle(contextText: "", citations: []))
    }

    func testMessagesShape() {
        let messages = AskLibraryContext.messages(question: "Q?", contextText: "CTX")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertTrue(messages[0]["content"]!.contains("ONLY the meeting context"))
        XCTAssertTrue(messages[0]["content"]!.contains("I couldn't find that in your meetings."))
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]!.contains("CTX"))
        XCTAssertTrue(messages[1]["content"]!.hasSuffix("Question: Q?"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AskLibraryContextTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find 'AskLibraryContext' in scope`.

- [ ] **Step 3: Write the implementation**

`LokalBot/CLISupport/AskLibraryContext.swift`:

```swift
import Foundation

/// Builds the retrieval context, citations, and chat messages for
/// `ask_library` (spec §5). Pure value-in/value-out so retrieval selection,
/// prompt construction, and citation extraction test without an LLM.
enum AskLibraryContext {
    static let maxSnippets = 12

    struct Citation: Encodable, Equatable {
        var meeting_id: String
        var title: String
        var date: String   // yyyy-MM-dd, UTC
    }

    struct ContextBundle: Equatable {
        var contextText: String
        var citations: [Citation]
    }

    /// Words worth searching for: lowercased, ≥ 4 letters, question
    /// scaffolding removed, deduped in order. Substring-searching the whole
    /// question never matches ("What did we decide about caching?" appears in
    /// no transcript) — its content words individually do.
    static func searchTerms(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "what", "when", "where", "which", "whom", "about", "does", "that",
            "this", "with", "have", "from", "were", "they", "their", "them",
            "will", "would", "should", "could", "meeting", "meetings",
            "please", "tell",
        ]
        var seen: Set<String> = []
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    static func build(question: String, meetings: [Meeting]) -> ContextBundle {
        let byShortID = Dictionary(meetings.map { (SessionLookup.shortID($0.id), $0) },
                                   uniquingKeysWith: { first, _ in first })
        var sections: [String] = []
        var citedShortIDs: [String] = []

        // 1. Question names a meeting by title → include its summary whole.
        let lowered = question.lowercased()
        for meeting in meetings {
            let title = meeting.title.trimmingCharacters(in: .whitespaces)
            guard title.count >= 4, lowered.contains(title.lowercased()),
                  let summary = SessionLookup.summaryMarkdown(for: meeting) else { continue }
            sections.append("## \(meeting.title) — \(dayString(meeting.startedAt)) — full summary\n\(summary)")
            citedShortIDs.append(SessionLookup.shortID(meeting.id))
        }

        // 2. Per-term snippets across the library, deduped, capped.
        var snippetLines: [String] = []
        var seenSnippets: Set<String> = []
        for term in searchTerms(from: question) {
            guard snippetLines.count < maxSnippets else { break }
            let hits = (try? LibrarySearch.hits(query: term, limit: maxSnippets,
                                                meetings: meetings)) ?? []
            for hit in hits {
                guard snippetLines.count < maxSnippets else { break }
                guard seenSnippets.insert("\(hit.meeting_id)|\(hit.snippet)").inserted else { continue }
                let stamp = hit.timestamp.map { " @\($0)" } ?? ""
                snippetLines.append("- [\(hit.match_kind)\(stamp)] \(hit.meeting_title): \(hit.snippet)")
                citedShortIDs.append(hit.meeting_id)
            }
        }
        if !snippetLines.isEmpty {
            sections.append("## Snippets\n" + snippetLines.joined(separator: "\n"))
        }

        var seenIDs: Set<String> = []
        let citations = citedShortIDs
            .filter { seenIDs.insert($0).inserted }
            .compactMap { byShortID[$0] }
            .sorted { $0.startedAt > $1.startedAt }
            .map { Citation(meeting_id: SessionLookup.shortID($0.id),
                            title: $0.title,
                            date: dayString($0.startedAt)) }

        return ContextBundle(contextText: sections.joined(separator: "\n\n"),
                             citations: citations)
    }

    static func messages(question: String, contextText: String) -> [[String: String]] {
        [
            ["role": "system",
             "content": "You are LokalBot's meeting-library assistant. Answer the user's question using ONLY the meeting context provided. Cite the meetings you used by title and date. If the context does not contain the answer, reply exactly: I couldn't find that in your meetings."],
            ["role": "user",
             "content": "Meeting context:\n\n\(contextText)\n\nQuestion: \(question)"],
        ]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AskLibraryContextTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (8 tests).

- [ ] **Step 5: Commit**

```bash
git add LokalBot/CLISupport/AskLibraryContext.swift LokalBotTests/AskLibraryContextTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add retrieval context and prompt builder for ask_library

Term extraction, snippet gathering with a 12-snippet cap, full-summary
inlining for meetings named in the question, and the citations array —
all pure so they test without an LLM.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 7: `AskLibraryEngine` — health probe, wake protocol, completion

The impure half of `ask_library` (spec §5, §9): probe llama-server on 17872, wake the app through the gate's wake file when the server is cold, poll up to 60 s, distinguish `app_not_running` / `engine_unavailable` / `model_loading_timeout`, then complete and append the Sources block. HTTP sits behind a two-method protocol so every path tests with a mock.

**Files:**
- Create: `LokalBot/CLISupport/AskLibraryEngine.swift`
- Test: `LokalBotTests/AskLibraryEngineTests.swift`

**Interfaces:**
- Consumes: `AgentAccessGate` (Task 3: `isEnabled/touchWake()/consumeWake()/pendingWake/readWakeError()/clearWakeError()/writeWakeError(_:)`); `AskLibraryContext` (Task 6); `ToolResult`/`ToolErrorCode` (Task 2); `SessionLookup.loadAllMeetings` (pre-existing); app-side `LlamaServer.shared.baseURL` (test-only, for the port pin).
- Produces: `protocol LlamaChatClient { func healthy() async -> Bool; func complete(messages: [[String: String]]) async throws -> String }`; `URLSessionLlamaChatClient` with `static let mainServerBaseURL`; `AskLibraryEngine(gate:)` with mutable `client/loadMeetings/pollDelay/maxPollAttempts` and `func ask(_ question: String) async -> ToolResult`. Task 8 wires `engine.ask` into the provider; Task 10's wake watcher answers the wake file this engine touches.

- [ ] **Step 1: Write the failing test**

`LokalBotTests/AskLibraryEngineTests.swift`:

```swift
import XCTest
@testable import LokalBot

/// Scriptable stand-in for llama-server. `healthyScript` is consumed
/// front-first; when exhausted, `healthy()` returns true.
private final class MockChatClient: LlamaChatClient {
    var healthyScript: [Bool]
    var completion: Result<String, Error>
    private(set) var completedMessages: [[[String: String]]] = []

    init(healthyScript: [Bool] = [], completion: Result<String, Error> = .success("mock answer")) {
        self.healthyScript = healthyScript
        self.completion = completion
    }

    func healthy() async -> Bool {
        healthyScript.isEmpty ? true : healthyScript.removeFirst()
    }

    func complete(messages: [[String: String]]) async throws -> String {
        completedMessages.append(messages)
        return try completion.get()
    }
}

final class AskLibraryEngineTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askengine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
        try gate.enable()

        try MeetingFixture.write([
            .init(id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                  title: "Cache planning",
                  startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                  summary: "We chose Redis for the caching layer.",
                  transcriptLines: ["Redis wins because of pub sub."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// 3 poll attempts and a no-op delay keep every test instant.
    private func makeEngine(client: MockChatClient,
                            onPoll: @escaping () -> Void = {}) -> AskLibraryEngine {
        var engine = AskLibraryEngine(gate: gate)
        engine.client = client
        engine.maxPollAttempts = 3
        engine.pollDelay = { onPoll() }
        return engine
    }

    func testAnswersWithSourcesWhenHealthy() async {
        let client = MockChatClient(healthyScript: [true])
        let result = await makeEngine(client: client).ask("What did we decide about caching?")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasPrefix("mock answer"))
        XCTAssertTrue(result.text.contains("Sources:"))
        XCTAssertTrue(result.text.contains("Cache planning (2026-05-28, id aaaaaaaa)"))

        let messages = client.completedMessages.first ?? []
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertTrue(messages.last?["content"]?.contains("caching") ?? false)
    }

    func testGateDisabledRefuses() async {
        gate.disable()
        let result = await makeEngine(client: MockChatClient()).ask("anything at all")
        XCTAssertTrue(result.text.hasPrefix("[access_disabled]"))
    }

    func testEmptyQuestionIsInvalidArguments() async {
        let result = await makeEngine(client: MockChatClient()).ask("   ")
        XCTAssertTrue(result.text.hasPrefix("[invalid_arguments]"))
    }

    func testWakesAppThenAnswers() async {
        // Cold on first probe, cold on first poll, healthy on the second.
        let client = MockChatClient(healthyScript: [false, false, true])
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(gate.pendingWake, "engine touches the wake file; only the app consumes it")
    }

    func testWakeErrorBecomesEngineUnavailable() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let engine = makeEngine(client: client) {
            self.gate.writeWakeError("Main LLM is an external server; pick a built-in model.")
        }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[engine_unavailable]"))
        XCTAssertTrue(result.text.contains("external server"))
    }

    func testTimeoutWithUnconsumedWakeIsAppNotRunning() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[app_not_running]"))
        XCTAssertTrue(result.text.contains("read tools still work"))
    }

    func testTimeoutAfterConsumedWakeIsModelLoadingTimeout() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let engine = makeEngine(client: client) {
            _ = self.gate.consumeWake()   // the app took the wake, model still loading
        }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[model_loading_timeout]"))
    }

    func testEmptyLibraryIsFriendlyNonError() async {
        var engine = makeEngine(client: MockChatClient(healthyScript: [true]))
        engine.loadMeetings = { [] }
        let result = await engine.ask("caching decision")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("empty"))
    }

    func testNoRetrievalMatchesIsFriendlyNonError() async {
        let client = MockChatClient(healthyScript: [true])
        let result = await makeEngine(client: client).ask("quantum blockchain synergy")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("couldn't find"))
        XCTAssertTrue(client.completedMessages.isEmpty, "no context → no LLM call")
    }

    func testCompletionFailureIsAppNotRunning() async {
        let client = MockChatClient(healthyScript: [true],
                                    completion: .failure(URLError(.cannotConnectToHost)))
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[app_not_running]"))
    }

    /// Pins the CLI-side constant to the app's real server port so they can
    /// never drift apart silently. LlamaServer is app-only code, but the unit
    /// suite is hosted inside the app binary, so it's reachable here.
    @MainActor
    func testClientBaseURLMatchesLlamaServerPort() {
        XCTAssertEqual("\(URLSessionLlamaChatClient.mainServerBaseURL)/v1",
                       "\(LlamaServer.shared.baseURL)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AskLibraryEngineTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find type 'LlamaChatClient' in scope`.

**Note:** if `testClientBaseURLMatchesLlamaServerPort` fails on the exact string (e.g. `LlamaServer.baseURL` carries a trailing slash or no `/v1`), read `LokalBot/Engines/LlamaServer.swift`, fix the assertion to compare the same normalized form, and keep the port pin — the test's job is only that both sides say 17872.

- [ ] **Step 3: Write the implementation**

`LokalBot/CLISupport/AskLibraryEngine.swift`:

```swift
import Foundation

/// Minimal llama-server chat surface, protocol-shaped so tests mock it.
protocol LlamaChatClient {
    func healthy() async -> Bool
    func complete(messages: [[String: String]]) async throws -> String
}

/// Talks to the app's Main LLM llama-server on localhost. Port 17872 is
/// pinned against `LlamaServer.shared.baseURL` by a unit test.
struct URLSessionLlamaChatClient: LlamaChatClient {
    static let mainServerBaseURL = URL(string: "http://127.0.0.1:17872")!

    var baseURL = URLSessionLlamaChatClient.mainServerBaseURL

    func healthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func complete(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 1024,
        ] as [String: Any])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}

/// The privacy diode (spec §1): question in, local model reads the library,
/// only the synthesized answer + citations go back out. Owns the health
/// probe → wake → poll → complete flow and its error taxonomy (spec §9).
struct AskLibraryEngine {
    var gate: AgentAccessGate
    var client: LlamaChatClient = URLSessionLlamaChatClient()
    var loadMeetings: () throws -> [Meeting] = SessionLookup.loadAllMeetings
    /// One poll tick; production sleeps 1 s, tests substitute a no-op with
    /// side effects (writing wake errors, consuming the wake file).
    var pollDelay: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    var maxPollAttempts = 60

    func ask(_ question: String) async -> ToolResult {
        guard gate.isEnabled else {
            return .error(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(.invalidArguments, "ask_library requires a non-empty \"question\" string.")
        }

        if await !client.healthy(), let failure = await wakeAndWait() {
            return failure
        }

        let meetings = (try? loadMeetings()) ?? []
        guard !meetings.isEmpty else {
            return .text("The meeting library is empty — record a meeting in LokalBot first.")
        }
        let bundle = AskLibraryContext.build(question: trimmed, meetings: meetings)
        guard !bundle.contextText.isEmpty else {
            return .text("I couldn't find anything in your meetings matching that question. Try search_meetings with a specific keyword.")
        }

        let answer: String
        do {
            answer = try await client.complete(
                messages: AskLibraryContext.messages(question: trimmed,
                                                     contextText: bundle.contextText))
        } catch {
            return .error(.appNotRunning,
                          "Lost the connection to LokalBot's model server mid-answer (\(error.localizedDescription)). Make sure the LokalBot app is running and try again.")
        }
        return render(answer: answer, citations: bundle.citations)
    }

    /// llama-server is cold: touch the wake file (the app's watcher starts the
    /// engine, Task 10) and poll health. Returns nil once healthy, or the
    /// failure to hand back. Wake-file state disambiguates the timeout:
    /// still pending → nobody consumed it → the app isn't running; consumed
    /// but still unhealthy → the model is genuinely still loading.
    private func wakeAndWait() async -> ToolResult? {
        gate.clearWakeError()
        do {
            try gate.touchWake()
        } catch {
            return .error(.appNotRunning,
                          "Could not signal the LokalBot app (\(error.localizedDescription)). Open LokalBot and try again.")
        }
        for _ in 0..<maxPollAttempts {
            await pollDelay()
            if await client.healthy() { return nil }
            if let reason = gate.readWakeError() {
                return .error(.engineUnavailable, reason)
            }
        }
        if gate.pendingWake {
            return .error(.appNotRunning,
                          "ask_library needs the LokalBot app running (read tools still work without it). Open LokalBot and try again.")
        }
        return .error(.modelLoadingTimeout,
                      "The model is still loading. Try again in a moment — the first question after a cold start takes the longest.")
    }

    private func render(answer: String, citations: [AskLibraryContext.Citation]) -> ToolResult {
        guard !citations.isEmpty else { return .text(answer) }
        let sources = citations.map { "- \($0.title) (\($0.date), id \($0.meeting_id))" }
        return .text(answer + "\n\nSources:\n" + sources.joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AskLibraryEngineTests 2>&1 | tail -5
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli build 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **` (11 tests), then `** BUILD SUCCEEDED **`. The CLI-target build matters here: it proves `AskLibraryEngine.swift` uses nothing app-only (`LlamaServer` appears in the test file, which only the hosted unit suite compiles).

- [ ] **Step 5: Commit**

```bash
git add LokalBot/CLISupport/AskLibraryEngine.swift LokalBotTests/AskLibraryEngineTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add ask_library engine with llama health probe and app wake

Probes 127.0.0.1:17872, touches control/agent-wake when cold, polls up
to 60 s, and maps outcomes to engine_unavailable / app_not_running /
model_loading_timeout. Answers carry a Sources block, never transcripts.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 8: `mcp` subcommand + `HelperVersion`

Wire the dispatcher, gate, provider, and engine into a `lokalbot-cli mcp` subcommand that owns the stdio read-eval loop (spec §3). `serverInfo.version` comes from the enclosing app bundle's `Info.plist` — the helper lives at `Contents/Helpers/`, so `Contents/Info.plist` is two levels up — falling back to `"dev"` outside a bundle.

**Files:**
- Create: `LokalBot/CLISupport/HelperVersion.swift`
- Create: `CLI/Commands/MCPCommand.swift`
- Modify: `CLI/LokalBotCLI.swift` (register the subcommand)
- Test: `LokalBotTests/HelperVersionTests.swift`

**Interfaces:**
- Consumes: `MCPDispatcher(provider:serverVersion:)` (Task 2), `AgentAccessGate()` (Task 3), `FileLibraryToolProvider(gate:ask:)` (Task 5), `AskLibraryEngine(gate:)` (Task 7), `SessionLookup.storageRootURL`.
- Produces: `HelperVersion.current(binaryPath: String = CommandLine.arguments[0]) -> String`; the `lokalbot-cli mcp` verb that Task 9's integration tests, Task 12's skill text, Task 13's `.mcpb` shim, and Task 14's e2e step all invoke.

- [ ] **Step 1: Write the failing test**

`LokalBotTests/HelperVersionTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class HelperVersionTests: XCTestCase {
    func testReadsVersionFromEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helperversion-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Fake.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.9.9"],
            format: .xml, options: 0)
        try plist.write(to: root.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let binary = helpers.appendingPathComponent("lokalbot-cli")
        try Data().write(to: binary)

        XCTAssertEqual(HelperVersion.current(binaryPath: binary.path), "9.9.9")
    }

    func testFallsBackToDevOutsideABundle() {
        XCTAssertEqual(HelperVersion.current(binaryPath: "/tmp/loose-binary"), "dev")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/HelperVersionTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find 'HelperVersion' in scope`.

- [ ] **Step 3: Write `HelperVersion`**

`LokalBot/CLISupport/HelperVersion.swift`:

```swift
import Foundation

/// The version string the MCP handshake reports (spec §3): the enclosing app
/// bundle's `CFBundleShortVersionString`. Symlinks (the ~/.local/bin install)
/// are resolved first so the real bundle is found either way.
enum HelperVersion {
    static func current(binaryPath: String = CommandLine.arguments[0]) -> String {
        let binary = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()   // Helpers/
            .deletingLastPathComponent()   // Contents/
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            return "dev"
        }
        return version
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/HelperVersionTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (2 tests).

- [ ] **Step 5: Write the subcommand and register it**

`CLI/Commands/MCPCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the meeting library over MCP (stdio, JSON-RPC 2.0).",
        discussion: """
            For GUI agent clients (Claude Desktop, and any MCP-capable app):

              claude mcp add lokalbot -- \
                /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp

            Tools: list_meetings, get_meeting, search_meetings, ask_library.
            Read tools work with the app closed; ask_library needs the app
            running (it answers with the local model on localhost:17872).

            All tools require the Privacy toggle: LokalBot → Settings →
            Privacy → "Allow external agents to read your meeting library".
            While it is off, the handshake still succeeds and every call
            returns a structured access_disabled error with enable steps.
            """
    )

    func run() async throws {
        let gate = AgentAccessGate()
        let engine = AskLibraryEngine(gate: gate)
        let provider = FileLibraryToolProvider(gate: gate) { question in
            await engine.ask(question)
        }
        let dispatcher = MCPDispatcher(provider: provider,
                                       serverVersion: HelperVersion.current())

        FileHandle.standardError.write(Data(
            "lokalbot-cli mcp: serving on stdio (library: \(SessionLookup.storageRootURL.path))\n".utf8))

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await dispatcher.handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
```

In `CLI/LokalBotCLI.swift`, extend the `subcommands` array:

```swift
        subcommands: [ListCommand.self, GetCommand.self, SearchCommand.self, PathCommand.self,
                      MCPCommand.self]
```

- [ ] **Step 6: Build and smoke-test the loop by hand**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli -configuration Release \
  build SYMROOT="$(pwd)/build" 2>&1 | tail -3
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  | ./build/Release/lokalbot-cli mcp
```

Expected: `** BUILD SUCCEEDED **`; stderr shows the serving banner; stdout is exactly one JSON line containing `"serverInfo"`, `"name":"lokalbot"`, and `"version":"dev"` (a loose binary has no enclosing bundle). The process exits 0 on stdin EOF.

- [ ] **Step 7: Commit**

```bash
git add LokalBot/CLISupport/HelperVersion.swift LokalBotTests/HelperVersionTests.swift \
        CLI/Commands/MCPCommand.swift CLI/LokalBotCLI.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add mcp subcommand serving the meeting library over stdio

MCP clients spawn `lokalbot-cli mcp` and speak JSON-RPC over stdio; the
handshake reports the enclosing app bundle's version. No new processes
or listeners — the read-eval loop runs in the helper the app already
embeds and code-signs.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 9: Golden stdio integration tests

Spec §10's integration layer: pipe scripted sessions into the *embedded* helper binary (`LokalBot.app/Contents/Helpers/lokalbot-cli`) as a real subprocess against a fixture library, and assert on the JSON that comes back. This is what catches wiring bugs the in-process unit tests can't (argv parsing, stdio buffering, env propagation, the embed step itself).

**Files:**
- Test: `LokalBotTests/MCPServerIntegrationTests.swift`

**Interfaces:**
- Consumes: the `lokalbot-cli mcp` verb (Task 8), `AgentAccessGate(root:)` (Task 3), `MeetingFixture` (Task 4). Nothing new produced — this task is pure verification.

- [ ] **Step 1: Write the integration test**

`LokalBotTests/MCPServerIntegrationTests.swift`:

```swift
import XCTest
@testable import LokalBot

/// Spawns the embedded helper as a real subprocess and speaks MCP to it over
/// pipes. The unit suite is hosted inside LokalBot.app, so the helper sits at
/// a fixed path relative to Bundle.main.
final class MCPServerIntegrationTests: XCTestCase {
    private var root: URL!

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lokalbot-cli")
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw XCTSkip("no embedded lokalbot-cli in this build")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AgentAccessGate(root: root).enable()

        try MeetingFixture.write([
            .init(id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                  title: "Cache planning",
                  startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                  summary: "We chose Redis for the caching layer.",
                  transcriptLines: ["Redis wins because of pub sub."]),
        ], under: root)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// Writes `lines` to the helper's stdin, closes it (EOF ends the loop),
    /// and returns stdout split into lines. The child sees only the fixture
    /// library via LOKALBOT_STORAGE_ROOT.
    private func runSession(_ lines: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["LOKALBOT_STORAGE_ROOT"] = root.path
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        stdin.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        stdin.fileHandleForWriting.closeFile()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    func testGoldenSessionInitializeListCall() throws {
        let output = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"redis"}}}"#,
        ])
        XCTAssertEqual(output.count, 3, "the notification must produce no response line")
        XCTAssertTrue(output[0].contains(#""protocolVersion":"2025-06-18""#))
        XCTAssertTrue(output[0].contains(#""name":"lokalbot""#))
        for tool in ["list_meetings", "get_meeting", "search_meetings", "ask_library"] {
            XCTAssertTrue(output[1].contains("\"\(tool)\""), tool)
        }
        XCTAssertTrue(output[2].lowercased().contains("redis"))
        XCTAssertTrue(output[2].contains(#""isError":false"#))
    }

    func testToolsRefusedWithoutMarker() throws {
        AgentAccessGate(root: root).disable()
        let output = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#,
        ])
        XCTAssertEqual(output.count, 2, "handshake must still work with access off")
        XCTAssertTrue(output[1].contains("[access_disabled]"))
        XCTAssertTrue(output[1].contains(#""isError":true"#))
    }
}
```

- [ ] **Step 2: Run the integration tests**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/MCPServerIntegrationTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (2 tests) — everything under test already exists, so these pass first try; a failure here is a wiring bug (debug by printing the stderr pipe, which carries the serving banner and any crash output).

- [ ] **Step 3: Run the full unit suite to catch regressions**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add LokalBotTests/MCPServerIntegrationTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add golden stdio integration tests for the MCP server

Scripted initialize → tools/list → tools/call sessions piped into the
embedded helper as a real subprocess against a fixture library, plus the
access-off refusal path.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 10: `AgentAccessManager` — app-side toggle state + wake watcher

The app side of the wake protocol (spec §5–§6): one `@MainActor ObservableObject` that mirrors the Privacy toggle to the marker file, watches `control/` with a `DispatchSource` while enabled, consumes wake files, starts the Main LLM, and writes the wake-error file when it can't serve. Engine start is injected so tests never launch llama-server.

**Files:**
- Create: `LokalBot/Services/AgentAccessManager.swift`
- Modify: `LokalBot/LokalBotApp.swift` (AppState property + startup call)
- Test: `LokalBotTests/AgentAccessManagerTests.swift`

**Interfaces:**
- Consumes: `AgentAccessGate` (Task 3); app-only `AgentLLMEndpointResolver.resolve(settings:)` (cases `.ready/.builtIn/.unsupported`), `ModelCatalog.entry(id:custom:)/localURL(for:storage:)`, `LlamaServer.shared.ensureRunning(modelAt:)`, `StorageManager`, `AppSettings` — mirroring `AgentSessionController.resolveEndpoint` (`LokalBot/Agent/AgentSessionController.swift:267`). This file lives in `Services/` (NOT `CLISupport/`) precisely because it uses app-only types.
- Produces: `AgentAccessManager(storage:settings:gate:startEngine:)` with `@Published private(set) var isEnabled`, `func start()`, `func setEnabled(_:)`, `static func startMainLLM(settings:storage:) async -> String?`; `AppState.agentAccess`. Task 11's toggle row binds to it.

- [ ] **Step 1: Write the failing test**

`LokalBotTests/AgentAccessManagerTests.swift`:

```swift
import XCTest
@testable import LokalBot

@MainActor
final class AgentAccessManagerTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accessmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager(
        startEngine: @escaping (AppSettings, StorageManager) async -> String? = { _, _ in nil }
    ) -> AgentAccessManager {
        AgentAccessManager(storage: StorageManager(),
                           settings: { AppSettings() },
                           gate: gate,
                           startEngine: startEngine)
    }

    func testToggleMirrorsMarkerFile() {
        let manager = makeManager()
        manager.start()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(gate.isEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)
    }

    func testStartResumesEnabledStateFromMarker() throws {
        try gate.enable()
        let manager = makeManager()
        manager.start()
        XCTAssertTrue(manager.isEnabled)
    }

    func testWakeTouchStartsEngineAndConsumesWake() async throws {
        let woke = expectation(description: "engine started")
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [woke], timeout: 5)
        // Give the post-start sweep a beat, then verify the wake was consumed
        // and no error was written.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(gate.pendingWake)
        XCTAssertNil(gate.readWakeError())
    }

    func testEngineFailureWritesWakeErrorFile() async throws {
        let failed = expectation(description: "engine refused")
        let manager = makeManager { _, _ in
            failed.fulfill()
            return "The built-in model isn't downloaded."
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [failed], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gate.readWakeError(), "The built-in model isn't downloaded.")
    }

    func testNoWakeHandlingAfterDisable() async throws {
        let woke = expectation(description: "engine started")
        woke.isInverted = true
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)
        manager.setEnabled(false)

        try? gate.touchWake()   // may fail if control/ was removed — fine either way
        await fulfillment(of: [woke], timeout: 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AgentAccessManagerTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `cannot find 'AgentAccessManager' in scope`.

- [ ] **Step 3: Write the implementation**

`LokalBot/Services/AgentAccessManager.swift`:

```swift
import Combine
import Foundation

/// App-side owner of external-agent access (spec §6): mirrors the Privacy
/// toggle to the `control/agent-access-enabled` marker file and, while
/// enabled, watches `control/` for the CLI's wake file and starts the Main
/// LLM in response. Lives in Services/ (not CLISupport/) because starting
/// the engine needs app-only types (ModelCatalog, LlamaServer).
@MainActor
final class AgentAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false

    private let gate: AgentAccessGate
    private let storage: StorageManager
    private let settings: () -> AppSettings
    /// Starts the Main LLM and returns nil, or the reason it can't serve
    /// (written to the wake-error file for the CLI to relay). Injected so
    /// tests never launch llama-server.
    private let startEngine: (AppSettings, StorageManager) async -> String?

    private var watcher: DispatchSourceFileSystemObject?
    private var handlingWake = false

    init(storage: StorageManager,
         settings: @escaping () -> AppSettings,
         gate: AgentAccessGate = AgentAccessGate(),
         startEngine: ((AppSettings, StorageManager) async -> String?)? = nil) {
        self.storage = storage
        self.settings = settings
        self.gate = gate
        self.startEngine = startEngine ?? { await Self.startMainLLM(settings: $0, storage: $1) }
    }

    /// Call once at app startup: resumes the state the user left behind.
    /// The marker file is the cross-process truth, not UserDefaults.
    func start() {
        isEnabled = gate.isEnabled
        if isEnabled { startWatcher() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do { try gate.enable() } catch { return }
            isEnabled = true
            startWatcher()
        } else {
            stopWatcher()
            gate.disable()
            isEnabled = false
        }
    }

    // MARK: - Wake watcher

    private func startWatcher() {
        guard watcher == nil else { return }
        let descriptor = open(gate.controlDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleControlDirectoryChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        // A wake touched before the watcher existed would sit unanswered —
        // sweep once immediately.
        handleControlDirectoryChange()
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    private func handleControlDirectoryChange() {
        guard !handlingWake, gate.consumeWake() else { return }
        handlingWake = true
        Task { @MainActor in
            if let failure = await startEngine(settings(), storage) {
                gate.writeWakeError(failure)
            } else {
                gate.clearWakeError()
            }
            handlingWake = false
            // A wake touched while the engine was starting still needs answering.
            handleControlDirectoryChange()
        }
    }

    // MARK: - Engine start

    /// Mirrors the built-in branch of `AgentSessionController.resolveEndpoint`:
    /// only the bundled llama-server can answer ask_library on 17872.
    static func startMainLLM(settings: AppSettings, storage: StorageManager) async -> String? {
        switch AgentLLMEndpointResolver.resolve(settings: settings) {
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings.customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID),
                  let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                return "The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again."
            }
            do {
                try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
                return nil
            } catch {
                return "LokalBot's model server failed to start: \(error.localizedDescription)"
            }
        case .ready:
            return "The Main LLM is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models."
        case .unsupported(let reason):
            return reason
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/AgentAccessManagerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (5 tests). If `AgentLLMEndpointResolver.resolve` or `ModelCatalog` signatures don't match, copy the exact call shapes from `LokalBot/Agent/AgentSessionController.swift:267-283` — that code is the source of truth this mirrors.

- [ ] **Step 5: Wire into AppState**

In `LokalBot/LokalBotApp.swift`, add a stored property inside `AppState`, directly below `let audioMonitor = AudioSourceMonitor()`:

```swift
    /// External-agent access (Privacy toggle + wake watcher). Lazy because it
    /// captures `settings`, which is itself set up during init.
    private(set) lazy var agentAccess = AgentAccessManager(
        storage: storage,
        settings: { [weak self] in self?.settings ?? AppSettings.load() })
```

And in the startup block, directly after `AppUpdateManager.shared.start()`:

```swift
        // Resume the external-agent wake watcher if the Privacy toggle was
        // left on (the marker file under the storage root is the truth).
        agentAccess.start()
```

- [ ] **Step 6: Build the app target to verify the wiring**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot Dev" -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add LokalBot/Services/AgentAccessManager.swift LokalBotTests/AgentAccessManagerTests.swift \
        LokalBot/LokalBotApp.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add app-side agent-access manager with llama wake watcher

Mirrors the Privacy toggle to the control marker file; while enabled, a
DispatchSource on control/ consumes agent-wake touches, starts the Main
LLM, and writes agent-wake-error with the reason when it cannot serve
(external engine, model missing, launch failure).

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 11: Privacy toggle row in Settings

The user-facing switch (spec §6): a new row in Settings → Privacy, default off, with copy that says exactly what it enables. A dedicated `@ObservedObject` row view is required — `AgentAccessManager` is a nested `ObservableObject`, so its `@Published` changes do NOT fire `AppState.objectWillChange`, and binding through `app.agentAccess` directly would never refresh the toggle.

**Files:**
- Modify: `LokalBot/Views/SettingsView.swift` (privacy section at ~line 325 + its `shows` keywords)

**Interfaces:**
- Consumes: `AppState.agentAccess` (Task 10: `isEnabled`, `setEnabled(_:)`).
- Produces: UI only; nothing downstream consumes it.

- [ ] **Step 1: Add the toggle row view**

At the bottom of `LokalBot/Views/SettingsView.swift` (file scope, next to the other private helper views):

```swift
/// Dedicated row so the toggle observes AgentAccessManager directly —
/// a nested ObservableObject's changes don't flow through AppState.
private struct AgentAccessToggleRow: View {
    @ObservedObject var manager: AgentAccessManager

    var body: some View {
        Group {
            Toggle("Allow external agents to read your meeting library", isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }))
            Text("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, and search your meetings, and ask questions answered by your local model — read-only, localhost only. Off by default; while off, agent tools return an error explaining how to enable this.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Insert the row and searchable keywords**

In `privacySection`, after the existing OCR-retention caption `Text(...)` (the last row inside `Section("Privacy")`), add:

```swift
                    AgentAccessToggleRow(manager: app.agentAccess)
```

And extend the section's `shows` keyword array so Settings search finds it — change:

```swift
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security"]) {
```

to:

```swift
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security", "agents", "mcp", "claude", "cli"]) {
```

- [ ] **Step 3: Build and run the full unit suite**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot Dev" -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`. (The toggle's behavior is covered by AgentAccessManagerTests; this step verifies the view compiles and nothing regressed. Optionally run the Dev app and flip the toggle: `ls "$HOME/Library/Application Support/me.dotenv.LokalBot.dev/control/"` should show `agent-access-enabled` appear and disappear — note the Dev bundle id.)

- [ ] **Step 4: Commit**

```bash
git add LokalBot/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
Add Privacy toggle for external agent access

Default off. A dedicated ObservedObject row keeps the switch live —
AgentAccessManager is nested, so its changes bypass AppState.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 12: `install-skill` subcommand + installer extension + SKILL.md rewrite

Spec §7. Three pieces that only make sense together: move `LokalBotCLIInstaller` into `CLISupport/` so the CLI target can use it, extend it with a Claude-skills link + copy mode + self-location, add the `install-skill` verb, and rewrite the bundled skill text (stale `com.dotenv.BotinaV2` path, no ask_library/MCP guidance).

Note: the repo has TWO skill files. `.agents/skills/lokalbot-cli/SKILL.md` is the one bundled to `Contents/Resources/lokalbot-cli/` (project.yml line 74) and symlinked by the installer — **this one gets rewritten**. `LokalBot/Resources/pi/lokalbot-cli-skill/SKILL.md` is the embedded pi agent's own short variant with no stale paths — **leave it untouched** (pi preconnects to the CLI already and gains nothing from MCP guidance).

**Files:**
- Move: `LokalBot/Services/LokalBotCLIInstaller.swift` → `LokalBot/CLISupport/LokalBotCLIInstaller.swift` (`git mv`, then extend)
- Create: `CLI/Commands/InstallSkillCommand.swift`
- Modify: `CLI/LokalBotCLI.swift` (register), `.agents/skills/lokalbot-cli/SKILL.md` (rewrite)
- Test: `LokalBotTests/LokalBotCLIInstallerTests.swift` (new — the installer had no tests)

**Interfaces:**
- Consumes: existing `LokalBotCLIInstaller` internals (`replaceSymlink/ensureDirectory/symlink(_:resolvesTo:)/isExistingDirectory`, `InstallError`, `binLink`, `skillLink`, `pathExportLine`, `localBinOnPath`); `ArgumentParser`.
- Produces: `claudeSkillLink: URL`; `SkillMode` (`.symlink`/`.copy`); `install(skillMode: SkillMode = .symlink)` (replaces `install()` — existing app-side call sites compile unchanged via the default); `uninstall()` extended to three links + copied dirs; `static let copyMarkerName = ".lokalbot-skill-copy"`; `static func fromCurrentBinary(path:fileManager:) -> LokalBotCLIInstaller?`; the `lokalbot-cli install-skill` verb.

- [ ] **Step 1: Move the installer into the shared layer**

```bash
git mv LokalBot/Services/LokalBotCLIInstaller.swift LokalBot/CLISupport/LokalBotCLIInstaller.swift
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **` — the file uses only Foundation + os + `AppIdentifiers`, all available to the CLI target. (`Bundle.main` appears only inside `static var bundled`, which the CLI simply never calls.)

- [ ] **Step 2: Write the failing tests**

`LokalBotTests/LokalBotCLIInstallerTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class LokalBotCLIInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: URL!
    private var skillDir: URL!
    private var installer: LokalBotCLIInstaller!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliinstaller-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        let helpers = root.appendingPathComponent("Applications/LokalBot.app/Contents/Helpers")
        skillDir = root.appendingPathComponent("Applications/LokalBot.app/Contents/Resources/lokalbot-cli")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        binary = helpers.appendingPathComponent("lokalbot-cli")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try Data("skill".utf8).write(to: skillDir.appendingPathComponent("SKILL.md"))

        installer = LokalBotCLIInstaller(
            home: home, bundledBinary: binary, bundledSkillDir: skillDir,
            fileManager: .default, environment: [:])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func testInstallCreatesAllThreeSymlinks() throws {
        try installer.install()
        XCTAssertTrue(isSymlink(installer.binLink))
        XCTAssertTrue(isSymlink(installer.skillLink))
        XCTAssertTrue(isSymlink(installer.claudeSkillLink))
        XCTAssertTrue(installer.isInstalled)
    }

    func testInstallIsIdempotent() throws {
        try installer.install()
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
    }

    func testCopyModeCopiesSkillDirsWithMarker() throws {
        try installer.install(skillMode: .copy)
        XCTAssertTrue(isSymlink(installer.binLink), "binary stays a symlink even in copy mode")
        for dir in [installer.skillLink, installer.claudeSkillLink] {
            XCTAssertFalse(isSymlink(dir))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("SKILL.md").path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(LokalBotCLIInstaller.copyMarkerName).path))
        }
    }

    func testUninstallRemovesSymlinkInstall() throws {
        try installer.install()
        try installer.uninstall()
        for link in [installer.binLink, installer.skillLink, installer.claudeSkillLink] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: link.path), link.path)
            XCTAssertFalse(isSymlink(link), link.path)
        }
    }

    func testUninstallRemovesCopiedInstall() throws {
        try installer.install(skillMode: .copy)
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.skillLink.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.claudeSkillLink.path))
    }

    func testUninstallLeavesForeignFilesAlone() throws {
        // A foreign symlink at our binary path and a real user directory
        // (no marker) at our claude path must both survive uninstall.
        try FileManager.default.createDirectory(
            at: installer.binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.binLink, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createDirectory(
            at: installer.claudeSkillLink, withIntermediateDirectories: true)
        try Data("mine".utf8).write(
            to: installer.claudeSkillLink.appendingPathComponent("SKILL.md"))

        try installer.uninstall()
        XCTAssertTrue(isSymlink(installer.binLink))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.claudeSkillLink.appendingPathComponent("SKILL.md").path))
    }

    func testFromCurrentBinaryFindsTheBundle() {
        let found = LokalBotCLIInstaller.fromCurrentBinary(path: binary.path)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.bundledBinary?.resolvingSymlinksInPath().path,
                       binary.resolvingSymlinksInPath().path)
        XCTAssertEqual(found?.bundledSkillDir?.resolvingSymlinksInPath().path,
                       skillDir.resolvingSymlinksInPath().path)

        XCTAssertNil(LokalBotCLIInstaller.fromCurrentBinary(path: "/tmp/loose-binary"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/LokalBotCLIInstallerTests 2>&1 | tail -5
```

Expected: BUILD FAILED — `value of type 'LokalBotCLIInstaller' has no member 'claudeSkillLink'`.

- [ ] **Step 4: Extend the installer**

In `LokalBot/CLISupport/LokalBotCLIInstaller.swift`:

**(a)** Below the existing `var skillLink` declaration, add:

```swift
    /// Claude Code's user-skill path — linked in addition to the canonical
    /// `~/.agents` path so the skill shows up in both discovery locations.
    var claudeSkillLink: URL { home.appending(path: ".claude/skills/lokalbot-cli") }

    /// Marker written inside copied skill directories so `uninstall` only
    /// ever deletes directories this installer created.
    static let copyMarkerName = ".lokalbot-skill-copy"

    enum SkillMode { case symlink, copy }
```

**(b)** Update `touchedPaths`:

```swift
    var touchedPaths: [String] {
        ["~/.local/bin/lokalbot-cli", "~/.agents/skills/lokalbot-cli", "~/.claude/skills/lokalbot-cli"]
    }
```

**(c)** Replace `func install() throws { … }` entirely with:

```swift
    /// Place the links. Idempotent: existing symlinks pointing at this bundle
    /// are left alone; symlinks pointing elsewhere are replaced. In `.copy`
    /// mode the skill directories are real copies (for agents that can't
    /// follow symlinks) stamped with `copyMarkerName`; the binary link is
    /// always a symlink so it tracks app updates.
    func install(skillMode: SkillMode = .symlink) throws {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            throw InstallError.bundleNotShipped
        }
        guard isBundleLocationStable else { throw InstallError.bundleNotStable }

        try ensureDirectory(binLink.deletingLastPathComponent())
        try replaceSymlink(at: binLink, target: binary)
        for link in [skillLink, claudeSkillLink] {
            try ensureDirectory(link.deletingLastPathComponent())
            switch skillMode {
            case .symlink: try replaceSymlink(at: link, target: skill)
            case .copy: try replaceWithCopy(at: link, of: skill)
            }
        }
        logger.info("CLI installed at \(binLink.path) -> \(binary.path)")
    }
```

**(d)** Replace `func uninstall() throws { … }` entirely with:

```swift
    /// Remove what we created and nothing else: symlinks that resolve into a
    /// LokalBot app bundle (incl. the legacy LokalBotV3 name), and copied
    /// skill directories carrying our marker. Foreign files at our canonical
    /// paths are left alone.
    func uninstall() throws {
        for link in [binLink, skillLink, claudeSkillLink] {
            if let destPath = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if destPath.contains("LokalBot.app/") || destPath.contains("LokalBotV3.app/") {
                    try fileManager.removeItem(at: link)
                }
            } else if isExistingDirectory(link),
                      fileManager.fileExists(atPath: link.appendingPathComponent(Self.copyMarkerName).path) {
                try fileManager.removeItem(at: link)
            }
        }
        logger.info("CLI uninstalled")
    }
```

**(e)** Below `static var bundled`, add:

```swift
    /// Installer wired from the CLI's own binary location (argv[0]) — how the
    /// `install-skill` subcommand finds the bundle it lives in. Nil when the
    /// binary isn't inside an app bundle (loose local builds).
    static func fromCurrentBinary(path: String = CommandLine.arguments[0],
                                  fileManager: FileManager = .default) -> LokalBotCLIInstaller? {
        let binary = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()   // Helpers/
            .deletingLastPathComponent()   // Contents/
        guard contents.lastPathComponent == "Contents" else { return nil }
        let skill = contents.appending(path: "Resources/lokalbot-cli")
        guard fileManager.fileExists(atPath: binary.path),
              fileManager.fileExists(atPath: skill.path) else { return nil }
        return LokalBotCLIInstaller(
            home: fileManager.homeDirectoryForCurrentUser,
            bundledBinary: binary,
            bundledSkillDir: skill,
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment)
    }
```

**(f)** Next to `replaceSymlink` in the private section, add:

```swift
    private func replaceWithCopy(at destination: URL, of source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
            try Data().write(to: destination.appendingPathComponent(Self.copyMarkerName))
        } catch {
            throw InstallError.fileSystem("Could not copy skill to \(destination.path): \(error.localizedDescription)")
        }
    }
```

**(g)** In the type's doc comment, delete the now-wrong line "Pattern ported from Seminarly's `SeminarlyCLIInstaller`, simplified to the canonical skill path only (LokalBot does not also link `~/.claude/skills`)." and replace with "Pattern ported from Seminarly's `SeminarlyCLIInstaller`; links both `~/.agents/skills` and `~/.claude/skills`." `isInstalled` stays deliberately unchanged (binary + `.agents` skill pair) — the Claude link is additive and shouldn't flip the app UI to "not installed" for users who installed before it existed.

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test \
  -only-testing:LokalBotTests/LokalBotCLIInstallerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (7 tests).

- [ ] **Step 6: Add the `install-skill` subcommand**

`CLI/Commands/InstallSkillCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct InstallSkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skill",
        abstract: "Install the LokalBot skill and CLI symlinks for coding agents.",
        discussion: """
            Symlinks the app-bundled skill into ~/.agents/skills/lokalbot-cli
            and ~/.claude/skills/lokalbot-cli, and this binary into
            ~/.local/bin/lokalbot-cli. Symlinks track app updates
            automatically; pass --copy if your agent can't follow symlinks.
            Nothing is installed unless you run this.
            """
    )

    @Flag(name: .long, help: "Copy the skill directories instead of symlinking.")
    var copy: Bool = false

    @Flag(name: .long, help: "Remove everything install-skill created.")
    var uninstall: Bool = false

    func run() async throws {
        guard let installer = LokalBotCLIInstaller.fromCurrentBinary() else {
            throw ValidationError("""
                This binary isn't inside LokalBot.app, so there is no bundled \
                skill to install. Run the embedded helper instead:
                  /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli install-skill
                """)
        }
        if uninstall {
            try installer.uninstall()
            print("Removed the lokalbot-cli symlinks and skill installs.")
            return
        }
        try installer.install(skillMode: copy ? .copy : .symlink)
        let helper = installer.bundledBinary?.path
            ?? "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli"
        print("""
            Installed:
              \(installer.binLink.path)
              \(installer.skillLink.path)
              \(installer.claudeSkillLink.path)

            Claude Code picks the skill up automatically; point other agents
            at one of the skill directories above.

            MCP clients (Claude Desktop, ...) can add the same library with:
              claude mcp add lokalbot -- \(helper) mcp
            """)
        if !installer.localBinOnPath {
            print("""

                Note: ~/.local/bin isn't on your PATH. Add it with:
                  echo '\(LokalBotCLIInstaller.pathExportLine)' >> ~/.zshrc
                """)
        }
    }
}
```

In `CLI/LokalBotCLI.swift`, the array becomes:

```swift
        subcommands: [ListCommand.self, GetCommand.self, SearchCommand.self, PathCommand.self,
                      MCPCommand.self, InstallSkillCommand.self]
```

- [ ] **Step 7: Rewrite the bundled skill**

Replace the entire contents of `.agents/skills/lokalbot-cli/SKILL.md` with:

```markdown
---
name: lokalbot-cli
description: Read your LokalBot meeting library (recordings, transcripts, summaries) from a shell command. Use whenever the user asks about past meetings, decisions, action items, or anything that happened during a recorded meeting.
---

# LokalBot CLI Skill

LokalBot is a private, on-device AI workspace for macOS that records, transcribes, and summarises meetings entirely on-device. Audio, transcripts, and summaries live under `~/Library/Application Support/me.dotenv.LokalBot/meetings/`. The `lokalbot-cli` binary reads that library and prints meeting data so agents and shell scripts can use it without launching the GUI.

If `lokalbot-cli` isn't on PATH, use the embedded copy directly:
`/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

## When to invoke

- The user mentions a meeting, call, sync, standup, or talk that probably happened recently.
- The user asks about a decision, an action item, a quote, or "who said X" — that knowledge likely lives in a meeting summary or transcript.
- The user wants to find past mentions of a topic across all meetings.

## Picking the right verb

- `list` to surface candidate meetings (ids, titles, dates).
- `get` for the substance of one meeting — quote real snippets.
- `search` when the user remembers a phrase but not the meeting.
- `path` for the on-disk folder (grep, audio files).

## Discovery

```bash
# Newest 10 meetings, JSON
lokalbot-cli list --limit 10

# Human-readable table
lokalbot-cli list --limit 10 --table

# Filter by date or title substring
lokalbot-cli list --since 2026-06-01 --query "design"
```

The `id` field in each list entry is an 8-character prefix that the other commands accept.

## Reading a single meeting

```bash
# The most recent meeting, full markdown
lokalbot-cli get latest

# Specific meeting by short id
lokalbot-cli get 4f7c2a91

# Just the summary, as JSON (parse-friendly for agents)
lokalbot-cli get 4f7c2a91 --include summary --format json

# Transcript only
lokalbot-cli get 4f7c2a91 --include transcript
```

`--include` accepts a comma-separated list of `metadata`, `summary`, `transcript`. Default is all three.

## Cross-meeting search

```bash
# Substring search across titles, summaries, and transcripts
lokalbot-cli search "auth refactor"

# Quick scan, table form
lokalbot-cli search "auth refactor" --table --limit 20
```

Transcript hits include a `timestamp` (HH:MM:SS) so the user can jump to that moment in the in-app player.

## Path lookup

```bash
# Library root (useful for grep/ripgrep)
lokalbot-cli path

# A specific meeting's folder — `mic.m4a`, `system.m4a`, `summary.md`, etc.
lokalbot-cli path latest
cd $(lokalbot-cli path latest)
```

## MCP alternative (and ask_library)

The same library is available over MCP for GUI clients and anything else that speaks it: `lokalbot-cli mcp` serves `list_meetings`, `get_meeting`, `search_meetings`, and `ask_library` on stdio.

```bash
claude mcp add lokalbot -- /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp
```

`ask_library` is the synthesis tool: it sends the question to LokalBot's **local** model, which reads the library and returns only an answer with meeting citations — useful when the user wants a conclusion rather than quotes. It needs the LokalBot app running, and the first call can take up to a minute while the model loads. Prefer `search`/`get` when the user wants exact wording.

The MCP tools require the user's consent toggle: LokalBot → Settings → Privacy → "Allow external agents to read your meeting library". If a tool returns `[access_disabled]`, tell the user to flip that toggle — do not try to work around it.

## What you SHOULD do

- Lead with `list` to surface candidate meetings.
- Use `get` for the substance — quote actual snippets, never paraphrase past the meeting summary.
- Use `search` when the user remembers a phrase but not when the meeting happened.
- Cite the meeting by title and date in your answer; the `list` output has both.

## What you MUST NOT do

- Never invent meeting content. If `lokalbot-cli` returns no hits, say so.
- Never write into the meetings folder. The CLI is read-only by design.
- Never paste full transcripts into the chat unless explicitly asked — long meetings are long. Summarise, then offer to expand.
- Meeting content is sensitive personal data. Never send transcripts or summaries to external services; work with them locally.
```

- [ ] **Step 8: Build both targets, run the full suite**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -target lokalbot-cli build 2>&1 | tail -3
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add LokalBot/CLISupport/LokalBotCLIInstaller.swift CLI/Commands/InstallSkillCommand.swift \
        CLI/LokalBotCLI.swift .agents/skills/lokalbot-cli/SKILL.md \
        LokalBotTests/LokalBotCLIInstallerTests.swift LokalBot.xcodeproj
git rm --cached LokalBot/Services/LokalBotCLIInstaller.swift 2>/dev/null || true
git commit -m "$(cat <<'EOF'
Add install-skill verb and rewrite the agent skill

The installer moves to CLISupport so the CLI can self-install: symlinks
into ~/.local/bin, ~/.agents/skills, and now ~/.claude/skills, with
--copy for agents that can't follow symlinks and --uninstall that only
removes what we created. SKILL.md loses the stale com.dotenv.BotinaV2
path and gains ask_library/MCP guidance.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

(The `git rm --cached` is belt-and-braces; `git mv` in Step 1 already staged the rename.)

---

### Task 13: `.mcpb` bundle build script

Spec §8. A one-click bundle for GUI MCP clients (Claude Desktop). The bundle contains **no binary** — its entry shim execs the installed app's signed helper, so there is no second copy to drift or re-sign. Spec §13 explicitly defers exact manifest field names to implementation: the script runs the official validator, and if the validator rejects a field name, adjust the manifest per its output — that is the sanctioned verification path, not a plan deviation.

**Files:**
- Create: `Scripts/release/build-mcpb.sh` (executable)
- No `.gitignore` change: `dist/` is already ignored (line 20).

**Interfaces:**
- Consumes: `project.yml` (`CFBundleShortVersionString`, line ~124 — there is NO `MARKETING_VERSION` key, don't grep for one); the `mcp` subcommand from Task 8; `npx @anthropic-ai/mcpb` (packer + validator, fetched on demand).
- Produces: `dist/LokalBot.mcpb` — attached to releases by hand (release automation wiring is out of scope).

- [ ] **Step 1: Write the script**

`Scripts/release/build-mcpb.sh`:

```bash
#!/bin/bash
# Build dist/LokalBot.mcpb — a one-click MCP bundle for GUI clients
# (Claude Desktop, ...). The bundle contains NO binary: its entry shim
# execs the installed app's signed helper, so there is no second copy
# to drift or re-sign. Requires npm (npx) for the mcpb packer.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || { echo "could not read CFBundleShortVersionString from project.yml" >&2; exit 1; }

STAGE=$(mktemp -d /tmp/lokalbot-mcpb.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

# ${__dirname} is the mcpb runtime's substitution for the unpacked bundle
# directory — it must land in the JSON literally, hence the escape.
cat > "$STAGE/manifest.json" <<MANIFEST
{
  "manifest_version": "0.2",
  "name": "lokalbot",
  "display_name": "LokalBot Meetings",
  "version": "$VERSION",
  "description": "Ask your private, on-device meeting library: list, read, and search meetings, or get synthesized answers from LokalBot's local model. Requires the LokalBot app (lokalbot.me).",
  "author": { "name": "LokalBot" },
  "server": {
    "type": "binary",
    "entry_point": "run.sh",
    "mcp_config": {
      "command": "\${__dirname}/run.sh",
      "args": []
    }
  },
  "compatibility": { "platforms": ["darwin"] }
}
MANIFEST

cat > "$STAGE/run.sh" <<'RUNSH'
#!/bin/bash
CLI="/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli"
if [ ! -x "$CLI" ]; then
  echo "LokalBot.app not found in /Applications — install LokalBot first (https://lokalbot.me), then re-enable this extension." >&2
  exit 1
fi
exec "$CLI" mcp
RUNSH
chmod +x "$STAGE/run.sh"

npx -y @anthropic-ai/mcpb validate "$STAGE/manifest.json"
mkdir -p dist
npx -y @anthropic-ai/mcpb pack "$STAGE" dist/LokalBot.mcpb
echo "built dist/LokalBot.mcpb (version $VERSION)"
```

```bash
chmod +x Scripts/release/build-mcpb.sh
```

- [ ] **Step 2: Run it**

```bash
Scripts/release/build-mcpb.sh
```

Expected: validator prints its OK line, then `built dist/LokalBot.mcpb (version 0.1.5)` (version = whatever `project.yml` currently says). **If `mcpb validate` rejects a field name** (the spec anticipates this — §13), read its error, fix the manifest heredoc to match the current spec, and re-run until it validates. Do not skip validation.

- [ ] **Step 3: Inspect the bundle**

```bash
unzip -l dist/LokalBot.mcpb
```

Expected: an archive listing containing `manifest.json` and `run.sh` (an `.mcpb` is a zip). No binaries inside.

- [ ] **Step 4: Commit (script only — `dist/` is gitignored)**

```bash
git add Scripts/release/build-mcpb.sh
git commit -m "$(cat <<'EOF'
Add .mcpb bundle build script

The bundle ships only a manifest and a shim that execs the installed
app's signed helper (lokalbot-cli mcp) — no second binary to drift or
re-sign. Fails with an install-LokalBot-first message when the app is
missing.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 14: e2e step T11 + CLAUDE.md + final verification

Spec §10 (e2e bullet) and housekeeping: teach `Scripts/test/e2e.sh` to exercise the real MCP server end-to-end, document the new surface in CLAUDE.md, and run the whole suite one last time.

**Files:**
- Modify: `Scripts/test/e2e.sh` (insert T11 after the T10 block, line ~147)
- Modify: `CLAUDE.md` (extend the `lokalbot-cli` paragraph; add `control/` to the storage tree)

**Interfaces:**
- Consumes: the T2 fixture (its transcript contains "Redis"); `$ROOT` = the suite's hermetic `LOKALBOT_STORAGE_ROOT`; the `mcp` verb (Task 8); the gate marker `control/agent-access-enabled` (Task 3); llama-server health on `127.0.0.1:17872` (Task 7's port).
- Produces: nothing new — this is the final integration checkpoint.

- [ ] **Step 1: Insert T11 into `Scripts/test/e2e.sh`**

The T10 block ends with the `fi` at line 147; the file then has a blank `echo` + summary. Insert this between them (i.e., directly after T10's `fi`):

```bash
echo "== T11: MCP server (stdio handshake + gated tools) =="
CLI="${LOKALBOT_APP:-/Applications/LokalBot.app}/Contents/Helpers/lokalbot-cli"
if [ ! -x "$CLI" ]; then
  skip "embedded lokalbot-cli not present"
else
  mkdir -p "$ROOT/control"
  touch "$ROOT/control/agent-access-enabled"
  OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"redis"}}}' \
    | "$CLI" mcp 2>/dev/null)
  echo "$OUT" | head -1 | grep -q '"serverInfo"' \
    && echo "$OUT" | tail -1 | grep -qi "redis" \
    && pass "MCP handshake + search_meetings found the Redis discussion" \
    || fail "MCP session output unexpected: $(echo "$OUT" | tail -1 | cut -c1-120)"

  rm -f "$ROOT/control/agent-access-enabled"
  OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}' \
    | "$CLI" mcp 2>/dev/null)
  echo "$OUT" | grep -q "access_disabled" \
    && pass "tools refused while the Privacy toggle marker is absent" \
    || fail "expected access_disabled, got: $(echo "$OUT" | cut -c1-120)"

  if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:17872/health 2>/dev/null)" = "200" ]; then
    touch "$ROOT/control/agent-access-enabled"
    OUT=$(printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask_library","arguments":{"question":"Which datastore did we choose for caching?"}}}' \
      | "$CLI" mcp 2>/dev/null)
    echo "$OUT" | grep -qi "redis" \
      && pass "ask_library answered from the meeting (mentions 'Redis')" \
      || fail "ask_library answer missing expected content: $(echo "$OUT" | cut -c1-160)"
    rm -f "$ROOT/control/agent-access-enabled"
  else
    skip "llama-server not serving on 17872 — ask_library round-trip skipped"
  fi
fi

```

Notes for the implementer:
- The marker is created and removed **inside** T11, so it never leaks into other steps; the trailing `rm -f` after the ask_library branch restores the default-off posture even on the success path.
- `search_meetings` works with the app closed (reads files); `ask_library` needs the app's llama-server, hence the health-gated skip — matching the suite's permission-skip philosophy (header comment of the file).
- The CLI inherits `LOKALBOT_STORAGE_ROOT` from the suite's `export` at the top, so all of this runs against the hermetic fixture library, never the real one.

- [ ] **Step 2: Syntax-check the suite**

```bash
bash -n Scripts/test/e2e.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Update CLAUDE.md**

Two edits. First, in the Targets section, extend the `lokalbot-cli` paragraph — replace:

```markdown
It's built first, embedded into `LokalBot.app/Contents/Helpers/`, and gives agents read-only access to the meeting library (`list`/`get`/`search`/`path`, JSON by default, `--table` for humans).
```

with:

```markdown
It's built first, embedded into `LokalBot.app/Contents/Helpers/`, and gives agents read-only access to the meeting library (`list`/`get`/`search`/`path`, JSON by default, `--table` for humans). It also serves MCP over stdio (`mcp` subcommand: `list_meetings`/`get_meeting`/`search_meetings`/`ask_library` — the last answers via the app's llama-server and, like all four, requires the Privacy toggle's `control/agent-access-enabled` marker under the storage root) and installs the agent skill + PATH symlinks (`install-skill`). `Scripts/release/build-mcpb.sh` wraps the same helper into a one-click `dist/LokalBot.mcpb` for GUI MCP clients.
```

Second, in the on-disk library tree, add a `control/` line — replace:

```markdown
├── models/                     # downloaded GGUFs
```

with:

```markdown
├── control/                    # agent-access marker + wake files (Privacy toggle / MCP)
├── models/                     # downloaded GGUFs
```

- [ ] **Step 4: Full verification pass**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
git status --short   # must NOT list default.profraw (gitignored) or any stray generated file
```

Expected: `** TEST SUCCEEDED **`; status shows only the intentionally modified files.

Optionally, with a built app on the machine, run the real thing:

```bash
Scripts/build/install-app.sh && Scripts/test/e2e.sh
```

Expected: T11 prints two passes (handshake+search, gate refusal) and either a third pass (ask_library mentions "Redis") or the llama-server skip.

- [ ] **Step 5: Commit**

```bash
git add Scripts/test/e2e.sh CLAUDE.md
git commit -m "$(cat <<'EOF'
Add MCP e2e step and document the agent surface

T11 drives the real embedded helper over stdio: handshake + gated
search against the hermetic fixture library, plus an ask_library
round-trip when llama-server is up.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

## Done — what ships and what's deferred

Shipped by this plan: the `mcp` verb (4 tools: `list_meetings`, `get_meeting`, `search_meetings`, `ask_library`) behind the `LibraryToolProvider` seam; the `AgentAccessGate` marker + wake protocol with the app-side watcher and Privacy toggle; `install-skill` + the rewritten agent skill; `Scripts/release/build-mcpb.sh`; unit, integration (golden stdio), and e2e coverage.

Deliberately deferred (user-approved, do NOT add here): `Website/public/` docs page (follow-up PR), activity/screen tools (v1.1), app-hosted MCP server (post-broker), the inference broker (its own spec → plan → branch cycle).
