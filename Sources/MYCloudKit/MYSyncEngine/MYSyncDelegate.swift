//
//  Created by Mustafa Yusuf on 09/05/25.
//

import Foundation

public typealias MYRecordType = String

/// A protocol for handling record-level synchronization operations in CloudKit.
///
/// Conform to this protocol to define how your app interacts with the sync engine to manage CloudKit records.
/// `MYSyncDelegate` allows the sync engine (`MYSyncEngine`) to remain decoupled from your app-specific data models
/// while still performing necessary operations like saving, deleting, and syncing records.
///
/// By implementing this protocol, your app gains fine-grained control over how records are persisted, deleted,
/// and retried during syncing. This is crucial for managing complex hierarchical relationships between records
/// and ensuring that the app can handle synchronization failures gracefully.
///
/// ### Methods:
/// - **didReceiveRecordsToSave**: Called when new or updated records are ready to be saved locally.
/// - **didReceiveRecordsToDelete**: Called when records need to be deleted from local storage.
/// - **didReceiveGroupIDsToDelete**: Called when groups need to be removed - a group can be anything that is put as `myRootGroupID` in `MYRecordConvertible`.
/// - **handleUnsyncableRecord**: Handles records that failed to sync, allowing for custom resolution logic and retries, you can see the reason and then add records that need to be synced before it or send over the corrected record and it will put this in place of the current record in the queue position.
/// - **syncableRecordTypesInDependencyOrder**: Returns the list of record types eligible for syncing in the correct order (parent and references before child and records referenced respectably).
///
/// ### Example Usage:
/// Here’s how you might implement the methods of `MYSyncDelegate`:
/// ```swift
/// class MySyncDelegate: MYSyncDelegate {
///     func didReceiveRecordsToSave(_ records: [MYSyncEngine.FetchedRecord]) {
///         // Save records to the local database
///     }
///
///     func didReceiveRecordsToDelete(_ records: [(myRecordID: String, myRecordType: MYRecordType)]) {
///         // Delete specified records from the local database
///     }
///
///     func didReceiveGroupIDsToDelete(_ ids: [String]) {
///         // Delete groups (zones) based on their IDs
///     }
///
///     func handleUnsyncableRecord(recordID: String, recordType: MYRecordType, reason: String, error: Error) -> [any MYRecordConvertible]? {
///         // Handle failed records, fix and retry syncing them
///         return nil
///     }
///
///     func syncableRecordTypesInDependencyOrder() -> [MYRecordType] {
///         // Return records ordered by dependency (parents before children)
///         return ["Project", "Task", "Subtask"]
///     }
/// }
/// ```
///
/// ### Notes:
/// - **Hierarchy and Dependencies**: When syncing records that have references or hierarchical relationships (like parent-child),
///   the order of records is crucial. Always sync parent records first to ensure referenced records exist when needed.
///   For example, if a `Task` references a `Project`, `Project` should be synced first.
///
/// - **Handling Sync Failures**: The `handleUnsyncableRecord` method allows you to decide what to do when a record fails to sync,
///   whether you want to attempt to fix the error and retry the sync or ignore it.
public protocol MYSyncDelegate: AnyObject {
    
    /// Called when new or updated records are ready to be saved locally.
    ///
    /// - Parameter records: A dictionary where the key is the record type and the value is an array of `MYCloudEngine.Record` instances to be saved.
    func didReceiveRecordsToSave(_ records: [MYSyncEngine.FetchedRecord])
    
    /// Called when specific records need to be deleted from local storage.
    ///
    /// - Parameter records: An array of tuples containing `myRecordID` and `myRecordType`, identifying which records to delete.
    func didReceiveRecordsToDelete(_ records: [(myRecordID: String, myRecordType: MYRecordType)])
    
    /// Called when entire record groups need to be removed (e.g. shared zones or logical groupings, this is basically anything that could have been the `rootGroupID`).
    ///
    /// - Parameter ids: An array of group identifiers that should be deleted from the local store.
    func didReceiveGroupIDsToDelete(_ ids: [String])
    
    /// Called when a specific record could not be synced successfully, allowing the delegate to correct and optionally retry syncing it.
    ///
    /// - Parameters:
    ///   - id: The unique identifier of the unsyncable record.
    ///   - type: The record type (usually a CloudKit record type or equivalent).
    ///   - reason: A developer-readable reason string explaining why syncing failed.
    ///   - error: The underlying `Error` that caused the sync failure.
    /// - Returns: An optional array of fixed records (conforming to `MYRecordConvertible`) to retry syncing, or `nil` to ignore and skip.
    func handleUnsyncableRecord(
        recordID: String,
        recordType: MYRecordType,
        reason: String,
        error: Error
    ) -> [any MYRecordConvertible]?
    
    /// Returns the list of record types that the app supports for syncing, in hierarchical dependency order.
    ///
    /// This order ensures that parent records or records referenced by others are synced before child or dependent records.
    /// CloudKit requires referenced records to exist before they can be linked to, so ordering is critical for successful sync.
    ///
    /// For example, if a `Task` references a `Project` record using a `.reference`, then `Project` should appear before `Task`.
    ///
    /// - Important: Ensure the record type used as `rootGroupID` (typically the zone root) is listed first if it is being shared.
    ///
    /// - Returns: An array of record type strings, ordered from top-most parent to deepest child.
    ///
    /// ### Example:
    /// ```swift
    /// func syncableRecordTypesInDependencyOrder() -> [MYRecordType] {
    ///     return [
    ///         "Project",   // zone root / top-level
    ///         "Task",      // references Project
    ///         "Subtask"    // references Task
    ///     ]
    /// }
    /// ```
    func syncableRecordTypesInDependencyOrder() -> [MYRecordType]
}
