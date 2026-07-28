import Darwin
import XCTest
@testable import PullerSystem

final class ProcessSocketObserverTests: XCTestCase {
    func testFindsConnectedLoopbackSocketOwnedByCurrentProcess() throws {
        let listener = try makeTCPSocket()
        defer { close(listener) }

        var listenerAddress = loopbackAddress(port: 0)
        try withSockAddrPointer(to: &listenerAddress) { address, length in
            try requireZero(Darwin.bind(listener, address, length), operation: "bind")
        }
        try requireZero(listen(listener, 1), operation: "listen")

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &boundAddress) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try requireZero(
                    getsockname(listener, address, &boundAddressLength),
                    operation: "getsockname(listener)"
                )
            }
        }
        let listenerPort = UInt16(bigEndian: boundAddress.sin_port)

        let client = try makeTCPSocket()
        defer { close(client) }
        var destination = loopbackAddress(port: listenerPort)
        try withSockAddrPointer(to: &destination) { address, length in
            try requireZero(Darwin.connect(client, address, length), operation: "connect")
        }

        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { throw POSIXTestError(operation: "accept", code: errno) }
        defer { close(accepted) }

        var clientAddress = sockaddr_in()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &clientAddress) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try requireZero(
                    getsockname(client, address, &clientAddressLength),
                    operation: "getsockname(client)"
                )
            }
        }
        let clientPort = UInt16(bigEndian: clientAddress.sin_port)

        let sockets = try ProcessSocketObserver().sockets(pid: getpid(), allowLoopback: true)

        XCTAssertTrue(sockets.contains { socket in
            socket.transport == .tcp
                && socket.localAddress == "127.0.0.1"
                && socket.localPort == clientPort
                && socket.remoteAddress == "127.0.0.1"
                && socket.remotePort == listenerPort
        })
    }
}

private func makeTCPSocket() throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXTestError(operation: "socket", code: errno) }
    return descriptor
}

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private func withSockAddrPointer<Result>(
    to address: inout sockaddr_in,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) rethrows -> Result {
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

private func requireZero(_ result: Int32, operation: String) throws {
    guard result == 0 else { throw POSIXTestError(operation: operation, code: errno) }
}

private struct POSIXTestError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}
