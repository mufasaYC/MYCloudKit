//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit

fileprivate struct UserDefaultKey {
    static let prefix = "myCloudKitSync"
    
    // Keys for storing tokens and subscription status
    static let privatePreviousServerChangeToken = "\(prefix)_privatePreviousServerChangeToken"
    static let sharedPreviousServerChangeToken = "\(prefix)_sharedPreviousServerChangeToken"
    static let didSavePrivateSubscription = "\(prefix)_didSavePrivateSubscription"
    static let didSaveSharedSubscription = "\(prefix)_didSaveSharedSubscription"
}

extension UserDefaults {
    
    /// Stores or retrieves the previous server change token for the private database.
    fileprivate var privatePreviousServerChangeToken: CKServerChangeToken? {
        get {
            guard let tokenString = string(forKey: UserDefaultKey.privatePreviousServerChangeToken),
                  let data = Data(base64Encoded: tokenString) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            setValue(newValue?.asString(), forKey: UserDefaultKey.privatePreviousServerChangeToken)
        }
    }
    
    /// Stores or retrieves the previous server change token for the shared database.
    fileprivate var sharedPreviousServerChangeToken: CKServerChangeToken? {
        get {
            guard let tokenString = string(forKey: UserDefaultKey.sharedPreviousServerChangeToken),
                  let data = Data(base64Encoded: tokenString) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            setValue(newValue?.asString(), forKey: UserDefaultKey.sharedPreviousServerChangeToken)
        }
    }
    
    /// Retrieves the server change token for the given database scope.
    func previousServerChangeToken(for scope: CKDatabase.Scope) -> CKServerChangeToken? {
        switch scope {
            case .private:
                return privatePreviousServerChangeToken
            case .shared:
                return sharedPreviousServerChangeToken
            default:
                assertionFailure("Unsupported database scope")
        }
        return nil
    }
    
    /// Stores the server change token for the given database scope.
    func setPreviousServerChangeToken(for scope: CKDatabase.Scope, _ value: CKServerChangeToken?) {
        switch scope {
            case .private:
                privatePreviousServerChangeToken = value
            case .shared:
                sharedPreviousServerChangeToken = value
            default:
                assertionFailure("Unsupported database scope")
        }
    }
}

extension UserDefaults {
    
    /// Stores the server change token for a specific record zone.
    func setServerChangeToken(_ token: CKServerChangeToken?, for zoneID: CKRecordZone.ID) {
        let key = "\(UserDefaultKey.prefix)-previousServerChangeToken-\(zoneID.zoneName)-\(zoneID.ownerName)"
        setValue(token?.asString(), forKey: key)
    }

    /// Retrieves the server change token for a specific record zone.
    func getServerChangeToken(for zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        let key = "\(UserDefaultKey.prefix)-previousServerChangeToken-\(zoneID.zoneName)-\(zoneID.ownerName)"
        guard let tokenString = string(forKey: key),
              let data = Data(base64Encoded: tokenString) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

extension UserDefaults {
    
    /// Indicates whether the private subscription has been saved.
    fileprivate var didSavePrivateSubscription: Bool {
        get {
            bool(forKey: UserDefaultKey.didSavePrivateSubscription)
        }
        set {
            setValue(newValue, forKey: UserDefaultKey.didSavePrivateSubscription)
        }
    }
    
    /// Indicates whether the shared subscription has been saved.
    fileprivate var didSaveSharedSubscription: Bool {
        get {
            bool(forKey: UserDefaultKey.didSaveSharedSubscription)
        }
        set {
            setValue(newValue, forKey: UserDefaultKey.didSaveSharedSubscription)
        }
    }
    
    /// Returns whether a subscription was already saved for a given scope.
    func didSaveSubscription(for scope: CKDatabase.Scope) -> Bool {
        switch scope {
            case .private:
                return didSavePrivateSubscription
            case .shared:
                return didSaveSharedSubscription
            default:
                assertionFailure("Unsupported database scope")
                return false
        }
    }
    
    /// Marks that a subscription has been saved for the given scope.
    func setSavedSubscription(for scope: CKDatabase.Scope) {
        switch scope {
            case .private:
                didSavePrivateSubscription = true
            case .shared:
                didSaveSharedSubscription = true
            default:
                assertionFailure("Unsupported database scope")
        }
    }
}
