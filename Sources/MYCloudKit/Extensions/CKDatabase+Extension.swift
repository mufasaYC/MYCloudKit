//
//  Created by Mustafa Yusuf on 07/05/25.
//

import CloudKit

extension CKDatabase.Scope {
    
    // for logging purposes
    var name: String {
        switch self {
            case .private:
                return "private"
            case .shared:
                return "shared"
            case .public:
                return "public"
            @unknown default:
                return "Unknown"
        }
    }
}
