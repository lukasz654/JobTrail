import AppKit
import Foundation
import PDFKit
import Testing
@testable import JobTracker

struct TestFiles {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("JobTrackerTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    @MainActor func pdf(_ name: String = "source.pdf", pages: Int = 1) throws -> URL {
        let document = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 200, height: 200))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 200).fill(); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: i)
        }
        let url = root.appendingPathComponent(name)
        guard document.write(to: url) else { throw AppFailure("invalidPDF") }
        return url
    }
}
@Suite @MainActor struct ServiceTests {
    @Test func importedCopySurvivesSourceRemovalAndExports() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let source = try files.pdf()
        let service = try DocumentService(root: files.root.appendingPathComponent("Managed"))
        let id = UUID()
        let transaction = try await service.begin([.init(applicationID: id, source: source)])
        try await service.commit(transaction)
        try FileManager.default.removeItem(at: source)
        let url = try await service.checkedURL(id: id, relativePath: DocumentService.relativePath(for: id))
        #expect(PDFDocument(url: url)?.pageCount == 1)
        let destination = files.root.appendingPathComponent("export.pdf")
        try await service.export(id: id, relativePath: DocumentService.relativePath(for: id), destination: destination)
        #expect(PDFDocument(url: destination)?.pageCount == 1)
    }
    @Test func failedReplacementPreservesOriginalAndRollbackRestores() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let source = try files.pdf(); let replacement = try files.pdf("replacement.pdf", pages: 2)
        let invalid = files.root.appendingPathComponent("bad.pdf"); try Data("broken".utf8).write(to: invalid)
        let service = try DocumentService(root: files.root.appendingPathComponent("Managed")); let id = UUID()
        let initial = try await service.begin([.init(applicationID: id, source: source)])
        try await service.commit(initial)
        do { _ = try await service.begin([.init(applicationID: id, source: invalid)]); Issue.record("Invalid PDF accepted") } catch { }
        #expect(PDFDocument(url: service.url(for: id))?.pageCount == 1)
        let transaction = try await service.begin([.init(applicationID: id, source: replacement)])
        #expect(PDFDocument(url: service.url(for: id))?.pageCount == 2)
        try await service.rollback(transaction)
        #expect(PDFDocument(url: service.url(for: id))?.pageCount == 1)
        let deletion = try await service.begin([.init(applicationID: id, source: nil)])
        try await service.rollback(deletion)
        #expect(FileManager.default.fileExists(atPath: service.url(for: id).path))
    }
    @Test func rejectsTraversalAndSymlinkEscape() throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let id = UUID()
        #expect(throws: AppFailure.self) { try DocumentService.safeDocumentURL(root: files.root, relativePath: "../secret.pdf", applicationID: id) }
        let documents = files.root.appendingPathComponent("Documents")
        try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: URL(fileURLWithPath: "/tmp"))
        #expect(throws: AppFailure.self) { try DocumentService.safeDocumentURL(root: files.root, relativePath: DocumentService.relativePath(for: id), applicationID: id) }
    }
    @Test func rejectsDanglingSymlinksAtEveryDocumentLevel() throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let id = UUID()
        let documents = files.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let applicationDirectory = documents.appendingPathComponent(id.uuidString)
        let missingTarget = files.root.deletingLastPathComponent().appendingPathComponent("Missing-\(UUID())")
        try FileManager.default.createSymbolicLink(at: applicationDirectory, withDestinationURL: missingTarget)
        #expect(throws: AppFailure.self) {
            try DocumentService.safeDocumentURL(root: files.root, relativePath: DocumentService.relativePath(for: id), applicationID: id)
        }
        try FileManager.default.removeItem(at: applicationDirectory)
        try FileManager.default.createDirectory(at: applicationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: applicationDirectory.appendingPathComponent("job-offer.pdf"), withDestinationURL: missingTarget)
        #expect(throws: AppFailure.self) {
            try DocumentService.safeDocumentURL(root: files.root, relativePath: DocumentService.relativePath(for: id), applicationID: id)
        }
    }
    @Test func backupRoundTripIncludesPDFUnicodeAndMultilineEmail() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let docs = try DocumentService(root: files.root.appendingPathComponent("Managed"))
        let app = JobApplication(companyName: "Żółć \"Firma\"", jobTitle: "Programista", appliedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let email = RecruitmentEvent(type: .email); email.emailContent = "Dzień dobry!\nZażółć gęślą jaźń.\n<html>plain text</html>"; email.application = app
        app.events.append(email); app.pdfRelativePath = DocumentService.relativePath(for: app.id)
        let source = try files.pdf()
        let transaction = try await docs.begin([.init(applicationID: app.id, source: source)]); try await docs.commit(transaction)
        let service = BackupService(); let destination = files.root.appendingPathComponent("backup.jobtrackerbackup")
        try await service.export(applications: [ApplicationDTO(app)], documentsRoot: docs.root, destination: destination)
        let result = try await service.validate(directory: destination)
        #expect(result.manifest.applications[0].companyName == app.companyName)
        #expect(result.manifest.applications[0].events.last?.emailContent == email.emailContent)
        let restored = result.manifest.applications[0].makeModel()
        #expect(restored.events.count == 2)
        #expect(restored.events.allSatisfy { $0.application === restored })
        try FileManager.default.removeItem(at: destination.appendingPathComponent(app.pdfRelativePath!))
        do { _ = try await service.validate(directory: destination); Issue.record("Missing PDF accepted") } catch { }
    }
    @Test func invalidBackupRelationshipsAndVersionsAreRejected() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let app = JobApplication(companyName: "A")
        let service = BackupService()
        var manifest = BackupManifest(applications: [ApplicationDTO(app)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        manifest.version = 100
        try encoder.encode(manifest).write(to: files.root.appendingPathComponent("manifest.json"))
        do { _ = try await service.validate(directory: files.root); Issue.record("Unsupported version accepted") } catch { }
        manifest.version = 1; manifest.applications[0].events[0].applicationID = UUID()
        try encoder.encode(manifest).write(to: files.root.appendingPathComponent("manifest.json"))
        do { _ = try await service.validate(directory: files.root); Issue.record("Invalid relationship accepted") } catch { }
    }
    @Test func backupPreservesSubsecondSubmissionIdentity() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let app = JobApplication(companyName: "A", appliedAt: Date(timeIntervalSince1970: 1_700_000_000))
        app.initialEvent?.createdAt = Date(timeIntervalSince1970: 1_700_000_001.1)
        let second = RecruitmentEvent(type: .applicationSent, date: app.appliedAt.addingTimeInterval(60))
        second.createdAt = Date(timeIntervalSince1970: 1_700_000_001.2)
        app.events.append(second); second.application = app
        let destination = files.root.appendingPathComponent("backup")
        let service = BackupService()
        try await service.export(applications: [ApplicationDTO(app)], documentsRoot: files.root, destination: destination)
        let restored = try await service.validate(directory: destination)
        #expect(restored.manifest.applications[0].makeModel().initialEvent?.id == app.initialEvent?.id)
    }
    @Test func archiveScanIsReadOnlyAndReportsBadFilesAndEmptyFolders() async throws {
        let files = try TestFiles(); defer { files.cleanup() }
        let folder = files.root.appendingPathComponent("Firma Żółć")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let source = try files.pdf()
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Offer.pdf"))
        try Data("bad".utf8).write(to: folder.appendingPathComponent("Broken.pdf"))
        let scan = try await ArchiveService().scan(root: files.root)
        #expect(scan.emptyFolders == 1)
        #expect(scan.candidates.count == 2)
        #expect(scan.candidates.allSatisfy { $0.company == "Firma Żółć" && !$0.dateConfirmed && $0.title.isEmpty })
        #expect(scan.candidates.filter { $0.issue != nil }.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    @Test func pdfTextSuggestionsUseOnlyExplicitLabels() {
        let result = ArchiveService.fields(in: "Stanowisko: Senior iOS Developer\nLink do ogłoszenia: https://example.com/jobs/123\n")
        #expect(result.title == "Senior iOS Developer")
        #expect(result.offerURL?.absoluteString == "https://example.com/jobs/123")
        let english = ArchiveService.fields(in: "Job title: macOS Developer\nJob URL: https://example.com/job\n")
        #expect(english.title == "macOS Developer")
        #expect(english.offerURL != nil)
    }
    @Test func pdfTextSuggestionsDoNotGuessAmbiguousOrUnlabelledFields() {
        let unlabelled = ArchiveService.fields(in: "Senior iOS Developer\nhttps://example.com/jobs/123\n")
        #expect(unlabelled.title == nil)
        #expect(unlabelled.offerURL == nil)
        let ambiguous = ArchiveService.fields(in: "Position: iOS Developer\nPosition: macOS Developer\nJob URL: javascript:alert(1)\n")
        #expect(ambiguous.title == nil)
        #expect(ambiguous.offerURL == nil)
    }
}
