//
//  Created by Mustafa Yusuf on 05/05/25.
//

import CloudKit

extension CKRecord {
    /// Property names CloudKit reserves for record metadata. Assigning a
    /// custom value to any of these keys raises an Objective-C exception.
    static let reservedCustomFieldKeys: Set<String> = [
        "creationDate",
        "creatorUserRecordID",
        "lastModifiedUserRecordID",
        "modificationDate",
        "recordChangeTag",
        "recordID",
        "recordType"
    ]

    static func reservedCustomFieldKeys<S: Sequence>(in keys: S) -> [String] where S.Element == String {
        keys.filter(reservedCustomFieldKeys.contains).sorted()
    }

    static func reservedCustomFieldKeyMessage(
        keys: [String],
        recordType: String
    ) -> String {
        let keyList = keys.map { "'\($0)'" }.joined(separator: ", ")
        return "MYCloudKit cannot sync '\(recordType)' because myProperties contains "
            + "CloudKit-reserved key(s): \(keyList). Rename these keys in your "
            + "MYRecordConvertible implementation (for example, use 'createdAt' "
            + "instead of 'creationDate')."
    }
}

extension CKRecord {
    
    /// Initializes a `CKRecord` from previously encoded system fields data.
    /// - Parameter data: A `Data` object representing the encoded system fields of a `CKRecord`.
    /// - Returns: A new `CKRecord` instance if decoding succeeds; otherwise, `nil`.
    convenience init?(data: Data) {
        do {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            self.init(coder: coder)
            coder.finishDecoding()
        } catch {
            return nil
        }
    }
    
    /// Encodes only the system fields of the record (metadata used by CloudKit) into `Data`.
    /// This is useful for persisting state locally (e.g., before saving or updating in the cloud).
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        self.encodeSystemFields(with: coder)
        return coder.encodedData
    }
}

extension CKRecord {
    /// Returns a typed value for the given key from the record.
    ///
    /// This function attempts to cast the value stored in the record to the specified type `T`.
    /// It also includes a special case: if the underlying value is a `CKRecord.Reference`
    /// and `T` is `String`, it will return the referenced record's `recordName`.
    ///
    /// - Parameter key: The key of the field in the `CKRecord`.
    /// - Returns: A value of type `T` if the cast is successful, or `nil` if the type does not match or the value is missing.
    ///
    /// ### Example:
    /// ```swift
    /// let name: String? = record.value(for: "name")           // Regular String
    /// let parentID: String? = record.value(for: "parentRef")  // Reference → recordName
    /// let score: Int? = record.value(for: "score")            // Int field
    /// ```
    func value<T: Codable>(for key: String) -> T? {
        let fieldValue = self[key]
        
        if let data = fieldValue as? Data,
           let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }

        return rawValue(for: key)
    }
    
    func value<T>(for key: String) -> T? {
        rawValue(for: key)
    }
    
    private func rawValue<T>(for key: String) -> T? {
        let rawValue = self[key]

        // Special case: CKRecord.Reference → String (recordName)
        if T.self == String.self,
           let reference = rawValue as? CKRecord.Reference {
            return reference.recordID.recordName as? T
        }

        return rawValue as? T
    }
}
