import Foundation
import FoundationModels

public protocol Backend: Sendable {
    var counter: any TokenCounter { get }
    /// The model `fm respond` uses: default guardrails, general use case.
    func model() -> any LanguageModel
    func isAvailable() -> Bool
}

public struct SystemBackend: Backend {
    public init() {}

    public var counter: any TokenCounter { SystemTokenCounter() }

    public func model() -> any LanguageModel {
        SystemLanguageModel.default
    }

    public func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
    }
}
