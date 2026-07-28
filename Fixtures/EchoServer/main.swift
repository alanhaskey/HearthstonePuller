import Darwin
import Foundation

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

let host = argument("--host") ?? "127.0.0.1"
guard let portText = argument("--port"), let port = UInt16(portText) else {
    fputs("usage: EchoServer --host ADDRESS --port PORT\n", stderr)
    exit(EXIT_FAILURE)
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
guard listener >= 0 else { exit(EXIT_FAILURE) }
var reuse: Int32 = 1
_ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
signal(SIGPIPE, SIG_IGN)

var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
    fputs("invalid IPv4 address\n", stderr)
    exit(EXIT_FAILURE)
}
let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0, listen(listener, 8) == 0 else { exit(EXIT_FAILURE) }

@Sendable func echo(descriptor: Int32) {
    defer { close(descriptor) }
    var buffer = Array(repeating: UInt8(0), count: 4_096)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return }
        var sent = 0
        while sent < count {
            let result = buffer.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), count - sent, 0)
            }
            guard result > 0 else { return }
            sent += result
        }
    }
}

print("listening \(host):\(port)")
fflush(stdout)
while true {
    let client = accept(listener, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        exit(EXIT_FAILURE)
    }
    DispatchQueue.global().async { echo(descriptor: client) }
}
