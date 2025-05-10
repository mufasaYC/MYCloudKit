//
//  Created by Mustafa Yusuf on 08/05/25.
//

import CloudKit

extension MYSyncEngine {

    /// Creates a `CKShare` for the given record, enabling collaboration via CloudKit sharing.
    ///
    /// This function handles both zone-based and record-based sharing transparently:
    ///
    /// - If the record being shared is the root of its group in the `MYRecordConvertible` (i.e. its `myRecordID` is equal to `myRootGroupID`),
    ///   a **zone-level share** is created. This allows sharing the entire group (zone) of related records,
    ///   which is ideal when your model represents a group or project (e.g., a shared folder or task list).
    ///
    /// - Otherwise, a **record-level share** is created using `CKShare(rootRecord:)`, which shares only the specific record
    ///   and its related hierarchy. CloudKit will include all records that are reachable via `.parent` references.
    ///   You define the `myParentID` on the `MYRecordConvertible` and `MYCloudKit` sets this hierarchy up for you!
    ///   So it is important that all related child records in your app properly set the `.parent` field to establish the hierarchy.
    ///   CloudKit uses this structure to determine what records to include in the shared scope.
    ///
    /// The function also checks if an existing share already exists for the record and reuses it if possible.
    /// Both the main record and its share are saved in a single transaction to ensure consistency.
    ///
    /// - Parameters:
    ///   - title: A displayable title for the share (visible in share sheet).
    ///   - record: The model to be shared, conforming to `MYRecordConvertible`.
    ///
    /// - Returns: A tuple containing the saved `CKShare` and the associated `CKContainer`.
    /// - Throws: An error if the share could not be created or saved.
    public func createShare(
        with title: String,
        for record: any MYRecordConvertible
    ) async throws -> (share: CKShare, container: CKContainer) {
        
        let transaction = getCreateUpdateTransaction(for: record)

        guard let ckRecord = transaction.asCKRecord(using: cache) else {
            throw NSError(
                domain: "MYSync",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Could not convert record to CKRecord"]
            )
        }

        let databaseScope = transaction.databaseScope(using: cache)
        let database = ckContainer.database(with: databaseScope)
        var shareRecord: CKShare

        // Reuse existing share if one already exists
        if let existingShareID = ckRecord.share?.recordID,
           let existingShare = try? await database.record(for: existingShareID) as? CKShare {
            shareRecord = existingShare
        } else if ckRecord.recordID.recordName == ckRecord.recordID.zoneID.zoneName {
            // This handles the case of a CKRecordZone sharing
            shareRecord = CKShare(recordZoneID: ckRecord.recordID.zoneID)
        } else {
            shareRecord = CKShare(rootRecord: ckRecord)
        }

        // Assign a visible title for the share
        shareRecord[CKShare.SystemFieldKey.title] = title

        // Save both the record and its share in a single transaction
        let result = try await database.modifyRecords(
            saving: [ckRecord, shareRecord],
            deleting: [],
            savePolicy: .allKeys
        )

        // Extract and return the updated CKShare
        for (key, result) in result.saveResults where key == shareRecord.recordID {
            switch result {
                case .success(let updatedRecord as CKShare):
                    return (updatedRecord, ckContainer)
                case .success:
                    return (shareRecord, ckContainer) // Return local share as fallback
                case .failure(let error):
                    throw error
            }
        }

        throw NSError(domain: "MYSync", code: 404, userInfo: [NSLocalizedDescriptionKey: "Failed to save or locate CKShare"])
    }

    /// Accepts a shared CloudKit record and fetches updated shared data.
    ///
    /// - Parameter metadata: The `CKShare.Metadata` received via the SceneDelegate.
    public func acceptShare(cloudKitShareMetadata metadata: CKShare.Metadata) async throws {
        self.logger.log(
            "🤝 Accepting CloudKit share",
            level: .info
        )

        do {
            try await ckContainer.accept(metadata)
            self.logger.log(
                "🎉 Share accepted successfully",
                level: .info
            )
        } catch {
            self.logger.log(
                "🛑 Failed to accept CloudKit share",
                level: .error,
                error: error
            )
            throw error
        }

        // Refresh local shared records
        try await fetch(in: .shared)
    }
}
