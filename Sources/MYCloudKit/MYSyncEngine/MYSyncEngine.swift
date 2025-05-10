//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit

/// `MYSyncEngine` is the core engine responsible for managing all CloudKit sync operations.
///
/// It abstracts complex CloudKit operations like record creation, updates, deletions, asset handling,
/// retry logic, and sharing into a simple, queue-based interface.
///
/// ### Responsibilities:
/// - Queues and processes transactions (`Transaction`) for creating, updating, and deleting records.
/// - Maintains `syncState` and `fetchState` for progress tracking and error feedback.
/// - Fetches new and changed records using `fetch()`.
/// - Automatically retries syncs for transient errors (network loss, token expiry, etc.).
/// - Supports `CKShare` generation for record and zone-based collaboration.
///
/// ### Features:
/// - ✅ Sync to private and shared databases
/// - ✅ Supports custom record zones (via `myRootGroupID`)
/// - ✅ CKAsset file support
/// - ✅ Share individual records or entire zones
/// - ✅ Parent and reference relationship support
/// - ✅ Real-time sync triggers via CloudKit subscriptions
/// - ✅ Configurable retry mechanism (`maxRetryAttempts`)
///
/// ### Usage:
/// ```swift
/// let syncEngine = MYSyncEngine()
/// syncEngine.delegate = self
///
/// syncEngine.sync(myTask) // Enqueue for sync
/// syncEngine.delete(myProject) // Delete a record or zone
///
/// // Observe states
/// syncEngine.$syncState
/// syncEngine.$fetchState
/// ```
///
/// ### Notes:
/// - You must implement `MYSyncDelegate` to handle local saves, deletes, and recoveries.
/// - Syncing respects reference and parent-child hierarchy; referenced records must be synced first (this is your responsibility).
/// - For sharing: if `myRecordID == myRootGroupID`, a zone share is created(advisable); otherwise, a record share is made.
///
/// ### Example Record Share:
/// If you’re syncing a `Task` that references a `Project`, make sure `Project` is synced first and appears earlier
/// in `syncableRecordTypesInDependencyOrder()`.
public final class MYSyncEngine: ObservableObject {
    
    /// The CloudKit container used for syncing.
    let ckContainer: CKContainer
    
    /// The custom cache used for retrieving encodedSystemFields, the zones on device and other things for a reliable sync
    let cache: Cache
    
    /// Logger for logging logs. Duh!
    let logger: Logger
    
    /// The `UserDefaults` instance for storing tokens and sync metadata.
    let userDefaults: UserDefaults
    
    /// The maximum number of retry attempts for failed sync operations.
    let maxRetryAttempts: Int
    
    /// Represents the state of a sync operation.
    public enum SyncState {
        case idle
        case stopped(queueCount: Int, error: Error?)
        case syncing(queueCount: Int)
        case completed(date: Date)
        
        /// Indicates whether a sync operation is currently active.
        var isActive: Bool {
            switch self {
                case .idle, .stopped, .completed:
                    return false
                case .syncing:
                    return true
            }
        }
    }

    /// Represents the state of a fetch operation.
    public enum FetchState {
        case idle
        case fetching
        case stopped(error: Error)
        case completed(date: Date)
        
        /// Indicates whether a fetch operation is currently active.
        var isActive: Bool {
            switch self {
                case .idle, .completed, .stopped:
                    return false
                case .fetching:
                    return true
            }
        }
    }
    
    /// Current state of the sync operation, published for UI observation.
    @Published public var syncState: SyncState = .idle
    
    /// Current state of the fetch operation, published for UI observation.
    @Published public var fetchState: FetchState = .idle

    /// Queue of pending transactions to be synced.
    var queue: [Transaction] {
        didSet {
            cache.cacheTransactionQueue(queue)
        }
    }
    
    /// Optional delegate to receive sync lifecycle callbacks.
    public weak var delegate: MYSyncDelegate?
    
    /// Initializes a new `MYCloudEngine` instance.
    ///
    /// - Parameters:
    ///   - containerIdentifier: Optional identifier for a custom CloudKit container. If `nil`, the default container is used.
    ///   - userDefaultsSuiteName: Optional suite name for using a shared `UserDefaults` instance, useful for app groups or extensions.
    ///   - maxRetryAttempts: The number of retry attempts before giving up on failed sync attempts. Defaults to 3.
    ///   - logLevel: The minimum log level to be printed. Defaults to `.debug`.
    public init(
        containerIdentifier: String? = nil,
        userDefaultsSuiteName: String? = nil,
        maxRetryAttempts: Int = 3,
        logLevel: LogLevel = .debug
    ) {
        let syncCache: Cache = .init()
        self.cache = syncCache
        self.queue = syncCache.retrieveTransactionQueue()
        self.logger = Logger(currentLevel: logLevel)
        // Set the CKContainer to either custom or default.
        if let containerIdentifier {
            self.logger.log(
                "☁️ Using custom CloudKit container '\(containerIdentifier)'",
                level: .info
            )
            self.ckContainer = .init(identifier: containerIdentifier)
        } else {
            self.logger.log(
                "☁️ Using default CloudKit container",
                level: .info
            )
            self.ckContainer = .default()
        }
        
        // Use shared UserDefaults if userDefaultsSuiteName is provided, else fall back to standard.
        if let userDefaultsSuiteName, let sharedUserDefaults = UserDefaults(suiteName: userDefaultsSuiteName) {
            self.logger.log(
                "💾 Using UserDefaults with suite '\(userDefaultsSuiteName)'",
                level: .info
            )
            self.userDefaults = sharedUserDefaults
        } else {
            self.logger.log(
                "💾 Using Standard UserDefaults",
                level: .info
            )
            self.userDefaults = .standard
        }
        
        self.maxRetryAttempts = maxRetryAttempts
        
        // Subscribe to private and shared CloudKit database changes for real-time sync triggers.
        self.subscribeToChanges(in: .private)
        self.subscribeToChanges(in: .shared)
        
        // Start the initial sync operation.
        self.sync()
    }
}
