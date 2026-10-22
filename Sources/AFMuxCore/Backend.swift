import Foundation
import FoundationModels

public protocol Backend: Sendable {
    var counter: any TokenCounter { get }
    func model(guardrails: String, useCase: String) -> any LanguageModel
    func isAvailable() -> Bool
}

public struct SystemBackend: Backend {
    public init() {}

    public var counter: any TokenCounter { SystemTokenCounter() }

    public func model(guardrails: String, useCase: String) -> any LanguageModel {
        SystemLanguageModel(
            useCase: useCase == "content-tagging" ? .contentTagging : .general,
            guardrails: guardrails == "default" ? .default : .permissiveContentTransformations)
    }

    public func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
    }
}
