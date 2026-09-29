import CloudKit
import XCTest
@testable import MYCloudKit

final class StagedAssetTests: XCTestCase {
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

    // MARK: - Atomic staging

    func testStagesAssetInsideTransactionFolder() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("v1".utf8)), using: cache)
        )

        guard case .asset(let url)?? = transaction.properties["payload"] else {
            return XCTFail("Expected a staged asset")
        }
        let stagedURL = try XCTUnwrap(url)
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data("v1".utf8))
        XCTAssertEqual(transaction.properties["title"], .string("Title"))
    }

    func testAssetWriteFailureProducesNoTransaction() throws {
        let cache = makeCache()
        // A file where the staging directory should be makes every asset write fail.
        try Data().write(to: directoryURL.appendingPathComponent("transactions"))

        XCTAssertNil(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("v1".utf8)), using: cache)
        )
    }

    func testNilAssetStillProducesTransaction() throws {
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: nil), using: makeCache())
        )
        XCTAssertEqual(transaction.properties["payload"], .asset(nil))
    }

    // MARK: - Container path changes

    func testStagedAssetIsResolvedAgainstCurrentCacheDirectory() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("v1".utf8)), using: cache)
        )
        let staleURL = URL(fileURLWithPath: "/old/container/Documents/MYCloudKit/transactions")
            .appendingPathComponent(transaction.id.uuidString)
            .appendingPathComponent("payload")

        let resolvedURL = cache.resolvedAssetURL(staleURL, for: transaction)

        XCTAssertEqual(try Data(contentsOf: resolvedURL), Data("v1".utf8))
    }

    func testCallerProvidedFileURLIsNotRewritten() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: nil), using: cache)
        )
        let callerURL = URL(fileURLWithPath: "/app/files/transactions/other-id/photo.jpg")

        XCTAssertEqual(cache.resolvedAssetURL(callerURL, for: transaction), callerURL)
    }

    func testCKRecordUsesResolvedAssetURL() throws {
        let cache = makeCache()
        var transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("v1".utf8)), using: cache)
        )
        let staleURL = URL(fileURLWithPath: "/old/container/MYCloudKit/transactions")
            .appendingPathComponent(transaction.id.uuidString)
            .appendingPathComponent("payload")
        transaction.properties["payload"] = .asset(staleURL)

        let record = try XCTUnwrap(transaction.asCKRecord(using: cache))
        let asset = try XCTUnwrap(record["payload"] as? CKAsset)

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset.fileURL)), Data("v1".utf8))
    }

    func testQueuePersistedByPreviousVersionStillDecodes() throws {
        let cache = makeCache()
        // Written in the on-disk format used before staged asset URLs were re-anchored.
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","operationType":{"createOrUpdate":{}},\
        "record":{"recordName":"r1","recordType":"Payload","zoneName":"Zone"},\
        "properties":{"payload":{"asset":{"_0":"file:///old/MYCloudKit/transactions/\(id.uuidString)/payload"}},\
        "title":{"string":{"_0":"Title"}}},"attempts":1,"createdAt":0}]
        """
        try Data(json.utf8).write(to: directoryURL.appendingPathComponent("transaction_cache.json"))

        let queue = cache.retrieveTransactionQueue()

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.id, id)
        XCTAssertEqual(queue.first?.attempts, 1)
        guard case .asset(let url)?? = queue.first?.properties["payload"], let url else {
            return XCTFail("Expected an asset URL")
        }
        XCTAssertEqual(
            cache.resolvedAssetURL(url, for: queue[0]),
            directoryURL
                .appendingPathComponent("transactions")
                .appendingPathComponent(id.uuidString)
                .appendingPathComponent("payload")
        )
    }

    // MARK: - Cleanup

    func testRemoveCacheDeletesStagedFolder() throws {
        let cache = makeCache()
        let transaction = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("v1".utf8)), using: cache)
        )

        cache.removeCache(for: transaction)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL(for: transaction.id).path))
    }

    func testOrphanSweepKeepsQueuedAndRecentFolders() throws {
        let cache = makeCache()
        let queued = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("queued".utf8)), using: cache)
        )
        let orphan = try XCTUnwrap(
            MYSyncEngine.createUpdateTransaction(for: Payload(data: Data("orphan".utf8)), using: cache)
        )
        let later = Date.now.addingTimeInterval(2 * 24 * 60 * 60)

        // Recent orphans survive, since another process may still be staging them.
        cache.removeOrphanedTransactionFolders(keeping: [queued.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL(for: orphan.id).path))

        cache.removeOrphanedTransactionFolders(keeping: [queued.id], now: later)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL(for: orphan.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL(for: queued.id).path))
    }

    // MARK: - Helpers

    private func makeCache() -> MYSyncEngine.Cache {
        .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }

    private func folderURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent("transactions")
            .appendingPathComponent(id.uuidString)
    }
}

private struct Payload: MYRecordConvertible {
    let data: Data?

    var myRecordID: String { "r1" }
    var myRecordType: String { "Payload" }
    var myRootGroupID: String? { "Zone" }
    var myProperties: [String: MYRecordValue] {
        ["payload": .asset(data), "title": .string("Title")]
    }
}
