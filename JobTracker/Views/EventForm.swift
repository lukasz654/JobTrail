import SwiftUI

struct EventForm: View {
    let application: JobApplication
    let event: RecruitmentEvent?
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var errorMessage: String?
    @State private var candidateURL: URL?
    @State private var confirmLink = false
    init(application: JobApplication, event: RecruitmentEvent? = nil, type: RecruitmentEventType? = nil) {
        self.application = application; self.event = event
        _draft = State(initialValue: EventDraft(event: event, type: type))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(p.text(event == nil ? "addEvent" : "editEvent")).font(.title2).padding()
            Form {
                Picker(p.text("eventType"), selection: $draft.type) {
                    ForEach(RecruitmentEventType.allCases) { type in Text(p.text(type.key)).tag(type) }
                }
                TextField(p.text(draft.type == .email ? "emailSubject" : "optionalTitle"), text: $draft.title)
                DatePicker(p.text("date"), selection: $draft.date, displayedComponents: draft.includesTime ? [.date,.hourAndMinute] : .date)
                Toggle(p.text("includeTime"), isOn: $draft.includesTime)
                Picker(p.text("eventState"), selection: $draft.state) {
                    ForEach(RecruitmentEventState.allCases) { state in Text(p.text(state.key)).tag(state) }
                }
                if draft.type.isMeeting {
                    HStack {
                        TextField(p.text("meetingURL"), text: $draft.meetingURL)
                        Button(p.text("paste")) { draft.meetingURL = NSPasteboard.general.string(forType: .string) ?? draft.meetingURL }
                    }
                    Stepper(value: $draft.durationMinutes, in: 0...1440, step: 15) {
                        Text(p.text("durationMinutes") + ": \(draft.durationMinutes)")
                    }
                    Text(p.text("zeroDurationHint")).font(.caption).foregroundStyle(.secondary)
                    if draft.state == .scheduled {
                        Toggle(p.text("enableReminder"), isOn: $draft.reminderEnabled)
                        if draft.reminderEnabled {
                            Picker(p.text("remindBefore"), selection: $draft.reminderMinutes) {
                                ForEach([5,15,30,60,1440], id: \.self) { minutes in Text(p.text("reminder\(minutes)")).tag(minutes) }
                            }
                            Text(p.text("notificationPermissionHint")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if [.email, .rejection, .offer, .recruiterContact, .followUp].contains(draft.type) || !draft.emailContent.isEmpty {
                    if draft.type == .email {
                        Picker(p.text("emailDirection"), selection: $draft.emailDirection) {
                            ForEach(EmailDirection.allCases) { direction in Text(p.text(direction.key)).tag(direction) }
                        }
                    }
                    Section(p.text("emailContent")) {
                        TextEditor(text: $draft.emailContent).frame(minHeight: 110).font(.body)
                            .accessibilityLabel(p.text("emailContent"))
                        Button(p.text("pasteEmail")) {
                            if let text = NSPasteboard.general.string(forType: .string) { draft.emailContent = text }
                        }
                    }
                }
                if !detectedURLs.isEmpty {
                    Section(p.text("detectedMeetings")) {
                        ForEach(detectedURLs, id: \.self) { url in
                            HStack {
                                Text(url.absoluteString).lineLimit(2).textSelection(.enabled)
                                Button(p.text("useMeetingLink")) {
                                    candidateURL = url
                                    if !draft.meetingURL.isEmpty && draft.meetingURL != url.absoluteString { confirmLink = true }
                                    else { draft.meetingURL = url.absoluteString }
                                }
                            }
                        }
                    }
                }
                if !draft.type.isMeeting && !draft.meetingURL.isEmpty {
                    TextField(p.text("meetingURL"), text: $draft.meetingURL)
                }
                Section(p.text("notes")) {
                    TextEditor(text: $draft.notes).frame(minHeight: 70).font(.body).accessibilityLabel(p.text("notes"))
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(store.busy)
            HStack {
                Spacer()
                Button(p.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(p.text("save")) { save() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(store.busy)
            }.padding()
        }.frame(width: 620, height: 680).environment(\.locale, p.locale).preferredColorScheme(p.colorScheme)
        .interactiveDismissDisabled(store.busy)
        .confirmationDialog(p.text("replaceMeetingLink"), isPresented: $confirmLink) {
            Button(p.text("replace")) { if let candidateURL { draft.meetingURL = candidateURL.absoluteString } }
            Button(p.text("cancel"), role: .cancel) { }
        }
    }
    private var detectedURLs: [URL] { Validation.detectedMeetingURLs(in: draft.emailContent) }
    private func save() {
        Task {
            guard !store.busy else { return }
            store.busy = true; defer { store.busy = false }
            do { try await store.saveEvent(draft, application: application, existing: event); dismiss() }
            catch { errorMessage = p.errorText(error) }
        }
    }
}
