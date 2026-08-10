import Testing
@testable import Doppelganger

struct SmokeTests {
    @Test func testTargetLinksAgainstApp() {
        _ = ChecksumAlgorithm.xxh64
        _ = RealFileSystem()
        #expect(Bool(true))
    }
}
