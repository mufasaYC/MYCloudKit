//
//  MYSyncEngine+AccountUnavailableError.swift
//

import CloudKit

extension MYSyncEngine {
    /// The error in `syncState` and `fetchState` when iCloud can't be used on this device: no account is
    /// signed in, iCloud is turned off for the app, or it's restricted.
    ///
    /// Nothing has failed: queued changes stay on the device and sync once the account is available again.
    /// Apps can use it to show a "paused" state rather than a sync error.
    ///
    /// ```swift
    /// if case .stopped(_, let error as MYSyncEngine.AccountUnavailableError) = syncEngine.syncState {
    ///     // error.accountStatus is .noAccount, .restricted, .temporarilyUnavailable or .couldNotDetermine
    /// }
    /// ```
    ///
    /// It bridges to the `NSError` reported before this type existed (domain "CloudKit account cannot sync",
    /// code 403), so code that checks those keeps working.
    public struct AccountUnavailableError: Error, CustomNSError, LocalizedError {
        /// The account status that stopped the fetch or sync. Never `.available`.
        public let accountStatus: CKAccountStatus
        
        public init(accountStatus: CKAccountStatus) {
            self.accountStatus = accountStatus
        }
        
        public static let errorDomain = "CloudKit account cannot sync"
        
        public var errorCode: Int { 403 }
        
        public var errorDescription: String? {
            switch accountStatus {
                case .noAccount:
                    return "No iCloud account is signed in on this device."
                case .restricted:
                    return "iCloud is restricted on this device."
                case .temporarilyUnavailable:
                    return "The iCloud account is temporarily unavailable."
                default:
                    return "The iCloud account can't be used right now."
            }
        }
    }
}
