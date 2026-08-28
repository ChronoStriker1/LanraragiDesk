import Foundation
import XCTest
@testable import LanraragiKit

final class PluginMetadataSupportTests: XCTestCase {
    func testQueuedResultDecodesSuccessfulMetadataPatchFromMinionDetail() throws {
        let status = try decodeStatus(
            #"{"state":"finished","result":{"data":{"new_tags":"","title":"plugin fixture"},"error":null,"success":1,"type":"metadata"}}"#
        )

        XCTAssertEqual(
            PluginMetadataSupport.queuedResult(from: status),
            .patch(PluginMetadataPatch(title: "plugin fixture", tags: nil, summary: nil))
        )
    }

    func testQueuedResultRecognizesSuccessfulNoOp() throws {
        let status = try decodeStatus(
            #"{"state":"finished","result":{"data":{"new_tags":"","title":"  ","summary":""},"error":null,"success":1,"type":"metadata"}}"#
        )

        XCTAssertEqual(PluginMetadataSupport.queuedResult(from: status), .noChanges)
    }

    func testQueuedResultRecognizesPluginFailureDespiteFinishedJobState() throws {
        let status = try decodeStatus(
            #"{"state":"finished","result":{"data":{"title":"must not apply"},"error":"lookup failed","success":0,"type":"metadata"}}"#
        )

        XCTAssertEqual(
            PluginMetadataSupport.queuedResult(from: status),
            .failed(message: "lookup failed")
        )
    }

    func testQueuedResultDistinguishesMissingMalformedAndNonMetadataResults() throws {
        let missing = try decodeStatus(#"{"state":"finished"}"#)
        let malformed = try decodeStatus(
            #"{"state":"finished","result":{"data":"not metadata JSON","error":null,"success":1,"type":"metadata"}}"#
        )
        let missingType = try decodeStatus(
            #"{"state":"finished","result":{"data":{"title":"ignored"},"error":null,"success":1}}"#
        )
        let nonMetadata = try decodeStatus(
            #"{"state":"finished","result":{"data":{"message":"done"},"error":null,"success":1,"type":"script"}}"#
        )

        XCTAssertEqual(PluginMetadataSupport.queuedResult(from: missing), .missing)
        XCTAssertEqual(PluginMetadataSupport.queuedResult(from: malformed), .malformed)
        XCTAssertEqual(PluginMetadataSupport.queuedResult(from: missingType), .malformed)
        XCTAssertEqual(
            PluginMetadataSupport.queuedResult(from: nonMetadata),
            .nonMetadata(type: "script")
        )
    }

    func testQueuedResultUsesFailedMinionStateAndTopLevelError() throws {
        let status = try decodeStatus(
            #"{"state":"failed","error":"worker crashed","result":{"success":1,"type":"metadata","data":{"title":"must not apply"}}}"#
        )

        XCTAssertEqual(
            PluginMetadataSupport.queuedResult(from: status),
            .failed(message: "worker crashed")
        )
    }

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

    private func decodeStatus(_ json: String) throws -> MinionStatus {
        try JSONDecoder().decode(MinionStatus.self, from: Data(json.utf8))
    }
}
