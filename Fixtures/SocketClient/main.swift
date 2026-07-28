import Darwin
import Foundation

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

let host = argument("--host") ?? "127.0.0.1"
guard let portText = argument("--port"), let port = UInt16(portText),
      let identifier = argument("--id"),
      let durationText = argument("--duration"), let duration = TimeInterval(durationText)
else {
    fputs("usage: SocketClient --host ADDRESS --port PORT --id ID --duration SECONDS\n", stderr)
    exit(EXIT_FAILURE)
}

let descriptor = socket(AF_INET, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(EXIT_FAILURE) }
defer { close(descriptor) }
var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
_ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { exit(EXIT_FAILURE) }
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard connected == 0 else { exit(EXIT_FAILURE) }

let end = Date().addingTimeInterval(duration)
var sequence = 0
while Date() < end {
    let line = "\(identifier) \(sequence)\n"
    let payload = Data(line.utf8)
    let started = Date()
    let sent = payload.withUnsafeBytes {
        Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard sent == payload.count else { exit(EXIT_FAILURE) }

    var response = Array(repeating: UInt8(0), count: payload.count)
    var received = 0
    while received < response.count {
        let remaining = response.count - received
        let count = response.withUnsafeMutableBytes { bytes in
            recv(
                descriptor,
                bytes.baseAddress!.advanced(by: received),
                remaining,
                0
            )
        }
        guard count > 0 else { exit(EXIT_FAILURE) }
        received += count
    }
    guard Data(response) == payload else { exit(EXIT_FAILURE) }
    let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
    print("ack \(identifier) \(sequence) \(milliseconds)ms")
    fflush(stdout)
    guard milliseconds <= 500 else { exit(EXIT_FAILURE) }
    sequence += 1
    usleep(50_000)
}
