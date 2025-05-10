//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit.CKRecord

/// A model representing a CloudKit-related operation to be performed, such as creating, updating, or deleting a record or zone.
///
/// `MYTransaction` instances are created for each sync-related change in the app, cached, and queued for processing.
/// Each transaction captures the operation type, the target record, and a set of property values (key-value pairs).
/// This abstraction allows the system to uniformly handle both sync and delete operations in CloudKit, and retry them if needed.
///
/// Transactions are typically created using helper functions like `getCreateUpdateTransaction(for:)`,
/// which convert an `MYRecordConvertible` object into a `MYTransaction` with encoded properties.
///
/// These transactions are used internally to manage a robust and fault-tolerant sync pipeline.
///
/// ### Example Flow:
/// 1. User creates or modifies data locally.
/// 2. An `MYTransaction` is initialized and added to a queue.
/// 3. The system processes this queue, converting transactions into `CKRecord` objects and syncing them with the `CKContainer`.
///
/// - Note: All asset data is stored as a temporary file and referenced using a file URL, ensuring compatibility with CloudKit's `CKAsset`.
///

extension MYSyncEngine {
    struct Transaction: Identifiable, Hashable, Codable {
        
        typealias Cache = MYSyncEngine.Cache
        
        /// The type of operation this transaction represents.
        enum OperationType: Codable, Hashable {
            
            /// Creates or updates a `CKRecord` in CloudKit.
            case createOrUpdate
            
            /// Deletes a specific `CKRecord` from CloudKit.
            case deleteRecord
            
            /// Deletes an entire custom zone in CloudKit.
            case deleteZone
            
            /// Deletes all child records under a given parent.
            case deleteChildRecords
        }
        
        /// The supported data types that can be stored in a `CKRecord` field.
        enum RecordValue: Hashable, Codable {
            case int(Int?)
            case double(Double?)
            case float(Float?)
            case bool(Bool?)
            case date(Date?)
            case asset(URL?) // Represents a file-based asset (image, video, etc.)
            case string(String?)
            
            /// Represents a reference to another record, with an associated delete rule.
            case reference(Record?, deleteRule: MYRecordValue.DeleteRule)
        }
        
        let id: UUID
        let operationType: OperationType
        let record: Record
        var properties: [String: RecordValue]
        
        /// The number of retry attempts made while processing this transaction. Once this is equal to `maxAttempts` passed in the `init` of `MYCloudEngine`, it will be notified via `MYCloudEngineDelegate` and removed from the queue
        var attempts: Int = .zero
    }
}

extension MYSyncEngine.Transaction {
    struct Record: Hashable, Codable {
        let recordName: String
        let recordType: String
        let zoneName: String?
        let parentRecordName: String?
        
        
        /// Builds the base `CKRecord` for the current model, using any previously saved system fields if available.
        ///
        /// This method attempts to reconstruct the original `CKRecord` using its archived system fields
        /// (typically obtained from a previous CloudKit fetch). If those aren't available, it tries to infer
        /// the appropriate `CKRecordZone.ID` from referenced records or uses a fallback zone.
        ///
        /// - Parameter recordReferencingRecordNames: An array of record names this record is referencing.
        ///   These are used as hints to infer the appropriate `CKRecordZone.ID` if the current record's system fields aren't cached.
        ///   This is especially useful when the current record is a participant in a shared CKRecord,
        ///   and we want to place it in the correct zone.
        ///
        /// - Returns: A `CKRecord` instance for this model. The returned record will have the correct type and ID,
        ///   and will attempt to reuse or infer the appropriate zone.
        ///   The caller should update this record with any values that need to be synced to CloudKit.
        ///
        /// - Note:
        ///   - If the system fields were saved previously (e.g. after a fetch or save operation), they are preferred to reconstruct the record.
        ///   - If no system fields are available, the zone is determined based on:
        ///     1. The zone of any referenced records (if cached),
        ///     2. A predefined `zoneName` that we get from `groupID` from `MYRecordConvertible`, or
        ///     3. A fallback default zone named `"MYiCloudZone"`.
        ///   - If decoding the saved system fields fails, an `assertionFailure` is triggered to help with debugging.
        func baseCKRecord(
            for recordReferencingRecordNames: [String] = [],
            using cache: Cache
        ) -> CKRecord {
            if let encodedSystemFields = cache.getEncodedSystemFields(for: recordName) {
                if let record = CKRecord(data: encodedSystemFields) {
                    return record
                } else {
                    assertionFailure("unable to reconstruct the CKRecord from the previous encodedSystemFields")
                }
            }
            
            let zoneID: CKRecordZone.ID
            var referenceZoneID: CKRecordZone.ID? = nil
            
            let referencedRecordNames = [parentRecordName].compactMap(\.self) + recordReferencingRecordNames
            for recordName in referencedRecordNames {
                if let data = cache.getEncodedSystemFields(for: recordName),
                   let zoneID = CKRecord(data: data)?.recordID.zoneID {
                    referenceZoneID = zoneID
                    break
                }
            }
            
            if let referenceZoneID {
                zoneID = referenceZoneID
            } else if let zoneName {
                if let existingZoneID = cache.getZoneIDs().first(where: { $0.zoneName == zoneName }) {
                    zoneID = existingZoneID
                } else {
                    zoneID = .init(zoneName: zoneName)
                }
            } else {
                zoneID = .init(zoneName: "MYiCloudZone")
            }
            
            return .init(
                recordType: recordType,
                recordID: .init(recordName: recordName, zoneID: zoneID)
            )
        }
    }
}

extension MYSyncEngine.Transaction {
    
    /// Determines the appropriate `CKDatabase.Scope` for the current record based on its zone ownership.
    ///
    /// This property inspects the `CKRecordZone.ID` of the record and returns:
    /// - `.private` if the zone is owned by the current user (`CKCurrentUserDefaultName`)
    /// - `.shared` otherwise, indicating that the record likely belongs to a shared database (e.g., from a CKShare)
    ///
    /// - Returns: The CloudKit database scope (`.private` or `.shared`) where this record should be synced.
    ///
    /// - Note:
    ///   - This is important for ensuring that the record is saved or fetched from the correct database,
    ///     especially in apps that support CloudKit sharing.
    ///   - The logic assumes that if the zone is not owned by the current user, the record belongs to a shared scope.
    func databaseScope(using cache: Cache) -> CKDatabase.Scope {
        let zoneID = record.baseCKRecord(for: referencingRecordNames, using: cache).recordID.zoneID

        if zoneID.ownerName == CKCurrentUserDefaultName {
            return .private
        } else {
            return .shared
        }
    }
    
    /// A list of record names that are referenced by the current transaction's properties.
    ///
    /// This computed property extracts the `recordName`s from all `.reference` values in the `properties` dictionary,
    /// allowing the system to identify dependencies or relationships to other records when building or syncing with CloudKit.
    ///
    /// - Returns: An array of `String` values representing the record names of all non-nil referenced records.
    ///
    /// - Note:
    ///   - This is useful when determining the appropriate `CKRecordZone.ID` for the current record,
    ///     especially when reconstructing a `CKRecord` that is part of a shared or linked structure.
    fileprivate var referencingRecordNames: [String] {
        var recordNames: [String] = []
        for value in properties.values {
            switch value {
                case .reference(let record, _):
                    if let recordName = record?.recordName {
                        recordNames.append(recordName)
                    }
                default:
                    continue
            }
        }
        return recordNames
    }
    
    /// Converts the current `MYTransaction` into a `CKRecord` that is ready to be synced with CloudKit.
    ///
    /// This method constructs a `CKRecord` by:
    /// - Reconstructing the base record using any previously saved system fields or inferred zone information.
    /// - Setting the parent record (if applicable) to maintain the hierarchical relationship.
    /// - Populating the record's fields with values stored in the `properties` dictionary.
    ///
    /// The mapping between local properties and `CKRecord` fields supports several types:
    /// `Int`, `Double`, `Float`, `Bool`, `Date`, `URL` (as `CKAsset`), `String`, and `CKRecord.Reference`.
    ///
    /// - Returns: A fully constructed `CKRecord` instance, or `nil` if base record creation fails.
    ///
    /// - Note:
    ///   - If the transaction has a parent record, it will be attached as a `.none` action reference.
    ///   - If a `.reference` property is `nil`, the corresponding field is cleared in the `CKRecord`.
    ///   - The function assumes that referenced records have valid base `CKRecord`s to derive `recordID`s from.
    ///
    /// - Warning:
    ///   - Ensure that asset URLs passed in `.asset` values are valid and accessible, as CloudKit requires the file to be reachable during the upload.
    ///   - The above is ensured and cleaned up on a successful sync.
    ///   - All field keys must match those expected by the corresponding CloudKit record type.
    func asCKRecord(using cache: Cache) -> CKRecord? {
        let ckRecord = record.baseCKRecord(for: referencingRecordNames, using: cache)
        
        if let parentRecordName = record.parentRecordName {
            ckRecord.parent = .init(
                recordID: .init(
                    recordName: parentRecordName,
                    zoneID: ckRecord.recordID.zoneID
                ),
                action: .none
            )
        } else {
            ckRecord.parent = nil
        }
        
        for (key, value) in properties {
            switch value {
                case .int(let int):
                    ckRecord[key] = int
                case .double(let double):
                    ckRecord[key] = double
                case .float(let float):
                    ckRecord[key] = float
                case .bool(let bool):
                    ckRecord[key] = bool
                case .date(let date):
                    ckRecord[key] = date
                case .asset(let assetURL):
                    if let assetURL {
                        ckRecord[key] = CKAsset(fileURL: assetURL)
                    }
                case .string(let string):
                    ckRecord[key] = string
                case .reference(let referencedRecord, let deleteRule):
                    if let referencedRecord {
                        let recordID = referencedRecord.baseCKRecord(using: cache).recordID
                        ckRecord[key] = CKRecord.Reference.init(
                            recordID: recordID,
                            action: deleteRule.referenceAction
                        )
                    } else {
                        ckRecord[key] = nil
                    }
            }
        }

        return ckRecord
    }
}
