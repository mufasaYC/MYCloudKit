//
//  File.swift
//  MYCloudKit
//
//  Created by Mustafa Yusuf on 11/08/25.
//

import Foundation

extension Array {
    public func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
