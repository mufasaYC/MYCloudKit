import CloudKit
import XCTest
@testable import MYCloudKit

final class ReservedFieldKeyTests: XCTestCase {
    func testFindsAllReservedCustomFieldKeys() {
        let keys = [
            "title",
            "recordType",
            "creationDate",
            "modificationDate",
            "recordID",
            "recordChangeTag",
            "creatorUserRecordID",
            "lastModifiedUserRecordID"
        ]

        XCTAssertEqual(
            CKRecord.reservedCustomFieldKeys(in: keys),
            [
                "creationDate",
                "creatorUserRecordID",
                "lastModifiedUserRecordID",
                "modificationDate",
                "recordChangeTag",
                "recordID",
                "recordType"
            ]
        )
    }

    func testAllowsOrdinaryCustomFieldKeys() {
        XCTAssertTrue(
            CKRecord.reservedCustomFieldKeys(
                in: ["createdAt", "modifiedAt", "title"]
            ).isEmpty
        )
    }

    func testAssertionMessageExplainsHowToFixTheModel() {
        let message = CKRecord.reservedCustomFieldKeyMessage(
            keys: ["creationDate"],
            recordType: "Task"
        )

        XCTAssertTrue(message.contains("Task"))
        XCTAssertTrue(message.contains("creationDate"))
        XCTAssertTrue(message.contains("createdAt"))
        XCTAssertTrue(message.contains("MYRecordConvertible"))
    }
}
