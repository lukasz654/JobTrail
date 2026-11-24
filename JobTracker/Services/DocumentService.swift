import Foundation
import PDFKit
import CryptoKit

struct DocumentChange: Sendable {
    let applicationID: UUID
    let source: URL?
}
struct DocumentTransaction: Sendable {
    let id: UUID
    let entries: [Entry]
    struct Entry: Sendable { let applicationID: UUID; let hadOriginal: Bool }
}

actor DocumentService {
    nonisolated let root: URL
    private let fm: FileManager
    private var activeTransaction: UUID?
    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root; fm = fileManager
        try fileManager.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }
    nonisolated static func relativePath(for id: UUID) -> String { "Documents/\(id.uuidString)/job-offer.pdf" }
    nonisolated func url(for id: UUID) -> URL { root.appendingPathComponent(Self.relativePath(for: id)) }
    static func validatePDF(at url: URL) throws {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw AppFailure("invalidPDF", detail: url.lastPathComponent)
        }
    }
    static func safeDocumentURL(root: URL, relativePath: String, applicationID: UUID) throws -> URL {
        guard relativePath == Self.relativePath(for: applicationID) else { throw AppFailure("unsafePath") }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        // Resolving a complete nonexistent path can leave its symlink ancestors
        // unresolved. Inspect each component without following the link target.
        var componentURL = root.standardizedFileURL
        for component in relativePath.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: componentURL.path)) != nil {
                throw AppFailure("unsafePath")
            }
        }
        let result = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(resolvedRoot.path + "/") else { throw AppFailure("unsafePath") }
        return result
    }
    func checkedURL(id: UUID, relativePath: String) throws -> URL {
        let url = try Self.safeDocumentURL(root: root, relativePath: relativePath, applicationID: id)
        guard fm.fileExists(atPath: url.path) else { throw AppFailure("missingPDF") }
        try Self.validatePDF(at: url)
        return url
    }
    func begin(_ changes: [DocumentChange]) throws -> DocumentTransaction {
        guard activeTransaction == nil else { throw AppFailure("operationBusy") }
        guard Set(changes.map(\.applicationID)).count == changes.count else { throw AppFailure("invalidBackup") }
        let id = UUID()
        let work = root.appendingPathComponent("Transactions/\(id.uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var entries: [DocumentTransaction.Entry] = []
        do {
            // Validate and stage every source before touching managed originals.
            for change in changes {
                try Task.checkCancellation()
                _ = try Self.safeDocumentURL(root: root, relativePath: Self.relativePath(for: change.applicationID), applicationID: change.applicationID)
                if let source = change.source {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try Self.validatePDF(at: source)
                    let staged = work.appendingPathComponent("new-\(change.applicationID.uuidString)")
                    try fm.createDirectory(at: staged, withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: staged.appendingPathComponent("job-offer.pdf"))
                    try Self.validatePDF(at: staged.appendingPathComponent("job-offer.pdf"))
                }
            }
            for change in changes {
                try Task.checkCancellation()
                let directory = root.appendingPathComponent("Documents/\(change.applicationID.uuidString)")
                let hadOriginal = fm.fileExists(atPath: directory.path)
                if hadOriginal { try fm.moveItem(at: directory, to: work.appendingPathComponent("old-\(change.applicationID.uuidString)")) }
                entries.append(.init(applicationID: change.applicationID, hadOriginal: hadOriginal))
                if change.source != nil {
                    try fm.moveItem(at: work.appendingPathComponent("new-\(change.applicationID.uuidString)"), to: directory)
                }
            }
            try Task.checkCancellation()
            activeTransaction = id
            return .init(id: id, entries: entries)
        } catch {
            let transaction = DocumentTransaction(id: id, entries: entries)
            activeTransaction = id
            do { try rollback(transaction) } catch { throw AppFailure("rollbackFailed", detail: work.path) }
            throw error
        }
    }
    func rollback(_ transaction: DocumentTransaction) throws {
        guard activeTransaction == transaction.id else { throw AppFailure("operationBusy") }
        let work = root.appendingPathComponent("Transactions/\(transaction.id.uuidString)")
        for entry in transaction.entries.reversed() {
            let target = root.appendingPathComponent("Documents/\(entry.applicationID.uuidString)")
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if entry.hadOriginal { try fm.moveItem(at: work.appendingPathComponent("old-\(entry.applicationID.uuidString)"), to: target) }
        }
        try fm.removeItem(at: work)
        activeTransaction = nil
    }
    func commit(_ transaction: DocumentTransaction) throws {
        guard activeTransaction == transaction.id else { throw AppFailure("operationBusy") }
        activeTransaction = nil
        try fm.removeItem(at: root.appendingPathComponent("Transactions/\(transaction.id.uuidString)"))
    }
    nonisolated static func digest(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func existingDigests(_ ids: [UUID]) throws -> Set<String> {
        var result = Set<String>()
        for id in ids {
            let source = try Self.safeDocumentURL(root: root, relativePath: Self.relativePath(for: id), applicationID: id)
            guard fm.fileExists(atPath: source.path) else { continue }
            do { result.insert(try Self.digest(at: source)) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return result
    }
    func export(id: UUID, relativePath: String, destination: URL) throws {
        let source = try checkedURL(id: id, relativePath: relativePath)
        let scope = destination.startAccessingSecurityScopedResource()
        defer { if scope { destination.stopAccessingSecurityScopedResource() } }
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        try data.write(to: destination, options: .atomic)
    }
}
