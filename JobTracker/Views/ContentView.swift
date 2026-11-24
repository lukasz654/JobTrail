import SwiftUI

struct ContentView: View {
    @State private var referenceDate = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @State private var deleting: JobApplication?
    var body: some View {
        @Bindable var store = store
        let filtered = store.filtered(asOf: referenceDate)
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach([false, true], id: \.self) { closed in
                    let apps = filtered.filter { $0.status(asOf: referenceDate).isClosed == closed }
                    if !apps.isEmpty {
                        Section(p.text(closed ? "closed" : "active")) {
                            ForEach(apps) { app in
                                ApplicationRow(application: app, referenceDate: referenceDate).tag(app.id)
                                    .contextMenu {
                                        Button(p.text("edit")) { store.edit(app) }
                                        if let url = app.jobOfferURL { Link(p.text("openOffer"), destination: url) }
                                        Divider()
                                        Button(p.text("deleteApplication"), role: .destructive) { deleting = app }
                                    }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("applicationsList")
            .disabled(store.busy)
            .overlay {
                if store.applications.isEmpty {
                    ContentUnavailableView { Label(p.text("noApplications"), systemImage: "briefcase") }
                    description: { Text(p.text("addFirstApplication")) }
                    actions: { Button(p.text("newApplication")) { store.newApplication() } }
                } else if filtered.isEmpty {
                    ContentUnavailableView(p.text("noResults"), systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $store.search, prompt: p.text("search"))
            .navigationTitle(p.text("appName"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 440)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker(p.text("sort"), selection: $store.sortByActivity) {
                            Text(p.text("newestApplication")).tag(false)
                            Text(p.text("lastActivity")).tag(true)
                        }
                        Picker(p.text("status"), selection: $store.statusFilter) {
                            Text(p.text("allStatuses")).tag(Optional<ProcessStatus>.none)
                            ForEach(ProcessStatus.allCases) { status in Text(p.text(status.key)).tag(Optional(status)) }
                        }
                    } label: { Label(p.text("filterAndSort"), systemImage: "line.3.horizontal.decrease.circle") }
                    .help(p.text("filterAndSort"))
                }
                ToolbarItem {
                    Button { store.showUpcoming = true } label: { Label(p.text("upcomingMeetings"), systemImage: "calendar") }
                        .help(p.text("upcomingMeetings"))
                }
            }
        } detail: {
            if let app = store.selectedApplication { DetailView(application: app, referenceDate: referenceDate).id(app.id).disabled(store.busy) }
            else { ContentUnavailableView(p.text("selectApplication"), systemImage: "sidebar.left") }
        }
        .toolbar {
            ToolbarItem(id: "newApplication", placement: .primaryAction) {
                Button { store.newApplication() } label: { Label(p.text("newApplication"), systemImage: "plus") }
                    .accessibilityIdentifier("newApplicationButton").help(p.text("newApplication"))
                    .disabled(store.busy)
            }
        }
        .overlay(alignment: .bottom) { if store.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
        .sheet(isPresented: $store.showApplicationForm) { ApplicationForm(application: store.editingApplication).environment(store).environment(p) }
        .sheet(isPresented: $store.showUpcoming) { UpcomingView().environment(store).environment(p) }
        .sheet(isPresented: $store.showBackupImport) {
            if let backup = store.backupPreview { BackupImportView(backup: backup).environment(store).environment(p) }
        }
        .sheet(isPresented: $store.showArchiveImport) {
            if let root = store.archiveRoot { ArchiveImportView(root: root).environment(store).environment(p) }
        }
        .alert(p.text("deleteApplication"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(p.text("cancel"), role: .cancel) { deleting = nil }
            Button(p.text("delete"), role: .destructive) {
                if let app = deleting { Task { await store.run { try await store.delete(app) } } }; deleting = nil
            }
        } message: { Text(p.text("deleteApplicationWarning")) }
        .alert(p.text(store.errorMessage != nil ? "error" : "information"), isPresented: Binding(get: { store.errorMessage != nil || store.notice != nil }, set: { if !$0 { store.errorMessage = nil; store.notice = nil } })) {
            Button(p.text("ok")) { store.errorMessage = nil; store.notice = nil }
        } message: { Text(store.errorMessage ?? store.notice ?? "") }
        .task {
            store.scheduleReminders()
            // Keep the window's navigation hierarchy stable while refreshing time.
            // This asynchronous sleep suspends rather than blocking the main actor.
            while !Task.isCancelled {
                referenceDate = .now
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { referenceDate = .now }
        }
        .onChange(of: p.language) { store.scheduleReminders() }
    }
}
struct ApplicationRow: View {
    let application: JobApplication
    var referenceDate: Date = .now
    @Environment(Preferences.self) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(application.companyName).font(.headline).lineLimit(2)
            if let title = application.jobTitle { Text(title).lineLimit(2) }
            Text(p.date(application.appliedAt) + " · " + p.text(application.status(asOf: referenceDate).key)).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}
struct UpcomingView: View {
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(p.text("upcomingMeetings")).font(.title2).padding()
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                List(store.upcoming) { event in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(event.application?.companyName ?? "").font(.headline)
                            if let title = event.application?.jobTitle { Text(title) }
                            Text(p.text(event.type.key) + " · " + p.date(event.date, time: event.includesTime)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = event.meetingURL { Link(p.text("joinMeeting"), destination: url) }
                        Button(p.text("showDetails")) { store.selection = event.application?.id; dismiss() }
                    }.padding(.vertical, 5)
                }
                .overlay { if store.upcoming.isEmpty { ContentUnavailableView(p.text("noUpcomingMeetings"), systemImage: "calendar") } }
            }
            HStack { Spacer(); Button(p.text("close")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
        }.frame(width: 740, height: 460)
    }
}

#Preview("Polski · jasny") { PreviewRoot(language: .pl, appearance: .light) }
#Preview("Polski · ciemny") { PreviewRoot(language: .pl, appearance: .dark) }
#Preview("English · light") { PreviewRoot(language: .en, appearance: .light) }
#Preview("English · dark") { PreviewRoot(language: .en, appearance: .dark) }
private struct PreviewRoot: View {
    let language: AppLanguage
    let appearance: AppAppearance
    var body: some View {
        if let state = try? makeState() {
            ContentView().environment(state.0).environment(state.1).environment(\.locale, state.1.locale).preferredColorScheme(state.1.colorScheme)
        }
    }
    @MainActor private func makeState() throws -> (ApplicationStore, Preferences) {
        let defaults = UserDefaults(suiteName: "JobTracker.Preview.\(UUID())")!
        let p = Preferences(defaults: defaults); p.language = language; p.appearance = appearance
        let container = try Persistence.container(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JobTrackerPreview-\(UUID())")
        let store = try ApplicationStore(container: container, documents: DocumentService(root: root), preferences: p)
        let app = JobApplication(companyName: "Example", jobTitle: "macOS Developer")
        container.mainContext.insert(app); try container.mainContext.save(); try store.reload(); store.selection = app.id
        return (store, p)
    }
}
