import Testing
@testable import Minidisc

@Suite("LRCParser")
struct LRCParserTests {
    @Test func parsesFractionsOffsetsMultipleTimestampsAndEnhancedTags() throws {
        let source = """
        [ar:Woodkid]
        [offset:+250]
        [00:01.2]First line
        [00:02.34][00:03.456]Second <00:02.50>line
        """

        let parsed = try #require(LRCParser.parse(source))

        #expect(parsed.offsetMilliseconds == 250)
        #expect(parsed.lines.map(\.startMilliseconds) == [1_200, 2_340, 3_456])
        #expect(parsed.lines.map(\.value) == ["First line", "Second line", "Second line"])
    }

    @Test func rejectsContentWithoutUsableTimedLines() {
        #expect(LRCParser.parse("[ar:Artist]\n[00:02.00]") == nil)
    }
}
