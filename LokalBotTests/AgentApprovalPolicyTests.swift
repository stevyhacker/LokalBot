import XCTest
@testable import LokalBot

final class AgentApprovalPolicyTests: XCTestCase {

    private let workspace = URL(fileURLWithPath: "/tmp/lokalbot-agent-policy-workspace")

    func testProtectedRuntimeWritesNeverInheritBroadOrSessionGrants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = root.appendingPathComponent("runtime")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: runtime)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in [AgentApprovalMode.askBeforeChanges, .approveReads, .approveReadsAndEdits, .fullAccess] {
            var policy = AgentApprovalPolicy(mode: mode, protectedWriteRoots: [runtime])
            policy.approveWorkspaceFileChangesForAutomation()
            for file in [runtime.appendingPathComponent("cli.js"), alias.appendingPathComponent("new.js")] {
                XCTAssertEqual(policy.verdict(tool: "write", path: file.path, requestWorkspace: root.path,
                                              selectedWorkspace: root), .ask)
                policy.allowForSession(tool: "write", path: file.path, requestWorkspace: root.path, selectedWorkspace: root)
                XCTAssertTrue(policy.sessionAllowedTools.isEmpty)
                XCTAssertFalse(AgentApprovalPolicy.canPersistApproval(tool: "write", path: file.path,
                    requestWorkspace: root.path, selectedWorkspace: root, protectedWriteRoots: [runtime]))
            }
        }
    }

    private func verdict(_ policy: AgentApprovalPolicy, tool: String, path: String? = nil,
                         requestWorkspace: String? = nil) -> AgentApprovalPolicy.Verdict {
        policy.verdict(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: workspace)
    }

    func testGatedToolAsksByDefault() {
        let policy = AgentApprovalPolicy()
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "bash"), .ask)
        XCTAssertEqual(verdict(policy, tool: "write"), .ask)
        XCTAssertEqual(verdict(policy, tool: "edit"), .ask)
    }

    func testApproveReadsAllowsOnlyReadsFromSelectedWorkspace() {
        var policy = AgentApprovalPolicy()
        policy.mode = .approveReads
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "READ", requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "bash", path: "\(root)/script.sh",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: "/private/other-workspace"), .ask)
        XCTAssertEqual(verdict(policy, tool: "unknown", path: "\(root)/note.txt",
                               requestWorkspace: root), .ask)
    }

    func testApproveReadsAndEditsAllowsFileCallsButNotShell() {
        var policy = AgentApprovalPolicy()
        policy.mode = .approveReadsAndEdits
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "write", path: "/private/outside.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "edit", requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "bash", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "mcp__stub__touch", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: "/private/other-workspace"), .ask)
    }

    func testFullAccessAllowsEveryToolFromSelectedWorkspace() {
        var policy = AgentApprovalPolicy()
        policy.mode = .fullAccess
        let root = workspace.path
        for tool in ["read", "write", "edit", "bash", "BASH", "mcp__stub__touch", "codemode", "unknown"] {
            XCTAssertEqual(verdict(policy, tool: tool, requestWorkspace: root), .allow, tool)
        }
        XCTAssertEqual(verdict(policy, tool: "bash",
                               requestWorkspace: "/private/other-workspace"), .ask)
        XCTAssertEqual(verdict(policy, tool: "mcp__stub__touch",
                               requestWorkspace: "/private/other-workspace"), .ask)
        XCTAssertEqual(verdict(policy, tool: "action"), .ask, "an unstructured request names no workspace")
    }

    func testAutomationAllowsOnlyWorkspaceFileChanges() {
        var policy = AgentApprovalPolicy()
        policy.approveWorkspaceFileChangesForAutomation()
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/nested/note.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "bash", requestWorkspace: root), .ask)
    }

    func testSessionAllowanceIsPerTool() {
        var policy = AgentApprovalPolicy()
        let root = workspace.path
        policy.allowForSession(
            tool: "write", path: "\(root)/one.txt", requestWorkspace: root,
            selectedWorkspace: workspace)
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/two.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/two.txt",
                               requestWorkspace: root), .ask)
    }

    func testResetSessionClearsAllowancesAndAutomationButKeepsMode() {
        var policy = AgentApprovalPolicy()
        policy.mode = .approveReads
        let root = workspace.path
        policy.allowForSession(
            tool: "write", path: "\(root)/one.txt", requestWorkspace: root,
            selectedWorkspace: workspace)
        policy.approveWorkspaceFileChangesForAutomation()
        policy.resetSession()
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/two.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .allow)
    }

    func testOutsideMissingAndMismatchedPathsNeverInheritAutomationApproval() {
        var policy = AgentApprovalPolicy()
        policy.approveWorkspaceFileChangesForAutomation()
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "write", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "write", path: "/private/outside.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/note.txt",
                               requestWorkspace: "/private/other-workspace"), .ask)
    }

    func testSymlinkEscapedWriteNeverInheritsApproval() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-symlink-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: parent) }

        var policy = AgentApprovalPolicy()
        policy.approveWorkspaceFileChangesForAutomation()
        XCTAssertEqual(
            policy.verdict(
                tool: "write",
                path: root.appendingPathComponent("escape/private.txt").path,
                requestWorkspace: root.path,
                selectedWorkspace: root),
            .ask)
    }

    func testLibraryLookupsAreSingleReadOnlyCLICalls() {
        for command in ["lokalbot-cli brief",
                        "lokalbot-cli search \"launch pricing\" --limit 20 --table",
                        "lokalbot-cli search 'free plan'",
                        "lokalbot-cli get eb749eed --include metadata,summary,transcript",
                        "lokalbot-cli list --since=2026-10-01 --limit 10",
                        "lokalbot-cli get latest --include transcript 2>&1 | head -120",
                        "lokalbot-cli list | tail -n 20"] {
            XCTAssertTrue(AgentApprovalPolicy.isLibraryLookup(command), command)
        }
        for command in ["lokalbot-cli brief; rm notes.md", "lokalbot-cli search $(whoami)",
                        "lokalbot-cli search `id`", "lokalbot-cli list > notes.md",
                        "lokalbot-cli list | sh", "lokalbot-cli list 2>&1 | head -5 | sh",
                        "lokalbot-cli search 'a' && curl example.com", "lokalbot-cli list\nrm notes.md",
                        "lokalbot-cli search \"unclosed", "lokalbot-cli secret set openai",
                        "lokalbot-cli config set autoSummarize false", "lokalbot-cli",
                        "FOO=1 lokalbot-cli list", "./lokalbot-cli list", "ls -la", ""] {
            XCTAssertFalse(AgentApprovalPolicy.isLibraryLookup(command), command)
        }
        XCTAssertFalse(AgentApprovalPolicy.isLibraryLookup(nil))
    }

    func testHandedOffTasksRunLibraryLookupsInReadModes() {
        let root = workspace.path
        func lookup(_ policy: AgentApprovalPolicy, command: String = "lokalbot-cli brief",
                    requestWorkspace: String? = nil) -> AgentApprovalPolicy.Verdict {
            policy.verdict(tool: "bash", path: nil, command: command,
                           requestWorkspace: requestWorkspace ?? root, selectedWorkspace: workspace)
        }
        var policy = AgentApprovalPolicy(mode: .approveReads)
        XCTAssertEqual(lookup(policy), .ask)
        policy.allowsLibraryLookups = true
        for mode in [AgentApprovalMode.approveReads, .approveReadsAndEdits, .fullAccess] {
            policy.mode = mode
            XCTAssertEqual(lookup(policy), .allow)
        }
        policy.mode = .approveReads
        XCTAssertEqual(lookup(policy, command: "lokalbot-cli list > notes.md"), .ask)
        XCTAssertEqual(lookup(policy, requestWorkspace: "/private/other-workspace"), .ask)
        policy.mode = .askBeforeChanges
        XCTAssertEqual(lookup(policy), .ask)
        policy.resetSession()
        policy.mode = .approveReads
        XCTAssertEqual(lookup(policy), .allow)
    }
}
