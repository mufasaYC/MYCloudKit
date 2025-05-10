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
        private var cacheDirectoryURL: URL {
            let documentDirectory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            
            return documentDirectory.appendingPathComponent("MYCloudKit")
        }
        
        private var transactionQueueFileURL: URL {
            cacheDirectoryURL.appendingPathComponent("transaction_cache.json")
        }
        
        private var zoneIDsFileURL: URL {
            cacheDirectoryURL.appendingPathComponent("zoneIDs.json")
        }
        
        private var encodedSystemFieldsDirectoryURL: URL {
            cacheDirectoryURL.appendingPathComponent("EncodedSystemFieldsData")
        }
        
        private let fileManager: FileManager = .default
        
        init() {
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
            assertionFailure(error.localizedDescription)
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
            try? fileManager.createDirectory(at: transactionFolderURL, withIntermediateDirectories: true)
        }

        let fileURL = transactionFolderURL.appendingPathComponent(key)
        try? data.write(to: fileURL)

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
            assertionFailure(error.localizedDescription)
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
            assertionFailure(error.localizedDescription)
        }
    }

    /// Retrieves previously saved system fields data for a record.
    func getEncodedSystemFields(for recordName: String) -> Data? {
        let url = encodedSystemFieldsDirectoryURL
            .appendingPathComponent(recordName)
            .appendingPathExtension("bin")
        return try? Data(contentsOf: url)
    }
}

// MARK: - Zone ID Caching

extension MYSyncEngine.Cache {
    
    fileprivate struct ZoneID: Codable {
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
            assertionFailure(error.localizedDescription)
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
}
