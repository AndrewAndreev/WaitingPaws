import Foundation

/// Language of the texts the core writes: the trainer's log, durations, event names, camera settings, errors.
/// It follows the app's UI language: Russian on Russian devices, English everywhere else. The parser reads
/// schedules in both languages whatever this is.
public enum CoreLanguage: String, Sendable {
    case ru, en

    /// Detected from the app bundle at launch; tests set it explicitly.
    nonisolated(unsafe) public static var current: CoreLanguage = detect()

    /// The language the bundle's UI runs in (`preferredLocalizations` picks between the app's en and ru).
    public static func detect(_ bundle: Bundle = .main) -> CoreLanguage {
        let language = bundle.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return language.hasPrefix("ru") ? .ru : .en
    }

    /// Dates and numbers in this language, with the device's region (en_GB writes 05/10/2026, en_US 10/5/2026).
    public var locale: Locale {
        let region = Locale.current.region?.identifier
        switch self {
        case .ru: return Locale(identifier: region.map { "ru_\($0)" } ?? "ru_RU")
        case .en: return Locale(identifier: region.map { "en_\($0)" } ?? "en_US")
        }
    }

    /// A formatter for `template` (e.g. "ddMMyyyy", "HHmm") in this language.
    public func dateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

/// The English or the Russian text, for the current language: `tr("Break", ru: "Перерыв")`.
func tr(_ en: String, ru: String) -> String {
    CoreLanguage.current == .ru ? ru : en
}

/// "1 exit", "2 exits" / "1 выход", "3 выхода", "5 выходов".
public func pluralText(_ count: Int, en: (one: String, other: String), ru: (one: String, few: String, many: String)) -> String {
    switch CoreLanguage.current {
    case .ru:
        let mod10 = count % 10, mod100 = count % 100
        let word = mod10 == 1 && mod100 != 11 ? ru.one
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? ru.few : ru.many
        return "\(count) \(word)"
    case .en:
        return "\(count) \(count == 1 ? en.one : en.other)"
    }
}
