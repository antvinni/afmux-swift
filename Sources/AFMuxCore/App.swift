import Foundation

public struct IO: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static func standard() -> IO {
        IO(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
           err: { FileHandle.standardError.write(Data($0.utf8)) })
    }
}

/// afmux main.
public func runAfm(_ argv: [String], io: IO, backend: any Backend) async -> Int32 {
    do {
        let o = try parseArgs(argv)
        if o.help {
            io.out(helpText)
            return 0
        }
        let counter = TimedCounter(base: backend.counter, timeout: o.timeout)
        let target = o.target!
        if o.command == "read" {
            guard isFile(target) else { throw AfmError(.usage, "file not found: \(target)") }
            let r = try await Reader(options: o, backend: backend, counter: counter).read(target)
            io.out(reportRead(path: target, chunks: r.chunks, tokens: r.tokens, results: r.results, json: o.json))
            return 0
        }
        let steps: [Step]
        if o.command == "run" {
            steps = try loadSteps(target)
        } else {
            guard isFile(target) else { throw AfmError(.usage, "step file not found: \(target)") }
            steps = [try parseStep(target)]
            try checkContext(steps)
        }
        let implementer = Implementer(options: o, backend: backend, counter: counter)
        var rows: [StepRow] = []
        var failed: StepFailure?
        var passed: [Step] = []
        for step in steps {
            if failed != nil {
                rows.append(StepRow(id: step.id, file: step.file, result: "skipped", attempts: 0, seconds: 0, notes: []))
                continue
            }
            let (row, failure) = try await implementer.run(step, earlier: passed)
            if row.result == "pass" { passed.append(step) }
            rows.append(row)
            failed = failure
        }
        io.out(o.json ? reportJSON(rows, failed) : reportText(rows, failed))
        return failed == nil ? 0 : 1
    } catch {
        let e = (error as? Fatal)?.error ?? mapError(error, backend: backend)
        io.err("afm: \(e.message)\n")
        return e.code.rawValue
    }
}
