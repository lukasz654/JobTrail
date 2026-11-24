import SwiftUI
import UniformTypeIdentifiers

struct ApplicationForm: View {
    let application: JobApplication?
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ApplicationDraft
    @State private var error: String?
    @FocusState private var companyFocused: Bool
    init(application: JobApplication?) { self.application = application; _draft = State(initialValue: ApplicationDraft(application: application)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(p.text(application == nil ? "newApplication" : "editApplication")).font(.title2).padding()
            Form {
                TextField(p.text("company"), text: $draft.companyName).focused($companyFocused).accessibilityIdentifier("companyField")
                TextField(p.text("jobTitleOptional"), text: $draft.jobTitle).accessibilityIdentifier("jobTitleField")
                DatePicker(p.text("appliedAt"), selection: $draft.appliedAt, displayedComponents: .date)
                HStack {
                    TextField(p.text("offerURL"), text: $draft.jobOfferURL)
                    Button(p.text("paste")) { if let text = NSPasteboard.general.string(forType: .string) { draft.jobOfferURL = text } }
                }
                if duplicateURL { Label(p.text("duplicateURLWarning"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                LabeledContent(p.text("pdfDocument")) {
                    VStack(alignment: .leading) {
                        Text(draft.pdfSource?.lastPathComponent ?? ((!draft.removePDF && application?.pdfRelativePath != nil) ? "job-offer.pdf" : p.text("noPDF")))
                            .lineLimit(2).textSelection(.enabled)
                        HStack {
                            Button(p.text("choosePDF")) { if let url = store.choosePDF() { draft.pdfSource = url; draft.removePDF = false } }
                            if draft.pdfSource != nil || (!draft.removePDF && application?.pdfRelativePath != nil) {
                                Button(p.text("remove")) { draft.pdfSource = nil; draft.removePDF = true }
                            }
                        }
                        Text(p.text("dropPDF")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .dropDestination(for: URL.self) { urls, _ in
                        guard urls.count == 1, let url = urls.first, url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return false }
                        draft.pdfSource = url; draft.removePDF = false; return true
                    }
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("formError") }
            }.formStyle(.grouped).disabled(store.busy)
            HStack {
                Spacer()
                Button(p.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(p.text("save")) { save() }.keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(store.busy).accessibilityIdentifier("saveApplicationButton")
            }.padding()
        }.frame(width: 580).fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, p.locale).preferredColorScheme(p.colorScheme)
        .onAppear { companyFocused = true }
        .interactiveDismissDisabled(store.busy)
    }
    private var duplicateURL: Bool {
        guard let url = try? Validation.url(draft.jobOfferURL) else { return false }
        return store.applications.contains { $0.id != application?.id && $0.jobOfferURL == url }
    }
    private func save() {
        Task {
            guard !store.busy else { return }
            store.busy = true; defer { store.busy = false }
            do { try await store.saveApplication(draft, existing: application); dismiss() }
            catch { self.error = p.errorText(error) }
        }
    }
}
