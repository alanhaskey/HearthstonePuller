import Darwin

public struct UnixPeerCredentials: Equatable, Sendable {
    public let uid: uid_t
    public let gid: gid_t

    public init(uid: uid_t, gid: gid_t) {
        self.uid = uid
        self.gid = gid
    }

    public static func read(from descriptor: Int32) throws -> Self {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            throw UnixPeerCredentialsError.systemCall(errno: errno)
        }
        return Self(uid: uid, gid: gid)
    }
}

public enum UnixPeerCredentialsError: Error, Equatable, Sendable {
    case systemCall(errno: Int32)
}
