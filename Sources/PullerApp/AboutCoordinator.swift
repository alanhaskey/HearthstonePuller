import AppKit
import Foundation

struct AboutMetadata {
    static let repositoryURL = URL(
        string: "https://github.com/alanhaskey/HearthstonePuller"
    )!

    let applicationName = "HearthstonePuller"
    let author = "Yunnn"
    let version: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let bundleVersion = infoDictionary?["CFBundleShortVersionString"] as? String
        version = bundleVersion.flatMap { $0.isEmpty ? nil : $0 }
            ?? L10n.text("未知", "Unknown")
    }

    var repositoryURL: URL { Self.repositoryURL }

    var informativeText: String {
        """
        \(L10n.text("作者", "Author")): \(author)
        GitHub: \(repositoryURL.absoluteString)
        \(L10n.text("版本", "Version")): \(version)
        """
    }
}

@MainActor
protocol RepositoryOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: RepositoryOpening {}

@MainActor
final class AboutCoordinator {
    static var openFailureMessage: String {
        L10n.text("无法打开 GitHub", "Unable to open GitHub")
    }

    let metadata: AboutMetadata
    private let opener: any RepositoryOpening

    init(
        metadata: AboutMetadata = AboutMetadata(),
        opener: any RepositoryOpening = NSWorkspace.shared
    ) {
        self.metadata = metadata
        self.opener = opener
    }

    func openRepository() -> Bool {
        opener.open(metadata.repositoryURL)
    }

    func open(_ url: URL) -> Bool {
        opener.open(url)
    }
}
