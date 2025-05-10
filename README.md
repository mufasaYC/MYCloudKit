**`MYCloudKit`** is a framework designed to simplify and automate CloudKit syncing, deletion, and fetching operations for your app. This guide explains how to integrate and use the various features of `MYCloudKit`.

## 🛠 Getting Your Model Ready to Sync

To sync your models with CloudKit using **`MYCloudKit`**, you must conform them to the **`MYRecordConvertible`** protocol. This enables the sync engine to understand how to convert your custom data types into CKRecords.

### ✅ Step-by-step Guide

1. **Conform Your Model to `MYRecordConvertible`** 

Add protocol conformance to your struct or class.

2. **Implement Record Identification**
    - `myRecordID`: A unique identifier (e.g., UUID or your model’s primary key).
    - `myRecordType`: The record type (e.g., "Task", "Note").
3. **Group Records with `myRootGroupID`** (optional)

This lets you group related records (like all tasks in a project) into a CloudKit zone. Especially useful when sharing.

> If you project has tasks, tags, subtasks and more other such models, make sure everyone's `myRootGroupID` is the `projectID`.

4. **Define Hierarchies with `myParentID`** (optional)

Use this to model parent-child relationships like folders and files. 

If A is the parent of B and B is the parent of C, sharing A would share A, B and C. Sharing B would only share B and C.

> Prefer `.reference(...)` in `myProperties` unless you specifically want record-level sharing.

5. **Map Properties to CloudKit-Compatible Values**

Use the `myProperties` dictionary to define each field using `MYRecordValue` (e.g. .string, .bool, .reference, etc.).

### Example: Syncing a Task Model

```swift
struct Task: MYRecordConvertible {
    let id: String
    let title: String
    let isDone: Bool
    let project: Project

    var myRecordID: String { id }
    var myRecordType: String { "Task" }
    var myRootGroupID: String? { project.id }

    var myProperties: [String: MYRecordValue] {
        [
            "title": .string(title),
            "isDone": .bool(isDone),
            "project": .reference(project, deleteRule: .deleteSelf)
        ]
    }
}
```

> ✅ With this setup, `MYCloudKit` knows how to save, update, delete, and share your Task model in CloudKit.

## Steps for Syncing, Deleting, and Fetching

1. Set Up MYSyncEngine

Before you start syncing, initialize the MYSyncEngine, which is responsible for managing all CloudKit operations:

```swift
let syncEngine = MYSyncEngine()
syncEngine.delegate = self  // Implement MYSyncDelegate to handle syncing and fetching
```

> Note: If you're going to be fetching/syncing from outside the main app target, make sure you provide `userDefaultsSuiteName` of the App Group so we can fetch correctly and efficiently.

> Provide the correct `containerIdentifier` if you're not using the default one. 

2. Syncing Records

To sync records, call the `sync(_:)` method on the `MYSyncEngine`. This will enqueue the record for syncing with CloudKit. The engine automatically handles uploading the record, retrying if necessary, and ensuring dependent records are synced in the correct order.

Example of syncing a Task record:

```swift
let task = Task(id: "task123", title: "Finish homework", isDone: false)
syncEngine.sync(task)
```

> It is your responsibility to sync data sensibly. Don't sync a newly created Task first and then the Project it belongs to (provided it has never been synced) which is conceptually incorrect. A new Project should be synced first and then the newly created Task. This is to ensure that Project that the Task to reference in CloudKit is already present before it (either in the queue or in CloudKit itself).

3. Deleting Records

To delete records, use the `delete(_:)` method. You can delete either a single record or an entire group of records (such as a Task and all its subtasks). The engine ensures dependent records are deleted in the right order and also handles zone deletion if needed.

Example of deleting a Task:

```swift
syncEngine.delete(task)
```

> By default CloudKit doesn't cascade delete all records that may reference a task. If you want this, we have exposed a parameter `shouldDeleteChildRecords` which defaults to `false`. You can set this to `true`, if you desire that behaviour.

4. Fetching Records

To fetch records from CloudKit, use the `fetch()` method. This fetches records modified or created since the last sync, ensuring your app stays up-to-date.

Example of fetching records:

```swift
await syncEngine.fetch()
```

You can observe the fetchState to track whether the fetch operation is in progress, completed, or failed.

5. Handle Record Relationships

`MYCloudKit` supports hierarchical relationships between records. For example, a Task may reference a Project record. To ensure proper syncing, define the correct parent-child relationships using `myParentID` and myRootGroupID in your MYRecordConvertible models.

6. Use CloudKit Sharing

For apps that support sharing, `MYCloudKit` integrates with CloudKit’s `CKShare` feature. You can create shares at the record level (for individual records and their nested records using a proper child-parent hierarchy) or zone level (for whole groups of records).

### Example of creating a share for a Task:

```swift
let (share, container) = try await syncEngine.createShare(with: "Shared Task List", for: task)
let controller = UICloudSharingController(share: share, container: container)
// present that controller or wrap it in a UIViewControllerRepresentable :P
```

> ⚠ Note: Don't spend hours debugging why sharing isn't working. Add `CKSharingSupported` in your info.plist and set it to `true` / `YES`.

To accept a share, make sure you have implemented the following function in your `SceneDelegate` , that is all that is required to enable sync. Pretty simple, right?

```swift
func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task {
            try await syncEngine.acceptShare(
                cloudKitShareMetadata: cloudKitShareMetadata
            )
        }
    }
```

7. MYSyncDelegate

Don't forget to conform to the `MYSyncDelegate` protocol. This delegate handles all sync-related communication between your app’s local storage and CloudKit.

You’ll implement methods to:

- Save and delete synced records locally
- Remove entire record groups (zones)
- Recover from sync failures by correcting broken records
- Provide the list of record types your app uses (in order of dependency)

### Record Type Order Matters

The most important method is:

```swift
func syncableRecordTypesInDependencyOrder() -> [MYRecordType]
```

This function tells `MYCloudKit` the order in which your records should be given back to you in order to save. The order **must respect reference and parent-child dependencies**.

If a record (e.g. Task) references another record (e.g. Project), then Project must appear *before* Task in the array. So when you receive the array of records to save, we'll send [Project] first to you to save and then the [Task] so that when Task is referencing the Project, it is locally present in your database!
func syncableRecordTypesInDependencyOrder() -> [MYRecordType] {
return [
"Project",   // Zone root / parent
"Task",      // References Project
"Subtask"    // References Task
]
}

### ✅ Example:

```swift
func syncableRecordTypesInDependencyOrder() -> [MYRecordType] {
    return [
        "Project",   // Root
        "Tag",       // Tasks may reference them so they're before Task
        "Task",      // References Project and Tags
        "Subtask"    // References Task
    ]
}
```

7. Handling Sync Errors and Retries

`MYCloudKit` automatically retries failed sync operations up to a configurable limit (`maxRetryAttempts` provided while initialising `CKSyncEngine`). If a record fails to sync, you can inspect the error and decide whether to fix the issue and retry or exclude the record.

You can implement the `handleUnsyncableRecord` method in `MYSyncDelegate` to customize error handling:

```swift
func handleUnsyncableRecord(recordID: String, recordType: String, reason: String, error: Error) -> [any MYRecordConvertible]? {
    // Return a fixed version of the record for retrying, or nil to skip syncing
    return nil
}
```

## ☁️ Built with Care

`MYCloudKit` is crafted to simplify CloudKit syncing so you can focus on building great apps and not wrestling with APIs as I have for the initial years.

If you found this helpful or you’re using it in your app, I’d love to hear from you!

Feel free to reach out on [X (Twitter)](https://x.com/mufasayc), [Instagram](https://instagram.com/mufasayc), or wherever you hang out. 

I’m probably there as @mufasayc.
