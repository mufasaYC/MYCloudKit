# MYCloudKit ☁️

**A powerful, modern Swift library for syncing your app’s data with CloudKit — reliably, efficiently, and beautifully.**

Built with 💙 by [@mufasayc](https://x.com/mufasayc) — follow on X, Instagram, or wherever you hang out. Same handle, same vibes.

---

## ✨ Features

- ✅ Transaction-based syncing (create, update, delete, child cleanup, zone cleanup)
- 🔁 Automatic retry & conflict handling
- 📦 Handles CKAssets, references, system fields, custom zones, and sharing
- 🧠 Smart caching for offline support and recovery
- 📡 CloudKit subscription support (real-time sync triggers)
- 🧩 Drop-in `MYRecordConvertible` protocol for easy model integration
- 👀 Observable sync & fetch states for clean UI binding
- 🧪 Testable architecture (no singletons)

---

## 🧱 Installation

### Using Swift Package Manager

```swift
.package(url: "https://github.com/yourusername/MYCloudKit.git", from: "1.0.0")
```

## 🚀 Getting Started
1. Conform your models to `MYRecordConvertible`
```swift
struct Task: MYRecordConvertible {
    let id: String
    let title: String

    var myRecordID: String { id }
    var myRecordType: String { "Task" }
    var myGroupID: String? { "DefaultGroup" }
    var myParentID: String? { nil }

    var myProperties: [String: MYDataType] {
        [
            "title": .string(title)
        ]
    }
}
```

2. Initialize the engine
```swift
let engine = MYSyncEngine()
```

4. Delegate Integration
```swift
engine.delegate = self

func didReceiveRecordsToSave(_ records: [String: [MYSyncEngine.FetchedRecord]]) { … }
func didReceiveRecordsToDelete(_ records: [(myRecordID: String, myRecordType: String)]) { … }
func didReceiveGroupIDsToDelete(_ ids: [String]) { … }
func handleUnsyncableRecord( id: String, type: String, reason: String, error: Error) -> [any MYRecordConvertible]? { … }
func supportedRecordTypes() -> [String] { … }
```

3. Sync or delete records
```swift
engine.sync(myTask)
engine.delete(myTask)
```

## 🔄 Sharing
```swift
let (share, container) = try await engine.createShare(
    with: "My Shared Task List",
    for: myTask
)
```

## 🔐 Notes
MYCloudKit only syncs private and shared scopes — public database not supported yet.

## 📬 Contact
Have feedback, feature requests, or just want to say hi?
Reach out to @mufasayc on X or raise an issue on here!

(more documentation coming soon)
