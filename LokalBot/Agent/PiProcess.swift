import Foundation
import Dispatch

enum PiProcessError: LocalizedError {
    case executableNotFound(String)
    case notRunning
    case payloadTooLarge
    case inputBackpressure
    case inputClosed
    case inputWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): "Agent executable not found: \(path)"
        case .notRunning: "The agent process is not running."
        case .payloadTooLarge: "The agent command exceeded the 4 MiB safety limit."
        case .inputBackpressure: "The agent input buffer is full."
        case .inputClosed: "The agent input stream is closed."
        case .inputWriteFailed(let errorNumber):
            "Writing to the agent input stream failed (errno \(errorNumber))."
        }
    }
}

final class PiStdinWriter: @unchecked Sendable {
    private struct WriteRequest {
        let id: UInt64
        let data: DispatchData
        let byteCount: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.pi-stdin-writer")
    private let channel: DispatchIO
    private let maximumBufferedBytes: Int
    private let maximumPendingWrites: Int
    private var pending: [WriteRequest] = []
    private var inFlight: WriteRequest?
    private var bufferedBytes = 0
    private var nextIdentifier: UInt64 = 0
    private var closed = false

    init(
        ownedFileDescriptor: Int32,
        maximumBufferedBytes: Int = PiJSONLFrameSplitter.defaultMaximumFrameBytes,
        maximumPendingWrites: Int = 128
    ) {
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumPendingWrites = max(1, maximumPendingWrites)
        channel = DispatchIO(
            type: .stream,
            fileDescriptor: ownedFileDescriptor,
            queue: queue,
            cleanupHandler: { _ in })
        channel.setLimit(lowWater: 1)
    }

    func write(_ payload: Data) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        let dispatchData = payload.withUnsafeBytes { bytes in
            DispatchData(bytes: bytes)
        }
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                enqueue(
                    data: dispatchData,
                    byteCount: payload.count,
                    continuation: continuation)
            }
        }
    }

    func close() {
        queue.async { [self] in closeOnQueue() }
    }

    private func enqueue(
        data: DispatchData,
        byteCount: Int,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !closed else {
            continuation.resume(throwing: PiProcessError.inputClosed)
            return
        }
        let writeCount = pending.count + (inFlight == nil ? 0 : 1)
        guard writeCount < maximumPendingWrites,
              byteCount <= maximumBufferedBytes - bufferedBytes else {
            continuation.resume(throwing: PiProcessError.inputBackpressure)
            return
        }

        nextIdentifier &+= 1
        pending.append(WriteRequest(
            id: nextIdentifier,
            data: data,
            byteCount: byteCount,
            continuation: continuation))
        bufferedBytes += byteCount
        startNextWriteIfNeeded()
    }

    private func startNextWriteIfNeeded() {
        guard !closed, inFlight == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        inFlight = request
        channel.write(offset: 0, data: request.data, queue: queue) { [weak self] done, remaining, error in
            guard done || error != 0 else { return }
            self?.finishWrite(
                id: request.id,
                unwrittenByteCount: remaining?.count ?? 0,
                errorNumber: error)
        }
    }

    private func finishWrite(id: UInt64, unwrittenByteCount: Int, errorNumber: Int32) {
        guard let request = inFlight, request.id == id else { return }
        inFlight = nil
        bufferedBytes -= request.byteCount

        guard errorNumber == 0, unwrittenByteCount == 0 else {
            let failure = PiProcessError.inputWriteFailed(
                errorNumber == 0 ? EIO : errorNumber)
            request.continuation.resume(throwing: failure)
            closeOnQueue(failingQueuedWith: failure)
            return
        }

        request.continuation.resume()
        startNextWriteIfNeeded()
    }

    private func closeOnQueue(failingQueuedWith error: Error = PiProcessError.inputClosed) {
        guard !closed else { return }
        closed = true
        channel.close(flags: .stop)

        var waiting = pending
        pending.removeAll(keepingCapacity: false)
        if let inFlight {
            waiting.append(inFlight)
            self.inFlight = nil
        }
        bufferedBytes = 0
        for request in waiting {
            request.continuation.resume(throwing: error)
        }
    }
}

actor PiProcess {

    private let plan: PiLaunchPlan
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdinWriter: PiStdinWriter?

    private var splitter = PiJSONLFrameSplitter()
    private var linesContinuation: AsyncStream<String>.Continuation?
    private var stdoutChunksContinuation: AsyncStream<Data>.Continuation?
    private var stdoutTask: Task<Void, Never>?
    private var stdoutReachedEOF = false
    private var overflowStopScheduled = false
    private var started = false
    private var exited = false
    private(set) var stderrTail: [String] = []

    let lines: AsyncStream<String>

    init(plan: PiLaunchPlan) {
        self.plan = plan
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream(bufferingPolicy: .bufferingOldest(2_048)) { continuation = $0 }
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

        let (chunks, chunksContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(64))
        stdoutChunksContinuation = chunksContinuation
        stdoutTask = Task.detached { [weak self] in
            for await data in chunks {
                await self?.consumeStdout(data)
            }
            await self?.handleStdoutEOF()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                chunksContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                if case .dropped = chunksContinuation.yield(data) {
                    Task { [weak self] in
                        await self?.failForBufferOverflow("stdout byte buffer overflow")
                    }
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in await self?.consumeStderr(text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in await self?.handleExit() }
        }
        let duplicateInput = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
        guard duplicateInput >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let writer = PiStdinWriter(ownedFileDescriptor: duplicateInput)
        stdinWriter = writer
        do {
            try process.run()
        } catch {
            stdinWriter = nil
            writer.close()
            throw error
        }
        try? stdinPipe.fileHandleForWriting.close()
        started = true
    }

    func send(line: String) async throws {
        guard isRunning, let stdinWriter else { throw PiProcessError.notRunning }
        let payload = Data((line + "\n").utf8)
        guard payload.count <= PiJSONLFrameSplitter.defaultMaximumFrameBytes else {
            throw PiProcessError.payloadTooLarge
        }
        try await stdinWriter.write(payload)
    }

    func stop() async {
        guard isRunning else { return }
        stdinWriter?.close()
        process.terminate()
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        handleExit()
        await stdoutTask?.value
    }

    private func consumeStdout(_ data: Data) {
        for frame in splitter.append(data) {
            guard let result = linesContinuation?.yield(frame) else { return }
            if case .dropped = result {
                failForBufferOverflow("RPC frame buffer overflow")
                return
            }
        }
    }

    private func handleStdoutEOF() {
        guard !stdoutReachedEOF else { return }
        stdoutReachedEOF = true
        if let last = splitter.flush(),
           let result = linesContinuation?.yield(last),
           case .dropped = result {
            failForBufferOverflow("RPC frame buffer overflow at EOF")
        }
        finishLinesIfReady()
    }

    private func consumeStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map {
            String($0.prefix(8_192))
        })
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
    }

    private func failForBufferOverflow(_ reason: String) {
        guard !overflowStopScheduled else { return }
        overflowStopScheduled = true
        stderrTail.append("LokalBot stopped pi: \(reason)")
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
        stdinWriter?.close()
        if process.isRunning { process.terminate() }
        Task { [weak self] in await self?.stop() }
    }

    private func handleExit() {
        guard !exited else { return }
        exited = true
        stdinWriter?.close()
        stdinWriter = nil
        finishLinesIfReady()
    }

    private func finishLinesIfReady() {
        guard exited, stdoutReachedEOF, linesContinuation != nil else { return }
        linesContinuation?.finish()
        linesContinuation = nil
        stdoutChunksContinuation?.finish()
        stdoutChunksContinuation = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}
