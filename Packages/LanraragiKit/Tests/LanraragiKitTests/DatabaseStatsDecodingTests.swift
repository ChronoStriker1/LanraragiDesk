import XCTest
@testable import LanraragiKit

final class DatabaseStatsDecodingTests: XCTestCase {
    func testDecodesTopLevelArray() throws {
        let json = """
        [
          {"tag":"female:ahegao","count":12,"weight":34},
          {"tag":"vanilla","count":"5","weight":"6"}
        ]
        """

        let stats = try JSONDecoder().decode(DatabaseStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.tags.count, 2)
        XCTAssertEqual(stats.tags[0].namespace, "female")
        XCTAssertEqual(stats.tags[0].text, "ahegao")
        XCTAssertEqual(stats.tags[0].count, 12)
        XCTAssertEqual(stats.tags[0].weight, 34)
        XCTAssertEqual(stats.tags[1].namespace, nil)
        XCTAssertEqual(stats.tags[1].text, "vanilla")
        XCTAssertEqual(stats.tags[1].count, 5)
        XCTAssertEqual(stats.tags[1].weight, 6)
    }

    func testDecodesWrappedTagsObject() throws {
        let json = """
        {"tags":[{"namespace":"artist","text":"someone","count":1,"weight":2}]}
        """

        let stats = try JSONDecoder().decode(DatabaseStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.tags, [TagStat(namespace: "artist", text: "someone", count: 1, weight: 2)])
    }
}

