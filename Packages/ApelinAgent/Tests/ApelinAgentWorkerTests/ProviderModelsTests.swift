@testable import ApelinAgentWorker
import ApelinProtocol
import KWWKAI
import Testing

struct ProviderModelsTests {
    @Test
    func `DeepSeek's Anthropic endpoint lists its real models, not Claude aliases`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/anthropic"),
        ])
        #expect(ProviderModels.list(.anthropic, credentials: credentials) == ["deepseek-flash", "deepseek-v4-pro"])
    }

    @Test
    func `DeepSeek reasoning levels come from kwwk, while unknown models have no guessed capability`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/anthropic"),
        ])
        let efforts = ProviderModels.reasoningEfforts(.anthropic, credentials: credentials)
        #expect(efforts["deepseek-v4-pro"]?.contains(.high) == true)
        #expect(efforts["custom-unknown"] == nil)
    }

    @Test
    func `a similarly named host does not receive DeepSeek's mapping`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com.example.org/anthropic"),
        ])
        #expect(!ProviderModels.isDeepSeek(credentials))
    }

    @Test
    func `a configured custom model remains selectable`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://example.invalid/v1"), "defaultModel": .string("custom-model"),
        ])
        #expect(ProviderModels.list(.openAICompatible, credentials: credentials) == ["custom-model"])
    }

    @Test
    func `model discovery uses the endpoint's list path and keeps the key out of the URL`() throws {
        let credentials = OAuthCredentials(access: "secret", refresh: "", expires: .max, extras: ["baseUrl": .string("https://api.deepseek.com/anthropic")])
        let request = try #require(ProviderModels.modelRequest(.anthropic, credentials: credentials))
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.url?.query == nil)
    }

    @Test
    func `OAuth accounts remain outside API-key configuration`() {
        let credentials = OAuthCredentials(access: "session", refresh: "refresh", expires: 123_456)
        #expect(!ProviderModels.usesAPIKey(.githubCopilot, credentials: credentials))
        #expect(ProviderModels.usesAPIKey(.anthropic, credentials: credentials))
    }
}
