import CloudKit
import XCTest
@testable import MYCloudKit

final class AccountUnavailableErrorTests: XCTestCase {

    func testKeepsTheAccountStatus() {
        let error: Error = MYSyncEngine.AccountUnavailableError(accountStatus: .noAccount)

        XCTAssertEqual((error as? MYSyncEngine.AccountUnavailableError)?.accountStatus, .noAccount)
    }

    func testBridgesToTheNSErrorReportedBefore() {
        let error = MYSyncEngine.AccountUnavailableError(accountStatus: .restricted) as NSError

        XCTAssertEqual(error.domain, "CloudKit account cannot sync")
        XCTAssertEqual(error.code, 403)
    }

    func testDescribesEachStatus() {
        let statuses: [CKAccountStatus] = [.noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine]
        let descriptions = statuses.map {
            MYSyncEngine.AccountUnavailableError(accountStatus: $0).localizedDescription
        }

        XCTAssertEqual(Set(descriptions).count, 4)
        XCTAssertTrue(descriptions.allSatisfy { !$0.isEmpty })
    }
}
