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
    @MainActor
    public func fetch() async {
        guard let delegate else {
            assertionFailure("MYSyncDelegate must be set before fetching data, otherwise you won't be able to save the fetched data.")
            return
        }
        // Set the fetch state to indicate fetching has started
        self.fetchState = .fetching
        
        do {
            // Attempt to fetch data from the private CloudKit database
            try await self.fetch(in: .private)
            
            // Attempt to fetch data from the shared CloudKit database
            try await self.fetch(in: .shared)
            
            // If both fetches succeed, update the fetch state with completion time
            self.fetchState = .completed(date: .now)
        } catch {
            // Log the error and update the fetch state to indicate failure
            self.logger.log(
                "🛑 Fetch operation failed",
                error: error
            )
            self.fetchState = .stopped(error: error)
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
        
        // Temporary storage for records to save and delete
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [(record: CKRecord.ID, recordType: CKRecord.RecordType)] = []
        
        self.logger.log(
            "Starting fetch in \(scope.name) scope",
            level: .debug
        )
        
        let database = ckContainer.database(with: scope)
        
        // Step 1: Fetch database-level changes (zone creations/deletions)
        repeat {
            let response = try await database.databaseChanges(since: databaseChangeToken)
            deletedZoneIDs = response.deletions.map { $0.zoneID }
            newZoneIDs = response.modifications.map { $0.zoneID }
            databaseChangeToken = response.changeToken
            moreComing = response.moreComing
        } while moreComing
        
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
        
        // Step 4: Fetch record-level changes within the zones
        await withCheckedContinuation { continuation in
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: allZoneIDs,
                configurationsByRecordZoneID: configurationsByRecordZoneID
            )
            
            // Always fetch all changes within each zone
            operation.fetchAllChanges = true
            
            // Called when a zone fetch completes
            operation.recordZoneFetchResultBlock = {
                [weak self] zoneID,
                result in
                switch result {
                    case .success((let serverChangeToken, _, let moreComing)):
                        assert(!moreComing, "Unexpected: moreComing should be false")
                        newZoneServerChangeToken[zoneID] = serverChangeToken
                    case .failure(let error):
                        if let ckError = error as? CKError,
                           ckError.code == .changeTokenExpired {
                            // Reset token if expired
                            self?.userDefaults.setServerChangeToken(nil, for: zoneID)
                        }
                        self?.logger.log(
                            "⚠️ Failed to fetch changes for zone '\(zoneID.zoneName)'",
                            level: .warning,
                            error: error
                        )
                }
            }
            
            // Called for each changed record
            operation.recordWasChangedBlock = {
                [weak self] recordID,
                result in
                switch result {
                    case .success(let record):
                        recordsToSave.append(record)
                    case .failure(let error):
                        self?.logger.log(
                            "⚠️ Error processing changed record '\(recordID.recordName)'",
                            level: .warning,
                            error: error
                        )
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
        
        // Step 5: Apply the changes to local storage
        self.recordsToSave(recordsToSave)
        self.recordsToDelete(recordIDsToDelete)
        self.updateZoneIDsCache(newZoneIDs: newZoneIDs, deletedZoneIDs: deletedZoneIDs)
        
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
    
    /// Processes and handles a list of CKRecord objects that were successfully saved.
    ///
    /// This function performs the following steps:
    /// 1. Logs the number of records saved.
    /// 2. Maps the saved records by their `recordType` into a dictionary for delegation.
    /// 3. Notifies the delegate with the grouped records.
    /// 4. Caches the encoded system fields of each record for future use.
    ///
    /// - Parameter records: An array of `CKRecord` objects that have been saved.
    func recordsToSave(_ records: [CKRecord]) {
        guard !records.isEmpty else {
            return
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
        delegate?.didReceiveRecordsToSave(orderedRecords)

        // Cache system fields for each record by record ID.
        records.forEach { record in
            cache.saveEncodedSystemFields(
                data: record.encodedSystemFields,
                for: record.recordID.recordName
            )
        }
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
    ) {
        guard !records.isEmpty else {
            return
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
        delegate?.didReceiveRecordsToDelete(mappedRecords)
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
    func updateZoneIDsCache(newZoneIDs: [CKRecordZone.ID], deletedZoneIDs: [CKRecordZone.ID]) {
        guard !newZoneIDs.isEmpty || !deletedZoneIDs.isEmpty else {
            return
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
        self.delegate?.didReceiveGroupIDsToDelete(deletedGroupIDs)

        // Retrieve and update the locally cached zone IDs.
        var existingZoneIDs = cache.getZoneIDs()
        existingZoneIDs.append(contentsOf: newZoneIDs)

        // Remove any zone IDs that are now deleted.
        existingZoneIDs = existingZoneIDs.filter { !deletedZoneIDs.contains($0) }
        
        // Avoid duplication
        existingZoneIDs = Array(Set(existingZoneIDs))

        // Save the updated zone list back into cache.
        self.cache.setZoneIDs(existingZoneIDs)
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
        /// It supports `Int`, `Double`, `Float`, `Bool`, `Date`, `URL`, `String`, and `String` for reference IDs.
        ///
        /// - Parameter key: The key for which to retrieve the value.
        /// - Returns: A value of type `T` if the key exists and the type matches; otherwise, `nil`.
        ///
        /// ### Example:
        /// ```swift
        /// let name: String? = record.value(for: "name")
        /// let createdAt: Date? = record.value(for: "createdAt")
        /// ```
        public func value<T>(for key: String) -> T? {
            ckRecord.value(forKey: key) as? T
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
