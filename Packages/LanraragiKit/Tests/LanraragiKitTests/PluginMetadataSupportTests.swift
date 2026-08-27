import XCTest
@testable import LanraragiKit

final class PluginMetadataSupportTests: XCTestCase {
    func testParsePatchExtractsRecursivelyNestedAndEncodedPayload() {
        let response = #"{"result":{"plugin_result":[{"ignored":true},{"data":"{\"metadata\":{\"title\":\"  New title  \",\"summary\":\" Summary \"}}"}]}}"#

        let patch = PluginMetadataSupport.parsePatch(from: response)

        XCTAssertEqual(
            patch,
            PluginMetadataPatch(title: "New title", tags: nil, summary: "Summary")
        )
    }

    func testParsePatchFormatsArrayNumberAndBooleanScalars() {
        let response = #"{"data":{"title":42,"summary":true,"new_tags":["artist:One",7,false],"tags":[null,"language:English"]}}"#

        let patch = PluginMetadataSupport.parsePatch(from: response)

        XCTAssertEqual(
            patch,
            PluginMetadataPatch(
                title: "42",
                tags: "artist:One, 7, false, language:English",
                summary: "true"
            )
        )
    }

    func testSignatureTreatsTagOrderCaseAndSpacingAsEquivalent() {
        let first = PluginMetadataSupport.signature(
            title: " Title ",
            tags: "artist:One, language:English",
            summary: " Summary "
        )
        let second = PluginMetadataSupport.signature(
            title: "Title",
            tags: " LANGUAGE:english , ARTIST:one ",
            summary: "Summary"
        )

        XCTAssertEqual(first, second)
    }

    func testOptionPresentationUsesFallbackAndRecognizesBooleanValues() {
        let parameter = PluginInfo.Parameter(
            id: "enabled",
            name: "  ",
            type: nil,
            value: " ",
            defaultValue: " yes "
        )

        XCTAssertEqual(
            PluginMetadataSupport.optionPresentation(for: parameter),
            PluginOptionPresentation(name: "Option", valueText: "yes", isBoolean: true, booleanValue: true)
        )
    }
}
