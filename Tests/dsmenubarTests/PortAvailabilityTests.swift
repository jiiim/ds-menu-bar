// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Darwin
import XCTest

@testable import dsmenubar

/// `ProcessManager.isListenPortAvailable` must predict whether the *real*
/// ds4-server can bind the listen port. The server
/// binds without `SO_REUSEADDR`, so the probe must too — otherwise it reports a
/// TIME_WAIT port as "available" and the relaunch fails with EADDRINUSE.
///
/// These tests recreate the kernel states the probe must distinguish (free,
/// actively listening, TIME_WAIT) using loopback sockets — no ds4-server needed.
final class PortAvailabilityTests: XCTestCase {

    // MARK: - Socket helpers

    /// 127.0.0.1 sockaddr_in for `port`.
    private func loopbackAddr(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    /// Try to bind 127.0.0.1:port, optionally with SO_REUSEADDR. Returns whether
    /// the bind succeeded; always closes the probe socket.
    private func canBind(port: UInt16, reuseAddr: Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if reuseAddr {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = loopbackAddr(port: port)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// A listening socket on an OS-assigned 127.0.0.1 port. Returns the fd (caller
    /// closes) and the chosen port.
    private func makeListener() -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        var addr = loopbackAddr(port: 0)   // port 0 → OS assigns an ephemeral port
        let brc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(brc == 0, "listener bind failed: \(errno)")
        precondition(listen(fd, 16) == 0, "listen failed: \(errno)")
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (fd, assigned.sin_port.bigEndian)
    }

    /// Establish a loopback connection and close it from the *server* side first,
    /// so the accepted socket (local port == returned port) becomes the active
    /// closer and lands in TIME_WAIT. The listener is then closed, leaving only
    /// the TIME_WAIT socket holding the port.
    private func makeTimeWaitPort() -> UInt16 {
        let (listenFD, port) = makeListener()

        let clientFD = socket(AF_INET, SOCK_STREAM, 0)
        precondition(clientFD >= 0, "client socket() failed")
        var caddr = loopbackAddr(port: port)
        let crc = withUnsafePointer(to: &caddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(crc == 0, "loopback connect failed: \(errno)")

        let acceptFD = accept(listenFD, nil, nil)
        precondition(acceptFD >= 0, "accept failed: \(errno)")

        // Server closes first → its accepted socket performs the active close and
        // ends up in TIME_WAIT on `port`.
        close(acceptFD)
        // Drain the client so the FIN/ACK exchange completes, then close it
        // (passive close → no TIME_WAIT on the client side).
        var buf = [UInt8](repeating: 0, count: 16)
        _ = read(clientFD, &buf, buf.count)   // returns 0 (EOF)
        close(clientFD)
        close(listenFD)

        // Let the kernel settle the connection into TIME_WAIT.
        usleep(150_000)
        return port
    }

    // MARK: - Tests

    /// A port with nothing bound to it is reported available.
    func testFreePortIsAvailable() {
        // Reserve then immediately release an ephemeral port. A bound-but-never-
        // connected socket does not enter TIME_WAIT, so the port is free on close.
        let (fd, port) = makeListener()
        close(fd)
        usleep(50_000)
        XCTAssertTrue(
            ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: Int(port)),
            "a port with no socket bound should be available")
    }

    /// A port with a live listener is reported unavailable.
    func testActivelyListeningPortIsUnavailable() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        XCTAssertFalse(
            ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: Int(port)),
            "a port with an active listener should be unavailable")
    }

    /// The crux: during TIME_WAIT the probe (no SO_REUSEADDR) must report
    /// the port UNAVAILABLE, matching the real server's plain bind. The contrast
    /// asserts show why SO_REUSEADDR is wrong here: a reuse-bind succeeds (false
    /// "available"), while a plain bind — like the server's — fails.
    func testPortInTimeWaitIsUnavailable() {
        let port = makeTimeWaitPort()

        // On macOS the kernel state here is deterministic: the server-side close
        // leaves a TIME_WAIT socket on `port`, so a plain bind must fail and a
        // SO_REUSEADDR bind must succeed. Asserted (not skipped) so a broken
        // setup surfaces as a failure rather than hiding.
        XCTAssertFalse(canBind(port: port, reuseAddr: false),
                       "a plain bind (like the real server) must fail during TIME_WAIT")
        XCTAssertTrue(canBind(port: port, reuseAddr: true),
                      "a SO_REUSEADDR bind succeeds during TIME_WAIT — exactly the false positive we avoid")

        // The production probe must agree with the plain bind: unavailable.
        XCTAssertFalse(
            ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: Int(port)),
            "probe must report a TIME_WAIT port as unavailable (mirrors the server's bind)")
    }

    /// An out-of-range port is reported available so start() surfaces the real
    /// error rather than the probe swallowing it.
    func testInvalidPortIsReportedAvailable() {
        XCTAssertTrue(ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: 70000))
        XCTAssertTrue(ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: -1))
        // Port 0 binds to an OS-assigned port, so probing it says nothing about
        // the configured port; it must not read as "available because it bound".
        XCTAssertTrue(ProcessManager.isListenPortAvailable(host: "127.0.0.1", port: 0))
    }

    /// A hostname is resolved rather than parsed numerically. `localhost`
    /// resolves to the loopback addresses, so a listener on 127.0.0.1 must make
    /// the port unavailable under that name too.
    func testHostnameIsResolvedNotTreatedAsWildcard() {
        let (fd, port) = makeListener()
        defer { close(fd) }
        XCTAssertFalse(
            ProcessManager.isListenPortAvailable(host: "localhost", port: Int(port)),
            "a listener on 127.0.0.1 must be seen when probing the name localhost")
    }

    /// A host in URL form must probe exactly like its bare form. getaddrinfo
    /// rejects the brackets with EAI_NONAME, and an unresolvable host is
    /// reported available — so without normalization a bracketed host would
    /// call a held port free, skip the pre-relaunch wait, and hand the
    /// replacement server an EADDRINUSE. Spelled with an IPv4 address so the
    /// test needs no IPv6 loopback; `[::]` and `[::1]` are what a user types,
    /// and they resolve the same way.
    func testBracketedHostIsProbedLikeItsBareForm() {
        let (fd, port) = makeListener()
        defer { close(fd) }

        XCTAssertFalse(
            ProcessManager.isListenPortAvailable(host: "[127.0.0.1]", port: Int(port)),
            "a bracketed host must still see the listener holding the port")
    }

    /// A host that does not resolve is reported available: launch's own error
    /// names the bad host, whereas a probe that reported "unavailable" would
    /// leave the restart waiting on a port that will never come free.
    func testUnresolvableHostIsReportedAvailable() {
        XCTAssertTrue(
            ProcessManager.isListenPortAvailable(host: "no-such-host.invalid", port: 8000))
    }
}
