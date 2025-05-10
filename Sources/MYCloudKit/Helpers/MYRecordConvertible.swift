//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit

/// A type-safe representation of values that can be stored in a CloudKit record.
/// Used internally by `MYCloudEngine` to encode/decode data for syncing.
///
/// This enum helps encode your data for storage in `CKRecord`.
///
public enum MYRecordValue {
    case int(Int?)
    case double(Double?)
    case float(Float?)
    case bool(Bool?)
    case date(Date?)
    case asset(Data?)
    case fileURL(URL?)
    case string(String?)
    
    /// Represents a reference to another record conforming to `MYRecordConvertible`, along with its deletion behavior.
    case reference((any MYRecordConvertible)?, deleteRule: DeleteRule)

    /// Specifies how a reference behaves when the target record is deleted.
    public enum DeleteRule: Codable {
        /// No action is taken when the referenced record is deleted.
        case none

        /// The current record is deleted if the referenced record is deleted.
        case deleteSelf

        /// Maps to CloudKit's `CKRecord.ReferenceAction`.
        var referenceAction: CKRecord.ReferenceAction {
            switch self {
                case .none: return .none
                case .deleteSelf: return .deleteSelf
            }
        }
    }
}

/// A protocol your data models conform to for CloudKit syncing via `MYSyncEngine`.
///
/// This protocol defines the minimal structure required to translate your model into a `CKRecord`
/// and back. It supports record typing, custom zones (grouping), hierarchical relationships, and
/// all CloudKit-supported field types.
///
/// Use this when you want to persist and sync data to iCloud across devices and users.
///
/// ### Example:
/// ```swift
/// struct Task: MYRecordConvertible {
///     let id: String
///     let title: String
///     let project: Project
///
///     var myRecordID: String { id }
///     var myRecordType: String { "Task" }
///     var myRootGroupID: String? { project.id }  // All tasks in the same project go in the same zone
///     var myParentID: String? { nil }
///
///     var myProperties: [String: MYRecordValue] {
///         [
///             "title": .string(title),
///             "project": .reference(
///                 project,
///                 deleteRule: .deleteSelf // when project is deleted, delete the task as well
///             )
///         ]
///     }
/// }
/// ```
///
/// > Tip: Use `myRootGroupID` to group related records into a custom zone — helpful for sharing entire sets.
/// > Use `myParentID` when building a hierarchy, but prefer `.reference` in `myProperties` if you don’t need record-based sharing.
public protocol MYRecordConvertible {
    
    /// Unique identifier for the CloudKit record, ideally your UUID/Identifier.
    var myRecordID: String { get }

    /// The CloudKit record type (e.g., "Task", "User", "Note"). This is whatever your model, class or struct is called.
    var myRecordType: String { get }

    /// Optional identifier for the group this record belongs to.
    ///
    /// Used to organize related records into the same CloudKit zone.
    /// For example, tasks in a project or notes in a folder.
    /// **Disclaimer**: Do this correctly, thing of it like a tree's root node, all child nodes should provide only the first root node's identifier
    var myRootGroupID: String? { get }

    /// Optional identifier for the parent record.
    ///
    /// Used to model hierarchical relationships like folders and files.
    /// Come's handy for sharing records, but you're better off sharing the entire group using `myRootGroupID`
    /// (I'll do a better job at documenting this in the future, just ask me if you have any doubts here @mufsasayc)
    ///
    /// Use sparringly and if it can be a reference in `myProperties`, ideally use that unless you know a little bit of CloudKit and are going to specifically do record sharing instead of zone sharing.
    var myParentID: String? { get }

    /// Dictionary of key-value pairs representing the record's fields.
    ///
    /// Keys are field names; values must be an `MYRecordValue`.
    /// Includes support for primitive types, CloudKit references, and assets.
    var myProperties: [String: MYRecordValue] { get }
}

extension MYRecordConvertible {
    public var myParentID: String? { nil }
}
