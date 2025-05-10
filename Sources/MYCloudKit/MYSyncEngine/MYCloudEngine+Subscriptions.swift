//
//  Created by Mustafa Yusuf on 06/05/25.
//

import CloudKit.CKSubscription

extension MYSyncEngine {

    /// Subscribes to silent push notifications for changes in the given CloudKit database scope.
    ///
    /// CloudKit uses subscriptions to notify the app when records in a database change.
    /// This method ensures the app subscribes only once per scope (private/shared) by checking a local flag.
    /// It sets `shouldSendContentAvailable` to `true` to receive silent pushes, which are used for background syncing.
    ///
    /// - Parameter scope: The `CKDatabase.Scope` to subscribe to (e.g., `.private`, `.shared`).
    func subscribeToChanges(in scope: CKDatabase.Scope) {
        
        // Avoid re-subscribing if already done
        guard !userDefaults.didSaveSubscription(for: scope) else {
            return
        }

        // Create a unique subscription for the scope
        let subscription = CKDatabaseSubscription(subscriptionID: "changes-\(scope.rawValue)")

        // Configure for silent push (no alert, badge, or sound)
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification

        Task { [weak self] in
            guard let self else { return }

            do {
                self.logger.log(
                    "📡 Attempting to subscribe to record changes in '\(scope.name)' scope",
                    level: .info
                )

                // Register the subscription with CloudKit
                try await ckContainer.database(with: scope).save(subscription)

                self.logger.log(
                    "✅ Successfully subscribed to record changes in '\(scope.name)' scope",
                    level: .info
                )

                // Save flag so we don't subscribe again unnecessarily
                userDefaults.setSavedSubscription(for: scope)

            } catch {
                self.logger.log(
                    "🛑 Failed to subscribe to record changes in '\(scope.name)' scope",
                    error: error
                )
            }
        }
    }
}
