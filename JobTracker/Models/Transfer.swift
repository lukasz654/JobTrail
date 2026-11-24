import Foundation

struct AppFailure: Error, Sendable {
    let key: String
    let detail: String
    init(_ key: String, detail: String = "") { self.key = key; self.detail = detail }
}

enum Validation {
    static func optionalText(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    static func url(_ text: String) throws -> URL? {
        guard let value = optionalText(text) else { return nil }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !value.contains(where: { $0.isWhitespace }) else { throw AppFailure("invalidURL") }
        return url
    }
    static func company(_ text: String) throws -> String {
        guard let name = optionalText(text) else { throw AppFailure("companyRequired") }
        return name
    }
    static func detectedMeetingURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var found: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, (try? self.url(url.absoluteString)) != nil else { continue }
            let host = url.host?.lowercased() ?? ""
            let known = ["teams.microsoft.com", "teams.live.com", "meet.google.com", "zoom.us", "webex.com"]
            if known.contains(where: { host == $0 || host.hasSuffix("." + $0) }), !found.contains(url) { found.append(url) }
        }
        return found
    }
}

struct ApplicationDraft: Sendable {
    var companyName = ""
    var jobTitle = ""
    var appliedAt = Date.now
    var jobOfferURL = ""
    var pdfSource: URL?
    var removePDF = false
    @MainActor init(application: JobApplication? = nil) {
        if let application {
            companyName = application.companyName; jobTitle = application.jobTitle ?? ""
            appliedAt = application.appliedAt; jobOfferURL = application.jobOfferURL?.absoluteString ?? ""
        }
    }
    func validate() throws { _ = try Validation.company(companyName); _ = try Validation.url(jobOfferURL) }
}
struct EventDraft: Sendable {
    var type: RecruitmentEventType = .recruiterContact
    var title = ""
    var date = Date.now
    var includesTime = false
    var meetingURL = ""
    var emailContent = ""
    var notes = ""
    var state: RecruitmentEventState = .completed
    var reminderEnabled = false
    var reminderMinutes = 15
    var durationMinutes = 0
    var emailDirection: EmailDirection = .incoming
    @MainActor init(event: RecruitmentEvent? = nil, type: RecruitmentEventType? = nil) {
        if let event {
            self.type = event.type; title = event.title ?? ""; date = event.date; includesTime = event.includesTime
            meetingURL = event.meetingURL?.absoluteString ?? ""; emailContent = event.emailContent ?? ""; notes = event.notes ?? ""
            state = event.state; reminderEnabled = event.reminderMinutes != nil; reminderMinutes = event.reminderMinutes ?? 15
            durationMinutes = event.durationMinutes ?? 0; emailDirection = event.emailDirection ?? .incoming
        } else if let type {
            self.type = type; includesTime = type.isMeeting; state = type.isMeeting ? .scheduled : .completed
        }
    }
}
struct EventDTO: Codable, Sendable, Equatable {
    var id: UUID
    var type: RecruitmentEventType
    var title: String?
    var date: Date
    var includesTime: Bool
    var meetingURL: URL?
    var emailContent: String?
    var notes: String?
    var state: RecruitmentEventState
    var createdAt: Date
    var updatedAt: Date
    var reminderMinutes: Int?
    var durationMinutes: Int?
    var emailDirection: EmailDirection?
    var applicationID: UUID
    @MainActor init(_ event: RecruitmentEvent, applicationID: UUID) {
        id = event.id; type = event.type; title = event.title; date = event.date; includesTime = event.includesTime
        meetingURL = event.meetingURL; emailContent = event.emailContent; notes = event.notes; state = event.state
        createdAt = event.createdAt; updatedAt = event.updatedAt; reminderMinutes = event.reminderMinutes
        durationMinutes = event.durationMinutes; emailDirection = event.emailDirection; self.applicationID = applicationID
    }
    @MainActor func makeModel() -> RecruitmentEvent {
        let event = RecruitmentEvent(id: id, type: type, date: date, includesTime: includesTime, state: state)
        event.title = title; event.meetingURL = meetingURL; event.emailContent = emailContent; event.notes = notes
        event.createdAt = createdAt; event.updatedAt = updatedAt; event.reminderMinutes = reminderMinutes
        event.durationMinutes = durationMinutes; event.emailDirection = emailDirection
        return event
    }
}
struct ApplicationDTO: Codable, Sendable, Equatable {
    var id: UUID
    var companyName: String
    var jobTitle: String?
    var appliedAt: Date
    var jobOfferURL: URL?
    var pdfRelativePath: String?
    var createdAt: Date
    var updatedAt: Date
    var events: [EventDTO]
    @MainActor init(_ app: JobApplication) {
        id = app.id; companyName = app.companyName; jobTitle = app.jobTitle; appliedAt = app.appliedAt
        jobOfferURL = app.jobOfferURL; pdfRelativePath = app.pdfRelativePath; createdAt = app.createdAt; updatedAt = app.updatedAt
        events = app.orderedEvents.map { EventDTO($0, applicationID: app.id) }
    }
    @MainActor func makeModel() -> JobApplication {
        let app = JobApplication(id: id, companyName: companyName, jobTitle: jobTitle, appliedAt: appliedAt, jobOfferURL: jobOfferURL, createSubmission: false)
        app.pdfRelativePath = pdfRelativePath; app.createdAt = createdAt; app.updatedAt = updatedAt
        app.events = events.map { $0.makeModel() }
        for event in app.events { event.application = app }
        return app
    }
}
struct BackupManifest: Codable, Sendable {
    var format = "JobTrackerBackup"
    var version = 1
    var exportedAt = Date.now
    var applications: [ApplicationDTO]
}
