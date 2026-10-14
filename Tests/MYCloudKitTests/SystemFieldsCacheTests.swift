import XCTest
@testable import MYCloudKit

final class SystemFieldsCacheTests: XCTestCase {
    private var directoryURL: URL!
    private var cache: MYSyncEngine.Cache!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
        cache = .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    func testRecordNameWithSlashIsCached() {
        let data = Data("system fields".utf8)

        cache.saveEncodedSystemFields(data: data, for: "ck_challenge_day_ABC/Day 01")

        XCTAssertEqual(cache.getEncodedSystemFields(for: "ck_challenge_day_ABC/Day 01"), data)
        XCTAssertNil(cache.getEncodedSystemFields(for: "ck_challenge_day_ABC"))
    }

    func testPlainRecordNamesKeepTheirExistingFile() {
        let name = "ck_asset_01363FE9-AE11-6C64-C2F5-9D8B0F5FD7B7_img_0"

        XCTAssertEqual(cache.encodedSystemFieldsURL(for: name).lastPathComponent, name + ".bin")
    }
}
