import Foundation
import FoundationModels

public struct ToolCapExceeded: Error, Equatable {
    public var max: Int
}

/// ModelManager error 1008 (the agent's sandbox), by domain and code, or by its text.
public func isSandboxError(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    var depth = 0
    while let ns = current, depth < 8 {
        if ns.domain.contains("ModelManager") && ns.code == 1008 { return true }
        current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    let text = String(describing: error) + " " + error.localizedDescription
    return text.contains("ModelManager") && text.contains("1008")
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

/// One place that turns any failure into an exit code and message (spec: Error handling).
public func mapError(_ error: Error, backend: any Backend, duringTools: Bool = false) -> AfmError {
    if let e = error as? AfmError { return e }
    if let e = error as? LanguageModelSession.ToolCallError {
        return mapError(e.underlyingError, backend: backend, duringTools: duringTools)
    }
    if let e = error as? ToolCapExceeded { return AfmError(.model, "more than \(e.max) tool calls") }
    if isSandboxError(error) { return AfmError(.sandbox, "fm is blocked by a sandbox; run afm outside it") }
    if let e = error as? GeneratedContent.ParsingError {
        return AfmError(.json, "model output is not valid JSON:\n" + e.rawContent.rstripped())
    }
    if !backend.isAvailable() { return AfmError(.unavailable, "model not available") }
    if error is CancellationError { return AfmError(.model, "cancelled") }
    if let e = error as? GenerationSchema.SchemaError { return AfmError(.usage, describe(e)) }
    if let e = error as? LanguageModelError {
        switch e {
        case .unsupportedGenerationGuide: return AfmError(.usage, describe(e))
        case .contextSizeExceeded where duringTools: return AfmError(.model, "context exceeded during tool calls")
        default: return AfmError(.model, describe(e))
        }
    }
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .unsupportedGuide: return AfmError(.usage, describe(e))
        case .assetsUnavailable: return AfmError(.unavailable, describe(e))
        case .exceededContextWindowSize where duringTools: return AfmError(.model, "context exceeded during tool calls")
        default: return AfmError(.model, describe(e))
        }
    }
    if let e = error as? SystemLanguageModel.Error, case .assetsUnavailable = e {
        return AfmError(.unavailable, describe(e))
    }
    return AfmError(.model, describe(error))
}
