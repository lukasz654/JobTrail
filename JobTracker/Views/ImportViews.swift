import SwiftUI

struct BackupImportView: View {
    let backup: ValidatedBackup
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BackupImportMode = .merge
    @State private var confirmReplace = false
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(p.text("importBackup")).font(.title2)
            Text(p.applicationCount(backup.manifest.applications.count))
            Text(p.text("conflicts") + ": \(conflicts)")
            Picker(p.text("importMode"), selection: $mode) {
                ForEach(BackupImportMode.allCases) { mode in Text(p.text(mode.key)).tag(mode) }
            }.pickerStyle(.radioGroup)
            Text(p.text(mode == .merge ? "mergeExplanation" : "replaceExplanation")).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(p.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(p.text("import")) { if mode == .replace { confirmReplace = true } else { startImport() } }
                    .buttonStyle(.borderedProminent).disabled(store.busy)
            }
            if store.busy { ProgressView() }
        }.padding(24).frame(width: 540)
        .interactiveDismissDisabled(store.busy)
        .alert(p.text("replaceAllData"), isPresented: $confirmReplace) {
            Button(p.text("cancel"), role: .cancel) { }
            Button(p.text("replace"), role: .destructive) { startImport() }
        } message: { Text(p.text("replaceExplanation")) }
    }
    private var conflicts: Int {
        let ids = Set(store.applications.map(\.id)); let events = Set(store.applications.flatMap(\.events).map(\.id))
        return backup.manifest.applications.filter { ids.contains($0.id) || !events.isDisjoint(with: $0.events.map(\.id)) }.count
    }
    private func startImport() {
        Task {
            guard !store.busy else { return }; store.busy = true; defer { store.busy = false }
            do { try await store.importBackup(backup, mode: mode); dismiss() }
            catch { errorMessage = p.errorText(error) }
        }
    }
}
struct ArchiveImportView: View {
    let root: URL
    @State private var emptyFolders = 0
    @State private var scanning = true
    @State private var suggesting = false
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ArchiveCandidate] = []
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    init(root: URL) { self.root = root }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.text("importArchive")).font(.title2)
            Text(p.text("archiveExplanation")).foregroundStyle(.secondary)
            HStack {
                Button(p.text("readPDFSuggestions")) { readSuggestions() }
                    .disabled(scanning || suggesting || store.busy || !rows.contains { $0.selected && $0.issue == nil })
                if suggesting { ProgressView().controlSize(.small) }
            }
            Text(p.text("pdfSuggestionsExplanation")).font(.caption).foregroundStyle(.secondary)
            Text(p.text("emptyFolders") + ": \(emptyFolders)").font(.caption)
            ScrollView([.horizontal,.vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        Text(p.text("import")); Text(p.text("company")); Text(p.text("pdfDocument"))
                        Text(p.text("suggestedDate")); Text(p.text("dateConfirmed")); Text(p.text("jobTitle")); Text(p.text("offerURL"))
                    }.font(.headline)
                    ForEach($rows) { $row in
                        GridRow {
                            Toggle(p.text("selectForImport"), isOn: $row.selected).labelsHidden().accessibilityLabel(p.text("selectForImport") + " " + row.company).disabled(row.issue != nil)
                            TextField(p.text("company"), text: $row.company).frame(width: 140)
                            VStack(alignment: .leading) {
                                Text(row.source.lastPathComponent).lineLimit(2)
                                if let issue = row.issue { Text(p.text(issue)).foregroundStyle(.red) }
                                if let warning = row.warning { Text(p.text(warning)).foregroundStyle(.secondary) }
                                if row.hasTextSuggestions { Text(p.text("reviewPDFSuggestions")).foregroundStyle(.secondary) }
                            }.frame(width: 150, alignment: .leading)
                            DatePicker(p.text("suggestedDate"), selection: $row.appliedAt, displayedComponents: .date).labelsHidden()
                            Toggle(p.text("dateConfirmed"), isOn: $row.dateConfirmed).labelsHidden().accessibilityLabel(p.text("dateConfirmed") + " " + row.company)
                            TextField(p.text("jobTitle"), text: $row.title).frame(width: 150)
                            TextField(p.text("offerURL"), text: $row.offerURL).frame(width: 190)
                        }
                    }
                }.padding().disabled(store.busy || suggesting)
            }.border(.separator)
            if scanning { ProgressView(p.text("scanningArchive")) }
            if !scanning && rows.isEmpty { Text(p.text("noArchivePDFs")) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(p.text("cancel")) { importTask?.cancel(); if !store.busy { dismiss() } }.keyboardShortcut(.cancelAction)
                Button(p.text("import")) { startImport() }.buttonStyle(.borderedProminent)
                    .disabled(scanning || suggesting || store.busy || !rows.contains { $0.selected } || rows.contains { $0.selected && !$0.dateConfirmed })
            }
        }.padding(20).frame(width: 1040, height: 600).interactiveDismissDisabled(store.busy)
        .task {
            do {
                let ids = store.applications.filter { $0.pdfRelativePath != nil }.map(\.id)
                let hashes = try await store.documents.existingDigests(ids)
                let scan = try await store.archive.scan(root: root, existingDigests: hashes)
                try Task.checkCancellation()
                rows = scan.candidates; emptyFolders = scan.emptyFolders
            } catch is CancellationError { }
            catch { errorMessage = p.errorText(error) }
            scanning = false
        }
    }
    private func readSuggestions() {
        suggesting = true
        let candidates = rows.filter { $0.selected && $0.issue == nil }
        importTask = Task {
            defer { suggesting = false }
            do {
                let suggestions = try await store.archive.suggestions(root: root, candidates: candidates)
                try Task.checkCancellation()
                for suggestion in suggestions {
                    guard let index = rows.firstIndex(where: { $0.id == suggestion.id }) else { continue }
                    if let issue = suggestion.issue { rows[index].issue = issue; rows[index].selected = false }
                    if rows[index].title.isEmpty, let title = suggestion.title { rows[index].title = title; rows[index].hasTextSuggestions = true }
                    if rows[index].offerURL.isEmpty, let url = suggestion.offerURL { rows[index].offerURL = url.absoluteString; rows[index].hasTextSuggestions = true }
                }
            } catch is CancellationError { }
            catch { errorMessage = p.errorText(error) }
        }
    }
    private func startImport() {
        importTask = Task {
            guard !store.busy else { return }; store.busy = true; defer { store.busy = false }
            do { try await store.importArchive(rows, root: root); dismiss() }
            catch { errorMessage = p.errorText(error) }
        }
    }
}
