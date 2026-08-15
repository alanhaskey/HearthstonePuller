import Foundation

struct ApplicationVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    var version: ApplicationVersion? { ApplicationVersion(tagName) }
}

enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(GitHubRelease)
    case upToDate
    case unavailable
}

protocol ReleaseFetching: Sendable {
    func latestRelease() async -> GitHubRelease?
}

struct GitHubReleaseFetcher: ReleaseFetching {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/alanhaskey/HearthstonePuller/releases/latest"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async -> GitHubRelease? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        request.setValue("HearthstonePuller/1.x", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                return nil
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard release.version != nil,
                  release.htmlURL.scheme?.lowercased() == "https",
                  release.htmlURL.host?.lowercased() == "github.com"
            else {
                return nil
            }
            return release
        } catch {
            return nil
        }
    }
}

struct UpdateChecker: Sendable {
    private let currentVersion: ApplicationVersion?
    private let fetcher: any ReleaseFetching

    init(
        currentVersion: String,
        fetcher: any ReleaseFetching = GitHubReleaseFetcher()
    ) {
        self.currentVersion = ApplicationVersion(currentVersion)
        self.fetcher = fetcher
    }

    func check() async -> UpdateCheckResult {
        guard let currentVersion,
              let release = await fetcher.latestRelease(),
              let latestVersion = release.version
        else {
            return .unavailable
        }
        return latestVersion > currentVersion
            ? .updateAvailable(release)
            : .upToDate
    }
}
