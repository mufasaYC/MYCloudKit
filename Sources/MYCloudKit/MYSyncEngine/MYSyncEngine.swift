//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit
#if canImport(UIKit)
import UIKit
#endif

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

    /// The CloudKit database scopes used by `fetch()` and automatic change subscriptions.
    ///
    /// By default, the engine monitors both the private and shared databases. Limit this set
    /// when an app does not use one of those databases to avoid unnecessary CloudKit work.
    public let databaseScopes: Set<CKDatabase.Scope>

    /// Keeps scope-dependent work deterministic while allowing callers to configure scopes as a set.
    var orderedDatabaseScopes: [CKDatabase.Scope] {
        Self.orderedDatabaseScopes(from: databaseScopes)
    }

    static func orderedDatabaseScopes(
        from databaseScopes: Set<CKDatabase.Scope>
    ) -> [CKDatabase.Scope] {
        [.private, .shared].filter { databaseScopes.contains($0) }
    }
    
    private var syncWorkItem: DispatchWorkItem? = nil
    
    /// The single pending retry, scheduled from CloudKit's retry-after or our own backoff.
    private var retryWorkItem: DispatchWorkItem? = nil
    
    /// Tracks when syncing may resume after a failed pass. Only accessed on the main actor.
    var retryState = SyncRetryState()
    
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
    
    @Published public var cloudKitAccountStatus: CKAccountStatus = .available
    
    /// Set when CloudKit reports an account-wide error that retrying cannot fix, such as
    /// `.quotaExceeded`, an iCloud account problem, or a misconfigured container.
    ///
    /// While this is set, edits stay queued but no sync is attempted. It is cleared, and syncing
    /// resumes, when the app returns to the foreground or `beginSync()` is called.
    @Published public private(set) var syncPausedError: CKError? = nil
    
    private var didAddForegroundNotificationObserver: Bool = false
    
    /// Runs fetch passes one at a time, adding a pass for any `beginFetch()` call made during one.
    private let fetchCoalescer = FetchCoalescer()

    /// Queue of pending transactions to be synced.
    private let transactionQueue: TransactionQueue
    
    /// A snapshot of the pending transactions. Use `mutateQueue(_:)` to change them.
    var queue: [Transaction] {
        transactionQueue.snapshot
    }
    
    /// Changes the queue atomically and persists it once.
    ///
    /// - Important: Never call the delegate or anything that may queue records from `body`; the lock is not reentrant.
    @discardableResult
    func mutateQueue<T>(_ body: (inout [Transaction]) -> T) -> T {
        transactionQueue.mutate(body)
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
    ///   - databaseScopes: At least one private and/or shared database to fetch and subscribe to. Defaults to both.
    public init(
        containerIdentifier: String? = nil,
        userDefaultsSuiteName: String? = nil,
        maxRetryAttempts: Int = 3,
        logLevel: LogLevel = .debug,
        databaseScopes: Set<CKDatabase.Scope> = [.private, .shared]
    ) {
        precondition(
            !databaseScopes.isEmpty,
            "MYSyncEngine requires at least one CloudKit database scope."
        )
        precondition(
            databaseScopes.subtracting([.private, .shared]).isEmpty,
            "MYSyncEngine supports only the private and shared CloudKit database scopes."
        )

        let logger = Logger(currentLevel: logLevel)
        let syncCache: Cache = .init(suiteName: userDefaultsSuiteName, logger: logger)
        self.cache = syncCache
        let transactionQueue = TransactionQueue(cache: syncCache)
        self.transactionQueue = transactionQueue
        self.logger = logger

        // Reclaim staged assets left behind by transactions that already finished.
        let queuedTransactionIDs = Set(transactionQueue.snapshot.map(\.id))
        DispatchQueue.global(qos: .utility).async {
            syncCache.removeOrphanedTransactionFolders(keeping: queuedTransactionIDs)
        }
        self.databaseScopes = databaseScopes
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
        
        // Subscribe only to configured CloudKit database changes for real-time sync triggers.
        self.orderedDatabaseScopes.forEach { scope in
            self.subscribeToChanges(in: scope)
        }
    }
    
    private func addForegroundNotificationObserver() {
        guard !didAddForegroundNotificationObserver else {
            return
        }
        didAddForegroundNotificationObserver = true
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForegroundNotification),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }
    
    @objc
    private func willEnterForegroundNotification() {
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.beginFetch()
            await self.beginSync()
        }
    }

    /// Asks CloudKit again when an earlier error marked the account unavailable, so a passing iCloud hiccup doesn't
    /// stop fetching and syncing. watchOS has no foreground notification to recover from it otherwise.
    func refreshCloudKitAccountStatusIfNeeded() async -> Bool {
        guard cloudKitAccountStatus != .available else {
            return true
        }
        if let status = try? await ckContainer.accountStatus() {
            self.cloudKitAccountStatus = status
        }
        return cloudKitAccountStatus == .available
    }

    /// Starts syncing the queue.
    ///
    /// Calling this resumes a sync paused by `syncPausedError` and skips any pending backoff,
    /// but still waits for a retry-after requested by CloudKit.
    @MainActor
    public func beginSync() {
        startSync(resumingPause: true)
    }
    
    @MainActor
    private func startSync(resumingPause: Bool) {
        addForegroundNotificationObserver()
        if resumingPause {
            retryState.resume()
            publishSyncPausedError()
        }
        
        guard !syncState.isActive, !queue.isEmpty else {
            return
        }
        
        if retryState.pauseError != nil {
            refreshStoppedQueueCount()
            logger.log(
                "⏸️ Sync is paused until the app returns to the foreground or beginSync() is called",
                level: .debug
            )
            return
        }
        
        if let nextSyncAllowedAt = retryState.nextSyncAllowedAt, nextSyncAllowedAt > .now {
            refreshStoppedQueueCount()
            scheduleRetry(at: nextSyncAllowedAt)
            return
        }
        
        cancelScheduledRetry()
        self.syncState = .syncing(queueCount: queue.count)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let state = await self.sync()
            // Update the retry state before publishing, so observers of `syncState` see it consistently.
            self.applyRetryPolicy(after: state)
            self.syncState = state
        }
    }
    
    @MainActor
    private func applyRetryPolicy(after state: SyncState) {
        switch state {
            case .completed:
                retryState.recordSuccess()
            case .stopped(_, let error?):
                switch retryState.recordFailure(error) {
                    case .paused:
                        cancelScheduledRetry()
                        logger.log(
                            "⏸️ Pausing sync until the app returns to the foreground or beginSync() is called",
                            level: .warning
                        )
                    case .retry(let date):
                        scheduleRetry(at: date)
                        logger.log(
                            "⏳ Retrying sync in \(Int(date.timeIntervalSinceNow.rounded(.up)))s",
                            level: .info
                        )
                    case .none:
                        break
                }
            case .stopped, .idle, .syncing:
                break
        }
        publishSyncPausedError()
    }
    
    @MainActor
    private func scheduleRetry(at date: Date) {
        retryWorkItem?.cancel()
        let delay = max(date.timeIntervalSinceNow, .zero)
        let workItem: DispatchWorkItem = .init { [weak self] in
            Task { @MainActor in
                self?.startSync(resumingPause: false)
            }
        }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: workItem)
        self.retryWorkItem = workItem
    }
    
    @MainActor
    private func cancelScheduledRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }
    
    @MainActor
    private func publishSyncPausedError() {
        if syncPausedError != retryState.pauseError {
            syncPausedError = retryState.pauseError
        }
    }
    
    /// Keeps `queueCount` current while syncing is held back, as it was when every edit retried.
    @MainActor
    private func refreshStoppedQueueCount() {
        if case .stopped(let queueCount, let error) = syncState, queueCount != queue.count {
            syncState = .stopped(queueCount: queue.count, error: error)
        }
    }
    
    /// Fetches changes from CloudKit and publishes the result in `fetchState`.
    ///
    /// A call made while a fetch is running returns at once, and the running fetch makes one more pass when it
    /// finishes. That pass may already have read its change token before the change that prompted the call
    /// (a silent push arriving mid-fetch), which would otherwise stay hidden until the next push or foreground.
    @MainActor
    public func beginFetch() async {
        addForegroundNotificationObserver()
        await fetchCoalescer.run { [weak self] in
            guard let self else {
                return
            }
            self.fetchState = .fetching
            self.fetchState = await self.fetch()
        }
    }
    
    func queueUpdated() {
        syncWorkItem?.cancel()
        let workItem: DispatchWorkItem = .init {
            Task { [weak self] in
                await self?.startSync(resumingPause: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: workItem)
        self.syncWorkItem = workItem
    }
    
    func interceptError(_ error: Error) {
        guard let ckError = error as? CKError else {
            return
        }
        
        switch ckError.code {
            case .managedAccountRestricted:
                self.cloudKitAccountStatus = .restricted
            case .notAuthenticated:
                self.cloudKitAccountStatus = .noAccount
            case .accountTemporarilyUnavailable:
                self.cloudKitAccountStatus = .temporarilyUnavailable
            default:
                break
        }
    }
}
