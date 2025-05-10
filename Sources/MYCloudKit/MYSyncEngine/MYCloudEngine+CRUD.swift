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
                            assertionFailure(error.localizedDescription)
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
            assert(delegate.syncableRecordTypesInDependencyOrder().contains(record.myRecordType))
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
        
        self.sync()
    }
    
    /// Deletes the given record and optionally deletes its child records.
    /// - Parameters:
    ///   - record: The record to be deleted.
    ///   - shouldDeleteChildRecords: A flag indicating whether child records of the given record should also be deleted. Defaults to `false`.
    ///   Set it to `true` if you this record is the `myParentID` for other records and you want them to all be cascade deleted.
    public func delete(_ record: any MYRecordConvertible, shouldDeleteChildRecords: Bool = false) {
        if let delegate {
            assert(delegate.syncableRecordTypesInDependencyOrder().contains(record.myRecordType))
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
        
        self.sync()
    }
}
