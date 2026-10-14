import XCTest
@testable import MYCloudKit

final class TransactionQueueTests: XCTestCase {
    private func transaction(_ recordName: String) -> MYSyncEngine.Transaction {
        .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: "Item", zoneName: "Zone", parentRecordName: nil),
            properties: [:]
        )
    }

    /// The race that lost uploads: records are queued from other threads while a sync
    /// removes the transactions it finished. Every queued record must survive.
    func testConcurrentEnqueueWhileSyncRemovesFinishedTransactions() {
        let finished = (0..<200).map { transaction("finished-\($0)") }
        let queue = MYSyncEngine.TransactionQueue(finished) { _ in }
        let finishedIDs = Set(finished.map(\.id))

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 100) {
                queue.mutate { $0.removeAll { finishedIDs.contains($0.id) } }
            }
            queue.mutate { $0.append(transaction("new-\(index)")) }
        }
        queue.mutate { $0.removeAll { finishedIDs.contains($0.id) } }

        let remaining = queue.snapshot
        XCTAssertEqual(remaining.count, 1_000)
        XCTAssertEqual(Set(remaining.map(\.record.recordName)).count, 1_000)
    }

    func testEveryChangeIsPersisted() {
        var persisted: [MYSyncEngine.Transaction] = []
        let queue = MYSyncEngine.TransactionQueue([]) { persisted = $0 }

        queue.mutate { $0.append(transaction("a")) }
        queue.mutate { $0.append(transaction("b")) }
        queue.mutate { $0.removeFirst() }

        XCTAssertEqual(persisted.map(\.record.recordName), ["b"])
    }
}
