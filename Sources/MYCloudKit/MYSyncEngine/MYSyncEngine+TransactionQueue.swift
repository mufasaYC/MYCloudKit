//
//  MYSyncEngine+TransactionQueue.swift
//  MYCloudKit
//

import Foundation

extension MYSyncEngine {
    /// The pending transactions, safe to change from any thread.
    ///
    /// `sync(_:)` and `delete(_:)` are called from any thread, often while a sync runs on the main
    /// actor and removes the transactions it finished. With a plain array, an append that landed
    /// between that read and write was silently lost, so the record never uploaded.
    final class TransactionQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var transactions: [Transaction]
        private let persist: ([Transaction]) -> Void

        init(_ transactions: [Transaction], persist: @escaping ([Transaction]) -> Void) {
            self.transactions = transactions
            self.persist = persist
        }

        var snapshot: [Transaction] {
            lock.lock()
            defer { lock.unlock() }
            return transactions
        }

        /// Changes the queue atomically and persists the result.
        /// Don't call into the sync delegate from `body`: it may enqueue, which would deadlock.
        @discardableResult
        func mutate<Result>(_ body: (inout [Transaction]) throws -> Result) rethrows -> Result {
            lock.lock()
            defer { lock.unlock() }
            let result = try body(&transactions)
            persist(transactions)
            return result
        }
    }
}
