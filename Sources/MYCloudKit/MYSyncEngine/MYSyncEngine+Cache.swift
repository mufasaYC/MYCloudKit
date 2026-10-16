//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit
import CryptoKit

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
    private var transactionsDirectoryURL: URL {
        cacheDirectoryURL.appendingPathComponent("transactions")
    }

    /// Saves asset data (like images/files) to disk under a transaction-specific folder.
    func saveAssetData(_ data: Data, with key: String, for transaction: Transaction) throws -> URL {
        let transactionFolderURL = transactionsDirectoryURL
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
            let url = transactionsDirectoryURL
                .appendingPathComponent(transaction.id.uuidString)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(atPath: url.path)
            }
        } catch {
            logger.log("🛑 Failed to remove cache for transaction", error: error)
        }
    }

    /// Re-anchors an asset URL staged by `saveAssetData` to the current cache directory.
    ///
    /// Queued transactions persist absolute URLs, but the app container path can change between
    /// launches (e.g. after an app update). URLs that were not staged for this transaction,
    /// such as caller-provided `fileURL` values, are returned unchanged.
    func resolvedAssetURL(_ url: URL, for transaction: Transaction) -> URL {
        let components = url.pathComponents
        guard components.count >= 3,
              components[components.count - 3] == "transactions",
              components[components.count - 2] == transaction.id.uuidString else {
            return url
        }
        return transactionsDirectoryURL
            .appendingPathComponent(transaction.id.uuidString)
            .appendingPathComponent(url.lastPathComponent)
    }

    /// Removes staged asset folders that no queued transaction references.
    ///
    /// Folders younger than `minimumAge` are kept, so a transaction that is still being staged
    /// (possibly by another process sharing this cache) is never removed.
    func removeOrphanedTransactionFolders(
        keeping transactionIDs: Set<UUID>,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = .now
    ) {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        guard let folderURLs = try? fileManager.contentsOfDirectory(
            at: transactionsDirectoryURL,
            includingPropertiesForKeys: keys
        ) else {
            return
        }

        for folderURL in folderURLs {
            if let id = UUID(uuidString: folderURL.lastPathComponent),
               transactionIDs.contains(id) {
                continue
            }
            let values = try? folderURL.resourceValues(forKeys: Set(keys))
            guard let date = values?.creationDate ?? values?.contentModificationDate,
                  now.timeIntervalSince(date) >= minimumAge else {
                continue
            }
            do {
                try fileManager.removeItem(at: folderURL)
            } catch {
                logger.log("🛑 Failed to remove orphaned transaction folder", error: error)
            }
        }
    }
}

// MARK: - Encoded System Fields

extension MYSyncEngine.Cache {
    /// The file holding a record's encoded system fields.
    ///
    /// Record names may contain `/` and be up to 255 characters, neither of which a filename allows.
    /// Names that are already valid filenames keep their original file, so existing caches still work.
    static func encodedSystemFieldsFileName(for recordName: String) -> String {
        let fileName = recordName.replacingOccurrences(of: "/", with: "%2F")
        let pathExtension = ".bin"
        // APFS limits a filename to 255 UTF-8 bytes.
        guard fileName.utf8.count + pathExtension.utf8.count <= 255 else {
            let digest = SHA256.hash(data: Data(recordName.utf8))
            return digest.map { String(format: "%02x", $0) }.joined() + pathExtension
        }
        return fileName + pathExtension
    }
    
    private func encodedSystemFieldsURL(for recordName: String) -> URL {
        encodedSystemFieldsDirectoryURL
            .appendingPathComponent(Self.encodedSystemFieldsFileName(for: recordName), isDirectory: false)
    }
    
    /// Stores the encoded system fields of a record (used for preserving CKRecord metadata).
    func saveEncodedSystemFields(data: Data, for recordName: String) {
        do {
            try data.write(to: encodedSystemFieldsURL(for: recordName))
        } catch {
            logger.log("🛑 Failed to save encoded system fields for record (\(recordName))", error: error)
        }
    }

    /// Retrieves previously saved system fields data for a record.
    func getEncodedSystemFields(for recordName: String) -> Data? {
        try? Data(contentsOf: encodedSystemFieldsURL(for: recordName))
    }
    
    /// Removes a record's cached system fields, so its next save creates a fresh record.
    func deleteEncodedSystemFields(for recordName: String) {
        let url = encodedSystemFieldsURL(for: recordName)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.log("🛑 Failed to remove encoded system fields for record (\(recordName))", error: error)
        }
    }

    /// Removes cached CloudKit system fields only for records in the specified zone.
    /// Records re-uploaded after a zone deletion or an encrypted-data reset must not reuse stale change tags.
    func deleteEncodedSystemFields(in zoneID: CKRecordZone.ID) {
        deleteEncodedSystemFields(in: [zoneID])
    }
    
    /// Removes cached CloudKit system fields for records in any of `zoneIDs`, reading the cache once.
    func deleteEncodedSystemFields(in zoneIDs: Set<CKRecordZone.ID>) {
        guard !zoneIDs.isEmpty else {
            return
        }
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: encodedSystemFieldsDirectoryURL,
                includingPropertiesForKeys: nil
            )

            for fileURL in fileURLs where fileURL.pathExtension == "bin" {
                guard let data = try? Data(contentsOf: fileURL),
                      let record = CKRecord(data: data),
                      zoneIDs.contains(record.recordID.zoneID) else {
                    continue
                }
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            logger.log(
                "🛑 Failed to clear encoded system fields for zones \(zoneIDs.map(\.zoneName))",
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
        deleteZoneIDs([zoneID])
    }
    
    func deleteZoneIDs(_ zoneIDs: Set<CKRecordZone.ID>) {
        let existingZoneIDs = getZoneIDs()
        let remainingZoneIDs = existingZoneIDs.filter { !zoneIDs.contains($0) }
        guard remainingZoneIDs.count != existingZoneIDs.count else {
            return
        }
        setZoneIDs(remainingZoneIDs)
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
