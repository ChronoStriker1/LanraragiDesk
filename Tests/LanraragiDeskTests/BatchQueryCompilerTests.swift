import XCTest
@testable import LanraragiDesk

final class BatchQueryCompilerTests: XCTestCase {
    func testLabelsDistinguishNamespaceChecksFromExactTagChecks() {
        XCTAssertEqual(BatchQueryCondition.ConditionType.tagPresent.label, "Namespace has any tag")
        XCTAssertEqual(BatchQueryCondition.ConditionType.tagAbsent.label, "Namespace has no tags")
        XCTAssertEqual(BatchQueryCondition.ConditionType.tagEquals.label, "Exact tag is present")
        XCTAssertEqual(BatchQueryCondition.ConditionType.tagNotEquals.label, "Exact tag is absent")
    }

    func testNamespaceConditionsMatchAnyValueInNamespace() {
        let compiled = BatchQueryCompiler.compile([
            BatchQueryCondition(type: .tagPresent, namespace: "artist"),
            BatchQueryCondition(type: .tagAbsent, namespace: "language")
        ])

        XCTAssertEqual(compiled.filter, "artist:, -language:")
    }

    func testExactConditionsUseLANraragiExactTagSyntax() {
        let compiled = BatchQueryCompiler.compile([
            BatchQueryCondition(type: .tagEquals, namespace: "artist", value: "wada rco"),
            BatchQueryCondition(type: .tagNotEquals, namespace: "language", value: "japanese")
        ])

        XCTAssertEqual(compiled.filter, "artist:wada rco$, -language:japanese$")
    }

    func testTagCombinationsAreCommaDelimitedAndTrimmed() {
        let compiled = BatchQueryCompiler.compile([
            BatchQueryCondition(type: .tagPresent, namespace: "  parody  "),
            BatchQueryCondition(type: .tagEquals, namespace: " character\n", value: "  ereshkigal "),
            BatchQueryCondition(type: .tagAbsent, namespace: " group ")
        ])

        XCTAssertEqual(compiled.filter, "parody:, character:ereshkigal$, -group:")
    }

    func testIncompleteExactConditionsAreIgnoredRatherThanActingLikeNamespaceChecks() {
        let compiled = BatchQueryCompiler.compile([
            BatchQueryCondition(type: .tagEquals, namespace: "artist", value: "   "),
            BatchQueryCondition(type: .tagNotEquals, namespace: "", value: "japanese"),
            BatchQueryCondition(type: .tagPresent, namespace: "language")
        ])

        XCTAssertEqual(compiled.filter, "language:")
    }

    func testCommaInNamespaceCannotCreateAnAdditionalPredicate() {
        let invalid = BatchQueryCondition(
            type: .tagPresent,
            namespace: "artist, -language"
        )

        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.validationMessage, "Namespaces cannot contain commas.")
        XCTAssertTrue(BatchQueryCompiler.compile([invalid]).isEmpty)
    }

    func testCommaInExactValueCannotCreateAnAdditionalPredicate() {
        let invalid = BatchQueryCondition(
            type: .tagEquals,
            namespace: "artist",
            value: "wada rco, -language:japanese"
        )

        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.validationMessage, "Exact tag values cannot contain commas.")
        XCTAssertTrue(BatchQueryCompiler.compile([invalid]).isEmpty)
    }

    func testNonTagConditionsStillCompileAlongsideTagConditions() {
        let compiled = BatchQueryCompiler.compile([
            BatchQueryCondition(type: .tagEquals, namespace: "language", value: "english"),
            BatchQueryCondition(type: .serverCategory, categoryID: "  SET_123  "),
            BatchQueryCondition(type: .newOnly),
            BatchQueryCondition(type: .untaggedOnly)
        ])

        XCTAssertEqual(compiled.filter, "language:english$")
        XCTAssertEqual(compiled.categoryID, "SET_123")
        XCTAssertTrue(compiled.newOnly)
        XCTAssertTrue(compiled.untaggedOnly)
        XCTAssertFalse(compiled.isEmpty)
    }

    func testLegacySavedEqualsConditionKeepsItsRawValueAndGainsExactSemantics() throws {
        let json = #"{"id":"76BB9738-47AD-4B2A-B058-91EB34F9A0C2","type":"tagEquals","namespace":"artist","value":"wada rco","categoryID":""}"#
        let condition = try JSONDecoder().decode(BatchQueryCondition.self, from: Data(json.utf8))

        XCTAssertEqual(condition.type, .tagEquals)
        XCTAssertEqual(BatchQueryCompiler.compile([condition]).filter, "artist:wada rco$")
    }
}
