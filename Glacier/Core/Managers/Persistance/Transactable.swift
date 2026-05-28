//
//  Transactable.swift
//  Glacier
//
//  Created by andyfriedman on 1/9/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

// A base class for DatabaseStorage and AnyDatabaseQueue.
@objc
public class Transactable: NSObject {
    fileprivate let asyncWriteQueue = DispatchQueue(label: "com.glacier.asyncWrite")

    public func read(file: String = #file,
                     function: String = #function,
                     line: Int = #line,
                     block: (GRDBReadTransaction) -> Void) {
        fatalError("Method should be implemented by subclasses.")
    }

    public func write(file: String = #file,
                      function: String = #function,
                      line: Int = #line,
                      block: (GRDBWriteTransaction) -> Void) {
        fatalError("Method should be implemented by subclasses.")
    }
}

// MARK: - Async Methods

public extension Transactable {
    @objc(asyncReadWithBlock:)
    func asyncReadObjC(block: @escaping (GRDBReadTransaction) -> Void) {
        asyncRead(file: "objc", function: "block", line: 0, block: block)
    }

    @objc(asyncReadWithBlock:completion:)
    func asyncReadObjC(block: @escaping (GRDBReadTransaction) -> Void, completion: @escaping () -> Void) {
        asyncRead(file: "objc", function: "block", line: 0, block: block, completion: completion)
    }

    func asyncRead(file: String = #file,
                   function: String = #function,
                   line: Int = #line,
                   block: @escaping (GRDBReadTransaction) -> Void,
                   completionQueue: DispatchQueue = .main,
                   completion: @escaping () -> Void = {}) {
        DispatchQueue.global().async {
            self.read(file: file, function: function, line: line, block: block)

            completionQueue.async(execute: completion)
        }
    }
}

// MARK: - Async Methods

// NOTE: This extension is not @objc. See SDSDatabaseStorage+Objc.h.
public extension Transactable {
    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (GRDBWriteTransaction) -> Void) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completion: { })
    }

    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (GRDBWriteTransaction) -> Void,
                    completion: @escaping () -> Void) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completionQueue: .main,
                   completion: completion)
    }

    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (GRDBWriteTransaction) -> Void,
                    completionQueue: DispatchQueue,
                    completion: @escaping () -> Void) {
        self.asyncWriteQueue.async {
            self.write(file: file,
                       function: function,
                       line: line,
                       block: block)

            completionQueue.async(execute: completion)
        }
    }
}

// MARK: - Value Methods

public extension Transactable {
    @discardableResult
    func read<T>(file: String = #file,
                 function: String = #function,
                 line: Int = #line,
                 block: (GRDBReadTransaction) -> T) -> T {
        var value: T!
        read(file: file, function: function, line: line) { (transaction) in
            value = block(transaction)
        }
        return value
    }

    @discardableResult
    func read<T>(file: String = #file,
                 function: String = #function,
                 line: Int = #line,
                 block: (GRDBReadTransaction) throws -> T) throws -> T {
        var value: T!
        var thrown: Error?
        read(file: file, function: function, line: line) { (transaction) in
            do {
                value = try block(transaction)
            } catch {
                thrown = error
            }
        }

        if let error = thrown {
            throw error.grdbErrorForLogging
        }

        return value
    }

    @discardableResult
    func write<T>(file: String = #file,
                  function: String = #function,
                  line: Int = #line,
                  block: (GRDBWriteTransaction) -> T) -> T {
        var value: T!
        write(file: file,
              function: function,
              line: line) { (transaction) in
            value = block(transaction)
        }
        return value
    }

    @discardableResult
    func write<T>(file: String = #file,
                  function: String = #function,
                  line: Int = #line,
                  block: (GRDBWriteTransaction) throws -> T) throws -> T {
        var value: T!
        var thrown: Error?
        write(file: file,
              function: function,
              line: line) { (transaction) in
            do {
                value = try block(transaction)
            } catch {
                thrown = error
            }
        }
        if let error = thrown {
            throw error.grdbErrorForLogging
        }
        return value
    }
}

// MARK: - @objc macro methods

// NOTE: Do NOT call these methods directly. See SDSDatabaseStorage+Objc.h.
@objc
public extension Transactable {
    @available(*, deprecated, message: "Use DatabaseStorageWrite() instead")
    func __private_objc_write(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: (GRDBWriteTransaction) -> Void
    ) {
        write(file: file, function: function, line: line, block: block)
    }

    @available(*, deprecated, message: "Use DatabaseStorageAsyncWrite() instead")
    func __private_objc_asyncWrite(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: @escaping (GRDBWriteTransaction) -> Void
    ) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completion: { })
    }
}

