//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit

extension MYSyncEngine {
    
    /// Asynchronously fetches data from the configured CloudKit databases.
    ///
    /// - This method updates the `fetchState` property to indicate the current status of the fetch process.
    /// - It fetches changes from each scope configured through `MYSyncEngine.init`.
    /// - On success, it sets the state to `.completed` with the current timestamp.
    /// - If an error occurs during the fetch, it logs the error and updates the state to `.stopped` with the error.
    ///
    /// - Note: This method is marked with `@MainActor` to ensure that `fetchState` updates happen on the main thread.
    public func fetch() async -> FetchState {
        guard cloudKitAccountStatus == .available else {
            return .stopped(error: NSError(domain: "CloudKit account cannot sync", code: 403))
        }
        guard delegate != nil else {
            assertionFailure("MYSyncDelegate must be set before fetching data, otherwise you won't be able to save the fetched data.")
            return .idle
        }
        
        do {
            for scope in orderedDatabaseScopes {
                try await self.fetch(in: scope)
            }

            // Keep requesting encrypted-data-reset recovery until the delegate confirms
            // that all affected local records have been queued through MYCloudKit.
            await requestPendingZoneResyncIfNeeded()
            
            // If every configured fetch succeeds, update the fetch state with completion time
            return .completed(date: .now)
        } catch {
            // Log the error and update the fetch state to indicate failure
            self.logger.log(
                "🛑 Fetch operation failed",
                error: error
            )
            self.interceptError(error)
            return .stopped(error: error)
        }
    }
    
    /// Fetches changes from the specified CloudKit database scope (.private or .shared).
    ///
    /// - This method checks for changes at the database level first (zones added or deleted),
    ///   and then fetches record-level changes within those zones.
    /// - It updates local caches, collects changed and deleted records, and stores updated change tokens.
    /// - A zone whose change token expired is re-fetched from the start in the same pass.
    /// - A zone that no longer exists is forwarded to the delegate as deleted instead of failing the fetch.
    ///
    /// - Parameter scope: The `CKDatabase.Scope` to fetch changes from (e.g., `.private` or `.shared`).
    /// - Throws: Rethrows errors encountered during the fetch process.
    func fetch(in scope: CKDatabase.Scope) async throws {
        // Retrieve the last known database change token to fetch deltas
        var databaseChangeToken = userDefaults.previousServerChangeToken(for: scope)
        var moreComing: Bool
        
        // Track new and deleted record zones
        var newZoneIDs: [CKRecordZone.ID] = []
        var deletedZoneIDs: [CKRecordZone.ID] = []
        var encryptedDataResetZoneIDs: [CKRecordZone.ID] = []
        
        self.logger.log(
            "Starting fetch in \(scope.name) scope",
            level: .debug
        )
        
        let database = ckContainer.database(with: scope)
        
        // Step 1: Fetch database-level changes (zone creations/deletions)
        do {
            repeat {
                let response = try await databaseChanges(
                    in: database,
                    since: databaseChangeToken
                )
                deletedZoneIDs.append(contentsOf: response.deletions)
                encryptedDataResetZoneIDs.append(contentsOf: response.encryptedDataResets)
                newZoneIDs.append(contentsOf: response.modifications)
                databaseChangeToken = response.changeToken
                moreComing = response.moreComing
            } while moreComing
        } catch {
            if let ckError = error as? CKError,
               ckError.code == .changeTokenExpired {
                userDefaults.setPreviousServerChangeToken(for: scope, nil)
                // The recursive fetch completes the whole scope and persists a fresh token,
                // so continuing here would redo the fetch and restore the expired token.
                try await fetch(in: scope)
                return
            } else {
                throw error
            }
        }

        // Persist recovery before advancing the database token, preserve local app data,
        // and discard only stale CloudKit metadata for the reset zones.
        try prepareForEncryptedDataReset(in: encryptedDataResetZoneIDs)
        
        // A deleted zone's change token and system fields are stale, even if the zone has been re-created since
        // (e.g. by an upload that ran before this fetch). A re-created zone is then fetched from the start.
        discardMetadata(forDeletedZones: deletedZoneIDs)
        
        // Step 2: Prepare the full list of zone IDs to fetch record changes from
        let allZoneIDs = Self.zoneIDsToFetch(
            cached: cache.getZoneIDs(),
            modified: newZoneIDs,
            deleted: deletedZoneIDs,
            in: scope
        )
        
        // Step 3: Fetch record-level changes within the zones
        var zoneChanges = await fetchZoneChanges(in: allZoneIDs, database: database)
        
        // Step 4: Re-fetch zones whose token expired (their tokens are reset) from the start
        if !zoneChanges.expiredZoneErrors.isEmpty {
            let expiredZoneIDs = Array(zoneChanges.expiredZoneErrors.keys)
            self.logger.log(
                "🔄 Change token expired for \(expiredZoneIDs.count) zone(s), fetching them from the start",
                level: .info
            )
            let retriedChanges = await fetchZoneChanges(in: expiredZoneIDs, database: database)
            zoneChanges.replaceResults(for: Set(expiredZoneIDs), with: retriedChanges)
        }
        
        // Zones that no longer exist are deletions, not failures
        let missingZoneIDs = zoneChanges.missingZoneIDs.filter { !deletedZoneIDs.contains($0) }
        discardMetadata(forDeletedZones: missingZoneIDs)
        newZoneIDs.removeAll { zoneChanges.missingZoneIDs.contains($0) }
        deletedZoneIDs.append(contentsOf: missingZoneIDs)
        
        if let error = zoneChanges.errors.first ?? zoneChanges.expiredZoneErrors.values.first {
            throw error
        }
        
        // Step 5: Apply the changes to local storage.
        // Zone deletions go first: a zone deleted and then re-created must end up with its new contents.
        guard await self.groupsToDelete(deletedZoneIDs) else {
            return
        }
        guard await self.recordsToSave(zoneChanges.recordsToSave) else {
            return
        }
        guard await self.recordsToDelete(zoneChanges.recordIDsToDelete) else {
            return
        }
        updateZoneIDsCache(newZoneIDs: newZoneIDs, deletedZoneIDs: deletedZoneIDs)
        
        // Step 6: Persist the new tokens for next sync
        userDefaults.setPreviousServerChangeToken(for: scope, databaseChangeToken)
        zoneChanges.serverChangeTokens.forEach { zoneID, token in
            self.userDefaults.setServerChangeToken(token, for: zoneID)
        }
        
        self.logger.log(
            "✅ Finished fetch in \(scope.name) scope",
            level: .debug
        )
    }
    
    /// The zones whose record changes a fetch asks for.
    ///
    /// `modified` also contains cached zones that have changes, so the list is de-duplicated to avoid
    /// fetching the same zone twice and delivering its records to the delegate twice.
    /// Zones reported deleted are skipped unless they were also reported modified, i.e. re-created.
    static func zoneIDsToFetch(
        cached: [CKRecordZone.ID],
        modified: [CKRecordZone.ID],
        deleted: [CKRecordZone.ID],
        in scope: CKDatabase.Scope
    ) -> [CKRecordZone.ID] {
        let deletedZoneIDs = Set(deleted).subtracting(modified)
        var seenZoneIDs = Set<CKRecordZone.ID>()
        return (cached + modified).filter { zoneID in
            guard !deletedZoneIDs.contains(zoneID), seenZoneIDs.insert(zoneID).inserted else {
                return false
            }
            switch scope {
                case .private:
                    return zoneID.ownerName == CKCurrentUserDefaultName
                case .shared:
                    return zoneID.ownerName != CKCurrentUserDefaultName
                default:
                    return false // Skip public database
            }
        }
    }
    
    /// The outcome of one `CKFetchRecordZoneChangesOperation`.
    struct ZoneChanges {
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [(record: CKRecord.ID, recordType: CKRecord.RecordType)] = []
        var serverChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
        /// Zones whose change token expired; their tokens have been reset.
        var expiredZoneErrors: [CKRecordZone.ID: Error] = [:]
        /// Zones that no longer exist on the server.
        var missingZoneIDs: [CKRecordZone.ID] = []
        /// Any other failure, which fails the fetch.
        var errors: [Error] = []
        
        /// Replaces everything fetched for `zoneIDs` with `retry`, a fetch of only those zones.
        mutating func replaceResults(for zoneIDs: Set<CKRecordZone.ID>, with retry: ZoneChanges) {
            recordsToSave.removeAll { zoneIDs.contains($0.recordID.zoneID) }
            recordIDsToDelete.removeAll { zoneIDs.contains($0.record.zoneID) }
            zoneIDs.forEach { serverChangeTokens[$0] = nil }
            expiredZoneErrors = expiredZoneErrors.filter { !zoneIDs.contains($0.key) }
            
            recordsToSave.append(contentsOf: retry.recordsToSave)
            recordIDsToDelete.append(contentsOf: retry.recordIDsToDelete)
            serverChangeTokens.merge(retry.serverChangeTokens) { _, new in new }
            expiredZoneErrors.merge(retry.expiredZoneErrors) { _, new in new }
            missingZoneIDs.append(contentsOf: retry.missingZoneIDs.filter { !missingZoneIDs.contains($0) })
            errors.append(contentsOf: retry.errors)
        }
    }
    
    /// Fetches record-level changes in `zoneIDs`, starting from each zone's saved change token.
    private func fetchZoneChanges(
        in zoneIDs: [CKRecordZone.ID],
        database: CKDatabase
    ) async -> ZoneChanges {
        guard !zoneIDs.isEmpty else {
            return .init()
        }
        
        // Prepare zone configurations for token-based incremental fetch
        typealias ZoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration
        var configurationsByRecordZoneID: [CKRecordZone.ID : ZoneConfig] = [:]
        
        zoneIDs.forEach { zoneID in
            configurationsByRecordZoneID[zoneID] = .init(
                previousServerChangeToken: userDefaults.getServerChangeToken(for: zoneID)
            )
        }
        
        var changes = ZoneChanges()
        
        await withCheckedContinuation { continuation in
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: zoneIDs,
                configurationsByRecordZoneID: configurationsByRecordZoneID
            )
            
            // Always fetch all changes within each zone
            operation.fetchAllChanges = true
            
            // Called when a zone fetch completes
            operation.recordZoneFetchResultBlock = { [weak self] zoneID, result in
                switch result {
                    case .success((let serverChangeToken, _, let moreComing)):
                        if moreComing {
                            self?.logger.log(
                                "Unexpected: moreComing should be false, kindly report this issue",
                                level: .warning
                            )
                        }
                        changes.serverChangeTokens[zoneID] = serverChangeToken
                    case .failure(let error):
                        self?.logger.log(
                            "⚠️ Failed to fetch changes for zone '\(zoneID.zoneName)'",
                            level: .warning,
                            error: error
                        )
                        switch (error as? CKError)?.code {
                            case .changeTokenExpired:
                                // Reset token if expired
                                self?.userDefaults.setServerChangeToken(nil, for: zoneID)
                                changes.expiredZoneErrors[zoneID] = error
                            case .zoneNotFound, .userDeletedZone:
                                changes.missingZoneIDs.append(zoneID)
                            default:
                                changes.errors.append(error)
                        }
                }
            }
            
            // Called for each changed record
            operation.recordWasChangedBlock = { [weak self] recordID, result in
                switch result {
                    case .success(let record):
                        changes.recordsToSave.append(record)
                    case .failure(let error):
                        self?.logger.log(
                            "⚠️ Error processing changed record '\(recordID.recordName)'",
                            level: .warning,
                            error: error
                        )
                        changes.errors.append(error)
                }
            }
            
            // Called for each deleted record
            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                changes.recordIDsToDelete.append((recordID, recordType))
            }
            
            // Called when change tokens are incrementally updated mid-fetch
            operation.recordZoneChangeTokensUpdatedBlock = {
                [weak self] zoneID,
                token,
                _ in
                if let token {
                    changes.serverChangeTokens[zoneID] = token
                } else {
                    self?.logger.log(
                        "⚠️ Missing token update for zone '\(zoneID.zoneName)'",
                        level: .warning
                    )
                }
            }
            
            // Called when the operation finishes
            operation.completionBlock = {
                continuation.resume()
            }
            
            database.add(operation)
        }
        
        return changes
    }

    private func databaseChanges(
        in database: CKDatabase,
        since changeToken: CKServerChangeToken?
    ) async throws -> (
        modifications: [CKRecordZone.ID],
        deletions: [CKRecordZone.ID],
        encryptedDataResets: [CKRecordZone.ID],
        changeToken: CKServerChangeToken,
        moreComing: Bool
    ) {
        try await withCheckedThrowingContinuation { continuation in
            var modifications: [CKRecordZone.ID] = []
            var deletions: [CKRecordZone.ID] = []
            var encryptedDataResets: [CKRecordZone.ID] = []
            let operation = CKFetchDatabaseChangesOperation(
                previousServerChangeToken: changeToken
            )
            operation.fetchAllChanges = false
            operation.recordZoneWithIDChangedBlock = { zoneID in
                modifications.append(zoneID)
            }
            operation.recordZoneWithIDWasDeletedBlock = { zoneID in
                deletions.append(zoneID)
            }
            operation.recordZoneWithIDWasPurgedBlock = { zoneID in
                deletions.append(zoneID)
            }
            operation.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { zoneID in
                encryptedDataResets.append(zoneID)
            }
            operation.fetchDatabaseChangesResultBlock = { result in
                switch result {
                    case .success((let serverChangeToken, let moreComing)):
                        continuation.resume(
                            returning: (
                                modifications: modifications,
                                deletions: deletions,
                                encryptedDataResets: encryptedDataResets,
                                changeToken: serverChangeToken,
                                moreComing: moreComing
                            )
                        )
                    case .failure(let error):
                        continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
    
    /// Forgets everything cached for zones that no longer exist on the server: their change tokens,
    /// their place in the zone cache and, for the user's own zones, their records' system fields.
    /// Local app data is untouched.
    func discardMetadata(forDeletedZones zoneIDs: [CKRecordZone.ID]) {
        Self.discardMetadata(forDeletedZones: zoneIDs, userDefaults: userDefaults, cache: cache)
    }
    
    static func discardMetadata(forDeletedZones zoneIDs: [CKRecordZone.ID], userDefaults: UserDefaults, cache: Cache) {
        guard !zoneIDs.isEmpty else {
            return
        }
        cache.deleteZoneIDs(Set(zoneIDs))
        discardChangeTracking(forZones: zoneIDs, userDefaults: userDefaults, cache: cache)
    }
    
    /// Clears the change tokens and system fields of zones that are, or are about to be, re-created empty.
    ///
    /// A shared zone's system fields are kept: they are what routes its records to the shared database,
    /// and only its owner can re-create it.
    func discardChangeTracking(forZones zoneIDs: [CKRecordZone.ID]) {
        Self.discardChangeTracking(forZones: zoneIDs, userDefaults: userDefaults, cache: cache)
    }
    
    static func discardChangeTracking(forZones zoneIDs: [CKRecordZone.ID], userDefaults: UserDefaults, cache: Cache) {
        zoneIDs.forEach { userDefaults.setServerChangeToken(nil, for: $0) }
        cache.deleteEncodedSystemFields(in: Set(zoneIDs.filter { $0.ownerName == CKCurrentUserDefaultName }))
    }

    private func prepareForEncryptedDataReset(in zoneIDs: [CKRecordZone.ID]) throws {
        guard !zoneIDs.isEmpty else {
            return
        }

        let uniqueZoneIDs = Array(Set(zoneIDs))
        try cache.addPendingZoneResyncIDs(uniqueZoneIDs)

        discardMetadata(forDeletedZones: uniqueZoneIDs)
        for zoneID in uniqueZoneIDs {
            logger.log(
                "🔐 Encrypted data reset detected for zone '\(zoneID.zoneName)'; local data will be preserved and requested for resync",
                level: .warning
            )
        }
    }

    func requestPendingZoneResyncIfNeeded() async {
        let pendingZoneIDs = cache.pendingZoneResyncIDs()
        guard !pendingZoneIDs.isEmpty else {
            return
        }

        let groupIDs = Array(Set(pendingZoneIDs.map(\.zoneName))).sorted()
        guard let delegate else {
            return
        }

        if await delegate.didReceiveGroupIDsToResync(groupIDs) {
            do {
                try cache.removePendingZoneResyncIDs(pendingZoneIDs)
                logger.log(
                    "✅ Delegate queued local records for \(groupIDs.count) encrypted-data-reset zone(s)",
                    level: .debug
                )
            } catch {
                logger.log("🛑 Failed to acknowledge encrypted-data-reset recovery", error: error)
            }
        } else {
            logger.log(
                "⚠️ Waiting for delegate to queue local records for \(groupIDs.count) encrypted-data-reset zone(s)",
                level: .warning
            )
        }
    }
    
    /// Processes and handles a list of CKRecord objects that were successfully saved.
    ///
    /// This function performs the following steps:
    /// 1. Logs the number of records saved.
    /// 2. Maps the saved records by their `recordType` into a dictionary for delegation.
    /// 3. Notifies the delegate with the grouped records.
    /// 4. Caches the encoded system fields of each record for future use.
    ///
    /// - Parameter records: An array of `CKRecord` objects that have been saved.
    func recordsToSave(_ records: [CKRecord]) async -> Bool {
        guard !records.isEmpty else {
            return true
        }

        // Group records by their type and convert them into internal Record representations.
        var mappedRecords: [String: [FetchedRecord]] = [:]
        records.forEach { record in
            var recordList = mappedRecords[record.recordType] ?? []
            recordList.append(.init(record: record))
            mappedRecords[record.recordType] = recordList
        }
        
        // Logging.
        for (type, records) in mappedRecords {
            self.logger.log(
                "📥 Received \(records.count) '\(type)' records to save",
                level: .debug
            )
        }
        
        var orderedRecords: [FetchedRecord] = []
        
        delegate?.syncableRecordTypesInDependencyOrder().forEach { type in
            guard let records = mappedRecords[type] else {
                return
            }
            orderedRecords.append(contentsOf: records)
        }

        // Notify the delegate about the records to save.
        guard let didSave = await delegate?.didReceiveRecordsToSave(orderedRecords), didSave else {
            return false
        }

        // Cache system fields for each record by record ID.
        records.forEach { record in
            cache.saveEncodedSystemFields(
                data: record.encodedSystemFields,
                for: record.recordID.recordName
            )
        }
        
        return true
    }
    
    /// Processes and handles a list of CKRecord identifiers that were successfully deleted.
    ///
    /// This function performs the following:
    /// 1. Logs the number of records deleted.
    /// 2. Maps the deleted record identifiers and types into a tuple format suitable for downstream use.
    /// 3. Notifies the delegate with the deleted record information.
    ///
    /// - Parameter records: An array of tuples, each containing a `CKRecord.ID` and its corresponding `CKRecord.RecordType`.
    func recordsToDelete(
        _ records: [(
            record: CKRecord.ID,
            recordType: CKRecord.RecordType
        )]
    ) async -> Bool {
        guard !records.isEmpty else {
            return true
        }

        // Convert CKRecord.IDs to simple string-based tuples.
        let mappedRecords: [(myRecordID: String, myRecordType: MYRecordType)] = records.map { record, recordType in
            (record.recordName, recordType)
        }
        
        // Logging.
        for (id, type) in mappedRecords {
            self.logger.log(
                "🗑️ Marked record '\(id)' of type '\(type)' for deletion",
                level: .debug
            )
        }

        // Notify the delegate about the records to delete.
        guard let didSave = await delegate?.didReceiveRecordsToDelete(mappedRecords) else {
            return false
        }
        
        return didSave
    }
    
    
    /// Tells the delegate which groups to delete, using the zone names.
    func groupsToDelete(_ deletedZoneIDs: [CKRecordZone.ID]) async -> Bool {
        let groupIDs = Self.deletedGroupIDs(deletedZoneIDs)
        guard !groupIDs.isEmpty else {
            return true
        }
        
        self.logger.log(
            "🗑️ Removed \(groupIDs.count) zones",
            level: .debug
        )
        
        guard let didSave = await self.delegate?.didReceiveGroupIDsToDelete(groupIDs), didSave else {
            return false
        }
        return true
    }
    
    /// The group IDs (zone names) of `deletedZoneIDs`, without duplicates, in the order reported.
    static func deletedGroupIDs(_ deletedZoneIDs: [CKRecordZone.ID]) -> [String] {
        var seenZoneIDs = Set<CKRecordZone.ID>()
        return deletedZoneIDs
            .filter { seenZoneIDs.insert($0).inserted }
            .map(\.zoneName)
    }
    
    /// Updates the local cache of CloudKit zone IDs based on newly fetched and deleted zones.
    ///
    /// - Parameters:
    ///   - newZoneIDs: Zones reported as changed, which may already be cached.
    ///   - deletedZoneIDs: Zones reported as deleted. A zone also in `newZoneIDs` was re-created and stays cached.
    func updateZoneIDsCache(newZoneIDs: [CKRecordZone.ID], deletedZoneIDs: [CKRecordZone.ID]) {
        guard !newZoneIDs.isEmpty || !deletedZoneIDs.isEmpty else {
            return
        }
        
        let existingZoneIDs = cache.getZoneIDs()
        
        // Log how many zones were added. `newZoneIDs` may include zones that are already cached.
        let addedZoneCount = Set(newZoneIDs).subtracting(existingZoneIDs).count
        self.logger.log(
            "📦 Added \(addedZoneCount) new zones",
            level: .debug
        )
        
        // Save the updated zone list back into cache.
        self.cache.setZoneIDs(
            Self.updatedZoneIDs(
                existing: existingZoneIDs,
                modified: newZoneIDs,
                deleted: deletedZoneIDs
            )
        )
    }
    
    /// The cached zone list after a fetch: existing and modified zones, minus deleted ones
    /// unless they were re-created (reported modified as well), without duplicates.
    static func updatedZoneIDs(
        existing: [CKRecordZone.ID],
        modified: [CKRecordZone.ID],
        deleted: [CKRecordZone.ID]
    ) -> [CKRecordZone.ID] {
        let removedZoneIDs = Set(deleted).subtracting(modified)
        var seenZoneIDs = Set<CKRecordZone.ID>()
        return (existing + modified).filter { zoneID in
            !removedZoneIDs.contains(zoneID) && seenZoneIDs.insert(zoneID).inserted
        }
    }
}

extension MYSyncEngine {
    /// A lightweight model representing a CloudKit record (`CKRecord`) used for saving data locally.
    /// `FetchedRecord` is a simplified structure that abstracts CloudKit's `CKRecord` by including only essential fields
    ///
    /// ### Key Properties:
    /// - **id**: The unique identifier of the record (same as `myRecordID` in `MYRecordConvertible`).
    /// - **type**: same as `myRecordType` in `MYRecordConvertible` (e.g., `"Task"`, `"Project"`).
    /// - **rootGroupID**: The identifier of the root group this record belongs to (same as `myRootGroupID` in `MYRecordConvertible`).
    /// - **parentID**: The identifier of the parent record (same as `myParentID` in `MYRecordConvertible`).
    ///
    /// ### Accessing Record Fields:
    /// The `FetchedRecord` class provides a type-safe interface for accessing record fields:
    /// - Use the `value(for:)` method to access any field in the record, like `String`, `Int`, `Date`, `URL`, or reference IDs.
    ///
    /// ### Example:
    /// ```swift
    /// // Creating a FetchedRecord from a CKRecord
    /// let record = FetchedRecord(record: ckRecord)
    ///
    /// // Accessing fields with type-safe value accessors
    /// let title: String? = record.value(for: "title")          // Accessing a string field
    /// let dueDate: Date? = record.value(for: "dueDate")        // Accessing a Date field
    /// let parentID: String? = record.value(for: "parentID")    // Accessing a reference ID (String)
    /// ```
    ///
    public struct FetchedRecord {
        
        // The unique identifier of the record (from `recordID.recordName`).
        public var id: String
        
        // The CloudKit record type (often maps to a model or entity name, like "Task", "Project", etc.).
        public var type: String
        
        // The root group or zone ID this record belongs to (i.e., the name of the CloudKit zone).
        public var rootGroupID: String?
        
        // The parent record’s ID, if the record has a hierarchical relationship.
        public var parentID: String?
        
        // The underlying `CKRecord` instance that contains the raw data for the record.
        private var ckRecord: CKRecord
        
        // MARK: - Value Accessors
        
        /// Returns a typed value for the given key from the record's properties.
        ///
        /// This method performs type-safe matching based on the expected return type `T`.
        /// It supports `Int`, `Double`, `Float`, `Bool`, `Date`, `URL`, `String`, and `String` for reference IDs and `URL` for files/images/videos or other binary data that you might have synced
        ///
        /// - Parameter key: The key for which to retrieve the value.
        /// - Returns: A value of type `T` if the key exists and the type matches; otherwise, `nil`.
        ///
        /// ### Example:
        /// ```swift
        /// let name: String? = record.value(for: "name")
        /// let createdAt: Date? = record.value(for: "createdAt")
        /// let file: URL? = record.value(for: "file")
        /// let childReference: String? = record.value(for: "child_record_id")
        /// ```
        public func value<T: Codable>(for key: String) -> T? {
            if let data = ckRecord[key] as? Data,
               let value = try? JSONDecoder().decode(T.self, from: data) {
                return value
            }
            
            return rawValue(for: key)
        }
        
        public func value<T>(for key: String) -> T? {
            rawValue(for: key)
        }
        
        private func rawValue<T>(for key: String) -> T? {
            if let asset = ckRecord[key] as? CKAsset {
                if let fileURL = asset.fileURL {
                    if let expectedReturn = asset.fileURL as? T {
                        return expectedReturn
                    } else if let expectedReturn = try? Data(contentsOf: fileURL) as? T {
                        return expectedReturn
                    }
                }
            } else if let reference = ckRecord[key] as? CKRecord.Reference {
                return reference.recordID.recordName as? T
            } else if let references = ckRecord[key] as? [CKRecord.Reference],
                      let result = references.map({ $0.recordID.recordName }) as? T {
                return result
            }
            
            return ckRecord.value(forKey: key) as? T
        }
        
        // MARK: - Initializer
        
        /// Initializes a `FetchedRecord` from a `CKRecord`, mapping supported field types.
        ///
        /// - Parameter record: The CloudKit record to convert.
        init(record: CKRecord) {
            self.id = record.recordID.recordName
            self.type = record.recordType
            self.rootGroupID = record.recordID.zoneID.zoneName
            self.parentID = record.parent?.recordID.recordName
            
            self.ckRecord = record
        }
    }
}
