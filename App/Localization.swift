import Foundation

final class LocalizationBundleToken: NSObject {}

/// Runtime localization for display strings that flow through models before
/// reaching SwiftUI. Literal labels localize natively; these helpers cover
/// dynamic status, validation, and error text.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: Bundle(for: LocalizationBundleToken.self),
            value: key,
            comment: ""
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
