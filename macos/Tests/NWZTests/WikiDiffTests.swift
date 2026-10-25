import Testing
import NWZWiki

@Suite struct WikiDiffTests {
    @Test func paragraphs() {
        #expect(WikiDiff.unified("<p>一</p><p>二</p><p>三</p>", "<p>一</p><p>贰</p><p>三</p>") == "@@ -1,3 +1,3 @@\n 一\n-二\n+贰\n 三\n")
        #expect(WikiDiff.unified("<p>a</p>", "<p>a</p>").isEmpty)
    }
    @Test func emptyFilesAndSeparatedHunks() {
        #expect(WikiDiff.text("", "一\n") == "@@ -0,0 +1 @@\n+一\n")
        #expect(WikiDiff.text("一\n", "") == "@@ -1 +0,0 @@\n-一\n")
        let old = (1...20).map(String.init).joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "1\n", with: "A\n")
        let diff = WikiDiff.text(old, new)
        #expect(diff.components(separatedBy: "@@ -").count == 3)
        #expect(WikiDiff.text("a", "b").contains("\\ No newline at end of file"))
    }
}
