import XCTest
@testable import LokalBot

// FakeTransport (shared with AgentSessionControllerTests) lives in
// TestSupport/FakeTransport.swift.

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

    func testRequestTimesOutAndIgnoresLateResponse() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport, requestTimeout: .milliseconds(40))
        await client.run()
        do {
            _ = try await client.request(.getState(id: "timeout"))
            XCTFail("expected timeout")
        } catch PiRPCError.requestTimedOut(let id) {
            XCTAssertEqual(id, "timeout")
        }
        transport.inject(#"{"type":"response","id":"timeout","command":"get_state","success":true}"#)
    }

    func testCancellationRemovesPendingRequest() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport, requestTimeout: .seconds(10))
        await client.run()
        let task = Task { try await client.request(.getState(id: "cancelled")) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testMalformedFrameBecomesVisibleProtocolError() async {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        var iterator = (await client.events).makeAsyncIterator()
        transport.inject("not-json")
        guard let event = await iterator.next(),
              case .extensionError(let message) = event else {
            return XCTFail("expected protocol error")
        }
        XCTAssertTrue(message.contains("malformed"))
    }

    func testTextDeltaOverflowDoesNotEvictApproval() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(
            transport: transport,
            requestTimeout: .seconds(1),
            eventBufferCapacity: 1)
        await client.run()

        async let responseTask = client.request(.getState(id: "overflow-barrier"))
        for _ in 0..<20 where !transport.sentLines.contains(where: { $0.contains("overflow-barrier") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(transport.sentLines.contains { $0.contains("overflow-barrier") })

        transport.inject(
            #"{"type":"extension_ui_request","id":"approval-1","method":"confirm"}"#)
        for _ in 0..<4 {
            transport.inject(
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}"#)
        }
        transport.inject(
            #"{"type":"response","id":"overflow-barrier","command":"get_state","success":true}"#)
        _ = try await responseTask

        var iterator = (await client.events).makeAsyncIterator()
        guard case .extensionUIRequest(let request) = await iterator.next() else {
            return XCTFail("expected the buffered approval to survive text overflow")
        }
        XCTAssertEqual(request.id, "approval-1")

        transport.inject(#"{"type":"agent_end"}"#)
        let eventAfterOverflow = await iterator.next()
        XCTAssertEqual(eventAfterOverflow, .agentEnd)
        transport.close()
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)
    }

    func testApprovalOverflowFailsPendingRequestAndTerminatesStream() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(
            transport: transport,
            requestTimeout: .seconds(1),
            eventBufferCapacity: 1)
        await client.run()

        let responseTask = Task { try await client.request(.getState(id: "structural-overflow")) }
        for _ in 0..<20 where !transport.sentLines.contains(where: { $0.contains("structural-overflow") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(transport.sentLines.contains { $0.contains("structural-overflow") })

        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(
            #"{"type":"extension_ui_request","id":"approval-dropped","method":"confirm"}"#)

        do {
            _ = try await responseTask.value
            XCTFail("expected structural event overflow")
        } catch PiRPCError.eventBufferOverflow {
            // Expected: the approval could not be queued, so the client failed closed.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        var iterator = (await client.events).makeAsyncIterator()
        let bufferedEvent = await iterator.next()
        XCTAssertEqual(bufferedEvent, .agentStart)
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)

        do {
            _ = try await client.request(.getState(id: "after-overflow"))
            XCTFail("expected the client to remain terminal")
        } catch PiRPCError.eventBufferOverflow {
            // Expected: later callers observe the same deterministic failure.
        } catch {
            XCTFail("unexpected terminal error: \(error)")
        }
    }
}
