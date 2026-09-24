import Darwin
import Foundation
import XCTest
@testable import LokalBot

final class SystemResourceSamplerTests: XCTestCase {
    private typealias Usage = SystemResourceSampler.ProcessUsage
    private typealias Snapshot = SystemResourceSampler.UsageSnapshot

    func testCPUPercentageAggregatesAcrossProcessesAndCanExceedOneHundred() {
        let previous = Snapshot(capturedAt: 10, processes: [
            usage(pid: 1, start: 100, cpuSeconds: 1),
            usage(pid: 2, start: 200, cpuSeconds: 2),
        ])
        let current = Snapshot(capturedAt: 12, processes: [
            usage(pid: 1, start: 100, cpuSeconds: 3),
            usage(pid: 2, start: 200, cpuSeconds: 3),
        ])

        let percentage = SystemResourceSampler.cpuUsagePercent(from: previous, to: current)
        XCTAssertNotNil(percentage)
        XCTAssertEqual(percentage ?? 0, 150, accuracy: 0.001)
    }

    func testCPUPercentageIgnoresNewExitedAndPIDReusedProcesses() {
        let previous = Snapshot(capturedAt: 10, processes: [
            usage(pid: 1, start: 100, cpuSeconds: 2),
            usage(pid: 2, start: 200, cpuSeconds: 2),
        ])
        let current = Snapshot(capturedAt: 12, processes: [
            usage(pid: 1, start: 999, cpuSeconds: 50), // reused PID
            usage(pid: 3, start: 300, cpuSeconds: 20), // new helper
        ])

        XCTAssertNil(SystemResourceSampler.cpuUsagePercent(from: previous, to: current))
    }

    func testSnapshotSumsPhysicalFootprints() {
        let snapshot = Snapshot(capturedAt: 0, processes: [
            Usage(processIdentifier: 1, startTime: 1, cpuTimeNanoseconds: 0,
                  physicalFootprintBytes: 100),
            Usage(processIdentifier: 2, startTime: 2, cpuTimeNanoseconds: 0,
                  physicalFootprintBytes: 250),
        ])

        XCTAssertEqual(snapshot.totalPhysicalFootprintBytes, 350)
        XCTAssertEqual(snapshot.usage(for: 2)?.physicalFootprintBytes, 250)
    }

    func testLiveSnapshotIncludesTheCurrentProcess() {
        let snapshot = SystemResourceSampler.usageSnapshot()
        let currentProcess = snapshot.usage(for: getpid())

        XCTAssertNotNil(currentProcess)
        XCTAssertGreaterThan(currentProcess?.physicalFootprintBytes ?? 0, 0)
    }

    func testLiveSnapshotIncludesAChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let snapshot = SystemResourceSampler.usageSnapshot()
        XCTAssertNotNil(snapshot.usage(for: child.processIdentifier))
    }

    private func usage(pid: pid_t, start: UInt64, cpuSeconds: UInt64) -> Usage {
        Usage(
            processIdentifier: pid,
            startTime: start,
            cpuTimeNanoseconds: cpuSeconds * 1_000_000_000,
            physicalFootprintBytes: 0
        )
    }
}

final class MediaPlaybackProcessControllerTests: XCTestCase {
    func testCancellationKillsTermIgnoringHelperWithinBound() async throws {
        let process = Process()
        let readyPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo ready; exec /bin/sleep 30"]
        process.standardOutput = readyPipe
        process.standardError = FileHandle.nullDevice

        let controller = ScriptProcessController(terminationGraceSeconds: 0.05)
        XCTAssertTrue(controller.attach(process))
        try process.run()
        controller.processDidStart(process)
        defer {
            controller.detach(process)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let ready = readyPipe.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "ready\n")
        XCTAssertNotNil(
            SystemResourceSampler.processUsage(for: process.processIdentifier)?.startTime)

        controller.cancel()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(process.isRunning, "TERM-ignoring helper exceeded the hard bound")
        guard !process.isRunning else { return }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }
}

@MainActor
final class ResourceMonitorPresentationTests: XCTestCase {
    private typealias Usage = SystemResourceSampler.ProcessUsage
    private typealias Snapshot = SystemResourceSampler.UsageSnapshot

    private func resident(_ id: String, label: String) -> ModelResidency.Resident {
        ModelResidency.Resident(id: id, label: label, bytes: 1_073_741_824,
                                processIdentifier: nil, processStartTime: nil,
                                lastUsed: Date(timeIntervalSince1970: 1_000_000))
    }

    func testModelsMergeRolesAndMeasuredAndEstimatedMemory() {
        let gibibyte = UInt64(1_073_741_824)
        let residency = ModelResidency.Resident(
            id: "llama-server:17872",
            label: "main.gguf",
            bytes: Int64(2 * gibibyte),
            processIdentifier: 42,
            processStartTime: 100,
            lastUsed: Date()
        )
        let transcription = ModelRuntimeRegistry.Resident(
            id: "transcription:whisper",
            role: "Transcription",
            label: "Whisper",
            estimatedBytes: gibibyte,
            processIdentifier: nil,
            processStartTime: nil
        )
        let snapshot = SystemResourceSampler.UsageSnapshot(
            capturedAt: 1,
            processes: [
                .init(processIdentifier: 42, startTime: 100, cpuTimeNanoseconds: 0,
                      physicalFootprintBytes: 2 * gibibyte),
            ]
        )

        let models = ResourceMonitorPresentation.models(
            residency: [residency],
            runtimes: [transcription],
            snapshot: snapshot
        )

        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first { $0.id == residency.id }?.role, "Think")
        XCTAssertEqual(
            ResourceMonitorPresentation.modelMemorySummary(models: models, snapshot: snapshot),
            "≈3.0 GB"
        )
    }

    func testModelsDiscardAStaleReusedProcessIdentifier() {
        let resident = ModelResidency.Resident(
            id: "llama-server:17873",
            label: "embed.gguf",
            bytes: 100,
            processIdentifier: 42,
            processStartTime: 100,
            lastUsed: Date()
        )
        let reusedPID = SystemResourceSampler.UsageSnapshot(
            capturedAt: 1,
            processes: [
                .init(processIdentifier: 42, startTime: 999, cpuTimeNanoseconds: 0,
                      physicalFootprintBytes: 10_000),
            ]
        )

        XCTAssertTrue(ResourceMonitorPresentation.models(
            residency: [resident],
            runtimes: [],
            snapshot: reusedPID
        ).isEmpty)
    }

    func testUnknownInProcessMemoryStillCountsTheModel() {
        let model = ModelRuntimeRegistry.Resident(
            id: "support:unknown",
            role: "Support",
            label: "Unknown",
            estimatedBytes: nil,
            processIdentifier: nil,
            processStartTime: nil
        )
        let models = ResourceMonitorPresentation.models(
            residency: [],
            runtimes: [model],
            snapshot: nil
        )

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(
            ResourceMonitorPresentation.modelMemorySummary(models: models, snapshot: nil),
            "included"
        )
    }

    func testHelperRuntimeUsesLiveFootprintAndRejectsAReusedPID() throws {
        let runtime = ModelRuntimeRegistry.Resident(
            id: "speech:kokoro:one",
            role: "Speech synthesis",
            label: "Kokoro 82M",
            estimatedBytes: 100,
            processIdentifier: 42,
            processStartTime: 200
        )
        let liveSnapshot = Snapshot(capturedAt: 1, processes: [
            Usage(processIdentifier: 42, startTime: 200, cpuTimeNanoseconds: 0,
                  physicalFootprintBytes: 500),
        ])
        let liveModels = ResourceMonitorPresentation.models(
            residency: [], runtimes: [runtime], snapshot: liveSnapshot
        )

        XCTAssertEqual(liveModels.count, 1)
        XCTAssertEqual(
            ResourceMonitorPresentation.memoryReading(
                for: try XCTUnwrap(liveModels.first), snapshot: liveSnapshot
            ),
            .init(bytes: 500, estimated: false)
        )

        let reusedPID = Snapshot(capturedAt: 2, processes: [
            Usage(processIdentifier: 42, startTime: 999, cpuTimeNanoseconds: 0,
                  physicalFootprintBytes: 9_999),
        ])
        XCTAssertTrue(ResourceMonitorPresentation.models(
            residency: [], runtimes: [runtime], snapshot: reusedPID
        ).isEmpty)
    }

    func testLeasedModelRowCarriesInUseNote() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17872", label: "Qwen 4B")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: ["llama-server:17872"],
            leaseDescriptions: ["llama-server:17872":
                ["chat (interactive)", "summary (background)"]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].leaseNote,
                       "in use — chat (interactive), summary (background)")
    }

    func testUnleasedModelRowHasNoNote() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17873", label: "EmbeddingGemma")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: [],
            leaseDescriptions: [:])
        XCTAssertEqual(models.count, 1)
        XCTAssertNil(models[0].leaseNote)
    }

    func testPinWithoutDescriptionsStillReadsInUse() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17872", label: "Qwen 4B")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: ["llama-server:17872"],
            leaseDescriptions: [:])
        XCTAssertEqual(models[0].leaseNote, "in use")
    }
}

@MainActor
final class ModelRuntimeRegistryTests: XCTestCase {
    func testRegisterUpsertsAndUnregisters() {
        let registry = ModelRuntimeRegistry()
        registry.register(id: "asr", role: "Transcription", label: "One", estimatedBytes: 10)
        registry.register(id: "asr", role: "Transcription", label: "Two", estimatedBytes: 20)

        XCTAssertEqual(registry.residents, [
            .init(id: "asr", role: "Transcription", label: "Two", estimatedBytes: 20,
                  processIdentifier: nil, processStartTime: nil),
        ])

        registry.unregister(id: "asr")
        XCTAssertTrue(registry.residents.isEmpty)
    }
}
