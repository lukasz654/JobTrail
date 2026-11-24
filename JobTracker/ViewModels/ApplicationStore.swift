import AppKit
import SwiftData
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class ApplicationStore {
    let container: ModelContainer
    let context: ModelContext
    let documents: DocumentService
    let backups: BackupService
    let reminders: ReminderService
    let archive: ArchiveService
    let preferences: Preferences
    var applications: [JobApplication] = []
    var selection: UUID?
    var search = ""
    var sortByActivity = false
    var statusFilter: ProcessStatus?
    var busy = false
    var errorMessage: String?
    var notice: String?
    var showApplicationForm = false
    var editingApplication: JobApplication?
    var showUpcoming = false
    var showBackupImport = false
    var backupPreview: ValidatedBackup?
    var showArchiveImport = false
    var archiveRoot: URL?
    private var reminderTask: Task<Void, Never>?

    init(container: ModelContainer, documents: DocumentService, backups: BackupService = BackupService(),
         reminders: ReminderService = ReminderService(), archive: ArchiveService = ArchiveService(), preferences: Preferences) throws {
        self.container = container; context = ModelContext(container); context.autosaveEnabled = false
        self.documents = documents; self.backups = backups; self.reminders = reminders; self.archive = archive; self.preferences = preferences
        try reload()
    }
    func reload() throws { applications = try context.fetch(FetchDescriptor<JobApplication>()) }
    var selectedApplication: JobApplication? { applications.first { $0.id == selection } }
    var filtered: [JobApplication] {
        filtered(asOf: .now)
    }
    func filtered(asOf now: Date) -> [JobApplication] {
        applications.filter { app in
            (search.isEmpty || app.companyName.localizedStandardContains(search) || (app.jobTitle?.localizedStandardContains(search) ?? false)) &&
            (statusFilter == nil || app.status(asOf: now) == statusFilter)
        }.sorted {
            let lhs = sortByActivity ? $0.lastActivity : $0.appliedAt
            let rhs = sortByActivity ? $1.lastActivity : $1.appliedAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    var upcoming: [RecruitmentEvent] {
        applications.filter { !$0.status.isClosed }.flatMap(\.events)
            .filter { $0.type.isMeeting && $0.state == .scheduled && !$0.isOverdue() }
            .sorted { $0.date < $1.date }
    }
    func newApplication() {
        guard !busy else { return }
        editingApplication = nil; showApplicationForm = true
    }
    func edit(_ app: JobApplication) {
        guard !busy else { return }
        editingApplication = app; showApplicationForm = true
    }
    @discardableResult func run(_ operation: @MainActor () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do { try await operation(); return true }
        catch { errorMessage = preferences.errorText(error); return false }
    }
    private func save(transaction: DocumentTransaction? = nil) async throws {
        do { try context.save() }
        catch {
            context.rollback()
            if let transaction { try await documents.rollback(transaction) }
            try reload()
            throw error
        }
        // Publish the saved collection before yielding to file cleanup. Views
        // must not retain a selection pointing at a now-deleted model.
        do { try reload() }
        catch {
            if let transaction { try? await documents.commit(transaction) }
            throw error
        }
        if let selection, !applications.contains(where: { $0.id == selection }) { self.selection = nil }
        if let transaction {
            do { try await documents.commit(transaction) }
            catch { notice = preferences.text("cleanupWarning") }
        }
        scheduleReminders()
    }
    func saveApplication(_ draft: ApplicationDraft, existing: JobApplication?) async throws {
        try draft.validate()
        let company = try Validation.company(draft.companyName)
        let offerURL = try Validation.url(draft.jobOfferURL)
        let app = existing ?? JobApplication(companyName: company, appliedAt: draft.appliedAt)
        let transaction: DocumentTransaction?
        if draft.pdfSource != nil || draft.removePDF {
            transaction = try await documents.begin([.init(applicationID: app.id, source: draft.pdfSource)])
        } else { transaction = nil }
        if existing == nil { context.insert(app) }
        app.companyName = company; app.jobTitle = Validation.optionalText(draft.jobTitle)
        app.appliedAt = draft.appliedAt; app.jobOfferURL = offerURL; app.updatedAt = .now
        app.initialEvent?.date = draft.appliedAt; app.initialEvent?.updatedAt = .now
        if draft.pdfSource != nil { app.pdfRelativePath = DocumentService.relativePath(for: app.id) }
        else if draft.removePDF { app.pdfRelativePath = nil }
        try await save(transaction: transaction)
        selection = app.id
    }
    func delete(_ app: JobApplication) async throws {
        let id = app.id
        let transaction = try await documents.begin([.init(applicationID: id, source: nil)])
        context.delete(app)
        try await save(transaction: transaction)
        if selection == id { selection = nil }
    }
    func removePDF(_ app: JobApplication) async throws {
        let transaction = try await documents.begin([.init(applicationID: app.id, source: nil)])
        app.pdfRelativePath = nil; app.updatedAt = .now
        try await save(transaction: transaction)
    }
    func saveEvent(_ draft: EventDraft, application: JobApplication, existing: RecruitmentEvent?) async throws {
        let url = try Validation.url(draft.meetingURL)
        if let existing, application.initialEvent?.id == existing.id { throw AppFailure("editSubmissionInApplication") }
        if draft.reminderEnabled && draft.type.isMeeting && draft.state == .scheduled {
            guard draft.includesTime else { throw AppFailure("reminderNeedsTime") }
            guard try await reminders.authorize() else { throw AppFailure("notificationsDenied") }
        }
        let event = existing ?? RecruitmentEvent(type: draft.type)
        if existing == nil {
            context.insert(event)
            application.events.append(event)
            event.application = application
        }
        event.type = draft.type; event.title = Validation.optionalText(draft.title); event.date = draft.date
        event.includesTime = draft.includesTime; event.state = draft.state; event.meetingURL = url
        event.emailContent = draft.emailContent.isEmpty ? nil : draft.emailContent
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.emailDirection = draft.type == .email ? draft.emailDirection : nil
        event.durationMinutes = draft.type.isMeeting && draft.durationMinutes > 0 ? draft.durationMinutes : nil
        event.reminderMinutes = draft.reminderEnabled && draft.type.isMeeting && draft.state == .scheduled ? draft.reminderMinutes : nil
        event.updatedAt = .now; application.updatedAt = .now
        try await save()
    }
    func changeState(_ event: RecruitmentEvent, to state: RecruitmentEventState) async throws {
        guard event.application?.initialEvent?.id != event.id else { throw AppFailure("editSubmissionInApplication") }
        event.state = state; event.updatedAt = .now; event.application?.updatedAt = .now
        try await save()
    }
    func deleteEvent(_ event: RecruitmentEvent) async throws {
        guard event.application?.initialEvent?.id != event.id else { throw AppFailure("editSubmissionInApplication") }
        let app = event.application
        app?.events.removeAll { $0.id == event.id }; app?.updatedAt = .now
        context.delete(event); try await save()
    }
    func meetingInfo(_ event: RecruitmentEvent) -> MeetingInfo {
        .init(id: event.id, company: event.application?.companyName ?? "", typeName: preferences.text(event.type.key),
              date: event.date, includesTime: event.includesTime, durationMinutes: event.durationMinutes, meetingURL: event.meetingURL,
              notes: event.notes, reminderMinutes: event.reminderMinutes,
              isEligible: event.type.isMeeting && event.state == .scheduled && !(event.application?.status.isClosed ?? true))
    }
    func scheduleReminders() {
        reminderTask?.cancel()
        let meetings = applications.flatMap(\.events).map(meetingInfo)
        let title = preferences.text("meetingReminder")
        reminderTask = Task { [weak self, reminders] in
            do {
                try Task.checkCancellation()
                try await reminders.synchronize(meetings, title: title)
            } catch is CancellationError { }
            catch { self?.errorMessage = self?.preferences.errorText(error) }
        }
    }
    func choosePDF() -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func savePanel(name: String, type: UTType? = nil) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        if let type { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }
    func exportPDF(_ app: JobApplication) async throws {
        guard let path = app.pdfRelativePath, let url = savePanel(name: "job-offer.pdf", type: .pdf) else { return }
        try await documents.export(id: app.id, relativePath: path, destination: url)
    }
    func exportICS(_ event: RecruitmentEvent) async throws {
        guard let url = savePanel(name: "meeting.ics") else { return }
        let info = meetingInfo(event)
        try await Task.detached { try CalendarExport.write(CalendarExport.ics(info), to: url) }.value
    }
    func exportBackup() async throws {
        // Selecting the parent grants sandbox access to both the staging directory
        // and the final portable backup directory.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = preferences.text("chooseBackupFolder")
        panel.prompt = preferences.text("exportBackupHere")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let date = Date.now.formatted(.iso8601.year().month().day())
        let url = parent.appendingPathComponent("JobTrail-\(date)-\(UUID().uuidString.prefix(8)).jobtrackerbackup")
        try await backups.export(applications: applications.map(ApplicationDTO.init), documentsRoot: documents.root, destination: url)
        notice = preferences.text("backupExported")
    }
    func chooseBackup() async throws {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupPreview = try await backups.validate(directory: url); showBackupImport = true
    }
    func importBackup(_ backup: ValidatedBackup, mode: BackupImportMode) async throws {
        let scope = backup.directory.startAccessingSecurityScopedResource()
        defer { if scope { backup.directory.stopAccessingSecurityScopedResource() } }
        // Revalidate immediately before mutation; the source may have changed since preview.
        let validated = try await backups.validate(directory: backup.directory)
        let currentIDs = Set(applications.map(\.id))
        let currentEventIDs = Set(applications.flatMap(\.events).map(\.id))
        let incoming = validated.manifest.applications
        let accepted = mode == .replace ? incoming : incoming.filter { !currentIDs.contains($0.id) && currentEventIDs.isDisjoint(with: $0.events.map(\.id)) }
        if mode == .replace {
            let emergency = documents.root.appendingPathComponent("EmergencyBackups/\(UUID().uuidString).jobtrackerbackup")
            try FileManager.default.createDirectory(at: emergency.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await backups.export(applications: applications.map(ApplicationDTO.init), documentsRoot: documents.root, destination: emergency)
        }
        var changes: [DocumentChange] = accepted.map { .init(applicationID: $0.id, source: $0.pdfRelativePath.map { validated.directory.appendingPathComponent($0) }) }
        if mode == .replace {
            let newIDs = Set(accepted.map(\.id))
            changes += applications.filter { !newIDs.contains($0.id) }.map { .init(applicationID: $0.id, source: nil) }
        }
        let transaction = try await documents.begin(changes)
        if mode == .replace {
            // Reassign globally unique event identities before deleting old parents.
            let oldEvents = Dictionary(uniqueKeysWithValues: applications.flatMap(\.events).map { ($0.id, $0) })
            let wantedEvents = Set(accepted.flatMap(\.events).map(\.id))
            let newIDs = Set(accepted.map(\.id))
            for dto in accepted {
                let app: JobApplication
                if let current = applications.first(where: { $0.id == dto.id }) { app = current }
                else { app = JobApplication(id: dto.id, companyName: dto.companyName, createSubmission: false); context.insert(app) }
                apply(dto, to: app, existingEvents: oldEvents)
            }
            for event in oldEvents.values where !wantedEvents.contains(event.id) { context.delete(event) }
            for app in applications where !newIDs.contains(app.id) { context.delete(app) }
        } else {
            for dto in accepted { context.insert(dto.makeModel()) }
        }
        try await save(transaction: transaction)
        selection = applications.first?.id
        notice = preferences.text("importCompleted") + " \(accepted.count) · " + preferences.text("skipped") + " \(incoming.count - accepted.count)"
    }
    private func apply(_ dto: ApplicationDTO, to app: JobApplication, existingEvents: [UUID: RecruitmentEvent]) {
        app.companyName = dto.companyName; app.jobTitle = dto.jobTitle; app.appliedAt = dto.appliedAt
        app.jobOfferURL = dto.jobOfferURL; app.pdfRelativePath = dto.pdfRelativePath
        app.createdAt = dto.createdAt; app.updatedAt = dto.updatedAt
        var events: [RecruitmentEvent] = []
        for data in dto.events {
            let event: RecruitmentEvent
            if let existing = existingEvents[data.id] { event = existing }
            else { event = data.makeModel(); context.insert(event) }
            event.type = data.type; event.title = data.title; event.date = data.date; event.includesTime = data.includesTime
            event.meetingURL = data.meetingURL; event.emailContent = data.emailContent; event.notes = data.notes
            event.state = data.state; event.createdAt = data.createdAt; event.updatedAt = data.updatedAt
            event.reminderMinutes = data.reminderMinutes; event.durationMinutes = data.durationMinutes; event.emailDirection = data.emailDirection
            event.application = app; events.append(event)
        }
        app.events = events
    }
    func exportCSV() async throws {
        guard let url = savePanel(name: "JobTrail.csv", type: .commaSeparatedText) else { return }
        let p = preferences
        var rows = [[p.text("company"), p.text("jobTitle"), p.text("appliedAt"), p.text("offerURL"), p.text("status"), p.text("lastActivity")]]
        rows += applications.map { [$0.companyName, $0.jobTitle ?? "", p.date($0.appliedAt), $0.jobOfferURL?.absoluteString ?? "", p.text($0.status.key), p.date($0.lastActivity, time: true)] }
        try await backups.writeCSV(rows: rows, destination: url)
    }
    func chooseArchive() async throws {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveRoot = url; showArchiveImport = true
    }
    func importArchive(_ rows: [ArchiveCandidate], root: URL) async throws {
        let selected = rows.filter { $0.selected && $0.issue == nil }
        guard selected.allSatisfy(\.dateConfirmed) else { throw AppFailure("confirmDates") }
        for row in selected { _ = try Validation.company(row.company); _ = try Validation.url(row.offerURL) }
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        var apps: [JobApplication] = []
        for row in selected {
            try Task.checkCancellation()
            let app = JobApplication(companyName: try Validation.company(row.company), jobTitle: Validation.optionalText(row.title), appliedAt: row.appliedAt, jobOfferURL: try Validation.url(row.offerURL))
            app.pdfRelativePath = DocumentService.relativePath(for: app.id); apps.append(app)
        }
        let changes = zip(apps, selected).map { DocumentChange(applicationID: $0.0.id, source: $0.1.source) }
        let transaction = try await documents.begin(changes)
        do { try Task.checkCancellation() }
        catch { try await documents.rollback(transaction); throw error }
        for app in apps { context.insert(app) }
        try await save(transaction: transaction)
        selection = apps.first?.id
        notice = preferences.text("importCompleted") + " \(apps.count) · " + preferences.text("skipped") + " \(rows.count - apps.count) · " + preferences.text("errors") + " \(rows.filter { $0.issue != nil }.count)"
    }
}
