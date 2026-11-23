import AVFoundation
import XCTest
@testable import LokalBot

final class WaveformAnalysisTests: XCTestCase {
    func testBothTracksUseSharedTimelineDespiteDifferentLengthsAndFormats() throws {
        let folder = try temporaryFolder()
        let mic = folder.appendingPathComponent("mic.caf")
        let system = folder.appendingPathComponent("system.caf")
        try writeAudio(mic, duration: 1, sampleRate: 8_000, channels: 1, active: 0.2..<0.3)
        try writeAudio(system, duration: 2, sampleRate: 16_000, channels: 2, active: 1.5..<1.6)
        let peaks = try XCTUnwrap(WaveformAnalysis.decode(.init(sources: [
            .init(url: mic, gain: 1), .init(url: system, gain: 0.5)
        ], duration: 2)))
        XCTAssertEqual(peaks[128], 1, accuracy: 0.01)
        XCTAssertEqual(peaks[256], 0)
        XCTAssertEqual(peaks[793], 0.5, accuracy: 0.01)
        XCTAssertEqual(peaks[1000], 0)
    }

    func testUnreadableTrackDoesNotHideValidTrack() throws {
        let folder = try temporaryFolder()
        let valid = folder.appendingPathComponent("valid.caf")
        try writeAudio(valid, duration: 1, active: 0.4..<0.6)
        let peaks = try XCTUnwrap(WaveformAnalysis.decode(.init(sources: [
            .init(url: folder.appendingPathComponent("missing.caf"), gain: 1),
            .init(url: valid, gain: 1)
        ], duration: 1)))
        XCTAssertEqual(peaks[512], 1)
    }

    func testSilentAudioStaysFlatAndMissingAudioHasNoInventedPeaks() throws {
        let folder = try temporaryFolder()
        let silent = folder.appendingPathComponent("silent.caf")
        try writeAudio(silent, duration: 1, active: 0..<0)
        let peaks = try XCTUnwrap(WaveformAnalysis.decode(.init(
            sources: [.init(url: silent, gain: 1)], duration: 1)))
        XCTAssertTrue(peaks.allSatisfy { $0 == 0 })
        XCTAssertNil(WaveformAnalysis.decode(.init(sources: [], duration: 1)))
        XCTAssertNil(WaveformAnalysis.decode(.init(sources: [], duration: .nan)))
    }

    func testResamplingPreservesBriefPeaksAtNarrowWidths() {
        var peaks = [Float](repeating: 0, count: 1_024)
        peaks[513] = 1
        for width in [1.0, 80, 160, 400, 800] {
            let bars = WaveformAnalysis.resample(peaks, width: width)
            XCTAssertLessThanOrEqual(bars.count, max(1, Int(width / 4)))
            XCTAssertEqual(bars.max(), 1)
        }
        XCTAssertTrue(WaveformAnalysis.resample(peaks, width: 0).isEmpty)
        XCTAssertTrue(WaveformAnalysis.resample(peaks, width: .infinity).isEmpty)
    }

    func testReplacingAudioAtSamePathInvalidatesCache() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("recording.caf")
        try writeAudio(url, duration: 1, active: 0.1..<0.2)
        let request = WaveformAnalysis.Request(sources: [.init(url: url, gain: 1)], duration: 2)
        let firstResult = await WaveformAnalysis.load(request)
        let first = try XCTUnwrap(firstResult)
        try writeAudio(url, duration: 2, active: 1.5..<1.6)
        WaveformAnalysis.clearMemoryCache()
        let secondResult = await WaveformAnalysis.load(request)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(first[76], 1)
        XCTAssertEqual(second[76], 0)
        XCTAssertEqual(second[793], 1)
    }

    func testDiskCacheSurvivesMemoryEvictionWithoutRegeneratingAudio() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("recording.caf")
        try writeAudio(url, duration: 1, active: 0.1..<0.2)
        let request = WaveformAnalysis.Request(sources: [.init(url: url, gain: 1)], duration: 1)
        let firstResult = await WaveformAnalysis.load(request)
        let expected = try XCTUnwrap(firstResult)
        let cacheURL = try XCTUnwrap(WaveformAnalysis.diskCacheURL(for: request))
        let markerDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: markerDate], ofItemAtPath: cacheURL.path)
        WaveformAnalysis.clearMemoryCache()
        let cached = await WaveformAnalysis.load(request)
        XCTAssertEqual(cached, expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, markerDate,
                       "disk cache hit must not decode and rewrite the envelope")
    }

    func testCorruptDiskCacheIsRegenerated() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("recording.caf")
        try writeAudio(url, duration: 1, active: 0.4..<0.6)
        let request = WaveformAnalysis.Request(sources: [.init(url: url, gain: 1)], duration: 1)
        let first = await WaveformAnalysis.load(request)
        let cacheURL = try XCTUnwrap(WaveformAnalysis.diskCacheURL(for: request))
        try Data("not a waveform".utf8).write(to: cacheURL)
        WaveformAnalysis.clearMemoryCache()
        let regenerated = await WaveformAnalysis.load(request)
        XCTAssertEqual(regenerated, first)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)))
    }

    func testChangedTimelineInvalidatesDiskCache() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("recording.caf")
        try writeAudio(url, duration: 1, active: 0.4..<0.6)
        let sources = [WaveformAnalysis.Source(url: url, gain: 1)]
        _ = await WaveformAnalysis.load(.init(sources: sources, duration: 1))
        WaveformAnalysis.clearMemoryCache()
        let result = await WaveformAnalysis.load(.init(sources: sources, duration: 2))
        let peaks = try XCTUnwrap(result)
        XCTAssertEqual(peaks[256], 1)
        XCTAssertEqual(peaks[512], 0)
    }

    func testVectorizedPeaksMatchScalarReferenceAtBinAndChunkBoundaries() throws {
        let folder = try temporaryFolder()
        for (sampleRate, frameCount, duration) in [(44_100.0, 70_003, 1.371), (8_000.0, 113, 0.021), (48_000.0, 71_001, 2.007)] {
            let url = folder.appendingPathComponent("\(frameCount).caf")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            var reference = [Float](repeating: 0, count: 1_024)
            var seed: UInt64 = 42
            for frame in 0..<frameCount {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                samples[frame] = Float(Int(seed >> 33) % 20_001 - 10_000) / 10_000
                let time = Double(frame) / sampleRate
                if time < duration {
                    let bin = min(1_023, Int(time / duration * 1_024))
                    reference[bin] = max(reference[bin], abs(samples[frame]))
                }
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let maximum = reference.max() ?? 1
            reference = reference.map { $0 / maximum }
            let peaks = try XCTUnwrap(WaveformAnalysis.decode(.init(sources: [.init(url: url, gain: 1)], duration: duration)))
            for index in reference.indices {
                XCTAssertEqual(peaks[index], reference[index], accuracy: 0.000001,
                               "bin \(index), sample rate \(sampleRate), frames \(frameCount)")
            }
        }
    }

    func testCancelledLoadDoesNotPublishPeaks() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("recording.caf")
        try writeAudio(url, duration: 1, active: 0.1..<0.2)
        let task = Task { () -> [Float]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await WaveformAnalysis.load(.init(sources: [.init(url: url, gain: 1)], duration: 1))
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    func testDetailBinResamplingCoversVisibleSlice() {
        var peaks = [Float](repeating: 0, count: WaveformAnalysis.detailBinCount)
        let targetBin = WaveformAnalysis.detailBinCount * 3 / 4
        peaks[targetBin] = 1
        let full = WaveformAnalysis.resample(
            peaks,
            duration: 100,
            visibleStart: 0,
            visibleEnd: 100,
            width: 400)
        XCTAssertEqual(full.max(), 1)

        let earlySlice = WaveformAnalysis.resample(
            peaks,
            duration: 100,
            visibleStart: 0,
            visibleEnd: 50,
            width: 400)
        XCTAssertEqual(earlySlice.max(), 0)

        let zoomedSlice = WaveformAnalysis.resample(
            peaks,
            duration: 100,
            visibleStart: 70,
            visibleEnd: 80,
            width: 400)
        XCTAssertEqual(zoomedSlice.max(), 1)
    }

    func testViewportAnchoredZoomAndPanClamping() {
        var viewport = WaveformViewport(windowStart: 10, windowEnd: 110)
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.visibleStart, 10)
        XCTAssertEqual(viewport.visibleEnd, 110)

        let anchorFraction = 0.25
        let anchorTimeBefore = viewport.time(atFraction: anchorFraction)
        XCTAssertEqual(anchorTimeBefore, 35, accuracy: 0.001)

        viewport.zoom(by: 4, anchorFraction: anchorFraction)
        XCTAssertEqual(viewport.zoom, 4, accuracy: 0.001)
        XCTAssertEqual(viewport.visibleSpan, 25, accuracy: 0.001)
        XCTAssertEqual(viewport.time(atFraction: anchorFraction), anchorTimeBefore, accuracy: 0.001)

        viewport.pan(by: -100)
        XCTAssertEqual(viewport.visibleStart, 10, accuracy: 0.001)

        viewport.pan(by: 500)
        XCTAssertEqual(viewport.visibleEnd, 110, accuracy: 0.001)

        viewport.zoom(by: 100, anchorFraction: 0.5)
        XCTAssertEqual(viewport.zoom, WaveformViewport.maxZoom, accuracy: 0.001)

        viewport.reset()
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.visibleStart, 10)
        XCTAssertEqual(viewport.visibleEnd, 110)
    }

    func testTwoClickSelectionCycleAndOrdering() {
        var state = WaveformSelectionState()
        let bounds = 10.0...100.0

        state.handleLeftClick(at: 50, bounds: bounds)
        XCTAssertEqual(state.pendingStart, 50)
        XCTAssertNil(state.selection)

        state.handleLeftClick(at: 20, bounds: bounds)
        XCTAssertNil(state.pendingStart)
        XCTAssertEqual(state.selection, .init(start: 20, end: 50))

        state.handleLeftClick(at: 65, bounds: bounds)
        XCTAssertEqual(state.pendingStart, 65)
        XCTAssertNil(state.selection)

        state.handleLeftClick(at: 65.1, bounds: bounds)
        XCTAssertEqual(state.pendingStart, 65.1)
        XCTAssertNil(state.selection)

        state.clear()
        XCTAssertNil(state.pendingStart)
        XCTAssertNil(state.selection)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeAudio(_ url: URL, duration: Double, sampleRate: Double = 8_000,
                            channels: AVAudioChannelCount = 1, active: Range<Double>) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let count = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(count) {
                data[channel][frame] = channel == Int(channels) - 1 && active.contains(Double(frame) / sampleRate) ? 0.5 : 0
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
