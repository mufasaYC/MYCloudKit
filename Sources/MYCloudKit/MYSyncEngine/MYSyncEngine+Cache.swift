//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit

extension MYSyncEngine {
    /// A singleton responsible for managing all local caching related to CloudKit sync operations,
    /// including transaction queues, asset files, encoded system fields, and zone IDs.
    class Cache {
        typealias Transaction = MYSyncEngine.Transaction
        
        // Main cache folder in the app's documents directory
        private let cacheDirectoryURL: URL
        
        private var transactionQueueFileURL: URL {
            cacheDirectoryURL.appendingPathComponent("transaction_cache.json")
        }
        
        private var zoneIDsFileURL: URL {
            cacheDirectoryURL.appendingPathComponent("zoneIDs.json")
        }

        private var pendingZoneResyncIDsFileURL: URL {
            cacheDirectoryURL.appendingPathComponent("pendingZoneResyncIDs.json")
        }
        
        private var encodedSystemFieldsDirectoryURL: URL {
            cacheDirectoryURL.appendingPathComponent("EncodedSystemFieldsData")
        }
        
        private let fileManager: FileManager = .default
        let logger: Logger
        
        init(suiteName: String?, logger: Logger) {
            let documentDirectory: URL
            
            if let suiteName,
                    let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
                documentDirectory = containerURL
            } else {
                documentDirectory = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first!
            }
            
            self.cacheDirectoryURL = documentDirectory.appendingPathComponent("MYCloudKit")
            self.logger = logger

            prepareDirectories()
        }

        /// Creates an isolated cache for tests and other internal tooling.
        init(cacheDirectoryURL: URL, logger: Logger) {
            self.cacheDirectoryURL = cacheDirectoryURL
            self.logger = logger

            prepareDirectories()
        }

        private func prepareDirectories() {
            
            // Ensure cache directory exists
            if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
                try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            }
            
            // Ensure encoded system fields directory exists
            if !fileManager.fileExists(atPath: encodedSystemFieldsDirectoryURL.path) {
                try? fileManager.createDirectory(at: encodedSystemFieldsDirectoryURL, withIntermediateDirectories: true)
            }
        }
    }
}

// MARK: - Transactions Queue

extension MYSyncEngine.Cache {
    /// Saves the array of transactions to disk for persistence across launches.
    func cacheTransactionQueue(_ transactions: [Transaction]) {
        do {
            let data = try JSONEncoder().encode(transactions)
            try data.write(to: transactionQueueFileURL, options: .atomic)
        } catch {
            logger.log("🛑 Failed to cache transaction queue", error: error)
        }
    }
    
    /// Retrieves the saved transaction queue, or returns an empty array if not found.
    func retrieveTransactionQueue() -> [Transaction] {
        do {
            let data = try Data(contentsOf: transactionQueueFileURL)
            let transactions = try JSONDecoder().decode([Transaction].self, from: data)
            return transactions
        } catch {
            return []
        }
    }
}

// MARK: - Asset Storage

extension MYSyncEngine.Cache {
    /// Saves asset data (like images/files) to disk under a transaction-specific folder.
    func saveAssetData(_ data: Data, with key: String, for transaction: Transaction) throws -> URL {
        let transactionFolderURL = cacheDirectoryURL
            .appendingPathComponent("transactions")
            .appendingPathComponent(transaction.id.uuidString)

        if !fileManager.fileExists(atPath: transactionFolderURL.path) {
            try fileManager.createDirectory(at: transactionFolderURL, withIntermediateDirectories: true)
        }

        let fileURL = transactionFolderURL.appendingPathComponent(key)
        try data.write(to: fileURL)

        return fileURL
    }
    
    /// Deletes cached asset data for a given transaction.
    func removeCache(for transaction: Transaction) {
        do {
            let url = cacheDirectoryURL
                .appendingPathComponent("transactions")
                .appendingPathComponent(transaction.id.uuidString)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(atPath: url.path)
            }
        } catch {
            logger.log("🛑 Failed to remove cache for transaction", error: error)
        }
    }
}

// MARK: - Encoded System Fields

extension MYSyncEngine.Cache {
    /// Stores the encoded system fields of a record (used for preserving CKRecord metadata).
    func saveEncodedSystemFields(data: Data, for recordName: String) {
        let url = encodedSystemFieldsDirectoryURL
            .appendingPathComponent(recordName)
            .appendingPathExtension("bin")
        do {
            try data.write(to: url)
        } catch {
            logger.log("🛑 Failed to save encoded system fields for record (\(recordName))", error: error)
        }
    }

    /// Retrieves previously saved system fields data for a record.
    func getEncodedSystemFields(for recordName: String) -> Data? {
        let url = encodedSystemFieldsDirectoryURL
            .appendingPathComponent(recordName)
            .appendingPathExtension("bin")
        return try? Data(contentsOf: url)
    }

    /// Removes cached CloudKit system fields only for records in the specified zone.
    /// Records re-uploaded after an encrypted-data reset must not reuse stale change tags.
    func deleteEncodedSystemFields(in zoneID: CKRecordZone.ID) {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: encodedSystemFieldsDirectoryURL,
                includingPropertiesForKeys: nil
            )

            for fileURL in fileURLs where fileURL.pathExtension == "bin" {
                guard let data = try? Data(contentsOf: fileURL),
                      let record = CKRecord(data: data),
                      record.recordID.zoneID == zoneID else {
                    continue
                }
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            logger.log(
                "🛑 Failed to clear encoded system fields for zone '\(zoneID.zoneName)'",
                error: error
            )
        }
    }
}

// MARK: - Zone ID Caching

extension MYSyncEngine.Cache {
    
    struct ZoneID: Codable, Hashable {
        let zoneName: String
        let ownerName: String
        
        var asCKRecordZoneID: CKRecordZone.ID {
            .init(zoneName: zoneName, ownerName: ownerName)
        }
        
        init(zone: CKRecordZone.ID) {
            self.zoneName = zone.zoneName
            self.ownerName = zone.ownerName
        }
    }
    
    /// Persists a list of CKRecordZone.IDs to disk.
    func setZoneIDs(_ zoneIDs: [CKRecordZone.ID]) {
        do {
            let zones = zoneIDs.map { ZoneID(zone: $0) }
            let data = try JSONEncoder().encode(zones)
            try data.write(to: zoneIDsFileURL, options: .atomic)
        } catch {
            logger.log("🛑 Failed to save zoneIDs", error: error)
        }
    }

    /// Loads previously saved CKRecordZone.IDs, or returns an empty list.
    func getZoneIDs() -> [CKRecordZone.ID] {
        do {
            let data = try Data(contentsOf: zoneIDsFileURL)
            let zones = try JSONDecoder().decode([ZoneID].self, from: data)
            return zones.map { $0.asCKRecordZoneID }
        } catch {
            return []
        }
    }
    
    func deleteZoneID(_ zoneID: CKRecordZone.ID) {
        var newZoneIDs = getZoneIDs()
        guard let index = newZoneIDs.firstIndex(of: zoneID) else {
            return
        }
        newZoneIDs.remove(at: index)
        setZoneIDs(newZoneIDs)
    }
}

// MARK: - Encrypted Data Reset Recovery

extension MYSyncEngine.Cache {
    /// Adds zones that must be re-uploaded, preserving existing requests across launches.
    func addPendingZoneResyncIDs(_ zoneIDs: [CKRecordZone.ID]) throws {
        guard !zoneIDs.isEmpty else {
            return
        }

        let existingZones = pendingZoneResyncIDs().map(ZoneID.init(zone:))
        let addedZones = zoneIDs.map(ZoneID.init(zone:))
        try setPendingZoneResyncIDs(Array(Set(existingZones + addedZones)))
    }

    /// Returns all zones awaiting delegate acknowledgment.
    func pendingZoneResyncIDs() -> [CKRecordZone.ID] {
        do {
            let data = try Data(contentsOf: pendingZoneResyncIDsFileURL)
            let zones = try JSONDecoder().decode([ZoneID].self, from: data)
            return zones.map(\.asCKRecordZoneID)
        } catch {
            return []
        }
    }

    /// Removes only the zones included in a successful delegate acknowledgment.
    func removePendingZoneResyncIDs(_ zoneIDs: [CKRecordZone.ID]) throws {
        let acknowledgedZoneIDs = Set(zoneIDs.map(ZoneID.init(zone:)))
        let remainingZoneIDs = pendingZoneResyncIDs()
            .map(ZoneID.init(zone:))
            .filter { !acknowledgedZoneIDs.contains($0) }
        try setPendingZoneResyncIDs(remainingZoneIDs)
    }

    private func setPendingZoneResyncIDs(_ zoneIDs: [ZoneID]) throws {
        let sortedZoneIDs = zoneIDs.sorted {
            if $0.ownerName == $1.ownerName {
                return $0.zoneName < $1.zoneName
            }
            return $0.ownerName < $1.ownerName
        }
        let data = try JSONEncoder().encode(sortedZoneIDs)
        try data.write(to: pendingZoneResyncIDsFileURL, options: .atomic)
    }
}
