import SwiftUI

private struct EventPresentation: Identifiable {
    var id = UUID()
    var event: RecruitmentEvent?
    var type: RecruitmentEventType?
}
struct DetailView: View {
    let application: JobApplication
    var referenceDate: Date = .now
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @State private var presentation: EventPresentation?
    @State private var deletingEvent: RecruitmentEvent?
    @State private var deletingApplication = false
    @State private var removingPDF = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(application.companyName).font(.largeTitle).textSelection(.enabled)
                    if let title = application.jobTitle { Text(title).font(.title2).foregroundStyle(.secondary).textSelection(.enabled) }
                    LabeledContent(p.text("appliedAt"), value: p.date(application.appliedAt))
                    LabeledContent(p.text("status"), value: p.text(application.status(asOf: referenceDate).key))
                    if let url = application.jobOfferURL { Link(p.text("openOffer"), destination: url) }
                }
                GroupBox(p.text("originalOffer")) {
                    if let path = application.pdfRelativePath {
                        PDFPreview(applicationID: application.id, relativePath: path, revision: application.updatedAt)
                            .frame(minHeight: 340)
                        HStack {
                            Button(p.text("openPDF")) { pdfAction { NSWorkspace.shared.open($0) } }
                            Button(p.text("exportPDF")) { Task { await store.run { try await store.exportPDF(application) } } }
                            Spacer()
                            Menu(p.text("actions")) {
                                Button(p.text("revealInFinder")) { pdfAction { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
                                Button(p.text("replace")) { store.edit(application) }
                                Button(p.text("remove"), role: .destructive) { removingPDF = true }
                            }.fixedSize()
                        }.padding(8)
                    } else {
                        HStack {
                            Text(p.text("noPDF")).foregroundStyle(.secondary)
                            Spacer()
                            Button(p.text("attachPDF")) { store.edit(application) }
                        }.padding()
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(p.text("history")).font(.title2)
                    HStack {
                        Menu(p.text("quickActions")) {
                            Button(p.text("addEmail")) { presentation = .init(type: .email) }
                            Button(p.text("scheduleInterview")) { presentation = .init(type: .hrInterview) }
                            Button(p.text("addNote")) { presentation = .init(type: .note) }
                            Button(p.text("markRejected")) { presentation = .init(type: .rejection) }
                            if application.status.isClosed { Button(p.text("reopenProcess")) { presentation = .init(type: .reopened) } }
                        }.fixedSize()
                        Spacer()
                        Button { presentation = .init() } label: { Label(p.text("addEvent"), systemImage: "plus") }
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(application.orderedEvents) { event in
                            EventRow(event: event, now: timeline.date,
                                edit: { presentation = .init(event: event) }, delete: { deletingEvent = event })
                        }
                    }
                }
            }.padding(24)
        }
        .toolbar {
            ToolbarItem {
                Button(p.text("editApplication")) { store.edit(application) }
                    .accessibilityIdentifier("editApplicationButton")
            }
            ToolbarItem {
                Menu {
                    if let url = application.jobOfferURL { Link(p.text("openOffer"), destination: url) }
                    Button(p.text("markRejected")) { presentation = .init(type: .rejection) }
                    if application.status.isClosed { Button(p.text("reopenProcess")) { presentation = .init(type: .reopened) } }
                    Divider()
                    Button(p.text("deleteApplication"), role: .destructive) { deletingApplication = true }
                } label: { Label(p.text("actions"), systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $presentation) { item in EventForm(application: application, event: item.event, type: item.type).environment(store).environment(p) }
        .alert(p.text("deleteEvent"), isPresented: Binding(get: { deletingEvent != nil }, set: { if !$0 { deletingEvent = nil } })) {
            Button(p.text("cancel"), role: .cancel) { deletingEvent = nil }
            Button(p.text("delete"), role: .destructive) { if let event = deletingEvent { Task { await store.run { try await store.deleteEvent(event) } } }; deletingEvent = nil }
        } message: { Text(p.text("deleteEventWarning")) }
        .alert(p.text("deleteApplication"), isPresented: $deletingApplication) {
            Button(p.text("cancel"), role: .cancel) { }
            Button(p.text("delete"), role: .destructive) { Task { await store.run { try await store.delete(application) } } }
        } message: { Text(p.text("deleteApplicationWarning")) }
        .alert(p.text("removePDF"), isPresented: $removingPDF) {
            Button(p.text("cancel"), role: .cancel) { }
            Button(p.text("remove"), role: .destructive) { Task { await store.run { try await store.removePDF(application) } } }
        }
    }
    private func pdfAction(_ action: @escaping @MainActor (URL) -> Void) {
        Task {
            await store.run {
                if let path = application.pdfRelativePath { action(try await store.documents.checkedURL(id: application.id, relativePath: path)) }
            }
        }
    }
}
struct EventRow: View {
    let event: RecruitmentEvent
    let now: Date
    let edit: () -> Void
    let delete: () -> Void
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @State private var expandedEmail = false
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.type.symbol).font(.title3).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.text(event.type.key)).font(.headline)
                        Spacer()
                        Text(p.text(event.state.key)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let title = event.title { Text(title).font(.headline).textSelection(.enabled) }
                    Text(p.date(event.date, time: event.includesTime)).foregroundStyle(.secondary)
                    if event.state == .scheduled {
                        Label(p.text(event.isOverdue(now: now) ? "overdueNeedsUpdate" : "upcoming"), systemImage: event.isOverdue(now: now) ? "exclamationmark.clock" : "calendar")
                            .font(.caption).foregroundStyle(event.isOverdue(now: now) ? Color.orange : Color.secondary)
                    }
                    if let url = event.meetingURL {
                        HStack {
                            Link(p.text("joinMeeting"), destination: url)
                            Button(p.text("copyLink")) { copy(url.absoluteString) }
                        }
                    }
                    if let email = event.emailContent {
                        DisclosureGroup(p.text("emailContent"), isExpanded: $expandedEmail) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let direction = event.emailDirection { Text(p.text(direction.key)).font(.caption).foregroundStyle(.secondary) }
                                Text(verbatim: email).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button(p.text("copyContent")) { copy(email) }
                            }.padding(.vertical, 6)
                        }
                    }
                    if let notes = event.notes { Text(verbatim: notes).textSelection(.enabled) }
                    if !isInitial {
                        HStack {
                            Button(p.text("edit"), action: edit)
                            if event.type.isMeeting { Button(p.text("exportICS")) { Task { await store.run { try await store.exportICS(event) } } } }
                            Spacer()
                            Menu(p.text("actions")) {
                                if event.state == .scheduled {
                                    Button(p.text("markCompleted")) { Task { await store.run { try await store.changeState(event, to: .completed) } } }
                                    Button(p.text("cancelEvent")) { Task { await store.run { try await store.changeState(event, to: .cancelled) } } }
                                }
                                Button(p.text("delete"), role: .destructive, action: delete)
                            }.fixedSize()
                        }.font(.caption)
                    } else {
                        Button(p.text("editSubmissionDate")) { if let app = event.application { store.edit(app) } }.font(.caption)
                    }
                }
            }.padding(8)
        }
        .contextMenu {
            if !isInitial {
                Button(p.text("edit"), action: edit)
                Button(p.text("delete"), role: .destructive, action: delete)
            }
            if let email = event.emailContent { Button(p.text("copyContent")) { copy(email) } }
        }
    }
    private var isInitial: Bool { event.application?.initialEvent?.id == event.id }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
