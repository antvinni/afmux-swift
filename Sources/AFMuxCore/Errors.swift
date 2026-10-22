import Foundation
import FoundationModels

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

/// One place that turns any failure into afmux's exit code and message. Like afmux's
/// run_fm policy: sandbox is 5, an unavailable model is 4, any other model failure is 1.
public func mapError(_ error: Error, backend: any Backend) -> AfmError {
    if let e = error as? AfmError { return e }
    if isSandboxError(error) { return AfmError(.sandbox, "fm is blocked by a sandbox; run afm outside it") }
    if !backend.isAvailable() { return AfmError(.unavailable, "model not available") }
    if error is CancellationError { return AfmError(.fail, "cancelled") }
    if let e = error as? LanguageModelSession.GenerationError, case .assetsUnavailable = e {
        return AfmError(.unavailable, describe(e))
    }
    if let e = error as? SystemLanguageModel.Error, case .assetsUnavailable = e {
        return AfmError(.unavailable, describe(e))
    }
    return AfmError(.fail, describe(error))
}
