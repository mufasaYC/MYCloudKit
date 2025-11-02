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

    func sync() async -> SyncState {
        /// Batch sync in order of what is returned in `MYSyncDelegate.syncableRecordTypesInDependencyOrder()`
        guard let orderedRecordTypes = delegate?.syncableRecordTypesInDependencyOrder(),
              !orderedRecordTypes.isEmpty else {
            assertionFailure("MYSyncDelegate must be set before syncing data, and `syncableRecordTypesInDependencyOrder` must not return an empty array")
            return .idle
        }
        
        var syncingRecordType: String = ""
        var batchedPrivateTransactions: [[Transaction]] = []
        var batchedSharedTransactions: [[Transaction]] = []
        
        for recordType in orderedRecordTypes {
            var privateTransactions: [Transaction] = []
            var sharedTransactions: [Transaction] = []
            
            for transaction in self.queue {
                if transaction.record.recordType == recordType {
                    switch transaction.databaseScope(using: cache) {
                        case .private:
                            privateTransactions.append(transaction)
                        case .shared:
                            sharedTransactions.append(transaction)
                        default:
                            assertionFailure("Unsupported database scope")
                    }
                }
            }
            
            if privateTransactions.isEmpty && sharedTransactions.isEmpty {
                /// good, continue to the next record type sync all that depend on it are synced
            } else {
                syncingRecordType = recordType
                batchedPrivateTransactions.append(contentsOf: privateTransactions.chunked(into: 200))
                batchedSharedTransactions.append(contentsOf: sharedTransactions.chunked(into: 200))
                /// break so that all these record types can be synced and their errors handled before syncing any records that might depend on it
                break
            }
        }
        let batchedTransactions = batchedPrivateTransactions + batchedSharedTransactions
        var transactionsCompleted: [Transaction] = []
        var transactionsFailed: [Transaction: Error] = [:]
        for transactions in batchedTransactions {
            guard let databaseScope = transactions.first?.databaseScope(using: cache) else {
                continue
            }
            let database = ckContainer.database(with: databaseScope)
            var recordIDTransactionMap: [CKRecord.ID: Transaction] = [:]
            var zoneIDTransactionMap: [CKRecordZone.ID: Transaction] = [:]
            var recordsToSave: [CKRecord] = []
            var recordsToDelete: [CKRecord.ID] = []
            var zonesToDelete: [CKRecordZone.ID] = []
            var recordsToCascadeDelete: [CKRecord.ID] = []
            
            for transaction in transactions {
                /// Convert the transaction to a `CKRecord`. If conversion fails, remove from queue and retry.
                guard let ckRecord = transaction.asCKRecord(using: self.cache) else {
                    self.handleError(NSError(domain: "Cannot parse CKRecord", code: 500), for: transaction)
                    continue
                }
                switch transaction.operationType {
                    case .createOrUpdate:
                        if recordIDTransactionMap[ckRecord.recordID] == nil {
                            recordsToSave.append(ckRecord)
                            recordIDTransactionMap.updateValue(transaction, forKey: ckRecord.recordID)
                        }
                    case .deleteZone:
                        if zoneIDTransactionMap[ckRecord.recordID.zoneID] == nil {
                            zonesToDelete.append(ckRecord.recordID.zoneID)
                            zoneIDTransactionMap.updateValue(transaction, forKey: ckRecord.recordID.zoneID)
                        }
                    case .deleteRecord:
                        if recordIDTransactionMap[ckRecord.recordID] == nil {
                            recordsToDelete.append(ckRecord.recordID)
                            recordIDTransactionMap.updateValue(transaction, forKey: ckRecord.recordID)
                        }
                    case .deleteChildRecords:
                        recordsToCascadeDelete.append(ckRecord.recordID)
                        recordIDTransactionMap.updateValue(transaction, forKey: ckRecord.recordID)
                }
            }
            
            self.logger.log(
                "🌀 Syncing \(recordsToSave.count) '\(syncingRecordType)'\n🗑️ Deleting \(recordsToDelete.count) '\(syncingRecordType)'",
                level: .debug
            )
            var missingZoneIDs: [CKRecordZone.ID] = []
            
            
            // MARK: Save & Delete Records
            if !recordsToSave.isEmpty || !recordsToDelete.isEmpty {
                /// making sure if there is a save and delete in the same request, respect the delete and mark the save as completed
                recordsToSave.forEach { record in
                    if let index = recordsToDelete.firstIndex(of: record.recordID) {
                        recordsToSave.remove(at: index)
                        if let transaction = recordIDTransactionMap[record.recordID] {
                            transactionsCompleted.append(transaction)
                        } else {
                            assertionFailure("How?")
                        }
                    }
                }
                do {
                    let modifyRecordsResult = try await database.modifyRecords(
                        saving: recordsToSave,
                        deleting: recordsToDelete,
                        savePolicy: .allKeys,
                        atomically: false
                    )
                    
                    var successSavesCount: Int = .zero
                    var failureSavesCount: Int = .zero
                    
                    var successDeleteCount: Int = .zero
                    var failureDeleteCount: Int = .zero
                    
                    for result in modifyRecordsResult.saveResults {
                        let recordID = result.key
                        guard let transaction = recordIDTransactionMap[recordID] else {
                            assertionFailure("How?")
                            continue
                        }
                        switch result.value {
                            case .success(let record):
                                self.cache.saveEncodedSystemFields(
                                    data: record.encodedSystemFields,
                                    for: record.recordID.recordName
                                )
                                successSavesCount += 1
                                transactionsCompleted.append(transaction)
                            case .failure(let error):
                                if let error = error as? CKError {
                                    switch error.code {
                                        case .zoneNotFound, .userDeletedZone:
                                            /// Zone missing – likely first time syncing. Create it and retry.
                                            self.logger.log(
                                                "📦 Zone '\(recordID.zoneID.zoneName)' not found — attempting to create it",
                                                level: .warning
                                            )
                                            if !missingZoneIDs.contains(recordID.zoneID) {
                                                missingZoneIDs.append(recordID.zoneID)
                                            }
                                        default:
                                            transactionsFailed.updateValue(error, forKey: transaction)
                                            failureSavesCount += 1
                                    }
                                } else {
                                    transactionsFailed.updateValue(error, forKey: transaction)
                                    failureSavesCount += 1
                                }
                        }
                    }
                    
                    if successSavesCount > 0 {
                        self.logger.log(
                            "✅ Successfully synced \(successSavesCount) '\(recordsToSave.first?.recordType ?? "Unknown")'",
                            level: .debug
                        )
                    }
                    
                    if failureDeleteCount > 0 {
                        self.logger.log(
                            "🛑 Failed to sync \(failureDeleteCount) '\(recordsToSave.first?.recordType ?? "Unknown")'",
                        )
                    }
                    
                    for result in modifyRecordsResult.deleteResults {
                        let recordID = result.key
                        guard let transaction = recordIDTransactionMap[recordID] else {
                            assertionFailure("How?")
                            continue
                        }
                        switch result.value {
                            case .success:
                                transactionsCompleted.append(transaction)
                                successDeleteCount += 1
                            case .failure(let error):
                                if let error = error as? CKError {
                                    switch error.code {
                                        case .userDeletedZone, .permissionFailure, .zoneNotFound:
                                            /// false positives
                                            self.cache.removeCache(for: transaction)
                                            successDeleteCount += 1
                                        default:
                                            transactionsFailed.updateValue(error, forKey: transaction)
                                            failureDeleteCount += 1
                                    }
                                } else {
                                    transactionsFailed.updateValue(error, forKey: transaction)
                                    failureSavesCount += 1
                                }
                        }
                    }
                    
                    if successDeleteCount > 0 {
                        self.logger.log(
                            "✅ Successfully deleted \(successDeleteCount) '\(syncingRecordType)'",
                            level: .debug
                        )
                    }
                    
                    if failureDeleteCount > 0 {
                        self.logger.log(
                            "🛑 Failed to delete \(failureDeleteCount) '\(syncingRecordType)'",
                        )
                    }
                } catch {
                    self.logger.log(
                        "🛑 Failed to modifyReccords for '\(syncingRecordType)'\nSave: \(recordsToSave.count)\nDelete: \(recordsToDelete)",
                    )
                    
                    transactions.forEach {
                        transactionsFailed.updateValue(error, forKey: $0)
                    }
                }
            }
            
            // MARK: Save & Delete Zones
            if !missingZoneIDs.isEmpty || !zonesToDelete.isEmpty {
                /// making sure if there is a save and delete in the same request, respect the delete and mark the save as completed
                missingZoneIDs.forEach { zoneID in
                    if let index = zonesToDelete.firstIndex(of: zoneID) {
                        missingZoneIDs.remove(at: index)
                    }
                }
                do {
                    let modifyRecordZonesResult = try await database.modifyRecordZones(
                        saving: missingZoneIDs.map { .init(zoneID: $0) },
                        deleting: zonesToDelete
                    )
                    for result in modifyRecordZonesResult.saveResults {
                        let zoneID = result.key
                        switch result.value {
                            case .success:
                                self.logger.log(
                                    "✅ Created zone '\(zoneID.zoneName)'",
                                    level: .debug
                                )
                            case .failure(let error):
                                self.logger.log(
                                    "🛑 Failed to create zone '\(zoneID.zoneName)'",
                                    error: error
                                )
                        }
                    }
                    
                    var successZoneDeleteCount: Int = .zero
                    var failureZoneDeleteCount: Int = .zero
                    for result in modifyRecordZonesResult.deleteResults {
                        let zoneID = result.key
                        guard let transaction = zoneIDTransactionMap[zoneID] else {
                            assertionFailure("How?")
                            continue
                        }
                        
                        switch result.value {
                            case .success:
                                transactionsCompleted.append(transaction)
                                successZoneDeleteCount += 1
                            case .failure(let error):
                                transactionsFailed.updateValue(error, forKey: transaction)
                                failureZoneDeleteCount += 1
                        }
                    }
                    
                    if successZoneDeleteCount > 0 {
                        self.logger.log(
                            "✅ Successfully deleted \(successZoneDeleteCount) zones (\(syncingRecordType))",
                            level: .debug
                        )
                    }
                    
                    if failureZoneDeleteCount > 0 {
                        self.logger.log(
                            "🛑 Failed to delete \(failureZoneDeleteCount) zones (\(syncingRecordType))",
                        )
                    }
                    
                } catch {
                    self.logger.log(
                        "🛑 Failed to delete \(zonesToDelete) record zones for '\(syncingRecordType)'",
                    )
                    transactions.forEach { transactionsFailed.updateValue(error, forKey: $0) }
                }
            }
            
            // MARK: Cascade Delete Records
            for recordID in recordsToCascadeDelete {
                guard let transaction = recordIDTransactionMap[recordID] else {
                    assertionFailure("How?")
                    continue
                }
                do {
                    try await cascadeDeleteChildRecords(
                        for: recordID,
                        in: database.databaseScope
                    )
                    transactionsCompleted.append(transaction)
                } catch {
                    transactionsFailed.updateValue(error, forKey: transaction)
                }
            }
            
            let completedTransactionIDs = transactionsCompleted.map { $0.id }
            transactionsFailed.forEach { transaction, error in
                self.handleError(error, for: transaction)
            }
            self.queue = queue.filter { !completedTransactionIDs.contains($0.id) }
            if !transactionsFailed.isEmpty {
                return .stopped(queueCount: queue.count, error: transactionsFailed.first?.value)
            }
        }
        
        return .completed(date: .now)
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
        
        /// Removes the transaction from the queue and informs the delegate.
        /// If the error was due to missing references, re-enqueues those first.
        func removeTransactionFromQueue(silenty: Bool = false) {
            if let index = queue.firstIndex(of: transaction) {
                if !silenty,
                   let recordsToSync = delegate?.handleUnsyncableRecord(
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
                logger.log("🤔 Transaction not found in queue", level: .error)
            }
        }
        
        // Special handling for CloudKit errors
        if let error = error as? CKError {
            switch error.code {
                case .zoneNotFound, .userDeletedZone:
                    switch transaction.operationType {
                        case .createOrUpdate:
                            // These are unexpected here — handled earlier in sync
                            reason = "None"
                            errorKind = .retryWithoutError
                            logger.log(reason, error: error)
                        case .deleteZone, .deleteRecord, .deleteChildRecords:
                            // this is a success technically for delete records
                            reason = "None"
                            errorKind = .dontSyncThis
                            removeTransactionFromQueue(silenty: true)
                            return
                    }
                    
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
                    
                    // Invalid data — usually due to unsynced references
                case .invalidArguments:
                    reason = "Invalid Arguments — this record has an unsynced reference. Return the referenced records and try syncing again."
                    errorKind = .dontSyncThis
                    
                    // Unexpected — only one record is synced at a time
                case .partialFailure:
                    // TODO: find out which partially failed and if not this record, mark it as success
                    reason = "Partial Failure."
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
                    
                    // Asset issues — usually should’ve been cleaned up after successful sync
                case .assetFileNotFound, .assetFileModified, .assetNotAvailable:
                    reason = "Asset error — file was not found or has changed. Retry the sync."
                    errorKind = .retryWithError
                    
                    // Save conflict between device and server record
                case .serverRecordChanged:
                    reason = "Record conflict between server and device."
                    errorKind = .retryWithError
                    
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
                    // TODO: find out which partially failed and if not this record, mark it as success
                    reason = "Batch request failed."
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
        
        logger.log(reason, error: error)
        
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
                    logger.log("🤔 Transaction not found in queue", level: .error)
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
