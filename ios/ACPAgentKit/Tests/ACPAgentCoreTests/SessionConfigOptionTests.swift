import Foundation
import Testing
@testable import ACPAgentCore

@Suite
struct SessionConfigOptionTests {
    private func decodeUpdate(_ json: String) throws -> SessionUpdateNotification {
        try JSONDecoder().decode(SessionUpdateNotification.self, from: Data(json.utf8))
    }

    @Test func decodesSelectConfigOptionFromWireShape() throws {
        let list = try JSONDecoder().decode(SessionConfigOptionList.self, from: Data(#"""
        [
          {
            "id": "model",
            "name": "Model",
            "category": "model",
            "type": "select",
            "currentValue": "model-1",
            "options": [
              {"value": "model-1", "name": "Model 1", "description": "Fast"},
              {"value": "model-2", "name": "Model 2"}
            ]
          },
          {
            "id": "mode",
            "name": "Session Mode",
            "description": "Permission posture",
            "category": "mode",
            "type": "select",
            "currentValue": "build",
            "options": [
              {"value": "build", "name": "Build"},
              {"value": "plan", "name": "Plan"}
            ]
          }
        ]
        """#.utf8))
        let options = list.options

        #expect(options.count == 2)
        #expect(options[0].id == "model")
        #expect(options[0].type == .select)
        #expect(options[0].category == "model")
        #expect(options[0].currentValue == .string("model-1"))
        #expect(options[0].options?[0] == SessionConfigOptionValue(value: "model-1", name: "Model 1", description: "Fast"))
        #expect(options[1].currentValue == .string("build"))
        #expect(options[1].description == "Permission posture")
    }

    @Test func ignoresUnknownConfigOptionType() throws {
        let list = try JSONDecoder().decode(SessionConfigOptionList.self, from: Data(#"""
        [
          {"id": "model", "name": "Model", "type": "select", "currentValue": "a", "options": [{"value": "a", "name": "A"}]},
          {"id": "brave", "name": "Brave", "type": "boolean", "currentValue": true},
          {"id": "future", "name": "Future", "type": "slider", "currentValue": "1"}
        ]
        """#.utf8))

        // Unknown / unadvertised types are skipped so Agents keep their defaults.
        #expect(list.options.map(\.id) == ["model"])
    }

    @Test func configOptionUpdateReplacesListWholesale() throws {
        let notification = try decodeUpdate(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"config_option_update","configOptions":[
          {"id":"model","name":"Model","category":"model","type":"select","currentValue":"model-2","options":[
            {"value":"model-1","name":"Model 1"},
            {"value":"model-2","name":"Model 2"}
          ]}
        ]}}
        """#)

        guard case .configOptions(let options) = notification.update else {
            Issue.record("Expected configOptions, got \(notification.update)")
            return
        }
        #expect(options.count == 1)
        #expect(options[0].currentValue == .string("model-2"))
        #expect(options[0].currentDisplayName == "Model 2")
    }

    @Test func currentModeUpdateDecodesModeId() throws {
        let notification = try decodeUpdate(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","modeId":"code"}}
        """#)
        #expect(notification.update == .currentMode(modeId: "code"))
    }

    @Test func currentModeUpdateAcceptsLegacyCurrentModeId() throws {
        let notification = try decodeUpdate(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","currentModeId":"build"}}
        """#)
        #expect(notification.update == .currentMode(modeId: "build"))
    }

    @Test func decodesModesState() throws {
        let modes = try JSONDecoder().decode(SessionModeState.self, from: Data(#"""
        {
          "currentModeId": "ask",
          "availableModes": [
            {"id": "ask", "name": "Ask", "description": "Ask first"},
            {"id": "code", "name": "Code"}
          ]
        }
        """#.utf8))

        #expect(modes.currentModeId == "ask")
        #expect(modes.availableModes.count == 2)
        #expect(modes.currentDisplayName == "Ask")
        #expect(modes.asSelectConfigOption().id == "mode")
        #expect(modes.asSelectConfigOption().currentValue == .string("ask"))
    }

    @Test func chipSummaryPrefersModelCategoryThenFirstOption() {
        let modelAndMode: [SessionConfigOption] = [
            SessionConfigOption(
                id: "mode", name: "Mode", category: "mode", type: .select,
                currentValue: .string("build"),
                options: [SessionConfigOptionValue(value: "build", name: "Build")]
            ),
            SessionConfigOption(
                id: "model", name: "Model", category: "model", type: .select,
                currentValue: .string("m1"),
                options: [SessionConfigOptionValue(value: "m1", name: "Claude")]
            ),
        ]
        #expect(SessionConversation.chipSummary(configOptions: modelAndMode, modes: nil) == "Claude")

        let modeOnly: [SessionConfigOption] = [
            SessionConfigOption(
                id: "mode", name: "Mode", category: "mode", type: .select,
                currentValue: .string("build"),
                options: [SessionConfigOptionValue(value: "build", name: "Build")]
            ),
        ]
        #expect(SessionConversation.chipSummary(configOptions: modeOnly, modes: nil) == "Build")

        let modes = SessionModeState(
            currentModeId: "ask",
            availableModes: [SessionMode(id: "ask", name: "Ask")]
        )
        #expect(SessionConversation.chipSummary(configOptions: [], modes: modes) == "Ask")
        #expect(SessionConversation.chipSummary(configOptions: [], modes: nil) == nil)
    }

    @Test func selectableOptionsPreferConfigOptionsOverModes() {
        let options = [
            SessionConfigOption(
                id: "model", name: "Model", category: "model", type: .select,
                currentValue: .string("m1"),
                options: [SessionConfigOptionValue(value: "m1", name: "M1")]
            ),
        ]
        let modes = SessionModeState(
            currentModeId: "ask",
            availableModes: [SessionMode(id: "ask", name: "Ask")]
        )
        let selectable = SessionConversation.selectableConfigOptions(configOptions: options, modes: modes)
        #expect(selectable.map(\.id) == ["model"])

        let fallback = SessionConversation.selectableConfigOptions(configOptions: [], modes: modes)
        #expect(fallback.map(\.id) == ["mode"])
        #expect(fallback[0].options?.map(\.value) == ["ask"])
    }
}
