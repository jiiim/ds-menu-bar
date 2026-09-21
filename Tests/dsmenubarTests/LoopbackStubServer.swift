// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// A minimal HTTP/1.1 responder on an OS-assigned 127.0.0.1 port, shared by
/// the health-checker and server-manager tests.
///
/// Answers whatever `statusCode` is at the time the connection is accepted; set
/// it to nil to accept and hang up without replying, which is what a server
/// mid-crash looks like to the poller. `holdResponses()` accepts and reads but
/// withholds the reply until `releaseResponses()`, so a test can run assertions
/// while a request is genuinely in flight.
final class LoopbackStubServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _statusCode: Int? = 200
    private var stopped = false
    private let gate = NSCondition()
    private var holdingResponses = false
    private var _requestsRead = 0

    var statusCode: Int? {
        get { lock.withLock { _statusCode } }
        set { lock.withLock { _statusCode = newValue } }
    }

    /// Requests whose line has been read — i.e. the poller really issued one,
    /// rather than being turned away by an earlier guard.
    var requestsRead: Int {
        gate.lock()
        defer { gate.unlock() }
        return _requestsRead
    }

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "bind failed: \(errno)")
        precondition(listen(fd, 16) == 0, "listen failed: \(errno)")
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        listenFD = fd
        port = assigned.sin_port.bigEndian

        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if lock.withLock({ stopped }) { return }
                continue
            }
            // Drain the request line so the client is not writing into a
            // socket nobody read before we reply.
            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = recv(client, &buffer, buffer.count, 0)
            gate.lock()
            _requestsRead += 1
            while holdingResponses { gate.wait() }
            gate.unlock()
            if let code = statusCode {
                let response = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                _ = response.withCString { send(client, $0, strlen($0), 0) }
            }
            close(client)
            if lock.withLock({ stopped }) { return }
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/models")! }

    /// Accept and read, but do not reply until `releaseResponses()`.
    func holdResponses() {
        gate.lock()
        holdingResponses = true
        gate.unlock()
    }

    func releaseResponses() {
        gate.lock()
        holdingResponses = false
        gate.broadcast()
        gate.unlock()
    }

    func stop() {
        lock.withLock { stopped = true }
        releaseResponses()
        close(listenFD)
    }
}
