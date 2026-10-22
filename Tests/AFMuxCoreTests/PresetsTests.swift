import Foundation
import Testing
@testable import AFMuxCore

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func presetConstantsMatchFiles() throws {
    for name in Presets.names {
        let file = try String(contentsOf: packageRoot.appendingPathComponent("presets/\(name).md"), encoding: .utf8)
        #expect(Presets.texts[name] == file.trimmingCharacters(in: .whitespacesAndNewlines), "\(name)")
    }
}

@Test func listingIsSortedAndPadded() {
    let lines = Presets.listing().split(separator: "\n").map(String.init)
    #expect(lines.map { $0.split(separator: " ")[0] } == ["classify", "commit-msg", "extract", "summarise"])
    #expect(lines[3].hasPrefix("summarise    Summarise the input"))
    #expect(Presets.listing().hasSuffix("\n"))
}
