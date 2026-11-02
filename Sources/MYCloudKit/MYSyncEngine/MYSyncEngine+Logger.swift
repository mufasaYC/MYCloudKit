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
    
    /// Receives MYCloudKit's log messages instead of the console. See `MYSyncEngine.init(logHandler:)`.
    ///
    /// - Parameters:
    ///   - level: The message's level. Never `.none`.
    ///   - message: The message, without the level symbol or "MYSyncKit:" prefix.
    ///   - error: The error the message is about, if any.
    public typealias LogHandler = @Sendable (_ level: LogLevel, _ message: String, _ error: Error?) -> Void
    
    struct Logger {
        
        private let currentLevel: LogLevel
        private let handler: LogHandler?
        
        init(currentLevel: LogLevel, handler: LogHandler? = nil) {
            self.currentLevel = currentLevel
            self.handler = handler
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
            
            if let handler {
                handler(level, message, error)
                return
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
