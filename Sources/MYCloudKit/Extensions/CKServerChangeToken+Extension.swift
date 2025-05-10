//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit.CKServerChangeToken

extension CKServerChangeToken {
    
    /// Converts the server change token into a Base64-encoded string for storage (e.g., in UserDefaults).
    ///
    /// - Returns: A Base64 string representation of the token, or `nil` if encoding fails.
    func asString() -> String? {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
            return data.base64EncodedString()
        } catch {
            assertionFailure("❌ Failed to encode CKServerChangeToken to string: \(error.localizedDescription)")
            return nil
        }
    }
}
