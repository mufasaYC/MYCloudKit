import CloudKit
import XCTest
@testable import MYCloudKit

final class QueueConcurrencyTests: XCTestCase {
    private typealias Transaction = MYSyncEngine.Transaction

    func testConcurrentAppendsAreKeptWhileCompletedTransactionsAreRemoved() {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let queue = MYSyncEngine.TransactionQueue(cache: makeCache(at: directoryURL))
        let completed = (0..<200).map { makeTransaction(recordName: "completed-\($0)") }
        queue.mutate { $0.append(contentsOf: completed) }
        let completedIDs = Set(completed.map(\.id))

        let appended = (0..<500).map { makeTransaction(recordName: "new-\($0)") }
        DispatchQueue.concurrentPerform(iterations: appended.count + 1) { index in
            if index == appended.count {
                // A sync pass finishing while records are queued from other threads.
                queue.mutate { $0.removeAll { completedIDs.contains($0.id) } }
            } else {
                queue.mutate { $0.append(appended[index]) }
            }
        }

        XCTAssertEqual(Set(queue.snapshot.map(\.id)), Set(appended.map(\.id)))
    }

    func testQueueIsPersisted() {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let transaction = makeTransaction(recordName: "persisted")
        MYSyncEngine.TransactionQueue(cache: makeCache(at: directoryURL)).mutate { $0.append(transaction) }

        XCTAssertEqual(
            MYSyncEngine.TransactionQueue(cache: makeCache(at: directoryURL)).snapshot.map(\.id),
            [transaction.id]
        )
    }

    func testDiscardingQueuedChangesFiltersByGroup() {
        let journal = makeTransaction(recordName: "journal", zoneName: "Journals")
        let ungrouped = makeTransaction(recordName: "ungrouped", zoneName: nil)

        XCTAssertTrue(MYSyncEngine.transaction(journal, isIn: ["Journals"]))
        XCTAssertFalse(MYSyncEngine.transaction(journal, isIn: ["Zens"]))
        XCTAssertFalse(MYSyncEngine.transaction(ungrouped, isIn: ["Journals"]))
        XCTAssertTrue(MYSyncEngine.transaction(ungrouped, isIn: nil))
    }

    private func makeTransaction(recordName: String, zoneName: String? = "Journals") -> Transaction {
        .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: "Item", zoneName: zoneName, parentRecordName: nil),
            properties: [:]
        )
    }

    private func makeCache(at directoryURL: URL) -> MYSyncEngine.Cache {
        .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
    }
}
