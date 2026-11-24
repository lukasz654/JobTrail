import Foundation

struct ValidatedBackup: Sendable {
    let manifest: BackupManifest
    let directory: URL
}
enum BackupImportMode: String, LocalizedOption { case merge, replace }

actor BackupService {
    private let fm: FileManager
    init(fileManager: FileManager = .default) { fm = fileManager }
    func export(applications: [ApplicationDTO], documentsRoot: URL, destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        guard !fm.fileExists(atPath: destination.path) else { throw AppFailure("destinationExists") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".JobTracker-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { if fm.fileExists(atPath: stage.path) { try? fm.removeItem(at: stage) } }
        for app in applications {
            if let relative = app.pdfRelativePath {
                let source = try DocumentService.safeDocumentURL(root: documentsRoot, relativePath: relative, applicationID: app.id)
                try DocumentService.validatePDF(at: source)
                let target = stage.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                try DocumentService.validatePDF(at: target)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep subsecond ordering when several events are created in one second.
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(BackupManifest(applications: applications)).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: stage, to: destination)
    }
    func validate(directory: URL) throws -> ValidatedBackup {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let resolved = manifestURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw AppFailure("unsafePath") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
            let string = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw AppFailure("invalidBackup")
        }
        let manifest: BackupManifest
        do { manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL, options: .mappedIfSafe)) }
        catch { throw AppFailure("invalidBackup") }
        guard manifest.format == "JobTrackerBackup", manifest.version == 1 else { throw AppFailure("unsupportedBackup") }
        var ids = Set<UUID>(); var eventIDs = Set<UUID>()
        for app in manifest.applications {
            guard ids.insert(app.id).inserted, (try? Validation.company(app.companyName)) != nil,
                  app.appliedAt.timeIntervalSince1970.isFinite,
                  app.jobOfferURL == nil || (try? Validation.url(app.jobOfferURL!.absoluteString)) != nil else { throw AppFailure("invalidBackup") }
            let submissions = app.events.filter { $0.type == .applicationSent }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            guard let initial = submissions.first, abs(initial.date.timeIntervalSince(app.appliedAt)) < 1,
                  initial.state == .completed else { throw AppFailure("invalidBackup") }
            for event in app.events {
                guard eventIDs.insert(event.id).inserted, event.applicationID == app.id,
                      event.meetingURL == nil || (try? Validation.url(event.meetingURL!.absoluteString)) != nil,
                      event.reminderMinutes == nil || [5,15,30,60,1440].contains(event.reminderMinutes!),
                      event.durationMinutes == nil || (1...1440).contains(event.durationMinutes!) else { throw AppFailure("invalidBackup") }
            }
            if let relative = app.pdfRelativePath {
                let url = try DocumentService.safeDocumentURL(root: directory, relativePath: relative, applicationID: app.id)
                try DocumentService.validatePDF(at: url)
            }
        }
        return .init(manifest: manifest, directory: directory)
    }
    func writeCSV(rows: [[String]], destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try Self.csv(rows: rows).data(using: .utf8)!.write(to: destination, options: .atomic)
    }
    nonisolated static func csv(rows: [[String]]) -> String {
        "\u{FEFF}" + rows.map { row in row.map { value in
            // Spreadsheet programs must not interpret user-controlled cells as formulas.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
