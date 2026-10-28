//
//  MYSyncEngine+FetchCoalescer.swift
//

import Foundation

extension MYSyncEngine {
    /// Runs fetch passes one at a time. A request made while a pass runs doesn't start another pass
    /// alongside it; the running call makes one more pass when it finishes, however many requests arrived.
    ///
    /// Only accessed on the main actor.
    final class FetchCoalescer {
        private var isRunning = false
        private var needsAnotherPass = false
        
        @MainActor
        func run(_ pass: () async -> Void) async {
            guard !isRunning else {
                needsAnotherPass = true
                return
            }
            isRunning = true
            defer { isRunning = false }
            repeat {
                needsAnotherPass = false
                await pass()
            } while needsAnotherPass
        }
    }
}
