import Foundation
import PDFKit

struct ArchiveCandidate: Identifiable, Sendable {
    var id = UUID()
    var company: String
    var title = ""
    var source: URL
    var appliedAt: Date
    var offerURL = ""
    var selected = true
    var dateConfirmed = false
    var issue: String?
    var warning: String?
    var hasTextSuggestions = false
}
struct ArchiveScan: Sendable { var candidates: [ArchiveCandidate]; var emptyFolders: Int }
struct ArchiveSuggestion: Sendable {
    var id: UUID
    var title: String?
    var offerURL: URL?
    var issue: String?
}
actor ArchiveService {
    nonisolated static func fields(in text: String) -> (title: String?, offerURL: URL?) {
        func uniqueValue(labels: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: "^(?:" + labels + ")[ \\t]*:[ \\t]*([^\\r\\n]+)$", options: [.caseInsensitive, .anchorsMatchLines]) else { return nil }
            let values = Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return Validation.optionalText(String(text[range]))
            })
            return values.count == 1 ? values.first : nil
        }
        let title = uniqueValue(labels: "stanowisko|job title|position").flatMap { $0.count <= 200 ? $0 : nil }
        let url = uniqueValue(labels: "link do ogłoszenia|adres ogłoszenia|job offer url|job url|offer url").flatMap { try? Validation.url($0) }
        return (title, url)
    }
    func suggestions(root: URL, candidates: [ArchiveCandidate]) throws -> [ArchiveSuggestion] {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var result: [ArchiveSuggestion] = []
        for row in candidates {
            try Task.checkCancellation()
            do {
                try DocumentService.validatePDF(at: row.source)
                guard let document = PDFDocument(url: row.source) else { throw AppFailure("invalidPDF") }
                var text = ""
                // Offer headers normally live near the start. Limit optional extraction
                // rather than eagerly reading every page of a large document.
                for index in 0..<min(document.pageCount, 3) {
                    try Task.checkCancellation()
                    text += (document.page(at: index)?.string ?? "") + "\n"
                }
                let fields = Self.fields(in: text)
                result.append(.init(id: row.id, title: fields.title, offerURL: fields.offerURL))
            } catch is CancellationError { throw CancellationError() }
            catch { result.append(.init(id: row.id, issue: "invalidPDF")) }
        }
        return result
    }
    func scan(root: URL, existingDigests: Set<String> = []) throws -> ArchiveScan {
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var candidates: [ArchiveCandidate] = []; var empty = 0
        var seen = existingDigests
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey,.contentModificationDateKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "pdf" }
            if files.isEmpty { empty += 1 }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let resource = try file.resourceValues(forKeys: [.creationDateKey,.contentModificationDateKey,.isSymbolicLinkKey])
                guard resource.isSymbolicLink != true else { continue }
                var row = ArchiveCandidate(company: folder.lastPathComponent, source: file, appliedAt: resource.creationDate ?? resource.contentModificationDate ?? .now)
                do {
                    try DocumentService.validatePDF(at: file)
                    let digest = try DocumentService.digest(at: file)
                    if !seen.insert(digest).inserted { row.warning = "duplicatePDFWarning"; row.selected = false }
                }
                catch is CancellationError { throw CancellationError() }
                catch { row.issue = "invalidPDF"; row.selected = false }
                candidates.append(row)
            }
        }
        return .init(candidates: candidates, emptyFolders: empty)
    }
}
