import Foundation

enum AppLanguage: String, CaseIterable {
    case system, en, zh

    var title: String {
        switch self {
        case .system: return tr("Follow System", "跟随系统")
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }
}

enum L10n {
    /// Resolved UI language: the user's choice, or the system's preferred language.
    static var isChinese: Bool {
        switch AppSettings.language {
        case .zh: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// Inline translation: tr("Start Recording", "开始录制").
func tr(_ en: String, _ zh: String) -> String { L10n.isChinese ? zh : en }
