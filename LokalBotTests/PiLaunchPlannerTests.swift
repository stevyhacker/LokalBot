import XCTest
@testable import LokalBot

final class PiLaunchPlannerTests: XCTestCase {

    private let endpoint = AgentLLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:17872/v1")!,
        model: "qwen2.5-7b-instruct",
        contextTokens: 16_384,
        apiKey: nil)

    private func makePlan(apiKey: String? = nil,
                          inheritedAPIKey: String? = nil,
                          skill: URL? = URL(fileURLWithPath: "/app/Resources/pi/lokalbot-cli-skill"),
                          systemPrompt: URL? = URL(fileURLWithPath: "/app/Resources/pi/system-prompt.md"),
                          workspaceKind: AgentWorkspaceKind? = .agentWorkspace,
                          helpers: URL? = URL(fileURLWithPath: "/app/Contents/Helpers"),
                          capability: String? = nil,
                          continuePrevious: Bool = false,
                          specificSession: URL? = nil,
                          reasoningLevelFile: URL? = nil,
                          inheritedEnvironment: [String: String] = [:]) -> PiLaunchPlan {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"].merging(inheritedEnvironment) { $1 }
        environment["LOKALBOT_LLM_API_KEY"] = inheritedAPIKey
        return PiLaunchPlanner.plan(
            bun: URL(fileURLWithPath: "/rt/bun/bun"),
            piCLI: URL(fileURLWithPath: "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
            extensionDirectory: URL(fileURLWithPath: "/app/Resources/pi/lokalbot-extension"),
            skillDirectory: skill,
            systemPrompt: systemPrompt,
            sessionDirectory: URL(fileURLWithPath: "/store/agent/sessions"),
            workspace: URL(fileURLWithPath: "/work"),
            workspaceKind: workspaceKind,
            endpoint: AgentLLMEndpoint(baseURL: endpoint.baseURL, model: endpoint.model,
                                       contextTokens: endpoint.contextTokens, apiKey: apiKey,
                                       reasoningDialect: .llamaServer),
            reasoningLevelFile: reasoningLevelFile,
            helpersDirectory: helpers,
            privateRoots: [URL(fileURLWithPath: "/store"), URL(fileURLWithPath: "/app-support")],
            agentAccessCapability: capability,
            continuePreviousSession: continuePrevious,
            specificSession: specificSession,
            baseEnvironment: environment)
    }

    func testArgumentsMatchTheSpecContract() {
        XCTAssertEqual(makePlan().arguments, [
            "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", "qwen2.5-7b-instruct",
            "--no-extensions", "-e", "/app/Resources/pi/lokalbot-extension",
            "--no-skills", "--skill", "/app/Resources/pi/lokalbot-cli-skill",
            "--system-prompt", "/app/Resources/pi/system-prompt.md",
            "--no-prompt-templates",
            "--no-context-files",
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
        XCTAssertEqual(env["PI_TELEMETRY"], "0")
        XCTAssertEqual(env["PI_CODING_AGENT_DIR"], "/store/agent/pi-config")
        XCTAssertEqual(env["PATH"], "/app/Contents/Helpers:/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/x", "base environment is preserved")
    }

    func testCompiledCopiesOutsideTheVerifiedRuntimeAreDisabled() {
        // Scripts/tests/pi-runtime.test.ts checks that these leave no cache.
        let env = makePlan(inheritedEnvironment: [
            "BUN_RUNTIME_TRANSPILER_CACHE_PATH": "/Users/x/Library/Caches/bun",
            "JITI_FS_CACHE": "true",
        ]).environment
        XCTAssertEqual(env["BUN_RUNTIME_TRANSPILER_CACHE_PATH"], "0")
        XCTAssertEqual(env["NODE_DISABLE_COMPILE_CACHE"], "1")
        XCTAssertEqual(env["JITI_FS_CACHE"], "false")
    }

    func testEnvironmentNamesTheReasoningFieldsAndLevelFile() {
        let file = URL(fileURLWithPath: "/tmp/lokalbot-agent-reasoning-x.json")
        XCTAssertEqual(makePlan(reasoningLevelFile: file).environment["LOKALBOT_LLM_REASONING_FILE"], file.path)
        XCTAssertEqual(makePlan().environment["LOKALBOT_LLM_REASONING_DIALECT"], "llama-server")
        XCTAssertNil(makePlan().environment["LOKALBOT_LLM_REASONING_FILE"])
    }

    func testEnvironmentNamesTheWireAPIAndWhoServesAPlan() {
        let local = makePlan().environment
        XCTAssertEqual(local["LOKALBOT_LLM_API"], "openai-completions")
        XCTAssertNil(local["LOKALBOT_LLM_SERVED_BY"])
        var relay = endpoint
        relay.api = .responses
        relay.plan = .chatGPT
        let plan = PiLaunchPlanner.plan(
            bun: URL(fileURLWithPath: "/rt/bun/bun"),
            piCLI: URL(fileURLWithPath: "/rt/cli.js"),
            extensionDirectory: URL(fileURLWithPath: "/app/Resources/pi/lokalbot-extension"),
            skillDirectory: nil,
            sessionDirectory: URL(fileURLWithPath: "/store/agent/sessions"),
            workspace: URL(fileURLWithPath: "/work"),
            endpoint: relay,
            helpersDirectory: nil,
            baseEnvironment: ["LOKALBOT_LLM_SERVED_BY": "inherited"]).environment
        XCTAssertEqual(plan["LOKALBOT_LLM_API"], "openai-responses")
        XCTAssertEqual(plan["LOKALBOT_LLM_SERVED_BY"], "OpenAI on the user's ChatGPT plan")
        XCTAssertNil(makePlan(inheritedEnvironment: ["LOKALBOT_LLM_SERVED_BY": "inherited"])
            .environment["LOKALBOT_LLM_SERVED_BY"], "a local server must not inherit a plan's label")
    }

    func testAPIKeyIsPassedWhenPresent() {
        XCTAssertEqual(makePlan(apiKey: "sk-test").environment["LOKALBOT_LLM_API_KEY"], "sk-test")
    }

    func testCredentialFreeEndpointCannotInheritAnotherServiceKey() {
        XCTAssertNil(makePlan(inheritedAPIKey: "unrelated-fixture-key").environment["LOKALBOT_LLM_API_KEY"])
        XCTAssertEqual(makePlan(apiKey: "selected-fixture-key", inheritedAPIKey: "unrelated-fixture-key")
            .environment["LOKALBOT_LLM_API_KEY"], "selected-fixture-key")
    }

    func testPrivateRootsArePassedSeparatelyFromTheWorkingFolder() throws {
        let plan = makePlan()
        let json = try XCTUnwrap(plan.environment["LOKALBOT_AGENT_PRIVATE_ROOTS"])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(json.utf8)), ["/store", "/app-support"])
        XCTAssertEqual(plan.workingDirectory.path, "/work")
    }

    func testMissingSystemPromptKeepsPiFromTakingThePathAsPromptText() {
        XCTAssertFalse(makePlan(systemPrompt: nil).arguments.contains("--system-prompt"))
    }

    func testEnvironmentNamesTheWorkingFolderKind() {
        XCTAssertEqual(makePlan().environment["LOKALBOT_AGENT_WORKSPACE_KIND"], "agent-workspace")
        XCTAssertEqual(makePlan(workspaceKind: .chosenFolder).environment["LOKALBOT_AGENT_WORKSPACE_KIND"],
                       "chosen-folder")
        XCTAssertNil(makePlan(workspaceKind: nil,
                              inheritedEnvironment: ["LOKALBOT_AGENT_WORKSPACE_KIND": "agent-workspace"])
            .environment["LOKALBOT_AGENT_WORKSPACE_KIND"])
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

    func testAutomaticContextDiscoveryIsDisabledToPreventParentDirectoryReads() {
        XCTAssertTrue(makePlan().arguments.contains("--no-context-files"))
    }

    func testScopedAgentCapabilityIsPassedOnlyWhenIssued() {
        XCTAssertNil(makePlan().environment[AgentAccessGate.capabilityEnvironmentKey])
        XCTAssertEqual(
            makePlan(capability: "id.secret").environment[AgentAccessGate.capabilityEnvironmentKey],
            "id.secret")
    }

    func testContinueFlagOnlyAppearsForResumeLaunches() {
        XCTAssertFalse(makePlan().arguments.contains("--continue"))
        XCTAssertTrue(makePlan(continuePrevious: true).arguments.contains("--continue"))
    }

    func testSpecificSessionTakesPrecedenceOverContinue() throws {
        let session = URL(fileURLWithPath: "/store/agent/sessions/saved.jsonl")
        let arguments = makePlan(continuePrevious: true, specificSession: session).arguments

        XCTAssertFalse(arguments.contains("--continue"))
        let sessionIndex = try XCTUnwrap(arguments.firstIndex(of: "--session"))
        XCTAssertEqual(arguments[sessionIndex + 1], session.path)
    }
}
