import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct ServerEndpointTests {

    @Test func parseBareHostAndPort() {
        let result = ServerEndpoint.parse("example.com:8787")
        #expect(result?.host == "example.com")
        #expect(result?.port == 8787)
        #expect(result?.useTLS == false)
    }

    @Test func parseWithWSscheme() {
        let result = ServerEndpoint.parse("ws://example.com:8787")
        #expect(result?.host == "example.com")
        #expect(result?.port == 8787)
        #expect(result?.useTLS == false)
    }

    @Test func parseWithWSSscheme() {
        let result = ServerEndpoint.parse("wss://example.com:1234")
        #expect(result?.host == "example.com")
        #expect(result?.port == 1234)
        #expect(result?.useTLS == true)
    }

    @Test func parseWithHTTPSscheme() {
        let result = ServerEndpoint.parse("https://example.com")
        #expect(result?.host == "example.com")
        #expect(result?.port == 443)
        #expect(result?.useTLS == true)
    }

    @Test func parseHTTPschemeDefaultPort() {
        let result = ServerEndpoint.parse("http://example.com")
        #expect(result?.host == "example.com")
        #expect(result?.port == 8787)
        #expect(result?.useTLS == false)
    }

    @Test func parseWithTrailingPath() {
        let result = ServerEndpoint.parse("ws://example.com:8787/ws/ignored")
        #expect(result?.host == "example.com")
        #expect(result?.port == 8787)
    }

    @Test func parseTrimsWhitespace() {
        let result = ServerEndpoint.parse("  example.com:8787  ")
        #expect(result?.host == "example.com")
    }

    @Test func parseInvalidPort() {
        #expect(ServerEndpoint.parse("example.com:abc") == nil)
        #expect(ServerEndpoint.parse("example.com:99999") == nil)
    }

    @Test func parseEmpty() {
        #expect(ServerEndpoint.parse("") == nil)
        #expect(ServerEndpoint.parse("   ") == nil)
    }

    @Test func urlConstruction() {
        let ep = ServerEndpoint(host: "localhost", port: 8787, useTLS: false)
        #expect(ep.url?.absoluteString == "ws://localhost:8787")

        let eps = ServerEndpoint(host: "acp.example.com", port: 443, useTLS: true)
        #expect(eps.url?.absoluteString == "wss://acp.example.com:443")
    }

    @Test func displayString() {
        let ep = ServerEndpoint(host: "localhost", port: 8787)
        #expect(ep.displayString == "ws://localhost:8787")
    }
}
