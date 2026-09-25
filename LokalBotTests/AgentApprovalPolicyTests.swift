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
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: "/private/other-workspace"), .ask)
    }

    func testFullAccessAllowsKnownGatedToolsFromSelectedWorkspace() {
        var policy = AgentApprovalPolicy()
        policy.mode = .fullAccess
        let root = workspace.path
        for tool in ["read", "write", "edit", "bash", "BASH"] {
            XCTAssertEqual(verdict(policy, tool: tool, requestWorkspace: root), .allow, tool)
        }
        XCTAssertEqual(verdict(policy, tool: "unknown", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "bash",
                               requestWorkspace: "/private/other-workspace"), .ask)
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
}
