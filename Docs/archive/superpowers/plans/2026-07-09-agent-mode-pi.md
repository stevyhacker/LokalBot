# Agent Mode (pi) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed the pi coding agent (v0.80.5, RPC mode under Bun) as a native "Agent" pane in LokalBot's main window, preconnected to the local LLM engine already used for summarization, with per-tool approval gating and a first-enable runtime download.

**Architecture:** `AgentView` (SwiftUI pane) → `AgentSessionController` (@MainActor view model) → `PiRPCClient` (JSONL request/response + event stream) → `PiProcess` (actor supervising `bun …/cli.js --mode rpc`) → bundled `lokalbot-extension` (registers the `lokalbot` provider from env vars, gates write/edit/bash via the extension-UI confirm sub-protocol) → llama-server on `127.0.0.1:17872/v1` (or Ollama / OpenAI-compatible per settings). Runtime (Bun + pi bundle) is downloaded on first enable by `AgentRuntimeInstaller` from two pinned, SHA256-verified artifacts.

**Tech Stack:** Swift 5.10 (actors, AsyncStream, CryptoKit), SwiftUI, XcodeGen, Bun 1.3.14, pi 0.80.5 (`@earendil-works/pi-coding-agent`), JSONL-over-stdio RPC.

**Spec:** `Docs/archive/superpowers/specs/2026-07-09-agent-mode-pi-design.md` (commit 35671bb). Protocol references: pi `docs/rpc.md` and `docs/extensions.md` at tag v0.80.5.

## Global Constraints

- **Nothing leaves the Mac.** pi is always launched with `--offline` and `PI_SKIP_VERSION_CHECK=1` (pi ships install telemetry + update checks ON by default — these flags neutralize both). The ONLY permitted network traffic added by this feature is the two pinned runtime downloads, and only after the user clicks "Download & Enable".
- **Isolation from user's ~/.pi:** always pass `--no-extensions -e <ours>`, `--no-skills` (plus `--skill <lokalbot-cli>`), `--no-prompt-templates`, `--no-approve`. `--no-context-files` is deliberately NOT passed (project AGENTS.md/CLAUDE.md context stays on).
- **Pinned versions:** Bun `1.3.14` (sha256 `d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620` for `bun-darwin-aarch64.zip`), pi `0.80.5`. Do not bump casually.
- **Display-only rename:** ModelsView "Summarization" card becomes "Main LLM engine"; stored settings keys (`summarizerBackend`, `builtInModelID`, …) are NOT renamed.
- **JSONL framing:** split on LF (0x0A) only; strip one trailing CR; never split on U+2028/U+2029 (they are legal inside JSON strings). Never use String-based line readers on the pipe.
- **Approval gating:** `write`, `edit`, `bash` are gated; reads run without asking; per-session "Allow for session" and an auto-approve toggle. Policy decisions live Swift-side; the TS extension only raises the question.
- The `.xcodeproj` is generated — after any `project.yml` change run `xcodegen generate`. New `.swift` files under `LokalBot/` and `LokalBotTests/` are picked up by the existing folder sources, but `xcodegen generate` must still run to add them to the project.
- Unit tests: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test` (scheme "LokalBot", not "LokalBot Dev"). Tests run hosted inside the prod app binary, so `Bundle.main` is the app bundle and `AppDirectories.applicationSupport` is the real `~/Library/Application Support/me.dotenv.LokalBot`.
- Commit after every task. Never commit `default.profraw` or `dist/`.

## File Map

New (Swift files are auto-included via the existing `LokalBot`/`LokalBotTests` folder sources):

| File | Responsibility |
|---|---|
| `LokalBot/Agent/PiJSONLFrameSplitter.swift` | Byte-level LF-only JSONL framing |
| `LokalBot/Agent/PiRPCMessages.swift` | `PiCommand` encode, `PiEvent`/`PiResponse`/`PiUIRequest` decode |
| `LokalBot/Agent/AgentApprovalPolicy.swift` | Pure approval policy (auto-approve, session allowances) |
| `LokalBot/Agent/AgentTranscript.swift` | `AgentTranscriptItem` + `AgentTranscriptFolder` event folding |
| `LokalBot/Agent/AgentRuntime.swift` | Pinned manifest, on-disk layout, SHA256 verifier |
| `LokalBot/Agent/AgentRuntimeInstaller.swift` | Download → verify → unpack → atomic install |
| `LokalBot/Agent/AgentLLMEndpoint.swift` | Settings → endpoint resolution (mirrors `makeTextEngine`) |
| `LokalBot/Agent/PiLaunchPlanner.swift` | The exact pi launch contract (argv/env/cwd) |
| `LokalBot/Agent/PiProcess.swift` | Subprocess supervision actor (LlamaServer pattern) |
| `LokalBot/Agent/PiRPCClient.swift` | id-correlated requests + event AsyncStream |
| `LokalBot/Agent/AgentSessionController.swift` | @MainActor orchestration + approval round-trips |
| `LokalBot/Views/AgentView.swift` | The pane: install card, header, transcript, composer |
| `LokalBot/Resources/pi/lokalbot-extension/index.ts` | Bundled pi extension (provider + tool gate) |
| `LokalBot/Resources/pi/lokalbot-cli-skill/SKILL.md` | pi skill teaching the agent to query the meeting library via `lokalbot-cli` |
| `LokalBotTests/Fixtures/stub-openai.ts` | Bun SSE stub for the integration test |
| `Scripts/build-pi-bundle.sh` | Builds/release-stamps the pi bundle; `--install-local` for dev |

Modified: `LokalBot/LokalBotApp.swift` (NavSection + AppState wiring), `LokalBot/Views/MainWindowView.swift` (sidebar + detail), `LokalBot/Views/ModelsView.swift` (rebrand), `LokalBot/HeadlessCommands.swift` (`--agent`), `project.yml` (extension resource), `Scripts/test/e2e.sh`, `.gitignore`, `CLAUDE.md`, `RELEASING.md`.

Test files: one `LokalBotTests/<Type>Tests.swift` per new type (named below per task), plus `LokalBotTests/Helpers/FakeTransport.swift` (shared scriptable transport, extracted in Task 13) and `LokalBotTests/PiIntegrationTests.swift`.

---

### Task 1: PiJSONLFrameSplitter

**Files:**
- Create: `LokalBot/Agent/PiJSONLFrameSplitter.swift`
- Test: `LokalBotTests/PiJSONLFrameSplitterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct PiJSONLFrameSplitter` with `mutating func append(_ chunk: Data) -> [String]` and `mutating func flush() -> String?`. Task 10 (`PiProcess`) feeds pipe chunks through it.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

/// pi RPC framing rules (docs/rpc.md "Framing"): LF is the ONLY record
/// delimiter; a trailing CR is stripped; U+2028/U+2029 inside JSON strings
/// must not split records.
final class PiJSONLFrameSplitterTests: XCTestCase {

    func testSplitsOnLFOnly() {
        var splitter = PiJSONLFrameSplitter()
        let lines = splitter.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testDoesNotSplitOnUnicodeLineSeparators() {
        var splitter = PiJSONLFrameSplitter()
        let record = "{\"text\":\"one\u{2028}two\u{2029}three\"}"
        let lines = splitter.append(Data((record + "\n").utf8))
        XCTAssertEqual(lines, [record])
    }

    func testStripsSingleTrailingCR() {
        var splitter = PiJSONLFrameSplitter()
        let lines = splitter.append(Data("{\"a\":1}\r\n".utf8))
        XCTAssertEqual(lines, ["{\"a\":1}"])
    }

    func testReassemblesRecordsAcrossChunks() {
        var splitter = PiJSONLFrameSplitter()
        // Split mid-record AND mid-UTF-8-sequence (é is 2 bytes).
        let full = Data("{\"text\":\"café\"}\n".utf8)
        var collected: [String] = []
        collected += splitter.append(full.prefix(5))
        collected += splitter.append(full.dropFirst(5).prefix(9))
        collected += splitter.append(full.dropFirst(14))
        XCTAssertEqual(collected, ["{\"text\":\"café\"}"])
    }

    func testFlushReturnsUnterminatedRemainder() {
        var splitter = PiJSONLFrameSplitter()
        XCTAssertEqual(splitter.append(Data("{\"a\":1}".utf8)), [])
        XCTAssertEqual(splitter.flush(), "{\"a\":1}")
        XCTAssertNil(splitter.flush())
    }

    func testSkipsEmptyLines() {
        var splitter = PiJSONLFrameSplitter()
        XCTAssertEqual(splitter.append(Data("\n\n{\"a\":1}\n\n".utf8)), ["{\"a\":1}"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiJSONLFrameSplitterTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'PiJSONLFrameSplitter' in scope" (compile error counts as the failing state; the test file references a type that doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Splits a byte stream into JSONL records per pi's RPC framing rules
/// (docs/rpc.md): LF (0x0A) is the only record delimiter; one trailing CR
/// is stripped; U+2028/U+2029 inside JSON strings must NOT split records —
/// which is why this operates on raw bytes and why `PiProcess` must never
/// use a String-based line reader.
struct PiJSONLFrameSplitter {
    private var buffer = Data()

    /// Feed a chunk; returns every complete record it terminates.
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let lf = buffer.firstIndex(of: 0x0A) {
            var record = buffer[buffer.startIndex..<lf]
            if record.last == 0x0D { record = record.dropLast() }
            if let line = String(data: record, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
            buffer.removeSubrange(buffer.startIndex...lf)
        }
        return lines
    }

    /// Drain an unterminated final record (call on EOF).
    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
              !line.isEmpty else { return nil }
        return line
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiJSONLFrameSplitterTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/PiJSONLFrameSplitter.swift LokalBotTests/PiJSONLFrameSplitterTests.swift LokalBot.xcodeproj
git commit -m "Add LF-only JSONL frame splitter for pi RPC"
```

---

### Task 2: PiRPCMessages — commands, responses, events

**Files:**
- Create: `LokalBot/Agent/PiRPCMessages.swift`
- Test: `LokalBotTests/PiRPCMessagesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 4, 11, 13):
  - `enum PiCommand` with cases `.prompt(id:message:streamingBehavior:)`, `.steer(id:message:)`, `.abort(id:)`, `.newSession(id:)`, `.getState(id:)`, `.uiConfirmResponse(requestID:confirmed:)`, `.uiCancelResponse(requestID:)`; `var jsonLine: String`.
  - `struct PiResponse { let id: String?; let command: String; let success: Bool; let error: String? }`
  - `struct PiUIRequest { let id: String; let method: String; let title: String?; let message: String? }`
  - `enum PiAssistantDelta { case textDelta(String); case other(kind: String) }`
  - `enum PiEvent` with cases `.response(PiResponse)`, `.agentStart`, `.agentEnd`, `.agentSettled`, `.messageStart(role: String)`, `.messageUpdate(PiAssistantDelta)`, `.messageEnd(role: String, text: String)`, `.toolExecutionStart(callID: String, name: String, argsJSON: String)`, `.toolExecutionUpdate(callID: String, output: String)`, `.toolExecutionEnd(callID: String, output: String, isError: Bool)`, `.extensionUIRequest(PiUIRequest)`, `.extensionError(message: String)`, `.unknown(type: String)`; `static func decode(line: String) -> PiEvent?`.

- [ ] **Step 1: Write the failing test** (fixtures are verbatim from pi's docs/rpc.md at v0.80.5)

```swift
import XCTest
@testable import LokalBot

final class PiRPCMessagesTests: XCTestCase {

    // MARK: - Command encoding

    func testPromptEncodesSingleLine() throws {
        let line = PiCommand.prompt(id: "req-1", message: "Hello\nworld", streamingBehavior: nil).jsonLine
        XCTAssertFalse(line.contains("\n"), "must be one JSONL record")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "prompt")
        XCTAssertEqual(obj["id"] as? String, "req-1")
        XCTAssertEqual(obj["message"] as? String, "Hello\nworld")
        XCTAssertNil(obj["streamingBehavior"])
    }

    func testPromptWithSteeringBehavior() throws {
        let line = PiCommand.prompt(id: "req-2", message: "x", streamingBehavior: "steer").jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["streamingBehavior"] as? String, "steer")
    }

    func testUIConfirmResponseEncoding() throws {
        let line = PiCommand.uiConfirmResponse(requestID: "uuid-2", confirmed: true).jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "extension_ui_response")
        XCTAssertEqual(obj["id"] as? String, "uuid-2")
        XCTAssertEqual(obj["confirmed"] as? Bool, true)
    }

    func testUICancelResponseEncoding() throws {
        let line = PiCommand.uiCancelResponse(requestID: "uuid-3").jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["cancelled"] as? Bool, true)
    }

    func testSimpleCommandTypes() throws {
        for (command, type) in [
            (PiCommand.steer(id: "a", message: "m"), "steer"),
            (.abort(id: "a"), "abort"),
            (.newSession(id: "a"), "new_session"),
            (.getState(id: "a"), "get_state"),
        ] {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.jsonLine.utf8)) as? [String: Any])
            XCTAssertEqual(obj["type"] as? String, type)
        }
    }

    // MARK: - Event decoding

    func testDecodesResponse() {
        let event = PiEvent.decode(line: #"{"id": "req-1", "type": "response", "command": "prompt", "success": true}"#)
        XCTAssertEqual(event, .response(PiResponse(id: "req-1", command: "prompt", success: true, error: nil)))
    }

    func testDecodesLifecycleEvents() {
        XCTAssertEqual(PiEvent.decode(line: #"{"type": "agent_start"}"#), .agentStart)
        XCTAssertEqual(PiEvent.decode(line: #"{"type": "agent_settled"}"#), .agentSettled)
    }

    func testDecodesTextDelta() {
        let line = #"{"type":"message_update","message":{"role":"assistant","content":[]},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello ","partial":{}}}"#
        XCTAssertEqual(PiEvent.decode(line: line), .messageUpdate(.textDelta("Hello ")))
    }

    func testDecodesMessageEndJoiningTextBlocks() {
        let line = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Hello "},{"type":"text","text":"world"}]}}"#
        XCTAssertEqual(PiEvent.decode(line: line), .messageEnd(role: "assistant", text: "Hello world"))
    }

    func testDecodesToolLifecycle() {
        let start = PiEvent.decode(line: #"{"type":"tool_execution_start","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"}}"#)
        XCTAssertEqual(start, .toolExecutionStart(callID: "call_abc123", name: "bash",
                                                  argsJSON: #"{"command":"ls -la"}"#))
        let update = PiEvent.decode(line: #"{"type":"tool_execution_update","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"},"partialResult":{"content":[{"type":"text","text":"partial output so far..."}],"details":{}}}"#)
        XCTAssertEqual(update, .toolExecutionUpdate(callID: "call_abc123", output: "partial output so far..."))
        let end = PiEvent.decode(line: #"{"type":"tool_execution_end","toolCallId":"call_abc123","toolName":"bash","result":{"content":[{"type":"text","text":"total 48"}],"details":{}},"isError":false}"#)
        XCTAssertEqual(end, .toolExecutionEnd(callID: "call_abc123", output: "total 48", isError: false))
    }

    func testDecodesExtensionUIConfirmRequest() {
        let line = #"{"type":"extension_ui_request","id":"uuid-2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\"}"}"#
        XCTAssertEqual(PiEvent.decode(line: line), .extensionUIRequest(PiUIRequest(
            id: "uuid-2", method: "confirm",
            title: "lokalbot_tool_approval", message: #"{"tool":"bash"}"#)))
    }

    func testUnknownEventTypeIsPreserved() {
        XCTAssertEqual(PiEvent.decode(line: #"{"type":"queue_update","steering":[]}"#), .unknown(type: "queue_update"))
    }

    func testGarbageLineDecodesToNil() {
        XCTAssertNil(PiEvent.decode(line: "not json"))
        XCTAssertNil(PiEvent.decode(line: "[1,2,3]"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiRPCMessagesTests 2>&1 | tail -20`
Expected: FAILS — "cannot find 'PiCommand' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Commands sent to pi over stdin (JSONL). Encoded with JSONSerialization,
/// which is guaranteed single-line without `.prettyPrinted`.
enum PiCommand: Equatable {
    case prompt(id: String, message: String, streamingBehavior: String?)
    case steer(id: String, message: String)
    case abort(id: String)
    case newSession(id: String)
    case getState(id: String)
    case uiConfirmResponse(requestID: String, confirmed: Bool)
    case uiCancelResponse(requestID: String)

    var jsonLine: String {
        var dict: [String: Any]
        switch self {
        case .prompt(let id, let message, let behavior):
            dict = ["type": "prompt", "id": id, "message": message]
            if let behavior { dict["streamingBehavior"] = behavior }
        case .steer(let id, let message):
            dict = ["type": "steer", "id": id, "message": message]
        case .abort(let id):
            dict = ["type": "abort", "id": id]
        case .newSession(let id):
            dict = ["type": "new_session", "id": id]
        case .getState(let id):
            dict = ["type": "get_state", "id": id]
        case .uiConfirmResponse(let requestID, let confirmed):
            dict = ["type": "extension_ui_response", "id": requestID, "confirmed": confirmed]
        case .uiCancelResponse(let requestID):
            dict = ["type": "extension_ui_response", "id": requestID, "cancelled": true]
        }
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

struct PiResponse: Equatable {
    let id: String?
    let command: String
    let success: Bool
    let error: String?
}

struct PiUIRequest: Equatable {
    let id: String
    let method: String
    let title: String?
    let message: String?
}

enum PiAssistantDelta: Equatable {
    case textDelta(String)
    case other(kind: String)
}

/// One decoded stdout record from pi RPC mode. Only the fields Agent Mode
/// displays are extracted; everything else lands in `.unknown` so protocol
/// additions never crash the client.
enum PiEvent: Equatable {
    case response(PiResponse)
    case agentStart
    case agentEnd
    case agentSettled
    case messageStart(role: String)
    case messageUpdate(PiAssistantDelta)
    case messageEnd(role: String, text: String)
    case toolExecutionStart(callID: String, name: String, argsJSON: String)
    case toolExecutionUpdate(callID: String, output: String)
    case toolExecutionEnd(callID: String, output: String, isError: Bool)
    case extensionUIRequest(PiUIRequest)
    case extensionError(message: String)
    case unknown(type: String)

    /// Decode one JSONL record; nil when the line isn't a JSON object.
    static func decode(line: String) -> PiEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "response":
            return .response(PiResponse(
                id: obj["id"] as? String,
                command: obj["command"] as? String ?? "",
                success: obj["success"] as? Bool ?? false,
                error: obj["error"] as? String))
        case "agent_start": return .agentStart
        case "agent_end": return .agentEnd
        case "agent_settled": return .agentSettled
        case "message_start":
            return .messageStart(role: role(of: obj["message"]))
        case "message_update":
            guard let delta = obj["assistantMessageEvent"] as? [String: Any],
                  let kind = delta["type"] as? String else {
                return .messageUpdate(.other(kind: ""))
            }
            if kind == "text_delta", let text = delta["delta"] as? String {
                return .messageUpdate(.textDelta(text))
            }
            return .messageUpdate(.other(kind: kind))
        case "message_end":
            return .messageEnd(role: role(of: obj["message"]), text: text(of: obj["message"]))
        case "tool_execution_start":
            return .toolExecutionStart(
                callID: obj["toolCallId"] as? String ?? "",
                name: obj["toolName"] as? String ?? "",
                argsJSON: compactJSON(obj["args"]) ?? "{}")
        case "tool_execution_update":
            return .toolExecutionUpdate(
                callID: obj["toolCallId"] as? String ?? "",
                output: resultText(obj["partialResult"]))
        case "tool_execution_end":
            return .toolExecutionEnd(
                callID: obj["toolCallId"] as? String ?? "",
                output: resultText(obj["result"]),
                isError: obj["isError"] as? Bool ?? false)
        case "extension_ui_request":
            guard let id = obj["id"] as? String, let method = obj["method"] as? String else {
                return .unknown(type: type)
            }
            return .extensionUIRequest(PiUIRequest(
                id: id, method: method,
                title: obj["title"] as? String,
                message: obj["message"] as? String))
        case "extension_error":
            return .extensionError(
                message: obj["error"] as? String ?? obj["message"] as? String ?? "extension error")
        default:
            return .unknown(type: type)
        }
    }

    private static func role(of message: Any?) -> String {
        (message as? [String: Any])?["role"] as? String ?? ""
    }

    /// Joins the `text` blocks of an AgentMessage `content` array.
    private static func text(of message: Any?) -> String {
        guard let content = (message as? [String: Any])?["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
    }

    /// Joins the `text` blocks of a ToolResult `content` array.
    private static func resultText(_ result: Any?) -> String {
        guard let content = (result as? [String: Any])?["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiRPCMessagesTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 12 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/PiRPCMessages.swift LokalBotTests/PiRPCMessagesTests.swift LokalBot.xcodeproj
git commit -m "Add pi RPC command encoding and event decoding"
```

---

### Task 3: AgentApprovalPolicy

**Files:**
- Create: `LokalBot/Agent/AgentApprovalPolicy.swift`
- Test: `LokalBotTests/AgentApprovalPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Task 13): `struct AgentApprovalPolicy` with `var autoApproveAll: Bool`, `enum Verdict { case allow, ask }`, `func verdict(tool: String) -> Verdict`, `mutating func allowForSession(tool: String)`, `mutating func resetSession()`. Also `enum ApprovalScope { case once, session }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

final class AgentApprovalPolicyTests: XCTestCase {

    func testGatedToolAsksByDefault() {
        let policy = AgentApprovalPolicy()
        XCTAssertEqual(policy.verdict(tool: "bash"), .ask)
        XCTAssertEqual(policy.verdict(tool: "write"), .ask)
        XCTAssertEqual(policy.verdict(tool: "edit"), .ask)
    }

    func testAutoApproveAllAllowsEverything() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveAll = true
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
    }

    func testSessionAllowanceIsPerTool() {
        var policy = AgentApprovalPolicy()
        policy.allowForSession(tool: "bash")
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
        XCTAssertEqual(policy.verdict(tool: "write"), .ask)
    }

    func testResetSessionClearsAllowances() {
        var policy = AgentApprovalPolicy()
        policy.allowForSession(tool: "bash")
        policy.resetSession()
        XCTAssertEqual(policy.verdict(tool: "bash"), .ask)
    }

    func testResetSessionKeepsAutoApproveToggle() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveAll = true
        policy.resetSession()
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentApprovalPolicyTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'AgentApprovalPolicy' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// How the user scoped an approval from the transcript card.
enum ApprovalScope: Equatable {
    case once, session
}

/// Pure approval policy for gated agent tools. The bundled pi extension
/// only raises approval requests for `write`, `edit`, and `bash` (reads run
/// without asking — see Resources/pi/lokalbot-extension/index.ts). This type
/// decides whether a raised request can be answered automatically
/// (auto-approve toggle, session allowances) or must be shown to the user.
struct AgentApprovalPolicy: Equatable {
    var autoApproveAll = false
    private(set) var sessionAllowedTools: Set<String> = []

    enum Verdict: Equatable { case allow, ask }

    func verdict(tool: String) -> Verdict {
        if autoApproveAll || sessionAllowedTools.contains(tool) { return .allow }
        return .ask
    }

    mutating func allowForSession(tool: String) {
        sessionAllowedTools.insert(tool)
    }

    mutating func resetSession() {
        sessionAllowedTools.removeAll()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentApprovalPolicyTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentApprovalPolicy.swift LokalBotTests/AgentApprovalPolicyTests.swift LokalBot.xcodeproj
git commit -m "Add agent tool approval policy"
```

---
### Task 4: AgentTranscript — items + event folding

**Files:**
- Create: `LokalBot/Agent/AgentTranscript.swift`
- Test: `LokalBotTests/AgentTranscriptTests.swift`

**Interfaces:**
- Consumes: `PiEvent`, `PiAssistantDelta` (Task 2).
- Produces (used by Tasks 13, 15):
  - `enum AgentToolStatus { case running, succeeded, failed }`
  - `enum AgentTranscriptItem: Equatable, Identifiable` with cases `.user(id: String, text: String)`, `.assistant(id: String, text: String, isStreaming: Bool)`, `.tool(id: String, name: String, argsJSON: String, output: String, status: AgentToolStatus)`, `.approval(id: String, tool: String, argsJSON: String)`, `.notice(id: String, text: String, isError: Bool)`; `var id: String`.
  - `struct AgentTranscriptFolder` with `private(set) var items: [AgentTranscriptItem]`, `private(set) var isAgentRunning: Bool`, `mutating func fold(_ event: PiEvent)`, `mutating func noteUserPrompt(_ text: String)`, `mutating func appendNotice(_ text: String, isError: Bool)`, `mutating func addApproval(requestID: String, tool: String, argsJSON: String)`, `mutating func resolveApproval(requestID: String)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

/// Folding rules: streaming deltas accumulate into one assistant bubble,
/// message_end replaces it with the final text, tool events drive one card
/// per toolCallId, and empty assistant bubbles (tool-call-only turns) are
/// dropped.
final class AgentTranscriptTests: XCTestCase {

    func testStreamingAssistantMessageLifecycle() {
        var folder = AgentTranscriptFolder()
        folder.fold(.agentStart)
        XCTAssertTrue(folder.isAgentRunning)
        folder.fold(.messageStart(role: "assistant"))
        folder.fold(.messageUpdate(.textDelta("Hello")))
        folder.fold(.messageUpdate(.textDelta(" world")))
        guard case .assistant(_, let streamed, let isStreaming) = folder.items.last else {
            return XCTFail("expected assistant item, got \(folder.items)")
        }
        XCTAssertEqual(streamed, "Hello world")
        XCTAssertTrue(isStreaming)
        folder.fold(.messageEnd(role: "assistant", text: "Hello world!"))
        folder.fold(.agentSettled)
        XCTAssertFalse(folder.isAgentRunning)
        XCTAssertEqual(folder.items.count, 1)
        guard case .assistant(_, let final, let stillStreaming) = folder.items[0] else {
            return XCTFail()
        }
        XCTAssertEqual(final, "Hello world!", "message_end text wins over accumulated deltas")
        XCTAssertFalse(stillStreaming)
    }

    func testDeltaWithoutMessageStartCreatesBubble() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageUpdate(.textDelta("hi")))
        guard case .assistant(_, "hi", true) = folder.items[0] else { return XCTFail() }
    }

    func testEmptyAssistantBubbleIsDroppedOnMessageEnd() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageStart(role: "assistant"))
        folder.fold(.messageEnd(role: "assistant", text: ""))
        XCTAssertTrue(folder.items.isEmpty, "tool-call-only turn leaves no empty bubble")
    }

    func testNonAssistantMessagesAreIgnored() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageStart(role: "user"))
        folder.fold(.messageEnd(role: "toolResult", text: "x"))
        XCTAssertTrue(folder.items.isEmpty)
    }

    func testToolCardLifecycle() {
        var folder = AgentTranscriptFolder()
        folder.fold(.toolExecutionStart(callID: "call_1", name: "bash", argsJSON: #"{"command":"ls"}"#))
        folder.fold(.toolExecutionUpdate(callID: "call_1", output: "partial"))
        folder.fold(.toolExecutionEnd(callID: "call_1", output: "total 48", isError: false))
        XCTAssertEqual(folder.items, [.tool(id: "call_1", name: "bash", argsJSON: #"{"command":"ls"}"#,
                                            output: "total 48", status: .succeeded)])
    }

    func testFailedToolGetsFailedStatus() {
        var folder = AgentTranscriptFolder()
        folder.fold(.toolExecutionStart(callID: "call_2", name: "write", argsJSON: "{}"))
        folder.fold(.toolExecutionEnd(callID: "call_2", output: "denied", isError: true))
        guard case .tool(_, _, _, _, .failed) = folder.items[0] else { return XCTFail() }
    }

    func testApprovalAddAndResolve() {
        var folder = AgentTranscriptFolder()
        folder.addApproval(requestID: "uuid-1", tool: "bash", argsJSON: #"{"command":"rm x"}"#)
        XCTAssertEqual(folder.items, [.approval(id: "uuid-1", tool: "bash", argsJSON: #"{"command":"rm x"}"#)])
        folder.resolveApproval(requestID: "uuid-1")
        XCTAssertTrue(folder.items.isEmpty)
    }

    func testUserPromptAndNotices() {
        var folder = AgentTranscriptFolder()
        folder.noteUserPrompt("do the thing")
        folder.appendNotice("Denied bash", isError: false)
        folder.fold(.extensionError(message: "boom"))
        XCTAssertEqual(folder.items.count, 3)
        guard case .notice(_, "boom", true) = folder.items[2] else { return XCTFail() }
    }

    func testAgentSettledFinishesStreamingBubble() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageUpdate(.textDelta("partial answer")))
        folder.fold(.agentSettled)   // e.g. user aborted mid-stream: no message_end
        guard case .assistant(_, "partial answer", false) = folder.items[0] else { return XCTFail() }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentTranscriptTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'AgentTranscriptFolder' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum AgentToolStatus: Equatable {
    case running, succeeded, failed
}

enum AgentTranscriptItem: Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, isStreaming: Bool)
    case tool(id: String, name: String, argsJSON: String, output: String, status: AgentToolStatus)
    case approval(id: String, tool: String, argsJSON: String)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .tool(let id, _, _, _, _),
             .approval(let id, _, _), .notice(let id, _, _):
            return id
        }
    }
}

/// Folds the PiEvent stream into a display-ready transcript. Pure state
/// machine — no async, no UI — so every folding rule is unit-testable
/// (same decomposition philosophy as the Cotyping policy types).
struct AgentTranscriptFolder: Equatable {
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var isAgentRunning = false
    private var streamingAssistantIndex: Int?
    private var counter = 0

    // MARK: - Local inserts (not driven by pi events)

    mutating func noteUserPrompt(_ text: String) {
        items.append(.user(id: nextID("user"), text: text))
    }

    mutating func appendNotice(_ text: String, isError: Bool = false) {
        items.append(.notice(id: nextID("notice"), text: text, isError: isError))
    }

    mutating func addApproval(requestID: String, tool: String, argsJSON: String) {
        items.append(.approval(id: requestID, tool: tool, argsJSON: argsJSON))
    }

    mutating func resolveApproval(requestID: String) {
        items.removeAll {
            if case .approval(let id, _, _) = $0 { return id == requestID }
            return false
        }
    }

    // MARK: - Event folding

    mutating func fold(_ event: PiEvent) {
        switch event {
        case .agentStart:
            isAgentRunning = true
        case .agentSettled:
            isAgentRunning = false
            finishStreamingAssistant()
        case .messageStart(let role):
            guard role == "assistant" else { return }
            items.append(.assistant(id: nextID("assistant"), text: "", isStreaming: true))
            streamingAssistantIndex = items.count - 1
        case .messageUpdate(.textDelta(let delta)):
            appendToStreamingAssistant(delta)
        case .messageEnd(let role, let text):
            guard role == "assistant" else { return }
            defer { streamingAssistantIndex = nil }
            if let index = streamingAssistantIndex,
               case .assistant(let id, let streamed, _) = items[index] {
                let final = text.isEmpty ? streamed : text
                if final.isEmpty {
                    items.remove(at: index)   // tool-call-only turn: drop the empty bubble
                } else {
                    items[index] = .assistant(id: id, text: final, isStreaming: false)
                }
            } else if !text.isEmpty {
                items.append(.assistant(id: nextID("assistant"), text: text, isStreaming: false))
            }
        case .toolExecutionStart(let callID, let name, let argsJSON):
            items.append(.tool(id: callID, name: name, argsJSON: argsJSON, output: "", status: .running))
        case .toolExecutionUpdate(let callID, let output):
            updateTool(callID) { _, _ in (output, .running) }
        case .toolExecutionEnd(let callID, let output, let isError):
            updateTool(callID) { _, _ in (output, isError ? .failed : .succeeded) }
        case .extensionError(let message):
            appendNotice(message, isError: true)
        case .agentEnd, .messageUpdate, .response, .extensionUIRequest, .unknown:
            break
        }
    }

    // MARK: - Helpers

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private mutating func appendToStreamingAssistant(_ delta: String) {
        if streamingAssistantIndex == nil {
            items.append(.assistant(id: nextID("assistant"), text: "", isStreaming: true))
            streamingAssistantIndex = items.count - 1
        }
        if let index = streamingAssistantIndex,
           case .assistant(let id, let text, _) = items[index] {
            items[index] = .assistant(id: id, text: text + delta, isStreaming: true)
        }
    }

    private mutating func finishStreamingAssistant() {
        defer { streamingAssistantIndex = nil }
        guard let index = streamingAssistantIndex,
              case .assistant(let id, let text, _) = items[index] else { return }
        if text.isEmpty {
            items.remove(at: index)
        } else {
            items[index] = .assistant(id: id, text: text, isStreaming: false)
        }
    }

    private mutating func updateTool(_ callID: String,
                                     _ transform: (String, AgentToolStatus) -> (String, AgentToolStatus)) {
        guard let index = items.firstIndex(where: { $0.id == callID }),
              case .tool(let id, let name, let args, let output, let status) = items[index] else { return }
        let (newOutput, newStatus) = transform(output, status)
        items[index] = .tool(id: id, name: name, argsJSON: args, output: newOutput, status: newStatus)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentTranscriptTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 9 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentTranscript.swift LokalBotTests/AgentTranscriptTests.swift LokalBot.xcodeproj
git commit -m "Add agent transcript model and pi event folding"
```

---

### Task 5: Scripts/build-pi-bundle.sh

Builds the release artifact `dist/lokalbot-pi-bundle-0.80.5.tar.gz` and, with `--install-local`, installs Bun + the bundle into this Mac's Application Support so the Task 14 integration test and manual smoke runs work before any GitHub release exists.

**Files:**
- Create: `Scripts/build-pi-bundle.sh`
- Modify: `.gitignore` (add `dist/`)

**Interfaces:**
- Consumes: nothing (host `bun` from Homebrew for building; downloads pinned Bun for install).
- Produces: tarball layout `package.json` + `node_modules/@earendil-works/pi-coding-agent/dist/cli.js` (Task 6's manifest checksum, Task 7's unpack expectations); local install layout `~/Library/Application Support/me.dotenv.LokalBot/agent-runtime/{bun/bun, pi/node_modules/...}` (Task 6's `AgentRuntimeLayout`).

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# Builds the pinned pi runtime bundle that LokalBot's Agent Mode downloads
# on first enable, and (with --install-local) installs Bun + the bundle into
# this Mac's Application Support for development and integration tests.
#
# Usage:
#   Scripts/build-pi-bundle.sh                 # build dist/lokalbot-pi-bundle-<ver>.tar.gz, print SHA256
#   Scripts/build-pi-bundle.sh --install-local # also install into Application Support
#
# Release flow (RELEASING.md): build ONCE, upload that exact tarball to the
# GitHub release tagged agent-runtime-<ver>, and commit the printed SHA256
# into AgentRuntimeManifest.current. The tarball is not byte-reproducible,
# so never rebuild without also updating the manifest.
set -euo pipefail

PI_VERSION="0.80.5"
BUN_VERSION="1.3.14"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO_ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v bun >/dev/null || { echo "error: bun not on PATH (brew install oven-sh/bun/bun)"; exit 1; }

echo "==> staging pi $PI_VERSION with host bun $(bun --version)"
echo '{"name":"lokalbot-pi-bundle","private":true}' > "$STAGE/package.json"
# --ignore-scripts: never execute postinstall hooks from the dependency tree
(cd "$STAGE" && bun add "@earendil-works/pi-coding-agent@$PI_VERSION" --ignore-scripts)

CLI="$STAGE/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
test -f "$CLI" || { echo "error: cli.js missing after install"; exit 1; }

mkdir -p "$DIST"
TARBALL="$DIST/lokalbot-pi-bundle-$PI_VERSION.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" package.json node_modules
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "==> built  $TARBALL"
echo "==> sha256 $SHA"

if [[ "${1:-}" == "--install-local" ]]; then
    RUNTIME="$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime"
    echo "==> installing runtime into $RUNTIME"
    rm -rf "$RUNTIME"
    mkdir -p "$RUNTIME/pi" "$RUNTIME/bun"
    tar -xzf "$TARBALL" -C "$RUNTIME/pi"
    BUNZIP="$STAGE/bun.zip"
    curl -fsSL -o "$BUNZIP" \
        "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-darwin-aarch64.zip"
    (cd "$STAGE" && unzip -q "$BUNZIP")
    cp "$STAGE/bun-darwin-aarch64/bun" "$RUNTIME/bun/bun"
    chmod 755 "$RUNTIME/bun/bun"
    echo "==> installed bun $("$RUNTIME/bun/bun" --version)"
fi
```

- [ ] **Step 2: Make it executable and ignore dist/**

```bash
chmod +x Scripts/build-pi-bundle.sh
echo "dist/" >> .gitignore
```

- [ ] **Step 3: Run it with --install-local and verify**

Run: `Scripts/build-pi-bundle.sh --install-local`
Expected output (sha will differ):
```
==> staging pi 0.80.5 with host bun 1.3.14
...
==> built  .../dist/lokalbot-pi-bundle-0.80.5.tar.gz
==> sha256 <64 hex chars>   ← SAVE THIS; Task 6 Step 3 pastes it into the manifest
==> installing runtime into /Users/.../Application Support/me.dotenv.LokalBot/agent-runtime
==> installed bun 1.3.14
```
Then verify the layout:
```bash
ls "$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime/bun/bun" \
   "$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
```
Expected: both paths print (no "No such file").

- [ ] **Step 4: Smoke the runtime end-to-end**

```bash
R="$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime"
echo '{"type":"get_state","id":"t1"}' | PI_SKIP_VERSION_CHECK=1 \
  "$R/bun/bun" "$R/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" \
  --mode rpc --offline --no-extensions --no-skills --no-prompt-templates --no-approve --no-session \
  --provider anthropic --model claude-opus-4-8 2>/dev/null | head -2
```
Expected: a JSON line containing `"type":"response","command":"get_state","success":true` (provider/model are irrelevant for get_state; this proves the vendored runtime boots in RPC mode).

- [ ] **Step 5: Commit**

```bash
git add Scripts/build-pi-bundle.sh .gitignore
git commit -m "Add pi runtime bundle build script"
```

---

### Task 6: AgentRuntime — manifest, layout, SHA256 verifier

**Files:**
- Create: `LokalBot/Agent/AgentRuntime.swift`
- Test: `LokalBotTests/AgentRuntimeTests.swift`

**Interfaces:**
- Consumes: `AppDirectories.applicationSupport`, `AppDirectories.libraryRoot` (existing).
- Produces (used by Tasks 7, 9, 13, 14, 17):
  - `enum AgentArchiveKind { case zip, tarGz }`
  - `struct AgentRuntimeArtifact { let name: String; let url: URL; let sha256: String; let archiveKind: AgentArchiveKind }`
  - `struct AgentRuntimeManifest { let bun: AgentRuntimeArtifact; let piBundle: AgentRuntimeArtifact; static let current: AgentRuntimeManifest; static let bunVersion: String; static let piVersion: String }`
  - `enum AgentRuntimeLayout` with `static var defaultRoot: URL`, `static func bunBinary(under root: URL) -> URL`, `static func piCLI(under root: URL) -> URL`, `static func isInstalled(under root: URL) -> Bool` (and a no-arg overload defaulting to `defaultRoot`), `static var sessionsDirectory: URL`.
  - `enum SHA256Verifier { static func hexDigest(of url: URL) throws -> String }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

final class AgentRuntimeTests: XCTestCase {

    func testSHA256HexDigestOfKnownData() throws {
        // shasum -a 256 <<< "hello" (with trailing newline stripped): sha256("hello")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SHA256Verifier.hexDigest(of: url),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testLayoutPaths() {
        let root = URL(fileURLWithPath: "/tmp/agent-runtime")
        XCTAssertEqual(AgentRuntimeLayout.bunBinary(under: root).path, "/tmp/agent-runtime/bun/bun")
        XCTAssertEqual(AgentRuntimeLayout.piCLI(under: root).path,
                       "/tmp/agent-runtime/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
    }

    func testDefaultRootLivesInApplicationSupport() {
        XCTAssertEqual(AgentRuntimeLayout.defaultRoot,
                       AppDirectories.applicationSupport.appendingPathComponent("agent-runtime", isDirectory: true))
    }

    func testIsInstalledRequiresExecutableBunAndCLI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))

        let bun = AgentRuntimeLayout.bunBinary(under: root)
        let cli = AgentRuntimeLayout.piCLI(under: root)
        try FileManager.default.createDirectory(at: bun.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bun)
        try Data("// cli".utf8).write(to: cli)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root), "bun not yet executable")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bun.path)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testManifestPinsExpectedVersions() {
        let manifest = AgentRuntimeManifest.current
        XCTAssertEqual(AgentRuntimeManifest.bunVersion, "1.3.14")
        XCTAssertEqual(AgentRuntimeManifest.piVersion, "0.80.5")
        XCTAssertTrue(manifest.bun.url.absoluteString.contains("bun-v1.3.14/bun-darwin-aarch64.zip"))
        XCTAssertEqual(manifest.bun.sha256.count, 64)
        XCTAssertEqual(manifest.piBundle.sha256.count, 64)
        XCTAssertEqual(manifest.bun.archiveKind, .zip)
        XCTAssertEqual(manifest.piBundle.archiveKind, .tarGz)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentRuntimeTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'SHA256Verifier' in scope".

- [ ] **Step 3: Write the implementation**

In the `piBundle.sha256` field below, `PASTE-SHA256-PRINTED-BY-TASK-5-STEP-3` is a generated input, not a decision: replace it with the 64-hex digest that `Scripts/build-pi-bundle.sh` printed in Task 5 Step 3. (At release time, RELEASING.md re-stamps it against the uploaded artifact — see Task 18.)

```swift
import CryptoKit
import Foundation

enum AgentArchiveKind: Equatable {
    case zip, tarGz
}

struct AgentRuntimeArtifact: Equatable {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex
    let archiveKind: AgentArchiveKind
}

/// Pinned, checksum-verified runtime downloads for Agent Mode. Versions are
/// deliberate (see the 2026-07-09 spec); bump Bun and pi together and
/// refresh both checksums via Scripts/build-pi-bundle.sh + RELEASING.md.
struct AgentRuntimeManifest: Equatable {
    let bun: AgentRuntimeArtifact
    let piBundle: AgentRuntimeArtifact

    static let bunVersion = "1.3.14"
    static let piVersion = "0.80.5"

    static let current = AgentRuntimeManifest(
        bun: AgentRuntimeArtifact(
            name: "Bun \(bunVersion)",
            url: URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(bunVersion)/bun-darwin-aarch64.zip")!,
            sha256: "d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620",
            archiveKind: .zip),
        piBundle: AgentRuntimeArtifact(
            name: "pi \(piVersion)",
            url: URL(string: "https://github.com/stevyhacker/lokalbot/releases/download/agent-runtime-\(piVersion)/lokalbot-pi-bundle-\(piVersion).tar.gz")!,
            sha256: "PASTE-SHA256-PRINTED-BY-TASK-5-STEP-3",
            archiveKind: .tarGz))
}

/// On-disk layout of the installed runtime. Lives in Application Support
/// (NOT the storage root) alongside model caches and the llama-server
/// binary — it's a machine-local cache, not user data.
enum AgentRuntimeLayout {

    static var defaultRoot: URL {
        AppDirectories.applicationSupport.appendingPathComponent("agent-runtime", isDirectory: true)
    }

    static func bunBinary(under root: URL) -> URL {
        root.appendingPathComponent("bun/bun")
    }

    static func piCLI(under root: URL) -> URL {
        root.appendingPathComponent("pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
    }

    static func isInstalled(under root: URL = defaultRoot) -> Bool {
        FileManager.default.isExecutableFile(atPath: bunBinary(under: root).path)
            && FileManager.default.fileExists(atPath: piCLI(under: root).path)
    }

    /// pi session JSONL trees live under the storage root so they follow
    /// LOKALBOT_STORAGE_ROOT (hermetic in e2e/UI tests) and land next to
    /// the rest of the user's library.
    static var sessionsDirectory: URL {
        AppDirectories.libraryRoot.appendingPathComponent("agent/sessions", isDirectory: true)
    }
}

enum SHA256Verifier {
    /// Streaming digest so ~60 MB artifacts don't land in memory at once.
    static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentRuntimeTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 5 tests passed. (If `testDefaultRootLivesInApplicationSupport` fails on the property name, check `LokalBot/Models/AppDirectories.swift` — the property is `applicationSupport` as of commit 267586f.)

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentRuntime.swift LokalBotTests/AgentRuntimeTests.swift LokalBot.xcodeproj
git commit -m "Add pinned agent runtime manifest, layout, and SHA256 verifier"
```

---
### Task 7: AgentRuntimeInstaller

**Files:**
- Create: `LokalBot/Agent/AgentRuntimeInstaller.swift`
- Test: `LokalBotTests/AgentRuntimeInstallerTests.swift`

**Interfaces:**
- Consumes: `AgentRuntimeManifest`, `AgentRuntimeArtifact`, `AgentArchiveKind`, `AgentRuntimeLayout`, `SHA256Verifier` (Task 6).
- Produces (used by Tasks 13, 15): `@MainActor final class AgentRuntimeInstaller: ObservableObject` with `enum Phase: Equatable { case idle, downloading(name: String, progress: Double), installing(name: String), installed, failed(String) }`, `@Published private(set) var phase: Phase`, `init(root: URL = AgentRuntimeLayout.defaultRoot, session: URLSession = .shared)`, `func installIfNeeded(manifest: AgentRuntimeManifest = .current) async`.

The download pattern deliberately does NOT reuse `ParallelRangeDownloader` (that's tuned for multi-GB GGUFs with resume stashes); a plain `URLSession.bytes` loop with progress is right for two ~25 MB files. Unlike `ModelDownloadManager`, checksums here are mandatory.

- [ ] **Step 1: Write the failing test**

The test builds real zip/tar.gz fixtures with the exact layouts the Bun and pi artifacts use, computes their real SHA256s, and installs from `file://` URLs — hermetic, no network.

```swift
import XCTest
@testable import LokalBot

@MainActor
final class AgentRuntimeInstallerTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// zip containing bun-darwin-aarch64/bun (the layout of the real Bun release zip)
    private func makeBunFixture() throws -> URL {
        let stage = sandbox.appendingPathComponent("bun-stage/bun-darwin-aarch64", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fake-bun\n".utf8).write(to: stage.appendingPathComponent("bun"))
        let zip = sandbox.appendingPathComponent("bun-darwin-aarch64.zip")
        try run("/usr/bin/zip", ["-qr", zip.path, "bun-darwin-aarch64"],
                cwd: stage.deletingLastPathComponent())
        return zip
    }

    /// tar.gz containing package.json + node_modules/.../dist/cli.js (the pi bundle layout)
    private func makePiFixture() throws -> URL {
        let stage = sandbox.appendingPathComponent("pi-stage", isDirectory: true)
        let cliDir = stage.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stage.appendingPathComponent("package.json"))
        try Data("// cli".utf8).write(to: cliDir.appendingPathComponent("cli.js"))
        let tar = sandbox.appendingPathComponent("lokalbot-pi-bundle-test.tar.gz")
        try run("/usr/bin/tar", ["-czf", tar.path, "-C", stage.path, "package.json", "node_modules"], cwd: sandbox)
        return tar
    }

    private func run(_ tool: String, _ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }

    private func manifest(bunZip: URL, piTar: URL, corruptBunSHA: Bool = false) throws -> AgentRuntimeManifest {
        AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(
                name: "Bun test", url: bunZip,
                sha256: corruptBunSHA ? String(repeating: "0", count: 64)
                                      : try SHA256Verifier.hexDigest(of: bunZip),
                archiveKind: .zip),
            piBundle: AgentRuntimeArtifact(
                name: "pi test", url: piTar,
                sha256: try SHA256Verifier.hexDigest(of: piTar),
                archiveKind: .tarGz))
    }

    func testInstallsVerifiedArtifactsIntoLayout() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture()))
        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: AgentRuntimeLayout.bunBinary(under: root).path))
    }

    func testChecksumMismatchFailsAndInstallsNothing() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(
            manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture(), corruptBunSHA: true))
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testAlreadyInstalledShortCircuits() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture()))
        XCTAssertEqual(installer.phase, .installed)
        // Second call must short-circuit without downloading: this manifest
        // points at nonexistent files, so any fetch attempt would fail.
        let bogus = AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(name: "Bun", url: URL(fileURLWithPath: "/nonexistent.zip"),
                                      sha256: String(repeating: "0", count: 64), archiveKind: .zip),
            piBundle: AgentRuntimeArtifact(name: "pi", url: URL(fileURLWithPath: "/nonexistent.tgz"),
                                           sha256: String(repeating: "0", count: 64), archiveKind: .tarGz))
        await installer.installIfNeeded(manifest: bogus)
        XCTAssertEqual(installer.phase, .installed)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentRuntimeInstallerTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'AgentRuntimeInstaller' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Downloads, verifies, and installs the Agent Mode runtime (Bun + the pi
/// bundle) into `AgentRuntimeLayout`. Both artifacts are pinned by SHA256
/// in `AgentRuntimeManifest.current`; a mismatch aborts the install — no
/// unverified code ever lands on disk. Assembly happens in a staging
/// directory that is swapped into place at the end, so a failed install
/// leaves nothing half-written.
@MainActor
final class AgentRuntimeInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(name: String, progress: Double)   // 0…1; -1 when length unknown
        case installing(name: String)
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let root: URL
    private let session: URLSession

    init(root: URL = AgentRuntimeLayout.defaultRoot, session: URLSession = .shared) {
        self.root = root
        self.session = session
        if AgentRuntimeLayout.isInstalled(under: root) { phase = .installed }
    }

    func installIfNeeded(manifest: AgentRuntimeManifest = .current) async {
        guard !AgentRuntimeLayout.isInstalled(under: root) else {
            phase = .installed
            return
        }
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("agent-runtime.staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let bunArchive = try await download(manifest.bun, into: staging)
            let piArchive = try await download(manifest.piBundle, into: staging)

            phase = .installing(name: manifest.bun.name)
            let bunStage = staging.appendingPathComponent("bun-extract", isDirectory: true)
            try Self.unpack(bunArchive, kind: manifest.bun.archiveKind, into: bunStage)
            let bunBinary = bunStage.appendingPathComponent("bun-darwin-aarch64/bun")
            guard FileManager.default.fileExists(atPath: bunBinary.path) else {
                throw InstallError.layout("bun binary missing from archive")
            }

            phase = .installing(name: manifest.piBundle.name)
            let piStage = staging.appendingPathComponent("pi-extract", isDirectory: true)
            try Self.unpack(piArchive, kind: manifest.piBundle.archiveKind, into: piStage)
            let stagedCLI = piStage.appendingPathComponent(
                "node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
            guard FileManager.default.fileExists(atPath: stagedCLI.path) else {
                throw InstallError.layout("pi cli.js missing from bundle")
            }

            let assembled = staging.appendingPathComponent("agent-runtime", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assembled.appendingPathComponent("bun", isDirectory: true),
                withIntermediateDirectories: true)
            let installedBun = assembled.appendingPathComponent("bun/bun")
            try FileManager.default.moveItem(at: bunBinary, to: installedBun)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBun.path)
            try FileManager.default.moveItem(at: piStage, to: assembled.appendingPathComponent("pi"))

            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: assembled, to: root)
            phase = .installed
        } catch {
            phase = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: - Download + verify

    private func download(_ artifact: AgentRuntimeArtifact, into staging: URL) async throws -> URL {
        phase = .downloading(name: artifact.name, progress: 0)
        let destination = staging.appendingPathComponent(artifact.url.lastPathComponent)
        let (bytes, response) = try await session.bytes(from: artifact.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download(artifact.name, "HTTP \(http.statusCode)")
        }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 1 << 16 {
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                phase = .downloading(name: artifact.name,
                                     progress: expected > 0 ? Double(received) / Double(expected) : -1)
            }
        }
        try handle.write(contentsOf: chunk)
        try handle.close()

        guard try SHA256Verifier.hexDigest(of: destination) == artifact.sha256 else {
            throw InstallError.checksum(artifact.name)
        }
        return destination
    }

    // MARK: - Unpack

    static func unpack(_ archive: URL, kind: AgentArchiveKind, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", directory.path]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack(archive.lastPathComponent, process.terminationStatus)
        }
    }

    // MARK: - Errors

    enum InstallError: Error {
        case download(String, String)
        case checksum(String)
        case unpack(String, Int32)
        case layout(String)
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case InstallError.download(let name, let detail):
            return "Couldn't download \(name) (\(detail)). Check your connection and try again."
        case InstallError.checksum(let name):
            return "The downloaded \(name) failed its checksum and was discarded. Try again; if it keeps failing, the release may have been tampered with."
        case InstallError.unpack(let file, let code):
            return "Couldn't unpack \(file) (exit \(code))."
        case InstallError.layout(let detail):
            return "The downloaded archive didn't have the expected layout: \(detail)."
        default:
            return "Setup failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentRuntimeInstallerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentRuntimeInstaller.swift LokalBotTests/AgentRuntimeInstallerTests.swift LokalBot.xcodeproj
git commit -m "Add checksum-verified agent runtime installer"
```

---

### Task 8: AgentLLMEndpoint resolution

**Files:**
- Create: `LokalBot/Agent/AgentLLMEndpoint.swift`
- Test: `LokalBotTests/AgentLLMEndpointTests.swift`
- Read first: `LokalBot/Services/ProcessingPipeline.swift:453-490` (`makeTextEngine` — this resolver mirrors its backend switch, minus async work)

**Interfaces:**
- Consumes: `AppSettings` (`summarizerBackend`, `builtInModelID`, `customBuiltInModels`, `ollamaBaseURL`, `ollamaModel`, `openAIBaseURL`, `openAIModel`, `openAIAPIKey`), `ModelCatalog.entry(id:custom:)`, `ModelCatalog.recommendedSummarizationID`.
- Produces (used by Tasks 9, 13, 14):
  - `struct AgentLLMEndpoint: Equatable { let baseURL: URL; let model: String; let contextTokens: Int; let apiKey: String?; static let defaultContextTokens = 16_384 }`
  - `enum AgentLLMResolution: Equatable { case builtIn(modelID: String); case ready(AgentLLMEndpoint); case unsupported(reason: String) }`
  - `enum AgentLLMEndpointResolver { static func resolve(settings: AppSettings) -> AgentLLMResolution }`

Resolution is pure (no network, no server start): `.builtIn` defers `LlamaServer.ensureRunning` to the caller (Task 13); Ollama uses its OpenAI-compatible surface at `<ollamaBaseURL>/v1` and — unlike `makeTextEngine`'s zero-config auto-pick — requires an explicit model, because pi registers the model id statically at launch.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

final class AgentLLMEndpointTests: XCTestCase {

    private func settings(_ backend: AppSettings.SummarizerBackend) -> AppSettings {
        var s = AppSettings()
        s.summarizerBackend = backend
        return s
    }

    func testBuiltInResolvesToModelID() {
        let resolution = AgentLLMEndpointResolver.resolve(settings: settings(.builtIn))
        guard case .builtIn(let modelID) = resolution else {
            return XCTFail("expected .builtIn, got \(resolution)")
        }
        XCTAssertFalse(modelID.isEmpty)
    }

    func testAppleIntelligenceIsUnsupportedWithGuidance() {
        let resolution = AgentLLMEndpointResolver.resolve(settings: settings(.appleIntelligence))
        guard case .unsupported(let reason) = resolution else { return XCTFail() }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
        XCTAssertTrue(reason.contains("Built-in"))
    }

    func testOllamaRequiresExplicitModel() {
        var s = settings(.ollama)
        s.ollamaModel = ""
        guard case .unsupported(let reason) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("Ollama"))
    }

    func testOllamaAppendsV1() {
        var s = settings(.ollama)
        s.ollamaModel = "qwen3:8b"
        guard case .ready(let endpoint) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(endpoint.model, "qwen3:8b")
        XCTAssertNil(endpoint.apiKey)
        XCTAssertEqual(endpoint.contextTokens, AgentLLMEndpoint.defaultContextTokens)
    }

    func testOpenAICompatibleUsesBaseURLVerbatim() {
        var s = settings(.openAICompatible)
        s.openAIBaseURL = "http://localhost:1234/v1"
        s.openAIModel = "my-model"
        guard case .ready(let endpoint) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(endpoint.model, "my-model")
    }

    func testOpenAICompatibleRequiresModel() {
        var s = settings(.openAICompatible)
        s.openAIModel = ""
        guard case .unsupported = AgentLLMEndpointResolver.resolve(settings: s) else { return XCTFail() }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentLLMEndpointTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'AgentLLMEndpointResolver' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A resolved OpenAI-compatible endpoint the agent's provider will talk to.
struct AgentLLMEndpoint: Equatable {
    let baseURL: URL
    let model: String
    let contextTokens: Int
    let apiKey: String?

    /// Matches LlamaServer.shared's context size; also a sane compaction
    /// threshold for external endpoints whose true window we can't know.
    static let defaultContextTokens = 16_384
}

enum AgentLLMResolution: Equatable {
    /// Caller must `LlamaServer.shared.ensureRunning(modelAt:)` first, then
    /// build the endpoint from `LlamaServer.shared.baseURL` + this model id.
    case builtIn(modelID: String)
    case ready(AgentLLMEndpoint)
    case unsupported(reason: String)
}

/// Pure settings → endpoint resolution for Agent Mode. Mirrors the backend
/// switch in ProcessingPipeline.makeTextEngine, with two deliberate
/// differences: no async work here (server startup is the caller's job),
/// and Ollama requires an explicit model because pi registers the model id
/// statically at launch.
enum AgentLLMEndpointResolver {

    static func resolve(settings: AppSettings) -> AgentLLMResolution {
        switch settings.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: settings.builtInModelID,
                                                 custom: settings.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                return .unsupported(reason: "No built-in model is configured. Pick one under Settings → Models.")
            }
            return .builtIn(modelID: entry.id)

        case .appleIntelligence:
            return .unsupported(reason: "Apple Intelligence doesn't expose a local endpoint Agent Mode can use. Switch the Main LLM engine to Built-in llama.cpp (or Ollama / an OpenAI-compatible server) under Settings → Models.")

        case .ollama:
            guard let base = URL(string: settings.ollamaBaseURL) else {
                return .unsupported(reason: "The Ollama server URL under Settings → Models isn't a valid URL.")
            }
            guard !settings.ollamaModel.isEmpty else {
                return .unsupported(reason: "Pick an Ollama model under Settings → Models — Agent Mode needs an explicit model.")
            }
            return .ready(AgentLLMEndpoint(
                baseURL: base.appendingPathComponent("v1"),
                model: settings.ollamaModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: nil))

        case .openAICompatible:
            guard let base = URL(string: settings.openAIBaseURL) else {
                return .unsupported(reason: "The server URL under Settings → Models isn't a valid URL.")
            }
            guard !settings.openAIModel.isEmpty else {
                return .unsupported(reason: "Set a model name for the OpenAI-compatible server under Settings → Models.")
            }
            let key = settings.openAIAPIKey
            return .ready(AgentLLMEndpoint(
                baseURL: base,
                model: settings.openAIModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: key.isEmpty ? nil : key))
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentLLMEndpointTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentLLMEndpoint.swift LokalBotTests/AgentLLMEndpointTests.swift LokalBot.xcodeproj
git commit -m "Add agent LLM endpoint resolution mirroring makeTextEngine"
```

---

### Task 9: PiLaunchPlanner — the launch contract

**Files:**
- Create: `LokalBot/Agent/PiLaunchPlanner.swift`
- Test: `LokalBotTests/PiLaunchPlannerTests.swift`

**Interfaces:**
- Consumes: `AgentLLMEndpoint` (Task 8).
- Produces (used by Tasks 10, 13, 14, 17):
  - `struct PiLaunchPlan: Equatable { let executable: URL; let arguments: [String]; let environment: [String: String]; let workingDirectory: URL }`
  - `enum PiLaunchPlanner { static func plan(bun: URL, piCLI: URL, extensionDirectory: URL, skillDirectory: URL?, sessionDirectory: URL, workspace: URL, endpoint: AgentLLMEndpoint, helpersDirectory: URL?, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> PiLaunchPlan }`

This encodes the spec's launch contract verbatim. Every flag is load-bearing: `--offline` + `PI_SKIP_VERSION_CHECK=1` keep pi off the network (Global Constraints); `--no-extensions -e` / `--no-skills --skill` / `--no-prompt-templates` / `--no-approve` isolate from `~/.pi` and repo-local pi config; `--no-context-files` is deliberately absent.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

final class PiLaunchPlannerTests: XCTestCase {

    private let endpoint = AgentLLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:17872/v1")!,
        model: "qwen2.5-7b-instruct",
        contextTokens: 16_384,
        apiKey: nil)

    private func makePlan(apiKey: String? = nil,
                          skill: URL? = URL(fileURLWithPath: "/app/Resources/pi/lokalbot-cli-skill"),
                          helpers: URL? = URL(fileURLWithPath: "/app/Contents/Helpers")) -> PiLaunchPlan {
        PiLaunchPlanner.plan(
            bun: URL(fileURLWithPath: "/rt/bun/bun"),
            piCLI: URL(fileURLWithPath: "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"),
            extensionDirectory: URL(fileURLWithPath: "/app/Resources/pi/lokalbot-extension"),
            skillDirectory: skill,
            sessionDirectory: URL(fileURLWithPath: "/store/agent/sessions"),
            workspace: URL(fileURLWithPath: "/work"),
            endpoint: AgentLLMEndpoint(baseURL: endpoint.baseURL, model: endpoint.model,
                                       contextTokens: endpoint.contextTokens, apiKey: apiKey),
            helpersDirectory: helpers,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
    }

    func testArgumentsMatchTheSpecContract() {
        XCTAssertEqual(makePlan().arguments, [
            "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", "qwen2.5-7b-instruct",
            "--no-extensions", "-e", "/app/Resources/pi/lokalbot-extension",
            "--no-skills", "--skill", "/app/Resources/pi/lokalbot-cli-skill",
            "--no-prompt-templates",
            "--no-approve",
            "--session-dir", "/store/agent/sessions",
            "--offline",
        ])
    }

    func testEnvironmentCarriesEndpointAndPrivacyGuards() {
        let env = makePlan().environment
        XCTAssertEqual(env["LOKALBOT_LLM_BASE_URL"], "http://127.0.0.1:17872/v1")
        XCTAssertEqual(env["LOKALBOT_LLM_MODEL"], "qwen2.5-7b-instruct")
        XCTAssertEqual(env["LOKALBOT_LLM_CTX"], "16384")
        XCTAssertNil(env["LOKALBOT_LLM_API_KEY"])
        XCTAssertEqual(env["PI_SKIP_VERSION_CHECK"], "1")
        XCTAssertEqual(env["PATH"], "/app/Contents/Helpers:/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/x", "base environment is preserved")
    }

    func testAPIKeyIsPassedWhenPresent() {
        XCTAssertEqual(makePlan(apiKey: "sk-test").environment["LOKALBOT_LLM_API_KEY"], "sk-test")
    }

    func testNoSkillDirectoryOmitsSkillFlagButKeepsNoSkills() {
        let arguments = makePlan(skill: nil).arguments
        XCTAssertTrue(arguments.contains("--no-skills"))
        XCTAssertFalse(arguments.contains("--skill"))
    }

    func testExecutableAndCwd() {
        let plan = makePlan()
        XCTAssertEqual(plan.executable.path, "/rt/bun/bun")
        XCTAssertEqual(plan.workingDirectory.path, "/work")
    }

    func testNoContextFilesFlagIsDeliberatelyAbsent() {
        XCTAssertFalse(makePlan().arguments.contains("--no-context-files"),
                       "project AGENTS.md/CLAUDE.md context stays enabled by design")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiLaunchPlannerTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'PiLaunchPlanner' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Everything needed to spawn one pi RPC subprocess.
struct PiLaunchPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

/// Builds the exact pi launch contract from the 2026-07-09 spec. pi is
/// fully isolated from the user's ~/.pi and any repo-local pi config
/// (--no-extensions/-e, --no-skills/--skill, --no-prompt-templates,
/// --no-approve) and fully offline (--offline + PI_SKIP_VERSION_CHECK —
/// pi ships install telemetry and update checks enabled by default).
/// --no-context-files is deliberately NOT passed: project AGENTS.md /
/// CLAUDE.md context stays on.
enum PiLaunchPlanner {

    static func plan(bun: URL,
                     piCLI: URL,
                     extensionDirectory: URL,
                     skillDirectory: URL?,
                     sessionDirectory: URL,
                     workspace: URL,
                     endpoint: AgentLLMEndpoint,
                     helpersDirectory: URL?,
                     baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> PiLaunchPlan {
        var arguments = [
            piCLI.path,
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", endpoint.model,
            "--no-extensions", "-e", extensionDirectory.path,
            "--no-skills",
        ]
        if let skillDirectory {
            arguments += ["--skill", skillDirectory.path]
        }
        arguments += [
            "--no-prompt-templates",
            "--no-approve",
            "--session-dir", sessionDirectory.path,
            "--offline",
        ]

        var environment = baseEnvironment
        environment["LOKALBOT_LLM_BASE_URL"] = endpoint.baseURL.absoluteString
        environment["LOKALBOT_LLM_MODEL"] = endpoint.model
        environment["LOKALBOT_LLM_CTX"] = String(endpoint.contextTokens)
        if let apiKey = endpoint.apiKey {
            environment["LOKALBOT_LLM_API_KEY"] = apiKey
        }
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        if let helpersDirectory {
            // lokalbot-cli lives in Contents/Helpers; the bundled skill
            // invokes it by name, so it must be on the agent's PATH.
            let existing = environment["PATH"] ?? ""
            environment["PATH"] = existing.isEmpty
                ? helpersDirectory.path
                : "\(helpersDirectory.path):\(existing)"
        }
        return PiLaunchPlan(executable: bun,
                            arguments: arguments,
                            environment: environment,
                            workingDirectory: workspace)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiLaunchPlannerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/PiLaunchPlanner.swift LokalBotTests/PiLaunchPlannerTests.swift LokalBot.xcodeproj
git commit -m "Add pi launch contract planner"
```

---
### Task 10: PiProcess — subprocess supervision

**Files:**
- Create: `LokalBot/Agent/PiProcess.swift`
- Test: `LokalBotTests/PiProcessTests.swift`
- Read first: `LokalBot/Services/LlamaServer.swift` (the existing Process-supervision pattern this follows)

**Interfaces:**
- Consumes: `PiLaunchPlan` (Task 9), `PiJSONLFrameSplitter` (Task 1).
- Produces (used by Task 11):
  - `actor PiProcess` with:
    - `init(plan: PiLaunchPlan)`
    - `func start() throws` — spawns; throws if executable missing
    - `func send(line: String) throws` — appends `\n`, writes to stdin; throws `PiProcessError.notRunning` if dead
    - `var lines: AsyncStream<String>` — complete JSONL frames from stdout (via `PiJSONLFrameSplitter`); finishes on process exit
    - `func stop() async` — SIGTERM, 2 s grace, SIGKILL; idempotent
    - `var isRunning: Bool`
    - `private(set) var stderrTail: [String]` — last 50 stderr lines, for error surfacing
  - `enum PiProcessError: Error { case executableNotFound(String), notRunning }`

The tests don't need Bun or pi — any executable that speaks lines on stdio works. They use `/bin/cat` (echoes stdin to stdout — perfect for framing round-trips) and `/bin/sh` scripts.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

final class PiProcessTests: XCTestCase {

    private func plan(_ executable: String, _ arguments: [String] = []) -> PiLaunchPlan {
        PiLaunchPlan(executable: URL(fileURLWithPath: executable),
                     arguments: arguments,
                     environment: ["PATH": "/usr/bin:/bin"],
                     workingDirectory: FileManager.default.temporaryDirectory)
    }

    func testRoundTripsLinesThroughCat() async throws {
        let process = PiProcess(plan: plan("/bin/cat"))
        try await process.start()
        try await process.send(line: #"{"type":"get_state"}"#)
        var iterator = (await process.lines).makeAsyncIterator()
        let echoed = await iterator.next()
        XCTAssertEqual(echoed, #"{"type":"get_state"}"#)
        await process.stop()
    }

    func testLinesStreamFinishesOnExit() async throws {
        let process = PiProcess(plan: plan("/bin/sh", ["-c", "printf 'one\\ntwo\\n'"]))
        try await process.start()
        var collected: [String] = []
        for await line in await process.lines { collected.append(line) }
        XCTAssertEqual(collected, ["one", "two"])
        let running = await process.isRunning
        XCTAssertFalse(running)
    }

    func testMissingExecutableThrows() async {
        let process = PiProcess(plan: plan("/nonexistent/bun"))
        do {
            try await process.start()
            XCTFail("expected throw")
        } catch PiProcessError.executableNotFound { // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSendAfterExitThrowsNotRunning() async throws {
        let process = PiProcess(plan: plan("/usr/bin/true"))
        try await process.start()
        // Wait for exit by draining the (empty) stream.
        for await _ in await process.lines {}
        do {
            try await process.send(line: "hello")
            XCTFail("expected throw")
        } catch PiProcessError.notRunning { // expected
        }
    }

    func testStderrTailIsCaptured() async throws {
        let process = PiProcess(plan: plan("/bin/sh", ["-c", "echo boom >&2"]))
        try await process.start()
        for await _ in await process.lines {}
        try await Task.sleep(for: .milliseconds(200))   // stderr pipe drains async
        let tail = await process.stderrTail
        XCTAssertTrue(tail.contains("boom"), "\(tail)")
        await process.stop()
    }

    func testStopIsIdempotent() async throws {
        let process = PiProcess(plan: plan("/bin/cat"))
        try await process.start()
        await process.stop()
        await process.stop()
        let running = await process.isRunning
        XCTAssertFalse(running)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiProcessTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'PiProcess' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum PiProcessError: Error {
    case executableNotFound(String)
    case notRunning
}

/// Owns one pi subprocess: spawns it from a PiLaunchPlan, feeds stdout
/// bytes through PiJSONLFrameSplitter (LF-only framing — see the splitter's
/// doc comment), exposes complete frames as an AsyncStream, and supervises
/// shutdown (SIGTERM → 2s grace → SIGKILL). Mirrors the Process-handling
/// approach in LlamaServer, as an actor because send/stop race with the
/// termination handler.
actor PiProcess {

    private let plan: PiLaunchPlan
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var splitter = PiJSONLFrameSplitter()
    private var linesContinuation: AsyncStream<String>.Continuation?
    private var started = false
    private var exited = false
    private(set) var stderrTail: [String] = []

    let lines: AsyncStream<String>

    init(plan: PiLaunchPlan) {
        self.plan = plan
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        linesContinuation = continuation
    }

    var isRunning: Bool { started && !exited }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: plan.executable.path) else {
            throw PiProcessError.executableNotFound(plan.executable.path)
        }
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { [weak self] in await self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in await self?.consumeStderr(text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in await self?.handleExit() }
        }
        try process.run()
        started = true
    }

    func send(line: String) throws {
        guard isRunning else { throw PiProcessError.notRunning }
        let payload = Data((line + "\n").utf8)
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
    }

    func stop() async {
        guard isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {   // 2s grace
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        handleExit()
    }

    // MARK: - Private

    private func consumeStdout(_ data: Data) {
        if data.isEmpty {   // EOF
            if let last = splitter.flush() { linesContinuation?.yield(last) }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        for frame in splitter.append(data) {
            linesContinuation?.yield(frame)
        }
    }

    private func consumeStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
    }

    private func handleExit() {
        guard !exited else { return }
        exited = true
        if let last = splitter.flush() { linesContinuation?.yield(last) }
        linesContinuation?.finish()
        linesContinuation = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
    }
}
```

One subtlety: `handleExit` may run before the final `consumeStdout` Task drains — that's why EOF handling in `consumeStdout` also flushes. Both paths are idempotent (`flush()` returns nil on an empty buffer; `exited` guards double-finish).

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiProcessTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/PiProcess.swift LokalBotTests/PiProcessTests.swift LokalBot.xcodeproj
git commit -m "Add supervised pi subprocess with JSONL frame streaming"
```

---

### Task 11: PiRPCClient — command/response correlation + event stream

**Files:**
- Create: `LokalBot/Agent/PiRPCClient.swift`
- Test: `LokalBotTests/PiRPCClientTests.swift`

**Interfaces:**
- Consumes: `PiCommand`, `PiResponse`, `PiEvent` (Task 2). Does NOT consume PiProcess directly — it takes a line transport, so tests inject a fake and Task 13 adapts PiProcess.
- Produces (used by Tasks 13, 14):
  - `protocol PiLineTransport: Sendable { func send(line: String) async throws; var incoming: AsyncStream<String> { get } }`
  - `extension PiProcess: PiLineTransport` (trivial — `send` forwards, `incoming` returns `lines`)
  - `actor PiRPCClient`:
    - `init(transport: PiLineTransport)`
    - `func run()` — starts consuming `transport.incoming`; call once
    - `var events: AsyncStream<PiEvent>` — every decoded non-response line, plus `.response` lines that carry no pending id
    - `func request(_ command: PiCommand) async throws -> PiResponse` — sends, suspends until the matching-id response arrives; throws `PiRPCError.transportClosed` if the stream finishes first
    - `func sendResponse(_ command: PiCommand)` async throws — fire-and-forget (for `extension_ui_response`, which pi never acks with a matching id)
  - `enum PiRPCError: Error { case transportClosed }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LokalBot

/// A scriptable transport: records sent lines and lets the test inject
/// incoming lines.
final class FakeTransport: PiLineTransport, @unchecked Sendable {
    private(set) var sent: [String] = []
    private let lock = NSLock()
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var c: AsyncStream<String>.Continuation!
        incoming = AsyncStream { c = $0 }
        continuation = c
    }

    func send(line: String) async throws {
        lock.lock(); sent.append(line); lock.unlock()
    }

    func inject(_ line: String) { continuation.yield(line) }
    func close() { continuation.finish() }
    var sentLines: [String] { lock.lock(); defer { lock.unlock() }; return sent }
}

final class PiRPCClientTests: XCTestCase {

    func testRequestResolvesOnMatchingID() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()

        async let responseTask = client.request(.getState(id: "s1"))
        // Give the request time to hit the wire, then answer it.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""id":"s1""#) })
        transport.inject(#"{"type":"response","id":"s1","command":"get_state","success":true}"#)
        let response = try await responseTask
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.command, "get_state")
    }

    func testNonResponseLinesFlowToEventStream() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        var iterator = (await client.events).makeAsyncIterator()
        transport.inject(#"{"type":"agent_start"}"#)
        let event = await iterator.next()
        XCTAssertEqual(event, .agentStart)
    }

    func testInterleavedEventsDoNotStealResponses() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        async let responseTask = client.request(.prompt(id: "p1", message: "hi", streamingBehavior: nil))
        try await Task.sleep(for: .milliseconds(100))
        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        let response = try await responseTask
        XCTAssertEqual(response.id, "p1")
    }

    func testTransportCloseFailsPendingRequests() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        async let responseTask = client.request(.getState(id: "s2"))
        try await Task.sleep(for: .milliseconds(100))
        transport.close()
        do {
            _ = try await responseTask
            XCTFail("expected throw")
        } catch PiRPCError.transportClosed { // expected
        }
    }

    func testSendResponseWritesWithoutWaiting() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        try await client.sendResponse(.uiConfirmResponse(requestID: "u1", confirmed: true))
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#) })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiRPCClientTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'PiRPCClient' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Line-oriented transport a PiRPCClient talks through. PiProcess is the
/// real one; tests inject fakes.
protocol PiLineTransport: Sendable {
    func send(line: String) async throws
    var incoming: AsyncStream<String> { get }
}

// The actor's synchronous `send(line:)` witnesses the async protocol
// requirement (callers hop onto the actor); only `incoming` needs adding.
extension PiProcess: PiLineTransport {
    nonisolated var incoming: AsyncStream<String> { lines }
}

enum PiRPCError: Error {
    case transportClosed
}

/// Correlates pi RPC commands with their `{type:"response", id:…}` acks
/// and fans every other stdout line out as a PiEvent. One consumer loop
/// (started by run()) owns the incoming stream; pending requests are keyed
/// by the id we generated into the command JSON.
actor PiRPCClient {

    private let transport: PiLineTransport
    private var pending: [String: CheckedContinuation<PiResponse, Error>] = [:]
    private var consuming = false
    let events: AsyncStream<PiEvent>
    private let eventContinuation: AsyncStream<PiEvent>.Continuation

    init(transport: PiLineTransport) {
        self.transport = transport
        var continuation: AsyncStream<PiEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func run() {
        guard !consuming else { return }
        consuming = true
        Task { [weak self] in
            guard let self else { return }
            for await line in transport.incoming {
                await self.handle(line: line)
            }
            await self.handleClose()
        }
    }

    func request(_ command: PiCommand) async throws -> PiResponse {
        guard let id = command.id else {
            preconditionFailure("request() needs a command with an id")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(line: command.jsonLine)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// For extension_ui_response and other lines pi never acks.
    func sendResponse(_ command: PiCommand) async throws {
        try await transport.send(line: command.jsonLine)
    }

    // MARK: - Private

    private func handle(line: String) {
        guard let event = PiEvent.decode(line: line) else { return }
        if case .response(let response) = event,
           let id = response.id,
           let waiting = pending.removeValue(forKey: id) {
            waiting.resume(returning: response)
            return
        }
        eventContinuation.yield(event)
    }

    private func handleClose() {
        for (_, waiting) in pending {
            waiting.resume(throwing: PiRPCError.transportClosed)
        }
        pending.removeAll()
        eventContinuation.finish()
    }
}
```

Note for the implementer: Task 2 defined `PiCommand` with per-case ids. Add this small extension in `PiRPCClient.swift` (it's transport plumbing, not message vocabulary):

```swift
extension PiCommand {
    /// The correlation id embedded in this command's JSON, if any.
    var id: String? {
        switch self {
        case .prompt(let id, _, _), .steer(let id, _), .abort(let id),
             .newSession(let id), .getState(let id):
            return id
        case .uiConfirmResponse, .uiCancelResponse:
            return nil   // ui responses correlate to pi's request id, not ours
        }
    }
}
```

If Task 2's implementation already exposes `var id: String?` on `PiCommand`, skip the extension.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiRPCClientTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/PiRPCClient.swift LokalBotTests/PiRPCClientTests.swift LokalBot.xcodeproj
git commit -m "Add id-correlated pi RPC client with event stream"
```

---

### Task 12: The LokalBot pi extension (provider + approval gate) and library skill

**Files:**
- Create: `LokalBot/Resources/pi/lokalbot-extension/index.ts`
- Create: `LokalBot/Resources/pi/lokalbot-cli-skill/SKILL.md`
- Modify: `project.yml` — add `LokalBot/Resources/pi` as a bundle resource (folder reference) on the app target template
- Test: manual smoke via the Task 5 vendored runtime (this is TypeScript running inside pi — no Swift test can cover it; Task 14's integration test exercises it end-to-end)

**Interfaces:**
- Consumes (env, set by `PiLaunchPlanner`, Task 9): `LOKALBOT_LLM_BASE_URL`, `LOKALBOT_LLM_MODEL`, `LOKALBOT_LLM_CTX`, `LOKALBOT_LLM_API_KEY` (optional).
- Produces: pi provider named `lokalbot` (matching `--provider lokalbot` in the launch plan); a `tool_call` gate that raises `ctx.ui.confirm(title: "lokalbot_tool_approval", message: JSON {tool, summary})` for `write`/`edit`/`bash` (which PiRPCClient sees as `extension_ui_request` and Task 13 answers via `uiConfirmResponse`); the `lokalbot-cli-skill` folder Task 13 passes to `--skill`.

- [ ] **Step 1: Write the extension**

```typescript
// LokalBot pi extension: registers the app-configured local LLM as a
// provider and gates mutating tools behind the host UI.
//
// Runs inside pi (RPC mode) under Bun. The env contract comes from
// PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
// extension_ui_request on stdout, answered over stdin.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const GATED_TOOLS = new Set(["write", "edit", "bash"]);

export default function lokalbotExtension(pi: ExtensionAPI) {
  const baseUrl = process.env.LOKALBOT_LLM_BASE_URL;
  const model = process.env.LOKALBOT_LLM_MODEL;
  if (!baseUrl || !model) {
    throw new Error(
      "LOKALBOT_LLM_BASE_URL and LOKALBOT_LLM_MODEL must be set (launched outside LokalBot?)",
    );
  }
  const contextWindow = Number(process.env.LOKALBOT_LLM_CTX ?? "16384");

  pi.registerProvider("lokalbot", {
    baseUrl,
    api: "openai-completions",
    // llama.cpp ignores the key; Ollama/LM Studio may want one.
    apiKey: process.env.LOKALBOT_LLM_API_KEY ?? "lokalbot",
    models: [
      {
        id: model,
        contextWindow,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!GATED_TOOLS.has(event.toolName)) return undefined; // reads auto-allowed

    // Machine-parseable payload: LokalBot recognizes the sentinel title and
    // parses tool + summary from the JSON message (PiUIRequest, Task 2).
    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify({
        tool: event.toolName,
        summary: summarize(event.toolName, event.input),
      }),
    );
    if (!approved) {
      return { block: true, reason: "Blocked by user in LokalBot." };
    }
    return undefined;
  });
}

function summarize(toolName: string, input: unknown): string {
  const args = (input ?? {}) as Record<string, unknown>;
  switch (toolName) {
    case "bash":
      return String(args.command ?? args.cmd ?? JSON.stringify(args)).slice(0, 500);
    case "write":
    case "edit":
      return String(args.path ?? args.file_path ?? JSON.stringify(args)).slice(0, 500);
    default:
      return JSON.stringify(args).slice(0, 500);
  }
}
```

- [ ] **Step 2: Write the meeting-library skill**

`LokalBot/Resources/pi/lokalbot-cli-skill/SKILL.md` — this is the "lokalbot-cli preinstalled as agent skill" spec decision. The launch plan (Task 9) puts `Contents/Helpers` on the agent's PATH, so the tool is invocable by name:

```markdown
---
name: lokalbot-library
description: Query the user's LokalBot meeting library (transcripts, summaries, full-text search) via the lokalbot-cli tool. Use when asked about the user's meetings, recordings, or what was said or decided in them.
---

# LokalBot meeting library

`lokalbot-cli` is preinstalled on PATH and gives read-only access to the
meeting library. Output is JSON by default; add `--table` for human-readable.

- `lokalbot-cli list [--limit N]` — recent meetings (id, title, date, duration)
- `lokalbot-cli get <id>` — one meeting's metadata and summary
- `lokalbot-cli search "<query>"` — full-text search across transcripts
- `lokalbot-cli path <id>` — filesystem folder of a meeting (transcript.md, summary.md, audio)

Prefer `search` over reading transcript files directly — transcripts can be
very long. Never modify files inside the library; treat it as read-only.
```

- [ ] **Step 3: Wire the resource into project.yml**

In `project.yml`, find the app target template's `sources:` list (the one shared by `LokalBot` and `LokalBot Dev`) and add the pi resources folder as a non-compiled resource:

```yaml
        - path: LokalBot/Resources/pi
          type: folder
          buildPhase: resources
```

Place it alongside the existing resource entries in the same template. Then:

```bash
xcodegen generate
```

- [ ] **Step 4: Smoke-test against the vendored runtime**

Uses the runtime installed by Task 5's `--install-local`. Verifies pi loads the extension, registers the provider, and the gate blocks/allows over the ui sub-protocol.

```bash
RT="$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime"
EXT="$(pwd)/LokalBot/Resources/pi/lokalbot-extension"
export PI_SKIP_VERSION_CHECK=1
export LOKALBOT_LLM_BASE_URL="http://127.0.0.1:9/v1"   # unreachable on purpose; we only test load + get_state
export LOKALBOT_LLM_MODEL="test-model"
printf '{"type":"get_state"}\n' | \
  "$RT/bun/bun" "$RT/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" \
  --mode rpc --provider lokalbot --model test-model \
  --no-extensions -e "$EXT" --no-skills --no-prompt-templates --no-approve --offline \
  | head -3
```

Expected: a `{"type":"response","command":"get_state","success":true,...}` line whose state shows model `test-model` — proving the provider registered from env and the extension loaded without error. If instead you get an `extension_error` event, read its message (typical cause: the `ExtensionAPI` type import name drifted in the pinned pi version — check `"$RT/pi/node_modules/@earendil-works/pi-coding-agent/dist/index.d.ts"` for the exported name and fix the import; the runtime shape `pi.registerProvider` / `pi.on("tool_call", ...)` is stable in 0.80.x).

- [ ] **Step 5: Build the app to confirm the resources land in the bundle**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot Dev" -destination 'platform=macOS' build 2>&1 | tail -3
ls ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/LokalBot.app/Contents/Resources/pi/lokalbot-extension/index.ts \
   ~/Library/Developer/Xcode/DerivedData/LokalBot-*/Build/Products/Debug/LokalBot.app/Contents/Resources/pi/lokalbot-cli-skill/SKILL.md
```

Expected: build succeeds; `ls` prints both paths (folder reference copied verbatim).

- [ ] **Step 6: Commit**

```bash
git add LokalBot/Resources/pi project.yml LokalBot.xcodeproj
git commit -m "Add LokalBot pi extension (provider + approval gate) and library skill"
```

---
### Task 13: AgentSessionController — the orchestrator

**Files:**
- Create: `LokalBot/Agent/AgentSessionController.swift`
- Test: `LokalBotTests/AgentSessionControllerTests.swift`

**Interfaces:**
- Consumes: `AgentLLMEndpointResolver`/`AgentLLMEndpoint` (Task 8), `PiLaunchPlanner` (Task 9), `PiProcess` (Task 10), `PiRPCClient`/`PiLineTransport` (Task 11), `AgentTranscriptFolder`/`AgentTranscriptItem` (Task 4), `AgentApprovalPolicy` (Task 3), `AgentRuntimeLayout` (Task 6), `LlamaServer.shared.ensureRunning(modelAt:)` + `.baseURL`, `ModelCatalog.localURL(for:storage:)`, `StorageManager` (`rootURL`).
- Produces (used by Tasks 15, 16, 18):
  - `@MainActor final class AgentSessionController: ObservableObject`:
    - `enum SessionState: Equatable { case idle, starting, ready, running, failed(String) }`
    - `@Published private(set) var state: SessionState`
    - `@Published private(set) var items: [AgentTranscriptItem]`
    - `@Published var workspace: URL`
    - `@Published var autoApproveSession: Bool` (didSet → `policy.autoApproveAll`)
    - `init(settings: @escaping () -> AppSettings, storage: StorageManager, runtimeRoot: URL = AgentRuntimeLayout.defaultRoot, makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil)` — `makeTransport` is the test seam; nil = real `PiProcess`
    - `func start() async` — resolve endpoint → (if `.builtIn`) ensure llama-server running → build plan → spawn transport → `PiRPCClient.run()` → consume events
    - `func send(prompt: String) async` — folds `.user`, issues `.prompt` (uses `streamingBehavior: "followUp"` when `state == .running`)
    - `func abort() async`
    - `func newSession() async`
    - `func respondToApproval(id: String, approved: Bool, scope: ApprovalScope) async` — answers pi, updates policy for `.session`, removes the approval card
    - `func shutdown() async`

Event loop rules (each is a test below):
1. Every `PiEvent` goes through `AgentTranscriptFolder.fold` and `items` is republished.
2. `.extensionUIRequest(PiUIRequest)` with `method == "confirm"`: consult `policy.verdict(tool:)` — our extension (Task 12) sends `title == "lokalbot_tool_approval"` and `message` = JSON `{"tool": "...", "summary": "..."}`; parse tool + summary from that JSON (fall back to title/message verbatim for foreign confirms). `.allow` ⇒ auto-reply `uiConfirmResponse(confirmed: true)` immediately, no card. `.ask` ⇒ `folder.addApproval` and wait for `respondToApproval`.
3. Non-confirm UI requests (select/input/editor) are auto-cancelled with `uiCancelResponse` and a `.notice` is folded (v1 has no UI for them; the spec's error table calls this "unsupported interaction, declined").
4. `agentStart` ⇒ `state = .running`; `agentSettled`/`agentEnd` ⇒ `.ready`.
5. Transport stream finishing while state ≠ idle ⇒ `state = .failed(…)` with stderr tail if available, and a `.notice(isError: true)`.

- [ ] **Step 1: Write the failing test**

The controller is tested end-to-end against the same `FakeTransport` from Task 11 (move it into a shared helper file now).

First, extract the fake: create `LokalBotTests/Helpers/FakeTransport.swift` containing the `FakeTransport` class exactly as written in Task 11 Step 1 (delete the copy inside `PiRPCClientTests.swift` and import it from both). Then:

```swift
import XCTest
@testable import LokalBot

@MainActor
final class AgentSessionControllerTests: XCTestCase {

    private var transport: FakeTransport!

    private func makeController(backend: AppSettings.SummarizerBackend = .openAICompatible) -> AgentSessionController {
        transport = FakeTransport()
        var settings = AppSettings()
        settings.summarizerBackend = backend
        settings.openAIBaseURL = "http://localhost:1234/v1"
        settings.openAIModel = "test-model"
        let captured = transport!
        return AgentSessionController(
            settings: { settings },
            storage: StorageManager(),
            makeTransport: { _ in captured })
    }

    private func pump() async throws {
        // Let the event-consumption task drain injected lines.
        try await Task.sleep(for: .milliseconds(150))
    }

    func testStartReachesReady() async throws {
        let controller = makeController()
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
    }

    func testUnsupportedBackendFailsWithoutSpawning() async throws {
        let controller = makeController(backend: .appleIntelligence)
        await controller.start()
        guard case .failed(let reason) = controller.state else { return XCTFail() }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
    }

    func testSendFoldsUserAndStreamsAssistant() async throws {
        let controller = makeController()
        await controller.start()
        await controller.send(prompt: "hello")
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""type":"prompt""#) && $0.contains("hello") })

        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(#"{"type":"message_start","message":{"role":"assistant"}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hi "}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"there"}}"#)
        try await pump()
        XCTAssertEqual(controller.state, .running)
        guard case .assistant(_, let text, let streaming) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertTrue(streaming)

        transport.inject(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"}]}}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertEqual(controller.state, .ready)
        guard case .assistant(_, let final, let stillStreaming) = controller.items.last else { return XCTFail() }
        XCTAssertEqual(final, "Hi there!")
        XCTAssertFalse(stillStreaming)
    }

    func testConfirmRequestRaisesApprovalCardAndReplies() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"rm -rf /tmp/x\"}"}"#)
        try await pump()
        guard case .approval(let id, let tool, let summary) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(id, "u1")
        XCTAssertEqual(tool, "bash")
        XCTAssertEqual(summary, "rm -rf /tmp/x")

        await controller.respondToApproval(id: "u1", approved: true, scope: .once)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertFalse(controller.items.contains {
            if case .approval = $0 { return true } else { return false }
        }, "approval card removed after answer")
    }

    func testSessionScopeAutoApprovesRepeats() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"ls\"}"}"#)
        try await pump()
        await controller.respondToApproval(id: "u1", approved: true, scope: .session)
        transport.inject(#"{"type":"extension_ui_request","id":"u2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"pwd\"}"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u2""#) && $0.contains(#""confirmed":true"#)
        }, "second bash auto-approved for the session")
        XCTAssertFalse(controller.items.contains {
            if case .approval(let id, _, _) = $0 { return id == "u2" } else { return false }
        })
    }

    func testNonConfirmUIRequestIsDeclined() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u3","method":"input","title":"Enter value"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u3""#) && $0.contains(#""cancelled":true"#)
        })
        guard case .notice(_, let text, _) = controller.items.last else { return XCTFail() }
        XCTAssertTrue(text.contains("unsupported"))
    }

    func testTransportDeathFailsSession() async throws {
        let controller = makeController()
        await controller.start()
        transport.close()
        try await pump()
        guard case .failed = controller.state else { return XCTFail("\(controller.state)") }
        guard case .notice(_, _, let isError) = controller.items.last else { return XCTFail() }
        XCTAssertTrue(isError)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentSessionControllerTests 2>&1 | tail -10`
Expected: FAILS — "cannot find 'AgentSessionController' in scope". (`PiRPCClientTests` must still pass after the FakeTransport extraction.)

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Orchestrates one Agent Mode session: resolves the LLM endpoint, spawns
/// the pi subprocess (or a test transport), pumps pi events into the
/// transcript, and round-trips tool approvals between pi's confirm dialogs
/// and the UI. Lives on the main actor because it feeds SwiftUI directly.
@MainActor
final class AgentSessionController: ObservableObject {

    enum SessionState: Equatable {
        case idle, starting, ready, running
        case failed(String)
    }

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var items: [AgentTranscriptItem] = []
    @Published var workspace: URL
    @Published var autoApproveSession = false {
        didSet { policy.autoApproveAll = autoApproveSession }
    }

    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let runtimeRoot: URL
    private let makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)?

    private var policy = AgentApprovalPolicy()
    private var folder = AgentTranscriptFolder()
    private var client: PiRPCClient?
    private var process: PiProcess?
    private var eventTask: Task<Void, Never>?
    private var nextRequestID = 0

    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil) {
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.makeTransport = makeTransport
        self.workspace = storage.rootURL
    }

    // MARK: - Lifecycle

    func start() async {
        guard state == .idle || isFailed else { return }
        state = .starting
        do {
            let endpoint = try await resolveEndpoint()
            let plan = makePlan(endpoint: endpoint)
            let transport: PiLineTransport
            if let makeTransport {
                transport = try await makeTransport(plan)
            } else {
                let piProcess = PiProcess(plan: plan)
                try await piProcess.start()
                process = piProcess
                transport = piProcess
            }
            let rpc = PiRPCClient(transport: transport)
            await rpc.run()
            client = rpc
            consumeEvents(from: rpc)
            state = .ready
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        await process?.stop()
        process = nil
        client = nil
        state = .idle
    }

    // MARK: - Prompting

    func send(prompt: String) async {
        guard let client, state == .ready || state == .running else { return }
        folder.noteUserPrompt(prompt)
        publish()
        let behavior = state == .running ? "followUp" : nil
        do {
            let response = try await client.request(
                .prompt(id: freshID("p"), message: prompt, streamingBehavior: behavior))
            if !response.success {
                folder.appendNotice(response.error ?? "pi rejected the prompt", isError: true)
                publish()
            }
        } catch {
            fail(with: error)
        }
    }

    func abort() async {
        guard let client else { return }
        _ = try? await client.request(.abort(id: freshID("a")))
    }

    func newSession() async {
        guard let client else { return }
        do {
            _ = try await client.request(.newSession(id: freshID("n")))
            folder = AgentTranscriptFolder()
            policy.resetSession()
            publish()
            state = .ready
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Approvals

    func respondToApproval(id: String, approved: Bool, scope: ApprovalScope) async {
        guard let client else { return }
        if approved, scope == .session,
           let tool = pendingApprovalTool(requestID: id) {
            policy.allowForSession(tool: tool)
        }
        folder.resolveApproval(requestID: id)
        publish()
        try? await client.sendResponse(.uiConfirmResponse(requestID: id, confirmed: approved))
    }

    // MARK: - Event loop

    private func consumeEvents(from client: PiRPCClient) {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await client.events {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
            await self.handleStreamEnd()
        }
    }

    private func handle(_ event: PiEvent) async {
        switch event {
        case .agentStart:
            state = .running
        case .agentSettled, .agentEnd:
            state = .ready
        case .extensionUIRequest(let request):
            await handleUIRequest(request)
        default:
            break
        }
        folder.fold(event)
        publish()
    }

    private func handleUIRequest(_ request: PiUIRequest) async {
        guard let client else { return }
        guard request.method == "confirm" else {
            folder.appendNotice("The agent asked for an unsupported interaction (\(request.method)); declined.", isError: false)
            try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            return
        }
        let (tool, summary) = Self.parseApprovalPayload(request)
        switch policy.verdict(tool: tool) {
        case .allow:
            try? await client.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: true))
        case .ask:
            folder.addApproval(requestID: request.id, tool: tool, argsJSON: summary)
        }
    }

    private func handleStreamEnd() async {
        guard state != .idle else { return }
        var detail = "The agent process exited unexpectedly."
        if let process {
            let tail = await process.stderrTail
            if !tail.isEmpty { detail += "\n" + tail.suffix(5).joined(separator: "\n") }
        }
        folder.appendNotice(detail, isError: true)
        publish()
        state = .failed(detail)
    }

    // MARK: - Endpoint + plan

    private func resolveEndpoint() async throws -> AgentLLMEndpoint {
        switch AgentLLMEndpointResolver.resolve(settings: settings()) {
        case .ready(let endpoint):
            return endpoint
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings().customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID),
                  let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw StartError.notReady("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
            return AgentLLMEndpoint(baseURL: LlamaServer.shared.baseURL,
                                    model: entry.id,
                                    contextTokens: AgentLLMEndpoint.defaultContextTokens,
                                    apiKey: nil)
        case .unsupported(let reason):
            throw StartError.notReady(reason)
        }
    }

    private func makePlan(endpoint: AgentLLMEndpoint) -> PiLaunchPlan {
        let resources = Bundle.main.resourceURL
        let extensionDir = resources?.appendingPathComponent("pi/lokalbot-extension")
            ?? URL(fileURLWithPath: "pi/lokalbot-extension")
        let skillDir = resources?.appendingPathComponent("pi/lokalbot-cli-skill")
        let skillExists = skillDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let sessions = AgentRuntimeLayout.sessionsDirectory
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return PiLaunchPlanner.plan(
            bun: AgentRuntimeLayout.bunBinary(under: runtimeRoot),
            piCLI: AgentRuntimeLayout.piCLI(under: runtimeRoot),
            extensionDirectory: extensionDir,
            skillDirectory: skillExists ? skillDir : nil,
            sessionDirectory: sessions,
            workspace: workspace,
            endpoint: endpoint,
            helpersDirectory: FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil)
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    private func publish() {
        items = folder.items
    }

    private func freshID(_ prefix: String) -> String {
        nextRequestID += 1
        return "\(prefix)\(nextRequestID)"
    }

    private func pendingApprovalTool(requestID: String) -> String? {
        for item in folder.items {
            if case .approval(let id, let tool, _) = item, id == requestID { return tool }
        }
        return nil
    }

    private func fail(with error: Error) {
        let message = Self.message(for: error)
        folder.appendNotice(message, isError: true)
        publish()
        state = .failed(message)
    }

    /// Our extension (Task 12) sends title "lokalbot_tool_approval" with a JSON
    /// message {"tool": "...", "summary": "..."}. Anything else (a foreign confirm)
    /// falls back to displaying the title/message verbatim.
    static func parseApprovalPayload(_ request: PiUIRequest) -> (tool: String, summary: String) {
        if request.title == "lokalbot_tool_approval",
           let data = request.message?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tool = obj["tool"] as? String {
            return (tool, obj["summary"] as? String ?? "")
        }
        return (request.title ?? "action", request.message ?? "")
    }

    enum StartError: Error { case notReady(String) }

    private static func message(for error: Error) -> String {
        switch error {
        case StartError.notReady(let reason): return reason
        case PiProcessError.executableNotFound:
            return "The agent runtime isn't installed. Enable Agent Mode to download it."
        case PiRPCError.transportClosed:
            return "The agent process exited unexpectedly."
        default:
            return error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass (including the untouched RPC suite)**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentSessionControllerTests -only-testing:LokalBotTests/PiRPCClientTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 12 tests passed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentSessionController.swift LokalBotTests/AgentSessionControllerTests.swift LokalBotTests/Helpers/FakeTransport.swift LokalBotTests/PiRPCClientTests.swift LokalBot.xcodeproj
git commit -m "Add agent session controller wiring transcript, approvals, and pi RPC"
```

---

### Task 14: Integration test — real Bun + pi against a stub OpenAI server

**Files:**
- Create: `LokalBotTests/PiIntegrationTests.swift`
- Create: `LokalBotTests/Fixtures/stub-openai.ts`
- Modify: `project.yml` — add `LokalBotTests/Fixtures` as test-target resources (folder reference), same syntax as Task 12 Step 2 but under the test target's sources

**Interfaces:**
- Consumes: everything — this is the one test that runs the real chain `PiProcess → bun → pi → lokalbot-extension → HTTP → stub`.
- Produces: confidence. No production types.

The stub is an OpenAI-compatible `/v1/chat/completions` endpoint (Bun.serve) that always streams a fixed completion. The test **skips** (XCTSkip) when the vendored runtime from Task 5 isn't installed — CI-less local repo, same posture as UI tests.

- [ ] **Step 1: Write the stub server**

`LokalBotTests/Fixtures/stub-openai.ts`:

```typescript
// Minimal OpenAI-compatible stub for integration tests. Streams one fixed
// assistant message for any /v1/chat/completions request. Prints the
// chosen port on stdout as its first line.
const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/v1/models") {
      return Response.json({ object: "list", data: [{ id: "stub-model", object: "model" }] });
    }
    if (url.pathname !== "/v1/chat/completions") {
      return new Response("not found", { status: 404 });
    }
    const encoder = new TextEncoder();
    const chunk = (payload: unknown) => encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
    const body = new ReadableStream({
      start(controller) {
        const base = { id: "stub", object: "chat.completion.chunk", model: "stub-model" };
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: { role: "assistant" } }] }));
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: { content: "STUB-REPLY" } }] }));
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }));
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      },
    });
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
  },
});
console.log(String(server.port));
```

- [ ] **Step 2: Write the integration test**

```swift
import XCTest
@testable import LokalBot

/// End-to-end: real Bun, real pi 0.80.5, our real extension, talking to a
/// stub OpenAI server. Skips when the vendored runtime isn't installed
/// (run `Scripts/build-pi-bundle.sh --install-local` once to enable).
final class PiIntegrationTests: XCTestCase {

    private var stub: Process?
    private var stubPort: Int = 0

    override func tearDown() async throws {
        stub?.terminate()
        stub = nil
    }

    private func requireRuntime() throws -> URL {
        let root = AgentRuntimeLayout.defaultRoot
        guard AgentRuntimeLayout.isInstalled(under: root) else {
            throw XCTSkip("agent runtime not installed; run Scripts/build-pi-bundle.sh --install-local")
        }
        return root
    }

    private func startStub(bun: URL) throws {
        guard let script = Bundle(for: Self.self).url(forResource: "stub-openai",
                                                      withExtension: "ts",
                                                      subdirectory: "Fixtures") else {
            return XCTFail("stub-openai.ts missing from test bundle")
        }
        let process = Process()
        process.executableURL = bun
        process.arguments = [script.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        stub = process
        guard let first = out.fileHandleForReading.availableLine(timeout: 10),
              let port = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("stub didn't print its port")
        }
        stubPort = port
    }

    func testPromptRoundTripsThroughRealPi() async throws {
        let root = try requireRuntime()
        let bun = AgentRuntimeLayout.bunBinary(under: root)
        try startStub(bun: bun)

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let repoRoot = URL(fileURLWithPath: #filePath)      // …/LokalBotTests/PiIntegrationTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
        let endpoint = AgentLLMEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(stubPort)/v1")!,
            model: "stub-model", contextTokens: 16_384, apiKey: nil)
        let plan = PiLaunchPlanner.plan(
            bun: bun,
            piCLI: AgentRuntimeLayout.piCLI(under: root),
            extensionDirectory: repoRoot.appendingPathComponent("LokalBot/Resources/pi/lokalbot-extension"),
            skillDirectory: nil,
            sessionDirectory: workspace.appendingPathComponent("sessions"),
            workspace: workspace,
            endpoint: endpoint,
            helpersDirectory: nil)

        let process = PiProcess(plan: plan)
        try await process.start()
        defer { Task { await process.stop() } }
        let client = PiRPCClient(transport: process)
        await client.run()

        // No mutable capture: the collector Task RETURNS the verdict.
        // If the reply never arrives, the deadline task cancels the collector,
        // the for-await loop ends, and `collector.value` resolves to false.
        let events = await client.events
        let collector = Task { () -> Bool in
            for await event in events {
                if case .messageEnd(let role, let text) = event,
                   role == "assistant", text.contains("STUB-REPLY") {
                    return true
                }
            }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            collector.cancel()
        }

        let response = try await client.request(
            .prompt(id: "it1", message: "say hi", streamingBehavior: nil))
        XCTAssertTrue(response.success, response.error ?? "")

        let sawStubReply = await collector.value
        deadline.cancel()
        XCTAssertTrue(sawStubReply, "assistant message with stub content never arrived")
        await process.stop()
    }
}

// MARK: - Small helpers

private extension FileHandle {
    /// Blocking single-line read with a deadline; fine for test setup.
    func availableLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let data = availableData
            if data.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
            buffer.append(data)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<newline], encoding: .utf8)
            }
        }
        return nil
    }
}
```

- [ ] **Step 3: Wire fixtures into project.yml and regenerate**

In `project.yml` under the `LokalBotTests` target's sources, add:

```yaml
        - path: LokalBotTests/Fixtures
          type: folder
          buildPhase: resources
```

Then `xcodegen generate`.

- [ ] **Step 4: Run the test**

If the vendored runtime is installed (Task 5 Step 4 did this):

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/PiIntegrationTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 1 test passed (or skipped with the install hint if the runtime is absent — both are acceptable outcomes for this step; passed is required before Task 15 ships).

If pi's stdout shows the prompt failing: run the Task 12 Step 3 smoke command first to isolate extension-load problems from RPC problems.

- [ ] **Step 5: Commit**

```bash
git add LokalBotTests/PiIntegrationTests.swift LokalBotTests/Fixtures/stub-openai.ts project.yml LokalBot.xcodeproj
git commit -m "Add end-to-end pi integration test against stub OpenAI server"
```

---
### Task 15: AgentView — the Agent Mode pane

**Files:**
- Create: `LokalBot/Views/AgentView.swift`
- Test: build-level (SwiftUI); the folding/approval logic it renders is already covered by Tasks 4 and 13

**Interfaces:**
- Consumes: `AgentSessionController` (Task 13), `AgentRuntimeInstaller` (Task 7), `AgentTranscriptItem`/`AgentToolStatus` (Task 4), `ApprovalScope` (Task 3), `AgentRuntimeLayout.isInstalled` (Task 6).
- Produces (used by Task 16): `struct AgentView: View { init(controller: AgentSessionController, installer: AgentRuntimeInstaller) }`.

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import UniformTypeIdentifiers

/// The Agent Mode pane: install card when the runtime is missing, otherwise
/// header (workspace + session controls) / transcript / composer. All agent
/// state lives in AgentSessionController; this file is rendering only.
struct AgentView: View {
    @ObservedObject var controller: AgentSessionController
    @ObservedObject var installer: AgentRuntimeInstaller
    @State private var draft = ""
    @State private var pickingFolder = false

    var body: some View {
        Group {
            if installer.phase == .installed {
                sessionBody
            } else {
                installCard
            }
        }
        .navigationTitle("Agent")
    }

    // MARK: - Install card

    private var installCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Agent Mode").font(.title2.bold())
            Text("An on-device coding and file agent (pi) powered by your Main LLM engine. It runs entirely on this Mac — the one-time ~50 MB runtime download below is the only network access it ever gets.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            switch installer.phase {
            case .idle:
                Button("Download & Enable Agent Mode") {
                    Task { await installer.installIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent.install")
            case .downloading(let name, let progress):
                ProgressView(value: progress >= 0 ? progress : nil)
                    .frame(maxWidth: 320)
                Text("Downloading \(name)…").font(.caption).foregroundStyle(.secondary)
            case .installing(let name):
                ProgressView().controlSize(.small)
                Text("Installing \(name)…").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: 420)
                Button("Try Again") { Task { await installer.installIfNeeded() } }
            case .installed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session

    private var sessionBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .task { await controller.start() }
        // No .onDisappear shutdown: the controller lives on AppState, so the
        // session (and any running work) survives switching sidebar tabs.
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                pickingFolder = true
            } label: {
                Label(controller.workspace.lastPathComponent.isEmpty
                      ? controller.workspace.path : controller.workspace.lastPathComponent,
                      systemImage: "folder")
            }
            .help(controller.workspace.path)
            .fileImporter(isPresented: $pickingFolder,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    controller.workspace = url
                    Task { await controller.shutdown(); await controller.start() }
                }
            }
            .accessibilityIdentifier("agent.workspace")

            statusBadge
            Spacer()
            Toggle("Auto-approve", isOn: $controller.autoApproveSession)
                .toggleStyle(.switch).controlSize(.small)
                .help("Approve every file edit and shell command this session without asking")
                .accessibilityIdentifier("agent.autoApprove")
            Button("New Session") { Task { await controller.newSession() } }
                .disabled(controller.state == .starting)
                .accessibilityIdentifier("agent.newSession")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var statusBadge: some View {
        switch controller.state {
        case .idle, .starting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Starting…") }
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .running:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Working…") }
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(1).help(message)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.items) { item in
                        row(for: item).id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: controller.items.count) {
                if let last = controller.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("agent.transcript")
    }

    @ViewBuilder private func row(for item: AgentTranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .padding(10)
                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text, let isStreaming):
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(text))   // renders markdown
                    .textSelection(.enabled)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let name, let argsJSON, let output, let status):
            toolCard(name: name, argsJSON: argsJSON, output: output, status: status)
        case .approval(let id, let tool, let argsJSON):
            approvalCard(id: id, tool: tool, argsJSON: argsJSON)
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
        }
    }

    private func toolCard(name: String, argsJSON: String, output: String, status: AgentToolStatus) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !argsJSON.isEmpty {
                    Text(argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(12)
                }
                if !output.isEmpty {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                Text(name).font(.callout.weight(.medium).monospaced())
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func approvalCard(id: String, tool: String, argsJSON: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The agent wants to run \(tool)", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            if !argsJSON.isEmpty {
                Text(argsJSON).font(.caption.monospaced())
                    .lineLimit(8).textSelection(.enabled)
            }
            HStack {
                Button("Allow Once") {
                    Task { await controller.respondToApproval(id: id, approved: true, scope: .once) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent.approve.once")
                Button("Allow \(tool) This Session") {
                    Task { await controller.respondToApproval(id: id, approved: true, scope: .session) }
                }
                Button("Deny", role: .destructive) {
                    Task { await controller.respondToApproval(id: id, approved: false, scope: .once) }
                }
                .accessibilityIdentifier("agent.approve.deny")
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit(submit)
                .accessibilityIdentifier("agent.composer")
            if controller.state == .running {
                Button("Stop") { Task { await controller.abort() } }
                    .accessibilityIdentifier("agent.stop")
            }
            Button("Send", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !(controller.state == .ready || controller.state == .running))
                .accessibilityIdentifier("agent.send")
        }
        .padding(12)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await controller.send(prompt: text) }
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot Dev" -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (The view isn't reachable yet — Task 16 wires it in.)

- [ ] **Step 3: Commit**

```bash
git add LokalBot/Views/AgentView.swift LokalBot.xcodeproj
git commit -m "Add Agent Mode pane UI"
```

---

### Task 16: Navigation wiring — sidebar entry + AppState

**Files:**
- Modify: `LokalBot/LokalBotApp.swift` (`AppState.NavSection`, ~line 116; `AppState` members, ~line 260)
- Modify: `LokalBot/Views/MainWindowView.swift` (sidebar `Section("Automation")` ~line 130; detail switch ~line 95-120)
- Test: `LokalBotTests/NavSectionTests.swift` (extend if it exists; create otherwise)

**Interfaces:**
- Consumes: `AgentView` (Task 15), `AgentSessionController` (Task 13), `AgentRuntimeInstaller` (Task 7).
- Produces: `AppState.NavSection.agent`; `AppState.agentController: AgentSessionController` (lazy); `AppState.agentInstaller: AgentRuntimeInstaller`.

- [ ] **Step 1: Write the failing test**

Create (or extend) `LokalBotTests/NavSectionTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class NavSectionAgentTests: XCTestCase {
    func testAgentSectionRoundTripsCaptureName() {
        XCTAssertEqual(AppState.NavSection(captureName: "agent"), .agent)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/NavSectionAgentTests 2>&1 | tail -5`
Expected: FAILS — "type 'AppState.NavSection' has no member 'agent'".

- [ ] **Step 3: Implement the wiring**

In `LokalBotApp.swift`, add the case to `NavSection` (keep the existing order, add after `.ask`):

```swift
enum NavSection: Hashable {
    case timeline, meetings, type, ask, agent, settings
```

and extend its `init?(captureName:)` with:

```swift
case "agent": self = .agent
```

In `AppState` (near `let storage = StorageManager()`), add:

```swift
    // Agent Mode (pi). Installer is cheap; the controller spawns nothing
    // until AgentView calls start().
    let agentInstaller = AgentRuntimeInstaller()
    private(set) lazy var agentController = AgentSessionController(
        settings: { [store = settingsStore] in store.current },
        storage: storage)
```

(If `AppState` exposes settings differently — check how `runChat` in `HeadlessCommands.swift` builds its `settings:` closure and copy that exact pattern.)

In `MainWindowView.swift`, add the sidebar row inside `Section("Automation")` after the Type row, matching the existing Label/tag/identifier pattern exactly:

```swift
Label("Agent", systemImage: "wand.and.sparkles")
    .tag(AppState.NavSection.agent)
    .accessibilityIdentifier("sidebar.agent")
```

and in the per-section detail switch, add alongside the other cases:

```swift
case .agent:
    AgentView(controller: app.agentController, installer: app.agentInstaller)
```

- [ ] **Step 4: Run the test and build**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/NavSectionAgentTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

Then launch the dev app and eyeball it: `xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot Dev" -destination 'platform=macOS' build 2>&1 | tail -3` — sidebar shows "Agent" under Automation; clicking it shows the install card (runtime not installed) or the session pane.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/LokalBotApp.swift LokalBot/Views/MainWindowView.swift LokalBotTests/NavSectionTests.swift LokalBot.xcodeproj
git commit -m "Wire Agent Mode into sidebar navigation"
```

---

### Task 17: Rebrand "Summarization" → "Main LLM engine"

**Files:**
- Modify: `LokalBot/Views/ModelsView.swift:133-135` (the `summarizationCard` ModelCard header)
- Test: none new — display-only copy change; existing UI tests keep passing because the `models.summarization` accessibility identifier and all stored settings keys (`summarizerBackend` etc.) are unchanged (Global Constraint)

- [ ] **Step 1: Change the card copy**

In `ModelsView.swift`, change exactly this (line 134-135):

```swift
        ModelCard(icon: "doc.text", title: "Summarization",
                  subtitle: "Meeting summaries, day digests, chat Q&A") {
```

to:

```swift
        ModelCard(icon: "brain", title: "Main LLM engine",
                  subtitle: "Used for questions, meeting summaries, and Agent Mode") {
```

Everything else in the card — the picker, backends, `accessibilityIdentifier("models.summarization")`, and the `summarizationCard` property name — stays. Renaming code symbols or stored keys is explicitly out of scope; only user-visible copy changes.

- [ ] **Step 2: Sweep for other user-visible "Summarization" card references**

Run: `grep -rn "Summarization" LokalBot/Views/ LokalBot/Engines/ --include="*.swift" | grep -v accessibilityIdentifier | grep -v summarizationCard | grep -v recommendedSummarization`

For each hit that is a **user-facing string** describing the engine as a whole (not a specific summarization feature like "RECOMMENDED SUMMARY" model badges, which stay): update the copy to "Main LLM engine". Expected hits: possibly a settings-pane section title or an error string in `TextEngineError`/`ModelsView`. Strings about the act of summarizing a meeting stay as they are.

- [ ] **Step 3: Build + run existing model-settings tests**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` — the full unit suite still passes (settings keys untouched).

- [ ] **Step 4: Commit**

```bash
git add LokalBot/Views/ModelsView.swift
git commit -m "Rebrand Summarization card as Main LLM engine"
```

(Include any other files Step 2 touched.)

---

### Task 18: Headless `--agent` flag, e2e wiring, docs

**Files:**
- Modify: `LokalBot/HeadlessCommands.swift` (enum ~line 13-19, `parse` ~line 24-40, `run` ~line 53-62, new `runAgent` next to `runChat` ~line 158)
- Modify: `Scripts/test/e2e.sh` (add an agent step that skips when the runtime is missing)
- Modify: `CLAUDE.md` (architecture + headless flags list)
- Modify: `RELEASING.md` (agent-runtime release asset step)
- Test: manual headless invocation (the app binary is the harness, same as `--chat`)

**Interfaces:**
- Consumes: `AgentSessionController` (Task 13), `AgentRuntimeLayout.isInstalled` (Task 6).
- Produces: `LokalBot --agent "<prompt>"` → runs one agent turn in the storage-root workspace with auto-approve on, prints transcript items, exit 0 ok / 3 skip (runtime not installed) / 1 fail.

- [ ] **Step 1: Add the command**

In `HeadlessCommands.swift`, add the case:

```swift
    case agent(prompt: String)
```

in `parse`, after the `--chat` clause:

```swift
        if let flag = args.firstIndex(of: "--agent"), args.count > flag + 1 {
            return .agent(prompt: args[flag + 1])
        }
```

in `run`:

```swift
        case .agent(let prompt): runAgent(prompt: prompt)
```

and the runner, next to `runChat`, following its structure:

```swift
    /// `LokalBot --agent "<prompt>"`: one Agent Mode turn against the real
    /// runtime + Main LLM engine, auto-approved, printing each transcript
    /// item. Exit 0 ok / 3 skip (runtime not installed) / 1 fail. Test hook
    /// for Agent Mode, same spirit as --chat.
    private func runAgent(prompt: String) {
        Task { @MainActor in
            guard AgentRuntimeLayout.isInstalled() else {
                print("LokalBot --agent: SKIP (agent runtime not installed; run Scripts/build-pi-bundle.sh --install-local)")
                exit(3)
            }
            let controller = app.agentController
            controller.autoApproveSession = true
            await controller.start()
            if case .failed(let reason) = controller.state {
                print("LokalBot --agent: FAILED to start — \(reason)")
                exit(1)
            }
            await controller.send(prompt: prompt)
            // send() returns after the prompt is accepted; work streams in as
            // events. Immediately after send() the state may still read .ready
            // (agent_start hasn't arrived yet), so first wait for .running,
            // THEN wait for it to leave .running. Otherwise the settle loop
            // exits before any work happened.
            for _ in 0..<100 where controller.state != .running {   // 10s to start
                try? await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<600 where controller.state == .running {   // 60s to settle
                try? await Task.sleep(for: .milliseconds(100))
            }
            for item in controller.items {
                switch item {
                case .user(_, let text): print("LokalBot --agent: > \(text)")
                case .assistant(_, let text, _): print("LokalBot --agent: \(text)")
                case .tool(_, let name, _, _, let status): print("LokalBot --agent: tool \(name) [\(status)]")
                case .approval: break   // auto-approve means none surface
                case .notice(_, let text, let isError): print("LokalBot --agent: \(isError ? "ERROR" : "note") \(text)")
                }
            }
            let ok = controller.state == .ready && controller.items.contains {
                if case .assistant = $0 { return true } else { return false }
            }
            await controller.shutdown()
            await LlamaServer.shared.stop()
            print("LokalBot --agent: \(ok ? "done" : "FAILED — no assistant reply")")
            exit(ok ? 0 : 1)
        }
    }
```

Note: `AgentRuntimeLayout.isInstalled()` uses the default-root overload from Task 6. If Task 6 shipped it as `isInstalled(under:)` with a default argument, this call compiles as-is.

- [ ] **Step 2: Wire into e2e.sh**

`Scripts/test/e2e.sh` has no `step` helper — each test is an inline block that runs `$BIN` with a flag, captures output and exit code, and calls `pass`/`fail`/`skip` (exit 3 = skip, matching the permission-gated steps). After the `--chat` block, add:

```bash
echo "== T10: agent mode (pi RPC, auto-approved) =="
AG=$("$BIN" --agent "Reply with the single word pong." 2>/dev/null); RC=$?
if [ "$RC" -eq 3 ]; then
  skip "agent runtime not installed"
elif [[ "$AG" == *"--agent: done"* ]]; then
  pass "agent replied"
else
  fail "agent: $(echo "$AG" | tail -1)"
fi
```

(Read the two adjacent blocks first and match their numbering — if the chat step is T9, this is T10; renumber if the file has drifted.)

- [ ] **Step 3: Verify headless run**

```bash
xcodegen generate
Scripts/build/install-app.sh
"/Applications/LokalBot.app/Contents/MacOS/LokalBot" --agent "Reply with the single word pong."
```

Expected: either `LokalBot --agent: SKIP (agent runtime not installed…)` (exit 3) or a transcript ending in `LokalBot --agent: done` (exit 0). With the Task 5 runtime installed and a downloaded built-in model, expect the full path.

- [ ] **Step 4: Update docs**

`CLAUDE.md`:
- In the headless-flags sentence (`--process <meeting-folder>`, `--search`, …), add `--agent "<prompt>"`.
- In the Architecture section, append one sentence after the Cotyping paragraph:

```markdown
**Agent Mode** (`LokalBot/Agent/`) embeds the pi coding agent as a `--mode rpc` subprocess under a vendored Bun runtime (downloaded on first enable, never bundled), preconnected to the Main LLM engine via an OpenAI-compatible provider extension; `write`/`edit`/`bash` tool calls are gated behind native approval cards. pi runs with `--offline` + `PI_SKIP_VERSION_CHECK=1` — the nothing-leaves-the-Mac invariant applies to it fully.
```

`RELEASING.md`: add a step to the release checklist:

```markdown
- Agent runtime asset: if `Scripts/build-pi-bundle.sh` changed (pi or Bun version bump), run it and upload `dist/lokalbot-pi-bundle-<version>.tar.gz` to the `agent-runtime-<version>` GitHub release tag, then update the sha256 in `AgentRuntimeManifest.current`.
```

- [ ] **Step 5: Full unit suite + commit**

Run: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

```bash
git add LokalBot/HeadlessCommands.swift Scripts/test/e2e.sh CLAUDE.md RELEASING.md LokalBot.xcodeproj
git commit -m "Add --agent headless flag, e2e step, and Agent Mode docs"
```

---

## Verification (whole feature)

1. `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test` — full unit suite green.
2. `Scripts/build-pi-bundle.sh --install-local` then re-run `LokalBotTests/PiIntegrationTests` — real pi round-trip green.
3. Manual: LokalBot Dev → sidebar Agent → install card → (with runtime) session pane → prompt "list the files in this folder" → watch tool card + approval card → Allow Once → assistant reply.
4. `Scripts/build/install-app.sh && Scripts/test/e2e.sh` — agent step passes or skips cleanly.
5. Privacy check: `lsof -i -a -p <pi pid>` while the agent works — only connections are to 127.0.0.1 (llama-server or configured local endpoint).
