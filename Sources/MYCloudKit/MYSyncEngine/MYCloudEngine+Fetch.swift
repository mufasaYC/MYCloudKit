//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit

extension MYSyncEngine {
    
    /// Asynchronously fetches data from both the private and shared CloudKit databases.
    ///
    /// - This method updates the `fetchState` property to indicate the current status of the fetch process.
    /// - It first sets the state to `.fetching`, then attempts to fetch changes from the `.private` and `.shared` databases.
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
            // Attempt to fetch data from the private CloudKit database
            try await self.fetch(in: .private)
            
            // Attempt to fetch data from the shared CloudKit database
            try await self.fetch(in: .shared)

            // Keep requesting encrypted-data-reset recovery until the delegate confirms
            // that all affected local records have been queued through MYCloudKit.
            await requestPendingZoneResyncIfNeeded()
            
            // If both fetches succeed, update the fetch state with completion time
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
    /// - Errors such as `CKError.changeTokenExpired` are handled gracefully by resetting the token.
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
        
        // Temporary storage for records to save and delete
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [(record: CKRecord.ID, recordType: CKRecord.RecordType)] = []
        
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
                try await fetch(in: scope)
            } else {
                throw error
            }
        }

        // Persist recovery before advancing the database token, preserve local app data,
        // and discard only stale CloudKit metadata for the reset zones.
        try prepareForEncryptedDataReset(in: encryptedDataResetZoneIDs)
        
        // Step 2: Prepare the full list of zone IDs to fetch record changes from
        let existingZoneIDs: [CKRecordZone.ID] = cache.getZoneIDs()
        var allZoneIDs = existingZoneIDs + newZoneIDs
        
        // Filter the zone IDs based on the current scope
        allZoneIDs = allZoneIDs.filter { zoneID in
            switch scope {
                case .private:
                    return zoneID.ownerName == CKCurrentUserDefaultName
                case .shared:
                    return zoneID.ownerName != CKCurrentUserDefaultName
                default:
                    return false // Skip public database
            }
        }
        
        // Step 3: Prepare zone configurations for token-based incremental fetch
        typealias ZoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration
        var configurationsByRecordZoneID: [CKRecordZone.ID : ZoneConfig] = [:]
        
        allZoneIDs.forEach { zoneID in
            configurationsByRecordZoneID[zoneID] = .init(
                previousServerChangeToken: userDefaults.getServerChangeToken(for: zoneID)
            )
        }
        
        var newZoneServerChangeToken: [CKRecordZone.ID: CKServerChangeToken] = [:]
        var fetchErrors: [Error] = []
        
        // Step 4: Fetch record-level changes within the zones
        await withCheckedContinuation { continuation in
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: allZoneIDs,
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
                        newZoneServerChangeToken[zoneID] = serverChangeToken
                    case .failure(let error):
                        if let ckError = error as? CKError {
                            if ckError.code == .changeTokenExpired {
                                // Reset token if expired
                                self?.userDefaults.setServerChangeToken(nil, for: zoneID)
                            } else if ckError.code == .zoneNotFound || ckError.code == .userDeletedZone {
                                self?.cache.deleteZoneID(zoneID)
                            }
                        }
                        self?.logger.log(
                            "⚠️ Failed to fetch changes for zone '\(zoneID.zoneName)'",
                            level: .warning,
                            error: error
                        )
                        fetchErrors.append(error)
                }
            }
            
            // Called for each changed record
            operation.recordWasChangedBlock = { [weak self] recordID, result in
                switch result {
                    case .success(let record):
                        recordsToSave.append(record)
                    case .failure(let error):
                        self?.logger.log(
                            "⚠️ Error processing changed record '\(recordID.recordName)'",
                            level: .warning,
                            error: error
                        )
                        fetchErrors.append(error)
                }
            }
            
            // Called for each deleted record
            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                recordIDsToDelete.append((recordID, recordType))
            }
            
            // Called when change tokens are incrementally updated mid-fetch
            operation.recordZoneChangeTokensUpdatedBlock = {
                [weak self] zoneID,
                token,
                _ in
                if let token {
                    newZoneServerChangeToken[zoneID] = token
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
        
        if let error = fetchErrors.first {
            throw error
        }
        
        // Step 5: Apply the changes to local storage
        guard await self.recordsToSave(recordsToSave) else {
            return
        }
        guard await self.recordsToDelete(recordIDsToDelete) else {
            return
        }
        guard await self.updateZoneIDsCache(newZoneIDs: newZoneIDs, deletedZoneIDs: deletedZoneIDs) else {
            return
        }
        
        // Step 6: Persist the new tokens for next sync
        userDefaults.setPreviousServerChangeToken(for: scope, databaseChangeToken)
        newZoneServerChangeToken.forEach { zoneID, token in
            self.userDefaults.setServerChangeToken(token, for: zoneID)
        }
        
        self.logger.log(
            "✅ Finished fetch in \(scope.name) scope",
            level: .debug
        )
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

    private func prepareForEncryptedDataReset(in zoneIDs: [CKRecordZone.ID]) throws {
        guard !zoneIDs.isEmpty else {
            return
        }

        let uniqueZoneIDs = Array(Set(zoneIDs))
        try cache.addPendingZoneResyncIDs(uniqueZoneIDs)

        for zoneID in uniqueZoneIDs {
            userDefaults.setServerChangeToken(nil, for: zoneID)
            cache.deleteZoneID(zoneID)
            cache.deleteEncodedSystemFields(in: zoneID)
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
    
    
    /// Updates the local cache of CloudKit zone IDs based on newly fetched and deleted zones.
    ///
    /// This function performs the following:
    /// 1. Logs how many zones were fetched and deleted.
    /// 2. Notifies the delegate of zone deletions (typically used to remove groups tied to those zones).
    /// 3. Updates the cached list of zone IDs by adding new ones and removing deleted ones.
    ///
    /// - Parameters:
    ///   - newZoneIDs: An array of `CKRecordZone.ID` objects representing newly fetched zones.
    ///   - deletedZoneIDs: An array of `CKRecordZone.ID` objects representing zones that have been deleted.
    func updateZoneIDsCache(newZoneIDs: [CKRecordZone.ID], deletedZoneIDs: [CKRecordZone.ID]) async -> Bool {
        guard !newZoneIDs.isEmpty || !deletedZoneIDs.isEmpty else {
            return true
        }

        // Log how many zones were fetched and deleted.
        self.logger.log(
            "📦 Added \(newZoneIDs.count) new zones",
            level: .debug
        )
        self.logger.log(
            "🗑️ Removed \(deletedZoneIDs.count) zones",
            level: .debug
        )

        // Inform the delegate about group IDs to delete, using the zone names.
        let deletedGroupIDs = deletedZoneIDs.map { $0.zoneName }
        guard let didSave = await self.delegate?.didReceiveGroupIDsToDelete(deletedGroupIDs), didSave else {
            return false
        }

        // Retrieve and update the locally cached zone IDs.
        var existingZoneIDs = cache.getZoneIDs()
        existingZoneIDs.append(contentsOf: newZoneIDs)

        // Remove any zone IDs that are now deleted.
        existingZoneIDs = existingZoneIDs.filter { !deletedZoneIDs.contains($0) }
        
        // Avoid duplication
        existingZoneIDs = Array(Set(existingZoneIDs))

        // Save the updated zone list back into cache.
        self.cache.setZoneIDs(existingZoneIDs)
        return true
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
