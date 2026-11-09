import Combine
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokalBot

/// A synthetic metrics page, drawn rather than captured, so Vision reads it
/// on any machine.
private func dashboardPNG() throws -> Data {
    let width = 1_200, height = 700
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func draw(_ text: String, x: CGFloat, top: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.textPosition = CGPoint(x: x, y: CGFloat(height) - top)
        CTLineDraw(line, context)
    }
    draw("Northwind Analytics Growth dashboard", x: 40, top: 70, size: 40)
    let rows = [("Trial to paid, July", "3.6%"), ("Trial to paid, August", "3.8%"), ("Trial to paid, September", "4.1%"),
                ("Monthly active teams", "1,284"), ("Net revenue retention", "108%")]
    for (index, row) in rows.enumerated() {
        let top = CGFloat(170 + index * 100)
        draw(row.0, x: 60, top: top, size: 28)
        draw(row.1, x: 1_000, top: top, size: 28)
    }
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func reply(_ object: [String: Any]) -> MuseChatClient.Reply {
    let content = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return MuseChatClient.Reply(content: content, toolCalls: [],
                                usage: .init(inputTokens: 1_200, outputTokens: 200), finishReason: "stop")
}

@MainActor
private final class StubFeed: RadarLineFeed {
    let subject = CurrentValueSubject<[LiveMeetingTranscriber.Line], Never>([])
    var isRunning = false
    var deliversTurns = true
    var linesPublisher: AnyPublisher<[LiveMeetingTranscriber.Line], Never> { subject.eraseToAnyPublisher() }
    var currentLines: [LiveMeetingTranscriber.Line] { subject.value }
    func activatePreview() { isRunning = true }
}

@MainActor
private final class NoEvidence: RadarEvidenceSource {
    func evidence(for text: String, meeting: Meeting, limit: Int) async -> [RadarEvidence] { [] }
}

@MainActor
private final class StubScreens: RadarScreenSource {
    let image: Data
    var questions: [String] = []
    init(image: Data) { self.image = image }
    func captures(for question: String, before: Date, limit: Int) async -> [RadarScreenCapture] {
        questions.append(question)
        let image = image
        return [RadarScreenCapture(snapshotID: 42, capturedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                   app: "Safari", windowTitle: "Growth dashboard", imageData: { image })]
    }
}

final class RadarScreenAnswersTests: XCTestCase {
    func testTermsDropQuestionWordsAndKeepNumbers() {
        XCTAssertEqual(RadarScreenAnswers.terms("What was our trial-to-paid conversion last month?"),
                       ["trial", "paid", "conversion", "last", "month"])
        XCTAssertEqual(RadarScreenAnswers.terms("Did we ship v2 in Q3?"), ["ship", "v2", "q3"])
    }

    func testCropKeepsTheMatchingRowsAndReadsThemOnThisMac() throws {
        let crop = try XCTUnwrap(RadarScreenAnswers.crop(try dashboardPNG(), terms: ["trial", "paid", "conversion"]))
        XCTAssertTrue(crop.text.contains("September"), crop.text)
        XCTAssertTrue(crop.text.contains("4.1"), crop.text)
        XCTAssertFalse(crop.text.contains("Northwind"), "the band stays around the matched rows: \(crop.text)")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(crop.jpeg as CFData, nil))
        let size = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThan(try XCTUnwrap(size[kCGImagePropertyPixelHeight] as? Int), 700)
        XCTAssertNil(RadarScreenAnswers.crop(try dashboardPNG(), terms: ["invoice"]), "no matching words, no crop")
    }

    func testAnswerCountsOnlyWhenItsQuoteIsInTheCrop() {
        let crop = RadarScreenCrop(jpeg: Data(), text: "Trial to paid, August 3.8%\nTrial to paid, September 4.1%")
        let good = #"{"answer":"4.1% in September","image":1,"quote":"Trial to paid, September 4.1%"}"#
        XCTAssertEqual(RadarScreenAnswers.answer(from: good, crops: [crop])?.text, "4.1% in September")
        XCTAssertNotNil(RadarScreenAnswers.answer(from: #"{"answer":"4.1%","image":1,"quote":"4.1%"}"#, crops: [crop]))
        XCTAssertNil(RadarScreenAnswers.answer(from: #"{"answer":"4.2%","image":1,"quote":"4.2%"}"#, crops: [crop]),
                     "a number that isn't on screen is dropped")
        XCTAssertNil(RadarScreenAnswers.answer(from: #"{"answer":"","image":0,"quote":""}"#, crops: [crop]))
        XCTAssertNil(RadarScreenAnswers.answer(from: #"{"answer":"4.1%","image":2,"quote":"4.1%"}"#, crops: [crop]),
                     "the image must be one that was sent")
    }

    func testRequestSendsOnlyTheCropsAndWhereTheyWereSeen() throws {
        let capture = RadarScreenCapture(snapshotID: 1, capturedAt: Date(), app: "Safari", windowTitle: "Dashboard",
                                         imageData: { nil })
        let messages = RadarScreenAnswers.messages(
            question: "What was our conversion?", meetingTitle: "Launch sync", meetingDate: Date(),
            crops: [(capture, RadarScreenCrop(jpeg: Data([0xFF, 0xD8]), text: "x"))])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "image_url" }.count, 1)
        XCTAssertTrue((content[1]["text"] as? String)?.contains("Safari — Dashboard") ?? false)
        let url = try XCTUnwrap((content[2]["image_url"] as? [String: String])?["url"])
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
    }

    @MainActor
    func testRadarAnswersACaughtQuestionFromTheScreenAndSavesTheCrop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://api.meta.ai"]
        settings.museScreenAnswersEnabled = true
        let feed = StubFeed()
        let screens = StubScreens(image: try dashboardPNG())
        var imagesSent = 0
        let radar = MeetingRadar(
            transcriber: feed, evidenceSource: NoEvidence(), screenSource: screens, settings: { settings },
            call: { messages, schema, _ in
                if (schema["properties"] as? [String: Any])?["answer"] != nil {
                    let content = messages.last?["content"] as? [[String: Any]] ?? []
                    imagesSent += content.filter { $0["type"] as? String == "image_url" }.count
                    return reply(["answer": "4.1% in September", "image": 1, "quote": "Trial to paid, September 4.1%"])
                }
                return reply(["items": [["kind": "question", "text": "Trial-to-paid conversion last month", "owner": "",
                                         "due": "", "line": "L1",
                                         "quote": "What was our trial-to-paid conversion last month?", "evidence": ""]],
                              "answered": [String]()])
            },
            availability: { _ in nil },
            timing: .init(minimumInterval: .seconds(60), turnInterval: .milliseconds(1), idlePoll: .milliseconds(5)))
        let meeting = Meeting(id: UUID(), title: "Launch sync", appName: "Meet", startedAt: Date(), relativePath: "m")
        radar.start(meeting: meeting, folder: folder)
        feed.subject.send([.init(time: 12, speaker: "them", text: "What was our trial-to-paid conversion last month?")])

        let deadline = Date().addingTimeInterval(10)
        while radar.items.first?.screenAnswer == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let answer = try XCTUnwrap(radar.items.first?.screenAnswer)
        XCTAssertEqual(answer.text, "4.1% in September")
        XCTAssertEqual(answer.snapshotID, 42)
        XCTAssertEqual(imagesSent, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(answer.image).path))
        XCTAssertEqual(screens.questions.count, 1)

        await radar.finish()
        let saved = try XCTUnwrap(MeetingRadarRecord.load(from: folder))
        XCTAssertEqual(saved.items.first?.screenAnswer, answer)
        XCTAssertEqual(saved.screenAnswerRequests?.count, 1)
        XCTAssertGreaterThan(saved.cost, saved.passes.reduce(0) { $0 + $1.cost }, "screen answers count toward cost")
    }

    @MainActor
    func testScreenAnswersStayOffUnlessTurnedOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://api.meta.ai"]
        let feed = StubFeed()
        let screens = StubScreens(image: Data())
        let radar = MeetingRadar(
            transcriber: feed, evidenceSource: NoEvidence(), screenSource: screens, settings: { settings },
            call: { _, _, _ in
                reply(["items": [["kind": "question", "text": "Conversion last month", "owner": "", "due": "",
                                  "line": "L1", "quote": "What was our conversion last month?", "evidence": ""]],
                       "answered": [String]()])
            },
            availability: { _ in nil },
            timing: .init(minimumInterval: .seconds(60), turnInterval: .milliseconds(1), idlePoll: .milliseconds(5)))
        radar.start(meeting: Meeting(id: UUID(), title: "Sync", appName: "Meet", startedAt: Date(), relativePath: "m"),
                    folder: folder)
        feed.subject.send([.init(time: 3, speaker: "them", text: "What was our conversion last month?")])
        let deadline = Date().addingTimeInterval(5)
        while radar.items.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await radar.finish()
        XCTAssertEqual(radar.items.count, 1)
        XCTAssertTrue(screens.questions.isEmpty, "screen memory isn't searched while screen answers are off")
    }
}
