import Foundation
import Testing
@testable import Doppelganger

struct LocalizationTests {
    @Test func simplifiedChineseCatalogShipsCriticalSafetyAndWorkflowText() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(
            bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "zh-Hans"
            )
        )
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])

        #expect(catalog["Verified"] == "已验证")
        #expect(catalog["Failed"] == "失败")
        #expect(catalog["Do not erase the source media."] != nil)
        #expect(catalog["Projects"] == "项目")
        #expect(catalog["Help"] == "帮助")
        #expect(catalog["At least one operator profile must remain active."] != nil)
    }
}
