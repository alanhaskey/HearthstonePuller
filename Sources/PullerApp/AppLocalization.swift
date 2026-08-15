import Foundation

enum AppLanguage: Equatable, Sendable {
    case chinese
    case english

    init(preferredLanguages: [String] = Locale.preferredLanguages) {
        let primaryCode = preferredLanguages.first?
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased()
        self = primaryCode == "zh" ? .chinese : .english
    }
}

enum L10n {
    static let language = AppLanguage()

    static func text(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}
