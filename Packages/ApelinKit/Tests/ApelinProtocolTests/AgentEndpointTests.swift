import Foundation
import XCTest
@testable import ApelinProtocol

/// The name two keys are grouped under: one Base URL, spelled any of the ways
/// a reader can paste it.
final class AgentEndpointTests: XCTestCase {
    func testOneAddressInTwoSpellingsIsOneEndpoint() {
        let forms = [
            "https://relay.example.com/v1",
            "https://relay.example.com/v1/",
            "relay.example.com/v1",
            "  https://relay.example.com/v1  ",
            "https://relay.example.com/v1/models",
            "https://relay.example.com/v1/chat/completions",
        ]
        for form in forms {
            XCTAssertEqual(
                AgentEndpoint.canonical(form),
                "https://relay.example.com/v1",
                "\(form) should name the endpoint of every other form",
            )
        }
    }

    /// Two addresses on one host are two endpoints: their keys are not
    /// interchangeable and neither are their model lists.
    func testTwoAddressesOnOneHostAreTwoEndpoints() {
        XCTAssertNotEqual(
            AgentEndpoint.canonical("https://relay.example.com/v1"),
            AgentEndpoint.canonical("https://relay.example.com/v2"),
        )
        XCTAssertNotEqual(
            AgentEndpoint.canonical("https://relay.example.com"),
            AgentEndpoint.canonical("http://relay.example.com"),
        )
        XCTAssertNotEqual(
            AgentEndpoint.canonical("https://relay.example.com:8080/v1"),
            AgentEndpoint.canonical("https://relay.example.com/v1"),
        )
    }

    func testHostIsComparedLowercasedAndThePathIsNot() {
        XCTAssertEqual(
            AgentEndpoint.canonical("https://Relay.Example.COM/v1"),
            "https://relay.example.com/v1",
        )
        XCTAssertNotEqual(
            AgentEndpoint.canonical("https://relay.example.com/V1"),
            AgentEndpoint.canonical("https://relay.example.com/v1"),
        )
    }

    func testNothingThatCouldBeAnAddressNamesNoEndpoint() {
        XCTAssertNil(AgentEndpoint.canonical(nil))
        XCTAssertNil(AgentEndpoint.canonical(""))
        XCTAssertNil(AgentEndpoint.canonical("   "))
        XCTAssertNil(AgentEndpoint.canonical("https://"))
    }

    func testTheSectionTitleDropsTheSchemeOnly() {
        XCTAssertEqual(AgentEndpoint.title("https://relay.example.com/v1"), "relay.example.com/v1")
        XCTAssertEqual(AgentEndpoint.title("http://relay.example.com"), "relay.example.com")
    }

    /// The account carries the address the worker builds its requests from,
    /// and reports nothing when it has none, so the app falls back to what an
    /// earlier version kept.
    func testAnAccountReportsTheEndpointItWasGiven() {
        var account = AgentAccount(
            provider: .openAICompatible,
            id: "openai-compatible.1",
            method: .apiKey,
            signedIn: true,
            account: "relay.example.com",
        )
        XCTAssertNil(account.endpoint)
        account.baseURL = "https://Relay.example.com/v1/"
        XCTAssertEqual(account.endpoint, "https://relay.example.com/v1")
    }

    /// A listing written before the address travelled with it still decodes,
    /// and says it has no endpoint rather than a made-up one.
    func testOlderListingsDecodeWithoutAnEndpoint() throws {
        let json = """
        {"provider":"openai-compatible","id":"openai-compatible.1","method":"apiKey",
         "signedIn":true,"account":"relay.example.com"}
        """
        let account = try JSONDecoder().decode(AgentAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.account, "relay.example.com")
        XCTAssertNil(account.endpoint)
    }
}