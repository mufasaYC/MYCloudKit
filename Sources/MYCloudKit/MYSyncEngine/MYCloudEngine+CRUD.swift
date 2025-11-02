//
//  Created by Mustafa Yusuf on 06/05/25.
//

import Foundation

extension MYSyncEngine {
    
    /// Creates or updates a transaction for a given record that conforms to `MYRecordConvertible`.
    /// - Parameter record: The record that needs to be created or updated.
    /// - Returns: A `Transaction` object representing the create/update transaction.
    func getCreateUpdateTransaction(for record: any MYRecordConvertible) -> Transaction {
        var transaction: Transaction = .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(
                recordName: record.myRecordID,
                recordType: record.myRecordType,
                zoneName: record.myRootGroupID,
                parentRecordName: record.myParentID
            ),
            properties: [:]
        )
        
        var properties: [String: Transaction.RecordValue] = [:]
        
        // Mapping properties of the record to transaction properties
        for (key, value) in record.myProperties {
            switch value {
                case .int(let int):
                    properties.updateValue(.int(int), forKey: key)
                case .double(let double):
                    properties.updateValue(.double(double), forKey: key)
                case .float(let float):
                    properties.updateValue(.float(float), forKey: key)
                case .bool(let bool):
                    properties.updateValue(.bool(bool), forKey: key)
                case .date(let date):
                    properties.updateValue(.date(date), forKey: key)
                case .asset(let data):
                    if let data {
                        do {
                            // Saving the asset data and updating the properties with asset URL
                            let url = try cache.saveAssetData(data, with: key, for: transaction)
                            properties.updateValue(.asset(url), forKey: key)
                        } catch {
                            // If there is an error in saving the asset data, log the error
                            logger.log("📁 Error in saving the asset data", error: error)
                        }
                    }
                case .fileURL(let url):
                    properties.updateValue(.asset(url), forKey: key)
                case .string(let string):
                    properties.updateValue(.string(string), forKey: key)
                case .reference(let reference, let deleteRule):
                    if let reference {
                        // Creating reference for a related record and adding it to the properties
                        properties.updateValue(
                            .reference(
                                .init(
                                    recordName: reference.myRecordID,
                                    recordType: reference.myRecordType,
                                    zoneName: reference.myRootGroupID,
                                    parentRecordName: nil
                                ),
                                deleteRule: deleteRule
                            ),
                            forKey: key
                        )
                    } else {
                        // In case no reference exists, set the delete rule to none
                        properties.updateValue(.reference(nil, deleteRule: .none), forKey: key)
                    }
                case .array(let values):
                    /// `kind` is going to see the kind of items you're adding to the array and see if it is homogeneous
                    var kind: String? = nil
                    var recordValues: [Transaction.RecordValue] = []
                    for value in values {
                        switch value {
                            case .int(let int):
                                if kind == nil { kind = "int" }
                                assert(kind == "int", "array of different types is not supported")
                                recordValues.append(.int(int))
                            case .double(let double):
                                if kind == nil { kind = "double" }
                                assert(kind == "double", "array of different types is not supported")
                                recordValues.append(.double(double))
                            case .float(let float):
                                if kind == nil { kind = "double" }
                                assert(kind == "double", "array of different types is not supported")
                                if let float {
                                    recordValues.append(.double(Double(float)))
                                }
                            case .bool(let bool):
                                if kind == nil { kind = "bool" }
                                assert(kind == "bool", "array of different types is not supported")
                                recordValues.append(.bool(bool))
                            case .date(let date):
                                if kind == nil { kind = "date" }
                                assert(kind == "date", "array of different types is not supported")
                                recordValues.append(.date(date))
                            case .asset:
                                assertionFailure("Array of data is not supported by CloudKit")
                                continue
                            case .fileURL:
                                assertionFailure("Array of files is not supported by CloudKit")
                                continue
                            case .string(let string):
                                if kind == nil { kind = "string" }
                                assert(kind == "string", "array of different types is not supported")
                                recordValues.append(.string(string))
                            case .reference(let reference, let deleteRule):
                                if kind == nil { kind = "reference" }
                                assert(kind == "reference", "array of different types is not supported")
                                if let reference {
                                    // Creating reference for a related record and adding it to the properties
                                    recordValues.append(
                                        .reference(
                                            .init(
                                                recordName: reference.myRecordID,
                                                recordType: reference.myRecordType,
                                                zoneName: reference.myRootGroupID,
                                                parentRecordName: nil
                                            ),
                                            deleteRule: deleteRule
                                        )
                                    )
                                }
                            case .array:
                                assertionFailure("You're testing me? Array of arrays in CloudKit? Nice try! :P")
                                continue
                        }
                    }
                    properties.updateValue(.array(recordValues), forKey: key)
            }
        }
        
        // Assigning the mapped properties to the transaction
        transaction.properties = properties
        
        return transaction
    }
    
    /// Syncs the given record
    /// - Parameter record: The record to be synchronized.
    /// - Note: Make sure the `myRecordType` is defined in the `syncableRecordTypesInDependencyOrder()`
    public func sync(_ record: any MYRecordConvertible) {
        if let delegate {
            assert(
                delegate.syncableRecordTypesInDependencyOrder().contains(record.myRecordType),
                "\(record.myRecordType) is not mentioned in MYSyncDelegate's `syncableRecordTypesInDependencyOrder()`"
            )
        }
        
        // Get the transaction for creating or updating the record
        let transaction = getCreateUpdateTransaction(for: record)
        
        // Add the transaction to the queue and trigger the sync operation
        self.queue.append(transaction)
        
        // Log the action of adding the transaction
        self.logger.log(
            "🌀 Queued sync for \(record.myRecordType) (\(record.myRecordID))",
            level: .debug
        )
        
        self.queueUpdated()
    }
    
    /// Deletes the given record and optionally deletes its child records.
    /// - Parameters:
    ///   - record: The record to be deleted.
    ///   - shouldDeleteChildRecords: A flag indicating whether child records of the given record should also be deleted. Defaults to `false`.
    ///   Set it to `true` if you this record is the `myParentID` for other records and you want them to all be cascade deleted.
    public func delete(_ record: any MYRecordConvertible, shouldDeleteChildRecords: Bool = false) {
        if let delegate {
            assert(
                delegate.syncableRecordTypesInDependencyOrder().contains(record.myRecordType),
                "\(record.myRecordType) is not mentioned in MYSyncDelegate's `syncableRecordTypesInDependencyOrder()`"
            )
        }
        
        let transactionRecord: Transaction.Record = .init(
            recordName: record.myRecordID,
            recordType: record.myRecordType,
            zoneName: record.myRootGroupID,
            parentRecordName: record.myParentID
        )
        
        if record.myRecordID == record.myRootGroupID {
            // If the record to be deleted is the root group, delete the zone
            let transaction: Transaction = .init(
                id: .init(),
                operationType: .deleteZone,
                record: transactionRecord,
                properties: [:]
            )
            
            self.queue.append(transaction)
        } else {
            if shouldDeleteChildRecords {
                // If the flag is true, delete child records as well
                let transaction: Transaction = .init(
                    id: .init(),
                    operationType: .deleteChildRecords,
                    record: transactionRecord,
                    properties: [:]
                )
                
                self.queue.append(transaction)
            }
            
            // Delete the record itself
            let transaction: Transaction = .init(
                id: .init(),
                operationType: .deleteRecord,
                record: transactionRecord,
                properties: [:]
            )
            
            self.queue.append(transaction)
        }
        
        // Log the action of adding the delete transaction
        self.logger.log(
            "🗑️ Queued delete for \(record.myRecordType) (\(record.myRecordID))",
            level: .debug
        )
        
        self.queueUpdated()
    }
}
