import CloudKit
import XCTest
@testable import MYCloudKit

final class DatabaseScopeConfigurationTests: XCTestCase {
    func testBothScopesUsePrivateThenSharedOrder() {
        XCTAssertEqual(
            MYSyncEngine.orderedDatabaseScopes(from: [.private, .shared]),
            [.private, .shared]
        )
    }

    func testPrivateOnlyConfigurationExcludesSharedScope() {
        XCTAssertEqual(
            MYSyncEngine.orderedDatabaseScopes(from: [.private]),
            [.private]
        )
    }

    func testSharedOnlyConfigurationExcludesPrivateScope() {
        XCTAssertEqual(
            MYSyncEngine.orderedDatabaseScopes(from: [.shared]),
            [.shared]
        )
    }
}
