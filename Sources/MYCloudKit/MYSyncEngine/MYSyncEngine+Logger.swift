//
//  Created by Mustafa Yusuf on 08/05/25.
//

import Foundation

extension MYSyncEngine {
    public enum LogLevel: Int, Comparable {
        case debug = 0
        case info
        case warning
        case error
        case none
        
        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    struct Logger {
        
        private let currentLevel: LogLevel
        
        init(currentLevel: LogLevel) {
            self.currentLevel = currentLevel
        }
        
        func log(_ message: String, level: LogLevel = .info, error: Error? = nil) {
            guard level >= currentLevel else {
                return
            }
            
            let symbol: String
            switch level {
                case .debug: symbol = "🔍"
                case .info: symbol = "ℹ️"
                case .warning: symbol = "⚠️"
                case .error: symbol = "⛔"
                case .none: return
            }
            
            print("\(symbol) MYSyncKit: \(message)")
            if let error {
                print("   ⤷ Error: \(error.localizedDescription)")
            }
        }
        
        func log(_ message: String, error: Error) {
            log(message, level: .error, error: error)
        }
    }
}
