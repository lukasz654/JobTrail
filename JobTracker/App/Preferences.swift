import AppKit
import SwiftUI
import Observation

enum AppLanguage: String, LocalizedOption { case system, pl, en }
enum AppAppearance: String, LocalizedOption { case system, light, dark }
@MainActor @Observable final class Preferences {
    private let defaults: UserDefaults
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }
    var languageCode: String {
        if language != .system { return language.rawValue }
        return Bundle.preferredLocalizations(from: ["en", "pl"]).first ?? "en"
    }
    var locale: Locale {
        if language == .system { return .current }
        let region = Locale.current.region?.identifier ?? (language == .pl ? "PL" : "US")
        return Locale(identifier: "\(language.rawValue)_\(region)")
    }
    var colorScheme: ColorScheme? { appearance == .system ? nil : appearance == .dark ? .dark : .light }
    private var localizationBundle: Bundle {
        let baseBundle = Bundle.main
        return baseBundle.path(forResource: languageCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? baseBundle
    }
    func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizationBundle, locale: locale)
    }
    func applicationCount(_ count: Int) -> String {
        String(localized: "\(count) applications", bundle: localizationBundle, locale: locale)
    }
    func date(_ date: Date, time: Bool = false) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(locale))
    }
    func applyAppearance() {
        NSApplication.shared.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
    func errorText(_ error: Error) -> String {
        if let failure = error as? AppFailure { return text(failure.key) + (failure.detail.isEmpty ? "" : "\n" + failure.detail) }
        if error is CancellationError { return text("operationCancelled") }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue: return text("fileAccessDenied")
            case CocoaError.Code.fileWriteOutOfSpace.rawValue: return text("diskFull")
            default: break
            }
        }
        return text("operationFailed")
    }
}
struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Picker(preferences.text("language"), selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { option in Text(preferences.text(option.rawValue)).tag(option) }
            }.accessibilityIdentifier("languagePicker")
            Picker(preferences.text("appearance"), selection: $preferences.appearance) {
                ForEach(AppAppearance.allCases) { option in Text(preferences.text(option.rawValue)).tag(option) }
            }
            Text(preferences.text("nativeLanguageNotice")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).frame(width: 460).fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, preferences.locale).preferredColorScheme(preferences.colorScheme)
        .navigationTitle(preferences.text("general"))
    }
}
