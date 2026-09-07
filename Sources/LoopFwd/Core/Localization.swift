import Foundation

enum L10n {
    // Resolve once per launch so changing the preference cannot leave menus,
    // cached diagnostics and already-open panels in different languages.
    static let language = resolvedLanguage(
        selection: UserDefaults.standard.string(forKey: Pref.interfaceLanguage),
        preferredLanguages: Locale.preferredLanguages)
    static let locale = Locale(identifier: language)

    static func resolvedLanguage(selection: String?, preferredLanguages: [String]) -> String {
        if let selection, selection == "en" || selection == "zh-Hans" { return selection }
        return preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    static func string(_ key: String) -> String {
        string(key, language: language)
    }

    static func string(_ key: String, language: String) -> String {
        guard language == "zh-Hans" else { return key }
        let localized = chineseBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        return localized == key ? developmentTranslations[key] ?? key : localized
    }

    private static let chineseBundle = LoopFwdResources.bundle?.path(forResource: "zh-Hans", ofType: "lproj")
        .flatMap { Bundle(path: $0) }

    /// `swift run` has an uncompiled catalog; packaged apps use generated
    /// .strings. Both paths consume the same catalog rather than two sources.
    private static let developmentTranslations: [String: String] = {
        guard let url = LoopFwdResources.bundle?.url(forResource: "Localizable", withExtension: "xcstrings"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = catalog["strings"] as? [String: [String: Any]]
        else { return [:] }
        return strings.compactMapValues {
            let localizations = $0["localizations"] as? [String: [String: Any]]
            let unit = localizations?["zh-Hans"]?["stringUnit"] as? [String: String]
            return unit?["value"]
        }
    }()

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 5 { return string("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
