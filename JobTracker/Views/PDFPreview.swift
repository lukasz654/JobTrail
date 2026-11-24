import SwiftUI
import PDFKit

struct PDFPreview: View {
    let applicationID: UUID
    let relativePath: String
    let revision: Date
    @Environment(ApplicationStore.self) private var store
    @Environment(Preferences.self) private var p
    @State private var pdfView = PDFView()
    @State private var errorMessage: String?
    @State private var loading = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { pdfView.goToPreviousPage(nil) } label: { Label(p.text("previousPage"), systemImage: "chevron.left") }
                Button { pdfView.goToNextPage(nil) } label: { Label(p.text("nextPage"), systemImage: "chevron.right") }
                Spacer()
                Button { pdfView.zoomOut(nil) } label: { Label(p.text("zoomOut"), systemImage: "minus.magnifyingglass") }
                Button { pdfView.zoomIn(nil) } label: { Label(p.text("zoomIn"), systemImage: "plus.magnifyingglass") }
                Button(p.text("fitPDF")) { pdfView.autoScales = true }
            }.labelStyle(.iconOnly).padding(8).disabled(loading || errorMessage != nil)
            if let errorMessage {
                ContentUnavailableView(p.text("pdfUnavailable"), systemImage: "doc.badge.exclamationmark", description: Text(errorMessage)).frame(minHeight: 240)
            } else {
                PDFKitView(pdfView: pdfView).frame(minHeight: 260)
                    .overlay { if loading { ProgressView() } }
            }
        }
        .task(id: revision) {
            loading = true; errorMessage = nil
            do {
                let url = try await store.documents.checkedURL(id: applicationID, relativePath: relativePath)
                try Task.checkCancellation()
                // PDFKit lazily reads page contents from this managed file URL.
                guard let document = PDFDocument(url: url) else { throw AppFailure("invalidPDF") }
                pdfView.document = document; pdfView.autoScales = true
            } catch is CancellationError { }
            catch { errorMessage = p.errorText(error) }
            loading = false
        }
    }
}
private struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView {
        pdfView.displayMode = .singlePageContinuous; pdfView.displayDirection = .vertical
        pdfView.appearance = NSAppearance(named: .aqua)
        return pdfView
    }
    func updateNSView(_ nsView: PDFView, context: Context) { }
}
