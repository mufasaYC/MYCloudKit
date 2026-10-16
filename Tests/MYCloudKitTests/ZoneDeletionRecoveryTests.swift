import CloudKit
import XCTest
@testable import MYCloudKit

final class ZoneDeletionRecoveryTests: XCTestCase {
    private let journals = CKRecordZone.ID(zoneName: "Journals", ownerName: CKCurrentUserDefaultName)
    private let zens = CKRecordZone.ID(zoneName: "Zens", ownerName: CKCurrentUserDefaultName)
    private let sharedZone = CKRecordZone.ID(zoneName: "Shared", ownerName: "owner")

    // MARK: - Zones to fetch

    func testDeletedZonesAreNotFetched() {
        let zoneIDs = MYSyncEngine.zoneIDsToFetch(
            cached: [journals, zens],
            modified: [],
            deleted: [journals],
            in: .private
        )

        XCTAssertEqual(zoneIDs, [zens])
    }

    func testRecreatedZonesAreFetchedOnce() {
        let zoneIDs = MYSyncEngine.zoneIDsToFetch(
            cached: [zens],
            modified: [journals, zens],
            deleted: [journals],
            in: .private
        )

        XCTAssertEqual(zoneIDs, [zens, journals])
    }

    func testZonesToFetchAreFilteredByScope() {
        XCTAssertEqual(
            MYSyncEngine.zoneIDsToFetch(cached: [journals, sharedZone], modified: [], deleted: [], in: .private),
            [journals]
        )
        XCTAssertEqual(
            MYSyncEngine.zoneIDsToFetch(cached: [journals, sharedZone], modified: [], deleted: [], in: .shared),
            [sharedZone]
        )
    }

    // MARK: - Zone cache

    func testUpdatedZoneIDsRemovesDeletedZones() {
        XCTAssertEqual(
            MYSyncEngine.updatedZoneIDs(existing: [journals, zens], modified: [], deleted: [journals]),
            [zens]
        )
    }

    func testUpdatedZoneIDsKeepsRecreatedZones() {
        XCTAssertEqual(
            MYSyncEngine.updatedZoneIDs(existing: [zens], modified: [journals], deleted: [journals]),
            [zens, journals]
        )
    }

    func testUpdatedZoneIDsDeduplicates() {
        XCTAssertEqual(
            MYSyncEngine.updatedZoneIDs(existing: [journals, zens], modified: [zens, journals], deleted: []),
            [journals, zens]
        )
    }

    // MARK: - Deleted groups

    func testDeletedGroupIDsAreDeduplicated() {
        XCTAssertEqual(MYSyncEngine.deletedGroupIDs([journals, zens, journals]), ["Journals", "Zens"])
    }

    // MARK: - Expired token retry

    func testRetriedZonesReplaceTheirFirstAttempt() {
        let staleRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "stale", zoneID: journals))
        let freshRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "fresh", zoneID: journals))
        let otherRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "other", zoneID: zens))

        var changes = MYSyncEngine.ZoneChanges()
        changes.recordsToSave = [staleRecord, otherRecord]
        changes.expiredZoneErrors = [journals: CKError(.changeTokenExpired)]

        var retry = MYSyncEngine.ZoneChanges()
        retry.recordsToSave = [freshRecord]

        changes.replaceResults(for: [journals], with: retry)

        XCTAssertEqual(changes.recordsToSave.map(\.recordID.recordName), ["other", "fresh"])
        XCTAssertTrue(changes.expiredZoneErrors.isEmpty)
        XCTAssertTrue(changes.errors.isEmpty)
    }

    func testZoneThatExpiresAgainStillFails() {
        var changes = MYSyncEngine.ZoneChanges()
        changes.expiredZoneErrors = [journals: CKError(.changeTokenExpired)]

        var retry = MYSyncEngine.ZoneChanges()
        retry.expiredZoneErrors = [journals: CKError(.changeTokenExpired)]

        changes.replaceResults(for: [journals], with: retry)

        XCTAssertEqual(Array(changes.expiredZoneErrors.keys), [journals])
    }

    // MARK: - Discarding a deleted zone's metadata

    func testDiscardMetadataOnlyAffectsDeletedZone() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let suiteName = "MYCloudKitTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let cache = makeCache(at: directoryURL)
        let token = try makeServerChangeToken()
        userDefaults.setServerChangeToken(token, for: journals)
        userDefaults.setServerChangeToken(token, for: zens)
        cache.setZoneIDs([journals, zens])
        let journalRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "journal", zoneID: journals))
        let zenRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "zen", zoneID: zens))
        cache.saveEncodedSystemFields(data: journalRecord.encodedSystemFields, for: "journal")
        cache.saveEncodedSystemFields(data: zenRecord.encodedSystemFields, for: "zen")

        MYSyncEngine.discardMetadata(forDeletedZones: [journals], userDefaults: userDefaults, cache: cache)

        XCTAssertNil(userDefaults.getServerChangeToken(for: journals))
        XCTAssertNotNil(userDefaults.getServerChangeToken(for: zens))
        XCTAssertEqual(cache.getZoneIDs(), [zens])
        XCTAssertNil(cache.getEncodedSystemFields(for: "journal"))
        XCTAssertNotNil(cache.getEncodedSystemFields(for: "zen"))
    }

    func testDiscardMetadataKeepsSharedZoneSystemFields() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let suiteName = "MYCloudKitTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let cache = makeCache(at: directoryURL)
        userDefaults.setServerChangeToken(try makeServerChangeToken(), for: sharedZone)
        cache.setZoneIDs([sharedZone])
        let sharedRecord = CKRecord(recordType: "Item", recordID: .init(recordName: "shared", zoneID: sharedZone))
        cache.saveEncodedSystemFields(data: sharedRecord.encodedSystemFields, for: "shared")

        MYSyncEngine.discardMetadata(forDeletedZones: [sharedZone], userDefaults: userDefaults, cache: cache)

        XCTAssertNil(userDefaults.getServerChangeToken(for: sharedZone))
        XCTAssertTrue(cache.getZoneIDs().isEmpty)
        // Re-synced records keep routing to the shared database instead of a new private zone.
        XCTAssertNotNil(cache.getEncodedSystemFields(for: "shared"))
    }

    // MARK: - Encoded system fields filenames

    func testPlainRecordNamesKeepTheirExistingFile() {
        XCTAssertEqual(MYSyncEngine.Cache.encodedSystemFieldsFileName(for: "Day 03"), "Day 03.bin")
    }

    func testRecordNamesWithSlashRoundTrip() {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let cache = makeCache(at: directoryURL)
        let recordName = "ck_challenge_day_B921F50E-5691-4AE5-A76C-0AC73E4A22C1/Day 03"
        let record = CKRecord(recordType: "Item", recordID: .init(recordName: recordName, zoneID: journals))

        cache.saveEncodedSystemFields(data: record.encodedSystemFields, for: recordName)
        XCTAssertEqual(
            cache.getEncodedSystemFields(for: recordName).flatMap(CKRecord.init(data:))?.recordID.recordName,
            recordName
        )

        cache.deleteEncodedSystemFields(in: journals)
        XCTAssertNil(cache.getEncodedSystemFields(for: recordName))
    }

    func testLongRecordNamesRoundTrip() {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let cache = makeCache(at: directoryURL)
        let recordName = String(repeating: "a", count: 255)
        let data = Data("fields".utf8)

        XCTAssertLessThanOrEqual(MYSyncEngine.Cache.encodedSystemFieldsFileName(for: recordName).utf8.count, 255)
        cache.saveEncodedSystemFields(data: data, for: recordName)
        XCTAssertEqual(cache.getEncodedSystemFields(for: recordName), data)

        cache.deleteEncodedSystemFields(for: recordName)
        XCTAssertNil(cache.getEncodedSystemFields(for: recordName))
    }

    // MARK: - Helpers

    private func makeServerChangeToken() throws -> CKServerChangeToken {
        // CKServerChangeToken has no public initializer; decode an empty archive of one.
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: PlaceholderToken.self)
        archiver.encode(PlaceholderToken(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        )
    }

    private func makeCache(at directoryURL: URL) -> MYSyncEngine.Cache {
        .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
    }
}

@objc(MYCloudKitTestsPlaceholderToken)
private final class PlaceholderToken: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    override init() {}
    init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}
