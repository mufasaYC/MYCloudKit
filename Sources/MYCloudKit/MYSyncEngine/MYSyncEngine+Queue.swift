//
//  Created by Mustafa Yusuf on 16/10/26.
//

import Foundation

extension MYSyncEngine {
    /// The persisted queue of pending transactions.
    ///
    /// Records are queued from any thread while a sync pass, which runs off the main thread,
    /// removes completed transactions. Every change happens under one lock so none are lost.
    final class TransactionQueue {
        private var transactions: [Transaction]
        private let lock = NSLock()
        private let cache: Cache

        init(cache: Cache) {
            self.cache = cache
            self.transactions = cache.retrieveTransactionQueue()
        }

        /// A snapshot of the pending transactions.
        var snapshot: [Transaction] {
            lock.lock()
            defer { lock.unlock() }
            return transactions
        }

        /// Changes the queue atomically and persists it once.
        ///
        /// - Important: Never call the delegate or anything that may queue records from `body`; the lock is not reentrant.
        @discardableResult
        func mutate<T>(_ body: (inout [Transaction]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            let result = body(&transactions)
            // Written under the lock so an older snapshot can never overwrite a newer one on disk.
            cache.cacheTransactionQueue(transactions)
            return result
        }

        /// Transactions a sync pass has picked up and may be sending to CloudKit right now.
        private var sendingIDs: Set<UUID> = []

        /// Returns the queued transactions matching `isIncluded` and marks them as being sent,
        /// so a newer save of the same record doesn't remove one (and its staged assets) mid-upload.
        ///
        /// Call `finishSending(_:)` with the result once the pass is done with them.
        func beginSending(where isIncluded: (Transaction) -> Bool) -> [Transaction] {
            lock.lock()
            defer { lock.unlock() }
            let picked = transactions.filter(isIncluded)
            sendingIDs.formUnion(picked.map(\.id))
            return picked
        }

        func finishSending(_ picked: [Transaction]) {
            lock.lock()
            defer { lock.unlock() }
            sendingIDs.subtract(picked.map(\.id))
        }

        /// Appends saves to the end of the queue, removing the waiting saves of the same records they replace.
        ///
        /// - Returns: The replaced saves. Their staged assets are no longer needed.
        func enqueueSaves(_ saves: [Transaction]) -> [Transaction] {
            lock.lock()
            defer { lock.unlock() }
            let replaced = Self.enqueueSaves(saves, into: &transactions, sendingIDs: sendingIDs)
            cache.cacheTransactionQueue(transactions)
            return replaced
        }

        /// Every save holds the whole record, so a newer one makes any waiting save of the same record redundant.
        ///
        /// The newer save goes to the end, never into the older one's place: it stays after a delete of the record
        /// queued in between, and after any record it references that was queued before it.
        /// A save that is being sent right now is left alone; the newer one waits behind it.
        static func enqueueSaves(
            _ saves: [Transaction],
            into queue: inout [Transaction],
            sendingIDs: Set<UUID>
        ) -> [Transaction] {
            // When the same record is saved more than once in one call, keep the last.
            var seen: Set<Transaction.Record> = []
            let newestSaves: [Transaction] = Array(
                saves.reversed().filter { seen.insert(Self.savedRecord($0)).inserted }.reversed()
            )
            let newestSaveIDs = Set(newestSaves.map(\.id))
            let replacedInCall = saves.filter { !newestSaveIDs.contains($0.id) }

            let savedRecords = Set(newestSaves.map(Self.savedRecord))
            var replaced: [Transaction] = []
            queue.removeAll { transaction in
                guard transaction.operationType == .createOrUpdate,
                      !sendingIDs.contains(transaction.id),
                      savedRecords.contains(Self.savedRecord(transaction)) else {
                    return false
                }
                replaced.append(transaction)
                return true
            }
            queue.append(contentsOf: newestSaves)
            return replaced + replacedInCall
        }

        /// The CloudKit record a save writes to: its name, type and zone. The parent can change between saves.
        private static func savedRecord(_ transaction: Transaction) -> Transaction.Record {
            .init(
                recordName: transaction.record.recordName,
                recordType: transaction.record.recordType,
                zoneName: transaction.record.zoneName,
                parentRecordName: nil
            )
        }
    }
}
