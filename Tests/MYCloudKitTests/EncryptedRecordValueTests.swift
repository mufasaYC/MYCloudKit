import CloudKit
import XCTest
@testable import MYCloudKit

final class EncryptedRecordValueTests: XCTestCase {
    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    func testEncryptedValuesAreWrittenToEncryptedFields() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Note(), using: cache)
        )

        let record = try XCTUnwrap(transaction.asCKRecord(using: cache))

        XCTAssertNil(record["body"])
        XCTAssertNil(record["views"])
        XCTAssertNil(record["tags"])
        XCTAssertEqual(record.encryptedValues["body"] as? String, "Secret")
        XCTAssertEqual(record.encryptedValues["views"] as? Int, 3)
        XCTAssertEqual(record.encryptedValues["tags"] as? [String], ["a", "b"])
        XCTAssertEqual(record["title"] as? String, "Title")
        XCTAssertNil(record.encryptedValues["title"])
    }

    func testFetchedRecordReadsEncryptedValues() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Note(), using: cache)
        )
        let fetched = MYSyncEngine.FetchedRecord(record: try XCTUnwrap(transaction.asCKRecord(using: cache)))

        let body: String? = fetched.value(for: "body")
        let views: Int? = fetched.value(for: "views")
        let metadata: Metadata? = fetched.value(for: "metadata")
        let title: String? = fetched.value(for: "title")

        XCTAssertEqual(body, "Secret")
        XCTAssertEqual(views, 3)
        XCTAssertEqual(metadata, Metadata(width: 2))
        XCTAssertEqual(title, "Title")
    }

    func testEncryptedAssetStaysAnAsset() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Note(), using: cache)
        )

        let record = try XCTUnwrap(transaction.asCKRecord(using: cache))

        XCTAssertNotNil(record["photo"] as? CKAsset)
        XCTAssertFalse(transaction.encryptedKeys?.contains("photo") ?? false)
    }

    func testEncryptedKeysSurviveTheQueueCache() throws {
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Note(), using: makeCache())
        )

        let data = try JSONEncoder().encode(transaction)
        let decoded = try JSONDecoder().decode(MYSyncEngine.Transaction.self, from: data)

        XCTAssertEqual(decoded.encryptedKeys, ["body", "views", "tags", "metadata"])
    }

    func testUnencryptedTransactionsKeepTheCachedFormat() throws {
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Plain(), using: makeCache())
        )

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(transaction), encoding: .utf8))

        XCTAssertNil(transaction.encryptedKeys)
        XCTAssertFalse(json.contains("encryptedKeys"))
    }

    private func makeCache() -> MYSyncEngine.Cache {
        .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }
}

private struct Metadata: Codable, Equatable {
    let width: Int
}

private struct Note: MYRecordConvertible {
    var myRecordID: String { "n1" }
    var myRecordType: String { "Note" }
    var myRootGroupID: String? { "Zone" }
    var myProperties: [String: MYRecordValue] {
        [
            "title": .string("Title"),
            "body": .encrypted(.string("Secret")),
            "views": .encrypted(.int(3)),
            "tags": .encrypted(.array([.string("a"), .string("b")])),
            "metadata": .encrypted(.codable(Metadata(width: 2))),
            "photo": .encrypted(.asset(Data("photo".utf8)))
        ]
    }
}

private struct Plain: MYRecordConvertible {
    var myRecordID: String { "p1" }
    var myRecordType: String { "Plain" }
    var myRootGroupID: String? { "Zone" }
    var myProperties: [String: MYRecordValue] {
        ["title": .string("Title")]
    }
}
