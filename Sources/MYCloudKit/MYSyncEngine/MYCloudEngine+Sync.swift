//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit

extension MYSyncEngine {
    /// Syncs the first transaction in the queue to CloudKit.
    ///
    /// This method ensures serialized syncing of transactions to prevent issues with `CKRecord.Reference`
    /// pointing to records that haven't yet been synced. It processes one transaction at a time, based on
    /// the first element in the queue. Depending on the type of transaction, it either creates, updates,
    /// deletes a record or deletes a zone.
    ///
    /// Syncing is skipped if another sync is already in progress. On encountering retryable errors like
    /// `.zoneNotFound`, it tries to resolve them (e.g. creating the missing zone) and retries the sync.
    ///
    /// The method updates `syncState` to reflect the current progress and handles retries, caching, and errors.

    func sync() {
        /// Linear sync to avoid `CKReference` issues:
        /// if a record references another that hasn’t been uploaded, CloudKit will fail.
        guard !syncState.isActive else {
            return
        }
        
        guard let transaction = queue.first else {
            return
        }
        
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            
            /// Convert the transaction to a `CKRecord`. If conversion fails, remove from queue and retry.
            guard let ckRecord = transaction.asCKRecord(using: self.cache) else {
                self.handleError(NSError(domain: "Cannot parse CKRecord", code: 500), for: transaction)
                self.sync()
                return
            }
            
            let databaseScope = transaction.databaseScope(using: cache)
            let database = self.ckContainer.database(with: databaseScope)
            self.syncState = .syncing(queueCount: self.queue.count)
            
            var retry = false
            var lastError: Error?
            
            do {
                switch transaction.operationType {
                        
                    case .createOrUpdate:
                        self.logger.log(
                            "🌀 Syncing record '\(ckRecord.recordType)' (\(ckRecord.recordID.recordName))",
                            level: .debug
                        )

                        let result = try await database.modifyRecords(
                            saving: [ckRecord],
                            deleting: [],
                            savePolicy: .allKeys
                        )

                        if let (_, value) = result.saveResults.first {
                            switch value {
                                case .success(let record):
                                    /// Save system fields for future use (for efficient delta sync, conflict resolution, etc.)
                                    self.cache.saveEncodedSystemFields(
                                        data: record.encodedSystemFields,
                                        for: record.recordID.recordName
                                    )
                                    self.logger.log(
                                        "✅ Successfully synced '\(ckRecord.recordType)' (\(ckRecord.recordID.recordName))",
                                        level: .debug
                                    )

                                case .failure(let error):
                                    lastError = error

                                    if let error = error as? CKError {
                                        switch error.code {
                                            case .zoneNotFound, .userDeletedZone:
                                                /// Zone missing – likely first time syncing. Create it and retry.
                                                self.logger.log(
                                                    "📦 Zone '\(ckRecord.recordID.zoneID.zoneName)' not found — attempting to create it",
                                                    level: .warning
                                                )
                                                do {
                                                    try await database.save(.init(zoneID: ckRecord.recordID.zoneID))
                                                    self.logger.log(
                                                        "✅ Created zone '\(ckRecord.recordID.zoneID.zoneName)'",
                                                        level: .debug
                                                    )
                                                    retry = true
                                                } catch {
                                                    self.logger.log(
                                                        "🛑 Failed to create zone '\(ckRecord.recordID.zoneID.zoneName)'",
                                                        error: error
                                                    )
                                                    self.handleError(error, for: transaction)
                                                }
                                            default:
                                                self.logger.log(
                                                    "🛑 Failed to sync '\(ckRecord.recordType)' (\(ckRecord.recordID.recordName))",
                                                    error: error
                                                )
                                                self.handleError(error, for: transaction)
                                        }
                                    } else {
                                        self.logger.log(
                                            "🛑 Failed to sync '\(ckRecord.recordType)' (\(ckRecord.recordID.recordName))",
                                            error: error
                                        )
                                        self.handleError(error, for: transaction)
                                    }
                            }
                        }

                    case .deleteRecord:
                        self.logger.log(
                            "🗑️ Deleting record '\(ckRecord.recordID.recordName)'",
                            level: .debug
                        )
                        try await database.deleteRecord(withID: ckRecord.recordID)
                        self.logger.log(
                            "✅ Successfully deleted '\(ckRecord.recordType)' (\(ckRecord.recordID.recordName))",
                            level: .debug
                        )

                    case .deleteChildRecords:
                        self.logger.log(
                            "🧹 Deleting child records for '\(ckRecord.recordID.recordName)'",
                            level: .debug
                        )
                        try await cascadeDeleteChildRecords(
                            for: ckRecord.recordID,
                            in: databaseScope
                        )
                        self.logger.log(
                            "✅ Successfully deleted child records for '\(ckRecord.recordID.recordName)'",
                            level: .debug
                        )

                    case .deleteZone:
                        self.logger.log(
                            "🗑️ Deleting zone '\(ckRecord.recordID.zoneID.zoneName)'",
                            level: .debug
                        )
                        try await database.deleteRecordZone(withID: ckRecord.recordID.zoneID)
                        self.logger.log(
                            "✅ Successfully deleted zone '\(ckRecord.recordID.zoneID.zoneName)'",
                            level: .debug
                        )
                }
                
            } catch {
                lastError = error
                self.logger.log(
                    "🛑 Transaction failed during sync",
                    error: error
                )
                self.handleError(error, for: transaction)
            }
            
            /// Post-sync state update and retry logic
            if let lastError {
                self.syncState = .stopped(queueCount: self.queue.count, error: lastError)
                
                if retry {
                    self.sync()
                }
                
            } else {
                /// Remove cache and transaction only if the sync succeeded
                cache.removeCache(for: transaction)
                if let index = queue.firstIndex(of: transaction) {
                    self.queue.remove(at: index)
                }
                
                self.syncState = .completed(date: .now)
                self.sync()  // Proceed to next transaction
            }
        }
    }
}

extension MYSyncEngine {
    /// Handles CloudKit-related errors that occur during a transaction and determines how to proceed.
    ///
    /// This method interprets the `CKError` (or a general `Error`), categorizes it,
    /// and either retries the transaction, drops it permanently, or prepares a fix
    /// by fetching referenced records if needed.
    ///
    /// - Parameters:
    ///   - error: The `Error` encountered while syncing the transaction.
    ///   - transaction: The `MYTransaction` representing the current sync operation.
    func handleError(_ error: Error, for transaction: Transaction) {
        
        /// Internal enum to categorize how to handle different error types.
        enum KindOfError {
            case retryWithoutError   // Retry silently without logging
            case retryWithError      // Retry with error tracking and retry limit
            case dontSyncThis        // Drop from queue and attempt to recover or skip
        }

        let reason: String
        let errorKind: KindOfError

        // Special handling for CloudKit errors
        if let error = error as? CKError {
            switch error.code {
            
            // These are unexpected here — handled earlier in sync
            case .zoneNotFound, .userDeletedZone:
                reason = "None"
                errorKind = .retryWithoutError
                assertionFailure(error.localizedDescription)
            
            // Retryable errors — transient issues like network/server problems
            case .accountTemporarilyUnavailable, .networkUnavailable, .networkFailure,
                 .serverResponseLost, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .operationCancelled, .notAuthenticated:
                reason = "None"
                errorKind = .retryWithoutError

            // Setup/config errors — dev needs to fix
            case .badContainer, .badDatabase, .missingEntitlement:
                reason = "None"
                errorKind = .retryWithoutError
                assertionFailure(error.localizedDescription)

            // Invalid data — usually due to unsynced references
            case .invalidArguments:
                reason = "Invalid Arguments — this record has an unsynced reference. Return the referenced records and try syncing again."
                errorKind = .dontSyncThis

            // Unexpected — only one record is synced at a time
            case .partialFailure:
                reason = "Partial Failure — this shouldn't happen."
                errorKind = .retryWithError

            // CloudKit not supported by user's iCloud account
            case .managedAccountRestricted:
                reason = "User's account doesn't have access to CloudKit."
                errorKind = .retryWithoutError

            // Permissions issue for current user/account
            case .permissionFailure:
                reason = "User doesn't have permission to modify this record."
                errorKind = .dontSyncThis

            // Shouldn’t occur in transaction-based sync
            case .alreadyShared, .participantMayNeedVerification, .tooManyParticipants:
                reason = "Share failure — should not apply to transactions."
                errorKind = .dontSyncThis
                assertionFailure(error.localizedDescription)

            // Asset issues — usually should’ve been cleaned up after successful sync
            case .assetFileNotFound, .assetFileModified, .assetNotAvailable:
                reason = "Asset error — file was not found or has changed. Retry the sync."
                errorKind = .retryWithError

            // Save conflict between device and server record
            case .serverRecordChanged:
                reason = "Record conflict between server and device."
                errorKind = .retryWithError
                assertionFailure(error.localizedDescription)

            // Referenced record is missing in CloudKit
            case .referenceViolation:
                reason = "Reference violation — record references another that isn’t synced. Return the referenced record(s) and try again."
                errorKind = .dontSyncThis

            // Schema issues — field constraints or requirements not met
            case .constraintViolation:
                reason = "Constraint violation — check CloudKit Dashboard for required fields or rules not adhered to."
                errorKind = .dontSyncThis

            // iCloud quota/limit issues
            case .quotaExceeded:
                reason = "Quota exceeded — iCloud storage full."
                errorKind = .retryWithoutError

            case .limitExceeded:
                reason = "Limit exceeded."
                errorKind = .retryWithoutError

            // Sync tokens no longer valid
            case .changeTokenExpired:
                reason = "Change token has expired."
                errorKind = .retryWithError

            // Item doesn’t exist anymore
            case .unknownItem:
                reason = "Unknown item — possibly deleted or inaccessible."
                errorKind = .retryWithError

            case .internalError:
                reason = "Internal CloudKit error — rare."
                errorKind = .retryWithoutError

            case .incompatibleVersion:
                reason = "Incompatible CloudKit version — possibly outdated Xcode or SDK."
                errorKind = .retryWithoutError

            case .resultsTruncated:
                reason = "CloudKit response too large — truncated."
                errorKind = .retryWithError

            case .serverRejectedRequest:
                reason = "Server rejected request multiple times."
                errorKind = .retryWithError

            case .batchRequestFailed:
                reason = "Batch request failed — shouldn't happen (we sync one record at a time)."
                errorKind = .retryWithError

            // Catch-all for unknown CKError codes
            @unknown default:
                reason = "@unknown CKError — please investigate."
                errorKind = .retryWithError
            }

        } else {
            // Non-CKError — retry with logging
            reason = error.localizedDescription
            errorKind = .retryWithError
        }

        /// Removes the transaction from the queue and informs the delegate.
        /// If the error was due to missing references, re-enqueues those first.
        func removeTransactionFromQueue() {
            if let index = queue.firstIndex(of: transaction) {
                if let recordsToSync = delegate?.handleUnsyncableRecord(
                    recordID: transaction.record.recordName,
                    recordType: transaction.record.recordType,
                    reason: reason,
                    error: error
                ) {
                    let transactions = recordsToSync.map { record in
                        getCreateUpdateTransaction(for: record)
                    }
                    queue.insert(contentsOf: transactions, at: index)
                } else {
                    cache.removeCache(for: transaction)
                    queue.remove(at: index)
                }
            } else {
                assertionFailure("Transaction not found in queue.")
            }
        }

        // Handle the error based on its category
        switch errorKind {
        case .retryWithoutError:
            // Do nothing, transaction stays in queue and will retry
            break

        case .retryWithError:
            if let index = queue.firstIndex(of: transaction) {
                if queue[index].attempts >= maxRetryAttempts {
                    removeTransactionFromQueue()
                } else {
                    queue[index].attempts += 1
                }
            } else {
                assertionFailure("Transaction not found in queue.")
            }

        case .dontSyncThis:
            removeTransactionFromQueue()
        }
    }
}

extension MYSyncEngine {
    
    /// Recursively deletes all child records of a given parent `CKRecord.ID` across all record types.
    ///
    /// This function uses a breadth-first traversal to find all records that have the given record as their parent,
    /// and deletes them in a cascading manner. It relies on a `MYCloudEngineDelegate` to provide all record types.
    ///
    /// - Parameters:
    ///   - recordID: The parent `CKRecord.ID` whose child records need to be deleted.
    ///   - scope: The `CKDatabase.Scope` where the records exist (`.private`, `.shared`, etc.).
    /// - Throws: Any errors thrown during record querying or deletion.
    ///
    /// > relevant record types are returned by the delegate's `syncableRecordTypesInDependencyOrder()` method.
    private func cascadeDeleteChildRecords(for recordID: CKRecord.ID, in scope: CKDatabase.Scope) async throws {
        guard let recordTypes = delegate?.syncableRecordTypesInDependencyOrder() else {
            return
        }
        
        let database = ckContainer.database(with: scope)
        
        try await withThrowingTaskGroup(of: Void.self) { [weak self] group in
            for recordType in recordTypes {
                group.addTask {
                    let query = CKQuery(recordType: recordType, predicate: NSPredicate(format: "parent == %@", recordID))
                    let childRecordIDs = (try await self?.getRecordIDs(with: query, zoneID: recordID.zoneID, scope: scope) ?? [])

                    try await withThrowingTaskGroup(of: Void.self) { childGroup in
                        for childRecordID in childRecordIDs {
                            childGroup.addTask {
                                try await self?.cascadeDeleteChildRecords(for: childRecordID, in: scope)
                            }
                        }
                        try await childGroup.waitForAll()
                    }

                    if !childRecordIDs.isEmpty {
                        _ = try await database.modifyRecords(saving: [], deleting: childRecordIDs)
                    }
                }
            }

            try await group.waitForAll()
        }
    }
    
    /// Recursively fetches all matching `CKRecord.ID`s for a given query in a specific zone and database scope.
    ///
    /// This function handles CloudKit pagination using `CKQueryOperation.Cursor` under the hood.
    ///
    /// - Parameters:
    ///   - query: The `CKQuery` defining the predicate and sort descriptors for fetching records.
    ///   - cursor: An optional `CKQueryOperation.Cursor` if continuing a paginated query (used in recursion).
    ///   - zoneID: The `CKRecordZone.ID` indicating the zone to query within.
    ///   - scope: The `CKDatabase.Scope` (`.private` or `.shared`) determining the target database. We are not supporting `public` as of now
    /// - Returns: An array of  `CKRecord.ID`.
    /// - Throws: Rethrows any errors from the CKOperations
    private func getRecordIDs(
        with query: CKQuery,
        cursor: CKQueryOperation.Cursor? = nil,
        zoneID: CKRecordZone.ID,
        scope: CKDatabase.Scope
    ) async throws -> [CKRecord.ID] {
        
        var recordIDs: [CKRecord.ID] = []
        let database = ckContainer.database(with: scope)

        let result: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

        if let cursor {
            // Continue from the previous query cursor
            result = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
        } else {
            // Start a fresh query in the given zone
            result = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: [])
        }

        // Collect all matched record IDs
        recordIDs.append(contentsOf: result.matchResults.map { $0.0 })

        // If there's a cursor, recurse to fetch the next batch
        if let nextCursor = result.queryCursor {
            let moreIDs = try await getRecordIDs(
                with: query,
                cursor: nextCursor,
                zoneID: zoneID,
                scope: scope
            )
            recordIDs.append(contentsOf: moreIDs)
        }

        return recordIDs
    }
}
