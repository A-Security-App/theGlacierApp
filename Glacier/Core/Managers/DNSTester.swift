//
//  DNSTester.swift
//  Glacier
//
//  Created by andyfriedman on 10/14/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

final class DNSTester {
    private let workerQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(workerQueue: DispatchQueue = DispatchQueue(label: "com.glacier.dnsTester", qos: .utility),
         callbackQueue: DispatchQueue = .main) {
        self.workerQueue = workerQueue
        self.callbackQueue = callbackQueue
    }

    func resolveHostName(_ host: String, completion: @escaping (Result<[String], Error>) -> Void) {
        workerQueue.async {
            let unmanagedHost = CFHostCreateWithName(kCFAllocatorDefault, host as CFString)
            let hostRef = unmanagedHost.takeRetainedValue()
            defer { CFHostCancelInfoResolution(hostRef, .addresses) }

            var streamError = CFStreamError()
            if !CFHostStartInfoResolution(hostRef, .addresses, &streamError) {
                self.callbackQueue.async {
                    completion(.failure(DNSTesterError.streamError(streamError)))
                }
                return
            }

            var resolved = DarwinBoolean(false)
            guard let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data],
                  resolved.boolValue else {
                self.callbackQueue.async {
                    completion(.failure(DNSTesterError.noAddresses))
                }
                return
            }

            var ips: [String] = []
            for addressData in addresses {
                addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
                    guard let baseAddress = pointer.baseAddress else { return }
                    let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        sockaddrPointer,
                        socklen_t(addressData.count),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )

                    if result == 0 {
                        ips.append(String(cString: hostname))
                    }
                }
            }

            self.callbackQueue.async {
                completion(.success(ips))
            }
        }
    }
}

private enum DNSTesterError: LocalizedError {
    case unableToCreateHost
    case streamError(CFStreamError)
    case noAddresses

    var errorDescription: String? {
        switch self {
        case .unableToCreateHost:
            return "Unable to create host reference"
        case .streamError(let error):
            return "Stream error domain=\(error.domain) code=\(error.error)"
        case .noAddresses:
            return "No addresses resolved"
        }
    }
}

