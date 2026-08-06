import Foundation
import Testing
@testable import ACPAgentCore

/// Structural decoding of the `session/request_permission` wire (ADR-005),
/// plus the response-shape builder used by the ConversationStore.
@Suite struct PermissionRequestTests {

    private func decodeParams(_ json: String) throws -> PermissionRequest {
        try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
    }

    @Test func decodesADR005WireSample() throws {
        let request = try decodeParams(#"""
        {"sessionId":"ses_123",
         "toolCall":{"toolCallId":"call_42","title":"curl -s https://example.com | head -3","kind":"execute","status":"pending","locations":[],"rawInput":{"command":"curl -s https://example.com | head -3"}},
         "options":[
           {"optionId":"once","kind":"allow_once","name":"Allow once"},
           {"optionId":"always","kind":"allow_always","name":"Always allow"},
           {"optionId":"reject","kind":"reject_once","name":"Reject"}
         ]}
        """#)

        #expect(request.sessionId == "ses_123")
        #expect(request.toolCall.toolCallId == "call_42")
        #expect(request.toolCall.title == "curl -s https://example.com | head -3")
        #expect(request.toolCall.kind == "execute")
        #expect(request.toolCall.locations.isEmpty)

        #expect(request.options.count == 3)
        #expect(request.options[0].optionId == "once")
        #expect(request.options[0].kind == .allowOnce)
        #expect(request.options[0].name == "Allow once")
        #expect(request.options[0].isAllow)
        #expect(request.options[1].kind == .allowAlways)
        #expect(request.options[2].kind == .rejectOnce)
        #expect(!request.options[2].isAllow)
    }

    @Test func decodesExternalDirectoryVariantWithLocations() throws {
        let request = try decodeParams(#"""
        {"sessionId":"ses_9",
         "toolCall":{"toolCallId":"call_7","title":"Read /etc/hosts","kind":"other","status":"pending","locations":[{"path":"/etc/hosts"},{"path":"/etc"}],"rawInput":{"filepath":"/etc/hosts","parentDir":"/etc"}},
         "options":[{"optionId":"reject","kind":"reject_once","name":"Reject"}]}
        """#)

        #expect(request.toolCall.kind == "other")
        #expect(request.toolCall.locations == ["/etc/hosts", "/etc"])
        #expect(request.toolCall.summaryLines == ["filepath: /etc/hosts", "parentDir: /etc"])
    }

    @Test func decodesEditRequestWithDiffPreview() throws {
        // ADR-005: read/edit requests carry a `content` diff preview.
        let request = try decodeParams(#"""
        {"sessionId":"s1",
         "toolCall":{"toolCallId":"c1","title":"Edit a.txt","kind":"edit","status":"pending","locations":[],"rawInput":{"filepath":"/proj/a.txt"},
           "content":[{"type":"diff","path":"/proj/a.txt","oldText":"a","newText":"b"}]},
         "options":[{"optionId":"once","kind":"allow_once","name":"Allow once"}]}
        """#)

        #expect(request.toolCall.content == ["Diff: /proj/a.txt"])
    }

    @Test func unknownOptionKindFallsBackToRejectSemantics() throws {
        let request = try decodeParams(#"""
        {"sessionId":"s1",
         "toolCall":{"toolCallId":"c1","title":"Do it","kind":"execute","status":"pending"},
         "options":[{"optionId":"weird","kind":"allow_forever","name":"Weird"}]}
        """#)

        // Never claim "approved" for an option we do not understand.
        #expect(request.options[0].kind == .rejectOnce)
        #expect(!request.options[0].isAllow)
        #expect(request.options[0].name == "Weird")
    }

    @Test func rawInputStringifyHandlesNestedValues() throws {
        let request = try decodeParams(#"""
        {"sessionId":"s1",
         "toolCall":{"toolCallId":"c1","title":"t","kind":"execute","status":"pending","rawInput":{"count":3,"ok":true,"none":null,"nested":{"a":1}}},
         "options":[]}
        """#)

        let lines = request.toolCall.summaryLines
        #expect(lines.contains("count: 3"))
        #expect(lines.contains("ok: true"))
        #expect(lines.contains("none: null"))
        #expect(lines.contains(#"nested: {"a":1}"#))
    }

    @Test func requestIdLivesOutsideParamsAndIsFilledByTheClient() throws {
        // Decode the buffered replay shape: params + envelope id.
        let paramsJSON = permissionRequestParamsJSON(sessionId: "s1")
        let event = try JSONDecoder().decode(
            BufferedSessionEvent.self,
            from: Data(#"{"method":"session/request_permission","params":\#(paramsJSON),"id":7,"cursor":3}"#.utf8)
        )

        #expect(event.method == "session/request_permission")
        #expect(event.cursor == 3)
        #expect(event.params == nil)
        let request = try #require(event.request)
        #expect(request.sessionId == "s1")
        #expect(request.requestId == .number(7))
        #expect(request.options.count == 2)
    }

    @Test func bufferedSessionUpdateStillDecodesAsBefore() throws {
        let event = try JSONDecoder().decode(
            BufferedSessionEvent.self,
            from: Data(#"{"method":"session/update","params":{"sessionId":"s1","update":\#(agentChunkJSON("hi"))},"cursor":1}"#.utf8)
        )

        #expect(event.request == nil)
        #expect(event.params?.sessionId == "s1")
        #expect(event.params?.update == .agentMessageChunk(.text("hi")))
    }

    @Test func wireResultMatchesADR005() throws {
        let allowOnce = PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once").wireResult
        let outcome = allowOnce.value.base as? [String: AnyCodable]
        let inner = outcome?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(inner?["outcome"]?.value.base as? String == "selected")
        #expect(inner?["optionId"]?.value.base as? String == "once")

        let always = PermissionOption(optionId: "always", kind: .allowAlways, name: "Always allow").wireResult
        let alwaysInner = (always.value.base as? [String: AnyCodable])?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(alwaysInner?["outcome"]?.value.base as? String == "selected")
        #expect(alwaysInner?["optionId"]?.value.base as? String == "always")

        let rejected = PermissionOption(optionId: "reject", kind: .rejectOnce, name: "Reject").wireResult
        let rejectInner = (rejected.value.base as? [String: AnyCodable])?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(rejectInner?["outcome"]?.value.base as? String == "rejected")
        #expect(rejectInner?["optionId"] == nil)
    }
}
