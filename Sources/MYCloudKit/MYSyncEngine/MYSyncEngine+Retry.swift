//
//  Created by Mustafa Yusuf on 13/10/26.
//

import CloudKit

extension MYSyncEngine {
    /// Decides how the engine reacts to a failed sync pass: honor Apple's retry-after,
    /// back off on transient errors, or pause on account-wide errors that retrying cannot fix.
    enum SyncRetryPolicy {
        static let initialBackoff: TimeInterval = 2
        static let maximumBackoff: TimeInterval = 5 * 60

        enum Kind {
            /// Account-wide problem (iCloud full, signed out, misconfigured container). Wait for the next foreground.
            case pause(CKError)
            /// CloudKit told us when to try again.
            case retryAfter(TimeInterval)
            /// Not retryable on a timer; keep the existing behavior of waiting for the next trigger.
            case other
            /// Network or server hiccup without a hint from CloudKit.
            case transient
        }

        private static let pauseCodes: Set<CKError.Code> = [
            .quotaExceeded,
            .notAuthenticated,
            .accountTemporarilyUnavailable,
            .managedAccountRestricted,
            .badContainer,
            .badDatabase,
            .missingEntitlement
        ]

        /// Kept in line with the codes `handleError` retries without counting an attempt,
        /// so automatic retries never push a transaction towards `maxRetryAttempts`.
        private static let transientCodes: Set<CKError.Code> = [
            .networkUnavailable,
            .networkFailure,
            .serverResponseLost,
            .zoneBusy,
            .serviceUnavailable,
            .requestRateLimited,
            .operationCancelled
        ]

        static func kind(of error: Error) -> Kind {
            guard let ckError = error as? CKError else {
                return .other
            }

            if ckError.code == .partialFailure,
               let partialErrors = ckError.partialErrorsByItemID,
               let kind = partialErrors.values.map(kind(of:)).max(by: isLessSignificant) {
                return kind
            }

            if pauseCodes.contains(ckError.code) {
                return .pause(ckError)
            }

            if let retryAfterSeconds = ckError.retryAfterSeconds, retryAfterSeconds > 0 {
                return .retryAfter(retryAfterSeconds)
            }

            if transientCodes.contains(ckError.code) {
                return .transient
            }

            return .other
        }

        /// Picks the error that best describes a failed pass.
        ///
        /// Priority: pause > largest retry-after > other > transient. Ranking `other` above `transient`
        /// means the engine only backs off automatically when every failure in the pass was transient.
        static func mostSignificantError(in errors: [Error]) -> Error? {
            errors.max { isLessSignificant(kind(of: $0), kind(of: $1)) }
        }

        /// Whether no further requests should be sent in the current pass.
        static func stopsSync(_ error: Error) -> Bool {
            switch kind(of: error) {
                case .pause, .retryAfter:
                    return true
                case .other, .transient:
                    return false
            }
        }

        /// Exponential backoff (2s, 4s, 8s, …) capped at `maximumBackoff`, scaled by `randomFactor` for jitter.
        static func backoffDelay(attempt: Int, randomFactor: Double) -> TimeInterval {
            let exponent = Double(max(attempt, 1) - 1)
            let delay = min(initialBackoff * pow(2, exponent), maximumBackoff)
            return delay * randomFactor
        }

        private static func isLessSignificant(_ lhs: Kind, _ rhs: Kind) -> Bool {
            if case .retryAfter(let lhsSeconds) = lhs, case .retryAfter(let rhsSeconds) = rhs {
                return lhsSeconds < rhsSeconds
            }
            return rank(of: lhs) < rank(of: rhs)
        }

        private static func rank(of kind: Kind) -> Int {
            switch kind {
                case .transient: return 0
                case .other: return 1
                case .retryAfter: return 2
                case .pause: return 3
            }
        }
    }

    /// When the engine may sync next, based on the outcome of previous passes.
    struct SyncRetryState {
        enum Outcome: Equatable {
            case none
            case paused
            case retry(at: Date)
        }

        /// Set from CloudKit's `retryAfterSeconds`. Nothing, not even a foreground, syncs before this.
        private(set) var retryAfterDate: Date?
        /// Set from our own backoff. Cleared on foreground or an explicit `beginSync()`.
        private(set) var backoffDate: Date?
        private(set) var consecutiveTransientFailures: Int = .zero
        private(set) var pauseError: CKError?

        var nextSyncAllowedAt: Date? {
            [retryAfterDate, backoffDate].compactMap { $0 }.max()
        }

        mutating func recordSuccess() {
            retryAfterDate = nil
            backoffDate = nil
            consecutiveTransientFailures = .zero
        }

        mutating func recordFailure(
            _ error: Error,
            now: Date = .now,
            randomFactor: Double = .random(in: 0.8...1.2)
        ) -> Outcome {
            switch SyncRetryPolicy.kind(of: error) {
                case .pause(let ckError):
                    pauseError = ckError
                    return .paused
                case .retryAfter(let seconds):
                    // CloudKit's hint replaces our own guess.
                    let date = now.addingTimeInterval(seconds)
                    retryAfterDate = date
                    backoffDate = nil
                    return .retry(at: date)
                case .transient:
                    consecutiveTransientFailures += 1
                    backoffDate = now.addingTimeInterval(
                        SyncRetryPolicy.backoffDelay(
                            attempt: consecutiveTransientFailures,
                            randomFactor: randomFactor
                        )
                    )
                    return .retry(at: nextSyncAllowedAt ?? now)
                case .other:
                    return .none
            }
        }

        /// Called on foreground or an explicit `beginSync()`. CloudKit's retry-after is always kept.
        mutating func resume() {
            pauseError = nil
            backoffDate = nil
        }
    }
}

extension MYSyncEngine {
    typealias ModifyRecordsResult = (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    )

    /// Runs `modify`, splitting the request in half whenever CloudKit rejects it with `.limitExceeded`.
    ///
    /// Once split, a half that fails has its items reported as per-record failures, and the remaining
    /// halves are failed with the same error without being sent, so a throttle mid-split is respected.
    /// Errors from the original, unsplit request are rethrown unchanged.
    static func modifyRecordsSplittingOnLimitExceeded(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        logger: Logger,
        modify: ([CKRecord], [CKRecord.ID]) async throws -> ModifyRecordsResult
    ) async throws -> ModifyRecordsResult {
        let itemCount = recordsToSave.count + recordIDsToDelete.count
        do {
            return try await modify(recordsToSave, recordIDsToDelete)
        } catch let error as CKError where error.code == .limitExceeded && itemCount > 1 {
            logger.log(
                "📦 Request with \(itemCount) records exceeded CloudKit limits — splitting it in two",
                level: .warning
            )

            let midpoint = itemCount / 2
            let firstSaveCount = min(midpoint, recordsToSave.count)
            let firstDeleteCount = midpoint - firstSaveCount
            let halves: [([CKRecord], [CKRecord.ID])] = [
                (Array(recordsToSave.prefix(firstSaveCount)), Array(recordIDsToDelete.prefix(firstDeleteCount))),
                (Array(recordsToSave.dropFirst(firstSaveCount)), Array(recordIDsToDelete.dropFirst(firstDeleteCount)))
            ]

            var result: ModifyRecordsResult = ([:], [:])
            /// Any failure other than a single oversized record (e.g. a throttle) stops the remaining halves.
            var stoppingError: Error?
            for (saves, deletes) in halves {
                let halfError: Error
                if let stoppingError {
                    halfError = stoppingError
                } else {
                    do {
                        let halfResult = try await modifyRecordsSplittingOnLimitExceeded(
                            saving: saves,
                            deleting: deletes,
                            logger: logger,
                            modify: modify
                        )
                        result.saveResults.merge(halfResult.saveResults) { _, new in new }
                        result.deleteResults.merge(halfResult.deleteResults) { _, new in new }
                        continue
                    } catch {
                        halfError = error
                        if (error as? CKError)?.code != .limitExceeded {
                            stoppingError = error
                        }
                    }
                }

                saves.forEach { result.saveResults[$0.recordID] = .failure(halfError) }
                deletes.forEach { result.deleteResults[$0] = .failure(halfError) }
            }
            return result
        }
    }
}
