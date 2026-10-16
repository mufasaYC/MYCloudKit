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
    }
}
