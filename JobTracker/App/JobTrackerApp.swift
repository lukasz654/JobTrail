import SwiftUI
import SwiftData
import UserNotifications
import AppKit

private enum AppWindow {
    static let main = "jobtracker.main"
}

@main @MainActor struct JobTrackerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var runtime = ApplicationRuntime()

    var body: some Scene {
        MainWindowScene(runtime: runtime)
        Settings { SettingsView().environment(runtime.preferences) }
    }
}

@MainActor private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Allow AppKit's initial-open path to present the SwiftUI window even
        // when the app was launched by the UI-test runner rather than Finder.
        log("applicationShouldOpenUntitledFile: allowed", application: sender)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Keep AppKit's standard reopen/untitled-window handling enabled.
        log("applicationShouldHandleReopen: allowed; hasVisibleWindows=\(flag)", application: sender)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        log("applicationDidFinishLaunching", application: application)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        log("applicationDidBecomeActive", application: application)
    }

    private func log(_ event: String, application: NSApplication) {
        #if DEBUG
        // Local launch diagnostics contain no recruitment data or document paths.
        print("[JobTracker lifecycle] \(event); windows=\(application.windows.count)")
        #endif
    }
}

@MainActor private final class ApplicationRuntime {
    let preferences: Preferences
    let store: ApplicationStore?
    let notificationDelegate = NotificationDelegate()
    let startupError: String?

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let preferences = Preferences()
        self.preferences = preferences
        do {
            let testing = isUITesting || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let root = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("JobTrackerTests-\(UUID().uuidString)") :
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JobTracker")
            let documents = try DocumentService(root: root)
            let container = try Persistence.container(inMemory: testing, storeURL: testing ? nil : root.appendingPathComponent("JobTracker.store"))
            store = try ApplicationStore(container: container, documents: documents, preferences: preferences)
            startupError = nil
        } catch { store = nil; startupError = preferences.errorText(error) }
    }
}

@MainActor private struct MainWindowScene: Scene {
    let runtime: ApplicationRuntime
    private var preferences: Preferences { runtime.preferences }
    private var store: ApplicationStore? { runtime.store }

    var body: some Scene {
        // A single identified scene can be presented explicitly at launch and
        // reopened by commands without creating duplicate main windows.
        Window(preferences.text("appName"), id: AppWindow.main) {
            Group {
                if let store { ContentView().environment(store) }
                else {
                    ContentUnavailableView(preferences.text("startupFailed"), systemImage: "exclamationmark.triangle", description: Text(runtime.startupError ?? ""))
                        .accessibilityIdentifier("startupError")
                }
            }
            .environment(preferences).environment(\.locale, preferences.locale)
            .preferredColorScheme(preferences.colorScheme).frame(minWidth: 850, minHeight: 560)
            .onAppear {
                preferences.applyAppearance()
                UNUserNotificationCenter.current().delegate = runtime.notificationDelegate
            }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            NewApplicationCommands(store: store, preferences: preferences)
            CommandGroup(after: .importExport) {
                Button(preferences.text("exportBackup")) { Task { await store?.run { try await store?.exportBackup() } } }
                Button(preferences.text("importBackup")) { Task { await store?.run { try await store?.chooseBackup() } } }
                Button(preferences.text("exportCSV")) { Task { await store?.run { try await store?.exportCSV() } } }
                Divider()
                Button(preferences.text("importArchive")) { Task { await store?.run { try await store?.chooseArchive() } } }
                Button(preferences.text("showDataFolder")) {
                    if let store { NSWorkspace.shared.open(store.documents.root) }
                }
            }
            CommandMenu(preferences.text("recruitment")) {
                Button(preferences.text("upcomingMeetings")) { store?.showUpcoming = true }.keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor private struct NewApplicationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: ApplicationStore?
    let preferences: Preferences

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(preferences.text("newApplication")) {
                openWindow(id: AppWindow.main)
                store?.newApplication()
            }
            .keyboardShortcut("n")
            .disabled(store == nil || store?.busy == true)
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
