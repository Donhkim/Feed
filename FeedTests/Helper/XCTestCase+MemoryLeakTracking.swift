//
//  XCTestCase+MemoryLeakTracking.swift
//  FeedTests
//
//  Created by Don Kim on 2020/01/01.
//

import XCTest

public extension XCTestCase {
    func trackForMemoryLeaks(_ instance: AnyObject, file: StaticString = #file, line: UInt = #line) {
        addTeardownBlock { [weak instance] in
            XCTAssertNil(instance, "Instance should have been deallocated. Potential memory leak.", file:file, line:line)
        }
    }
}
