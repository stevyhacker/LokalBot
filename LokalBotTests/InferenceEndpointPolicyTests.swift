import XCTest
@testable import LokalBot

final class InferenceEndpointPolicyTests: XCTestCase {
    func testLoopbackEndpointsDoNotRequireApproval() throws {
        for value in [
            "http://localhost:11434",
            "http://127.0.0.1:8080",
            "http://127.42.10.8:8080",
            "http://[::1]:9000",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(InferenceEndpointPolicy.isAllowed(url, approvedOrigins: []), value)
            XCTAssertNoThrow(try InferenceEndpointPolicy.validate(url, approvedOrigins: []), value)
        }
    }

    func testUnspecifiedAddressIsNotTreatedAsLoopback() throws {
        for value in ["http://0.0.0.0:11434", "https://0.0.0.0:8080/v1"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(InferenceEndpointPolicy.isLoopback(url), value)
            XCTAssertTrue(InferenceEndpointPolicy.requiresApproval(url), value)
            XCTAssertFalse(InferenceEndpointPolicy.isAllowed(url, approvedOrigins: []), value)
        }
    }

    func testHostnameBeginningWith127IsNotMistakenForLoopback() throws {
        let url = try XCTUnwrap(URL(string: "http://127.attacker.example/v1"))
        XCTAssertFalse(InferenceEndpointPolicy.isLoopback(url))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(url, approvedOrigins: [])) {
            XCTAssertEqual(
                $0 as? InferenceEndpointPolicy.PolicyError,
                .insecureRemoteEndpoint("http://127.attacker.example"))
        }
    }

    func testRemoteEndpointRequiresItsExactOrigin() throws {
        let url = try XCTUnwrap(URL(string: "https://inference.example.com/v1/chat/completions"))

        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(url, approvedOrigins: []))
        XCTAssertNoThrow(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: ["https://inference.example.com"]))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: ["https://other.example.com"]))
    }

    func testRemoteHTTPIsRejectedEvenWhenApproved() throws {
        let url = try XCTUnwrap(URL(string: "http://inference.example.com/v1"))

        XCTAssertFalse(InferenceEndpointPolicy.isAllowed(
            url, approvedOrigins: ["http://inference.example.com"]))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: ["http://inference.example.com"])) { error in
            XCTAssertEqual(
                error as? InferenceEndpointPolicy.PolicyError,
                .insecureRemoteEndpoint("http://inference.example.com"))
        }
    }

    func testPrivateNetworkHostsAreRecognizedFromTheURLAlone() throws {
        for value in [
            "http://192.168.1.20:8080/v1",
            "http://10.0.0.5:1234/v1",
            "http://172.20.10.2:8080",          // a USB or hotspot network
            "http://169.254.12.7:8080",         // link-local
            "http://100.101.102.103:11434",     // a Tailscale address
            "http://windows-box.tail1234.ts.net:1234/v1",
            "http://windows-box:1234/v1",       // a MagicDNS short name
            "http://studio.local:8080",
            "http://nas.home.arpa:8080",
            "http://[fd7a:115c:a1e0::1]:8080",  // Tailscale IPv6
            "http://[fe80::1]:8080",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(InferenceEndpointPolicy.isPrivateNetwork(url), value)
        }
        for value in [
            "http://localhost:8080",            // loopback has its own rule
            "http://127.0.0.1:8080",
            "http://0.0.0.0:8080",
            "http://8.8.8.8",
            "http://172.32.0.1",
            "http://100.128.0.1",
            "http://192.169.1.1",
            "https://openrouter.ai/api/v1",
            "http://inference.example.com/v1",
            "http://local.example.com",
            "http://ts.net.example.com",
            "http://[2001:db8::1]:8080",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(InferenceEndpointPolicy.isPrivateNetwork(url), value)
        }
    }

    func testPrivateNetworkHTTPNeedsTheCallerToOptInAndAnApproval() throws {
        let url = try XCTUnwrap(URL(string: "http://100.64.0.7:1234/v1"))
        let origin = "http://100.64.0.7:1234"

        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(url, approvedOrigins: [origin])) {
            XCTAssertEqual($0 as? InferenceEndpointPolicy.PolicyError, .insecureRemoteEndpoint(origin))
        }
        XCTAssertFalse(InferenceEndpointPolicy.isAllowed(url, approvedOrigins: [origin]))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: [], allowsPrivateNetworkHTTP: true)) {
            XCTAssertEqual($0 as? InferenceEndpointPolicy.PolicyError, .remoteApprovalRequired(origin))
        }
        XCTAssertNoThrow(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: [origin], allowsPrivateNetworkHTTP: true))
        XCTAssertTrue(InferenceEndpointPolicy.isAllowed(
            url, approvedOrigins: [origin], allowsPrivateNetworkHTTP: true))
    }

    func testPrivateNetworkOptInNeverAllowsInternetHTTP() throws {
        let url = try XCTUnwrap(URL(string: "http://inference.example.com/v1"))
        let origin = "http://inference.example.com"

        XCTAssertFalse(InferenceEndpointPolicy.isAllowed(
            url, approvedOrigins: [origin], allowsPrivateNetworkHTTP: true))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: [origin], allowsPrivateNetworkHTTP: true)) {
            XCTAssertEqual($0 as? InferenceEndpointPolicy.PolicyError, .insecureRemoteEndpoint(origin))
        }
    }

    func testOnlyHTTPInferenceURLsAreAccepted() throws {
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/model"))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(fileURL, approvedOrigins: []))
    }
}
