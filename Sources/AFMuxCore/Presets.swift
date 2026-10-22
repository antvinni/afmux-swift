import Foundation

public enum Presets {
    public static let names = ["summarise", "classify", "extract", "commit-msg"]

    /// afmux e814b9e presets/*.md, stripped. PresetsTests keeps these equal to the files.
    public static let texts: [String: String] = [
        "summarise": "Summarise the input in three to five plain sentences. State what it is about and the main points. Do not add opinions, headings or bullet points.",
        "classify": "Classify the input into exactly one of these labels: {labels}. Choose the label that fits best overall. Answer with the label only.",
        "extract": "Extract the requested fields from the input. Use only information present in the input. If a field is not present, use an empty string for text or 0 for numbers.",
        "commit-msg": #"Write a git commit message for this diff. The first line is a subject like "fix(parser): handle empty input" or "docs: explain exit codes": a type (feat, fix, docs, test, refactor, chore), an optional scope in parentheses, a colon, then a short imperative summary, all under 72 characters. If the change needs explanation, add a blank line and one short paragraph saying why. Output only the commit message, with no quotes, markdown or commentary."#,
    ]

    /// `afm --list`: afmux's "%-12s %s" of each name and its first line, sorted by name.
    public static func listing() -> String {
        texts.keys.sorted().map { name in
            let first = texts[name]!.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let padded = name.count >= 12 ? name : name + String(repeating: " ", count: 12 - name.count)
            return padded + " " + first.trimmingCharacters(in: .whitespaces) + "\n"
        }.joined()
    }
}
