import Foundation
import Synchronization

/// UI languages. Raw values are what's stored in UserDefaults ("zh" kept for existing settings).
enum AppLanguage: String, CaseIterable {
    case system
    case en
    case zhHans = "zh"
    case zhHant = "zh-Hant"
    case ja, ko, de, fr, es
    case ptBR = "pt-BR"

    /// Name of the .lproj folder in Resources/.
    var lproj: String {
        switch self {
        case .system: return L10n.systemLanguage.lproj
        case .zhHans: return "zh-Hans"
        default: return rawValue
        }
    }

    /// Shown in the language picker, each in its own language.
    var title: String {
        switch self {
        case .system: return tr("Follow System")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        }
    }
}

enum L10n {
    /// First of the user's preferred languages that the app supports; English otherwise.
    static let systemLanguage: AppLanguage = {
        for id in Locale.preferredLanguages {
            let l = Locale.Language(identifier: id)
            switch l.languageCode?.identifier {
            case "en": return .en
            case "zh":
                // script is inferred from the region when missing: zh-TW / zh-HK → Hant.
                return l.script?.identifier == "Hant" ? .zhHant : .zhHans
            case "ja": return .ja
            case "ko": return .ko
            case "de": return .de
            case "fr": return .fr
            case "es": return .es
            case "pt": return .ptBR
            default: continue
            }
        }
        return .en
    }()

    /// tr() is called from background threads too, hence the mutex.
    private static let cache = Mutex<(lproj: String, bundle: Bundle?)?>(nil)

    /// The .lproj bundle for the current language setting (nil = English, use the key).
    static var bundle: Bundle? {
        let lproj = AppSettings.language.lproj
        return cache.withLock { cache in
            if let cache, cache.lproj == lproj { return cache.bundle }
            let b = lproj == "en" ? nil
                : Bundle.main.path(forResource: lproj, ofType: "lproj").flatMap(Bundle.init(path:))
            cache = (lproj, b)
            return b
        }
    }
}

/// Looks up `key` (the English text) in the current language's Localizable.strings.
/// Arguments fill %@ / %1$@ placeholders: tr("Stop Recording (%@)", elapsed).
func tr(_ key: String, _ args: Any...) -> String {
    let s = L10n.bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    return args.isEmpty ? s : String(format: s, arguments: args.map { "\($0)" as NSString })
}
