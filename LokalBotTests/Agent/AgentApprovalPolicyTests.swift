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
                        "lokalbot-cli get latest --format json",
                        "lokalbot-cli list --since=2026-10-01 --limit 10",
                        "lokalbot-cli list --since 2026-06-01 --until 2026-06-30 --query \"design\"",
                        "lokalbot-cli list --include summary --table",
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

    /// Only the options the four lookups take pass. An output flag, or any
    /// option a later release might add, asks.
    func testLibraryLookupsTakeOnlyTheirKnownOptions() {
        for command in ["lokalbot-cli get latest --output notes.md", "lokalbot-cli list -o notes.md",
                        "lokalbot-cli search plan --out=notes.md", "lokalbot-cli brief --save",
                        "lokalbot-cli search --export plan", "lokalbot-cli get latest --limit 5",
                        "lokalbot-cli search plan --format json", "lokalbot-cli brief --table",
                        "lokalbot-cli list \"--output\" notes.md", "lokalbot-cli search -- plan",
                        "lokalbot-cli list --help"] {
            XCTAssertFalse(AgentApprovalPolicy.isLibraryLookup(command), command)
        }
    }

    /// Commands that read LokalBot but are not one of the four lookups, or
    /// that change it, are not lookups.
    func testOtherCLICommandsAreNotLookups() {
        for command in ["lokalbot-cli actions --owner me", "lokalbot-cli people \"Ana\"",
                        "lokalbot-cli personal-context --task plan", "lokalbot-cli search-files invoice",
                        "lokalbot-cli search-notes release", "lokalbot-cli path eb749eed",
                        "lokalbot-cli ask \"what changed\"", "lokalbot-cli open eb749eed",
                        "lokalbot-cli setup start", "lokalbot-cli mcp", "lokalbot-cli restart",
                        "lokalbot-cli models download whisper", "lokalbot-cli install-skill"] {
            XCTAssertFalse(AgentApprovalPolicy.isLibraryLookup(command), command)
        }
    }

    private func command(_ policy: AgentApprovalPolicy, _ command: String, tool: String = "bash",
                         requestWorkspace: String? = nil) -> AgentApprovalPolicy.Verdict {
        policy.verdict(tool: tool, path: nil, command: command,
                       requestWorkspace: requestWorkspace ?? workspace.path, selectedWorkspace: workspace)
    }

    private func localModelPolicy(_ mode: AgentApprovalMode = .askBeforeChanges) -> AgentApprovalPolicy {
        var policy = AgentApprovalPolicy(mode: mode)
        policy.modelRunsOnThisMac = true
        return policy
    }

    private let lookups = ["lokalbot-cli brief", "lokalbot-cli list --limit 10",
                           "lokalbot-cli get latest --include metadata,summary",
                           "lokalbot-cli search \"design review\" --limit 20",
                           "lokalbot-cli get eb749eed --include transcript 2>&1 | head -200"]

    /// The owner's decision: a read-only lookup of the user's own library
    /// runs without a request at the default level, and so at every level,
    /// when the task's model runs on this Mac.
    func testEachLibraryLookupRunsWithoutAskingAtTheDefaultLevelWithALocalModel() {
        let policy = localModelPolicy()
        XCTAssertEqual(policy.mode, .askBeforeChanges)
        for lookup in lookups {
            XCTAssertEqual(command(policy, lookup), .allow, lookup)
            for mode in AgentApprovalMode.allCases {
                XCTAssertEqual(command(localModelPolicy(mode), lookup), .allow, "\(mode) \(lookup)")
            }
        }
    }

    /// A lookup's output goes to the model. With a model on a server or a
    /// subscription plan, or one whose place is not known, the same lookups
    /// ask wherever they asked before lookups could skip approval.
    func testTheSameLookupsAskWhenTheModelIsNotOnThisMac() {
        XCTAssertFalse(AgentApprovalPolicy().modelRunsOnThisMac, "not known means not on this Mac")
        for lookup in lookups {
            for mode in [AgentApprovalMode.askBeforeChanges, .approveReads, .approveReadsAndEdits] {
                XCTAssertEqual(command(AgentApprovalPolicy(mode: mode), lookup), .ask, "\(mode) \(lookup)")
            }
            // Full access runs every command, as it did before.
            XCTAssertEqual(command(AgentApprovalPolicy(mode: .fullAccess), lookup), .allow, lookup)
        }
        // Learning that the model left this Mac takes the lookup back.
        var policy = localModelPolicy()
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow)
        policy.modelRunsOnThisMac = false
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .ask)
        policy.modelRunsOnThisMac = true
        policy.resetSession()
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow, "a session reset does not change where the model runs")
    }

    /// Unchanged from before: a task handed off from a meeting's actions runs
    /// lookups in the read levels wherever its model runs, and asks at the
    /// default level unless the model is on this Mac.
    func testHandedOffTasksRunLibraryLookupsInReadModes() {
        var policy = AgentApprovalPolicy(mode: .approveReads)
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .ask)
        policy.allowsLibraryLookups = true
        for mode in [AgentApprovalMode.approveReads, .approveReadsAndEdits, .fullAccess] {
            policy.mode = mode
            XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow)
        }
        policy.mode = .approveReads
        XCTAssertEqual(command(policy, "lokalbot-cli list > notes.md"), .ask)
        XCTAssertEqual(command(policy, "lokalbot-cli brief", requestWorkspace: "/private/other-workspace"), .ask)
        policy.mode = .askBeforeChanges
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .ask)
        policy.modelRunsOnThisMac = true
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow)
        policy.modelRunsOnThisMac = false
        policy.resetSession()
        policy.mode = .approveReads
        XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow, "the hand-off belongs to the task, not the session")
    }

    /// With a model on this Mac, everything that is not a proven lookup
    /// still asks at the default level.
    func testEverythingElseStillAsksAtTheDefaultLevel() {
        let policy = localModelPolicy()
        let root = workspace.path
        // A write, an edit, a read outside the folder, and another tool.
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.md", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/note.md", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "mcp_search", requestWorkspace: root), .ask)
        // An arbitrary command, and commands that only look like a lookup.
        for other in ["ls -la", "cat notes.md", "curl https://example.com", "rm -rf build",
                      "lokalbot-cli list | sh", "lokalbot-cli list | tee notes.md",
                      "lokalbot-cli list > notes.md", "lokalbot-cli list >> notes.md",
                      "lokalbot-cli list 2> errors.txt", "lokalbot-cli brief; rm notes.md",
                      "lokalbot-cli brief && curl example.com", "lokalbot-cli brief || true",
                      "lokalbot-cli search $(whoami)", "lokalbot-cli search `id`",
                      "(lokalbot-cli brief)", "lokalbot-cli brief &", "lokalbot-cli list < notes.md",
                      "lokalbot-cli get latest --output notes.md", "lokalbot-cli list -o notes.md",
                      "lokalbot-cli actions --owner me", "lokalbot-cli config set autoSummarize false",
                      "mkdir -p exports && lokalbot-cli list --table > exports/open-actions.md"] {
            XCTAssertEqual(command(policy, other), .ask, other)
            XCTAssertEqual(command(AgentApprovalPolicy(), other), .ask, "remote model: \(other)")
        }
        // The lookup rule is for the shell tool only, with its command present.
        XCTAssertEqual(command(policy, "lokalbot-cli brief", tool: "write"), .ask)
        XCTAssertEqual(policy.verdict(tool: "bash", path: nil, command: nil, requestWorkspace: root,
                                      selectedWorkspace: workspace), .ask)
    }

    /// A request from a folder other than the task's working folder is stale
    /// or malformed, and asks even when it is a lookup.
    func testLookupFromAnotherWorkingFolderStillAsks() {
        let policy = localModelPolicy()
        XCTAssertEqual(command(policy, "lokalbot-cli brief", requestWorkspace: "/private/other-workspace"), .ask)
        XCTAssertEqual(policy.verdict(tool: "bash", path: nil, command: "lokalbot-cli brief",
                                      requestWorkspace: nil, selectedWorkspace: workspace), .ask)
    }

    func testLookupsDoNotLoosenTheLevelsForOtherCommands() {
        for mode in [AgentApprovalMode.askBeforeChanges, .approveReads, .approveReadsAndEdits] {
            var policy = localModelPolicy(mode)
            XCTAssertEqual(command(policy, "lokalbot-cli list > notes.md"), .ask, "\(mode)")
            policy.resetSession()
            XCTAssertEqual(command(policy, "lokalbot-cli brief"), .allow, "\(mode)")
        }
        XCTAssertEqual(command(localModelPolicy(.fullAccess), "lokalbot-cli list > notes.md"), .allow)
    }
}
