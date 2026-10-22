import Testing
@testable import AFMuxCore

@Test(arguments: [
    ("abc", "'abc'"),
    ("it's", "\"it's\""),
    ("say \"hi\"", "'say \"hi\"'"),
    ("both ' and \"", "'both \\' and \"'"),
    ("a\\b", "'a\\\\b'"),
    ("tab\there\nnl\r", "'tab\\there\\nnl\\r'"),
    ("caf\u{e9}", "'caf\u{e9}'"),
    ("\u{7}", "'\\x07'"),
    ("\u{200b}", "'\\u200b'"),
    ("\u{1F600}", "'\u{1F600}'"),
])
func reprMatchesPython(input: String, expected: String) {
    #expect(pyRepr(input) == expected)
}

@Test func reprOfNilIsNone() {
    #expect(pyRepr(nil) == "None")
}

@Test func percentGMatchesPython() {
    #expect(pyG(120) == "120")
    #expect(pyG(0.5) == "0.5")
    #expect(pyG(1e-7) == "1e-07")
}

@Test func rstrippedRemovesTrailingWhitespaceOnly() {
    #expect("  a b \n\n\t".rstripped() == "  a b")
}
