import Foundation
import SwiftData
import Testing
@testable import JobTracker

@Suite @MainActor struct PersistenceTests {
    private func store(root: URL) throws -> ApplicationStore {
        try ApplicationStore(container: Persistence.container(inMemory: true), documents: DocumentService(root: root), reminders: ReminderService(enabled: false),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }
    @Test func formSaveDateSynchronizationAndHistoryPreservation() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let store = try store(root: files.root)
        var draft = ApplicationDraft(); draft.companyName = "  Żółć  "; draft.jobTitle = "Engineer"
        try await store.saveApplication(draft, existing: nil)
        let app = try #require(store.applications.first)
        #expect(app.companyName == "Żółć")
        #expect(store.selection == app.id)
        var event = EventDraft(type: .note); event.notes = "History\nNotatka"
        try await store.saveEvent(event, application: app, existing: nil)
        draft.appliedAt = .distantPast; draft.companyName = "Edited"
        try await store.saveApplication(draft, existing: app)
        #expect(app.initialEvent?.date == .distantPast)
        #expect(app.events.count == 2)
        #expect(app.events.contains { $0.notes == "History\nNotatka" })
        let fresh = ModelContext(store.container)
        #expect(try fresh.fetch(FetchDescriptor<JobApplication>()).first?.companyName == "Edited")
    }
    @Test func cascadeDeletionRemovesEventsAndPDF() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let store = try store(root: files.root.appendingPathComponent("Managed"))
        var draft = ApplicationDraft(); draft.companyName = "A"; draft.pdfSource = try files.pdf()
        try await store.saveApplication(draft, existing: nil)
        let app = try #require(store.applications.first)
        let pdfURL = store.documents.url(for: app.id)
        #expect(FileManager.default.fileExists(atPath: pdfURL.path))
        try await store.delete(app)
        #expect(try store.context.fetchCount(FetchDescriptor<RecruitmentEvent>()) == 0)
        #expect(store.applications.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pdfURL.path))
    }
    @Test func backupRestoreToEmptyStoreMergeAndReplacement() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let original = try store(root: files.root.appendingPathComponent("Original"))
        var draft = ApplicationDraft(); draft.companyName = "Łódź"; draft.pdfSource = try files.pdf()
        try await original.saveApplication(draft, existing: nil)
        let app = try #require(original.applications.first)
        var email = EventDraft(type: .email); email.emailContent = "Witaj\nŻółć"
        try await original.saveEvent(email, application: app, existing: nil)
        let backupURL = files.root.appendingPathComponent("Backup")
        try await original.backups.export(applications: original.applications.map(ApplicationDTO.init), documentsRoot: original.documents.root, destination: backupURL)
        let target = try store(root: files.root.appendingPathComponent("Target"))
        let backup = try await target.backups.validate(directory: backupURL)
        try await target.importBackup(backup, mode: .merge)
        #expect(target.applications.count == 1)
        #expect(target.applications[0].events.count == 2)
        #expect(FileManager.default.fileExists(atPath: target.documents.url(for: app.id).path))
        try await target.importBackup(backup, mode: .merge)
        #expect(target.applications.count == 1)
        var other = ApplicationDraft(); other.companyName = "Other"
        try await target.saveApplication(other, existing: nil)
        try await target.importBackup(backup, mode: .replace)
        #expect(target.applications.count == 1)
        #expect(target.applications[0].companyName == "Łódź")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.documents.root.appendingPathComponent("EmergencyBackups").path).count == 1)
        #expect(try target.context.fetchCount(FetchDescriptor<RecruitmentEvent>()) == 2)
    }
    @Test func invalidFormAndFailedImportLeaveDatabaseIntact() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let store = try store(root: files.root)
        var draft = ApplicationDraft(); draft.companyName = "A"
        try await store.saveApplication(draft, existing: nil)
        draft.companyName = " "
        do { try await store.saveApplication(draft, existing: nil); Issue.record("Invalid company accepted") } catch { }
        #expect(store.applications.count == 1)
        let bad = ValidatedBackup(manifest: BackupManifest(applications: []), directory: files.root.appendingPathComponent("missing"))
        do { try await store.importBackup(bad, mode: .replace); Issue.record("Invalid backup accepted") } catch { }
        #expect(store.applications.count == 1)
    }
    @Test func onDiskStorePersistsAcrossContainers() throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let url = files.root.appendingPathComponent("test.store")
        let id: UUID
        do {
            let container = try Persistence.container(storeURL: url)
            let app = JobApplication(companyName: "Persistence")
            id = app.id; container.mainContext.insert(app); try container.mainContext.save()
        }
        let reopened = try Persistence.container(storeURL: url)
        let app = try #require(reopened.mainContext.fetch(FetchDescriptor<JobApplication>()).first)
        #expect(app.id == id)
        #expect(app.initialEvent?.application?.id == id)
    }
    @Test func archiveRequiresDateConfirmationAndPreservesOriginal() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let source = try files.pdf()
        let store = try store(root: files.root.appendingPathComponent("Managed"))
        var row = ArchiveCandidate(company: "Żółć", source: source, appliedAt: Date(timeIntervalSince1970: 1_700_000_000))
        do { try await store.importArchive([row], root: files.root); Issue.record("Unconfirmed date accepted") } catch { }
        #expect(store.applications.isEmpty)
        row.dateConfirmed = true
        try await store.importArchive([row], root: files.root)
        #expect(store.applications.count == 1)
        #expect(store.applications[0].initialEvent?.date == row.appliedAt)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: store.documents.url(for: store.applications[0].id).path))
    }
}
