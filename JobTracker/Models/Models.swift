import Foundation
import SwiftData

protocol LocalizedOption: RawRepresentable, CaseIterable, Identifiable where RawValue == String { }
extension LocalizedOption {
    var id: String { rawValue }
    var key: String { rawValue }
}

enum RecruitmentEventType: String, Codable, Sendable, LocalizedOption {
    case applicationSent, recruiterContact, hrInterview, technicalInterview, assignment, otherInterview
    case email, followUp, offer, rejection, withdrawal, noResponse, reopened, note, other
    var isMeeting: Bool { [.hrInterview, .technicalInterview, .otherInterview].contains(self) }
    var changesStatus: Bool { ![.email, .note, .followUp, .other].contains(self) }
    var symbol: String {
        switch self {
        case .applicationSent: "paperplane"
        case .recruiterContact: "person.crop.circle.badge.checkmark"
        case .hrInterview, .otherInterview: "person.2"
        case .technicalInterview: "laptopcomputer"
        case .assignment: "checklist"
        case .email, .followUp: "envelope"
        case .offer: "checkmark.seal"
        case .rejection: "xmark.circle"
        case .withdrawal: "arrow.uturn.backward"
        case .noResponse: "clock"
        case .reopened: "arrow.clockwise"
        case .note, .other: "note.text"
        }
    }
}
enum RecruitmentEventState: String, Codable, Sendable, LocalizedOption {
    case scheduled, completed, cancelled
}
enum ProcessStatus: String, Codable, Sendable, LocalizedOption {
    case submitted, contacted, hr, technical, task, interview, offered, rejected, withdrawn, unanswered, resumed
    case noContactAutomatic
    var isClosed: Bool { [.offered, .rejected, .withdrawn, .unanswered].contains(self) }
}
enum EmailDirection: String, Codable, Sendable, LocalizedOption { case incoming, outgoing }

@Model final class JobApplication {
    @Attribute(.unique) var id: UUID
    var companyName: String
    var jobTitle: String?
    var appliedAt: Date
    var jobOfferURL: URL?
    var pdfRelativePath: String?
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \RecruitmentEvent.application)
    var events: [RecruitmentEvent] = []

    init(id: UUID = UUID(), companyName: String, jobTitle: String? = nil, appliedAt: Date = .now,
         jobOfferURL: URL? = nil, createSubmission: Bool = true) {
        self.id = id; self.companyName = companyName; self.jobTitle = jobTitle
        self.appliedAt = appliedAt; self.jobOfferURL = jobOfferURL
        let now = Date.now; createdAt = now; updatedAt = now
        if createSubmission {
            let event = RecruitmentEvent(type: .applicationSent, date: appliedAt, state: .completed)
            events = [event]
            event.application = self
        }
    }
    var initialEvent: RecruitmentEvent? {
        events.filter { $0.type == .applicationSent }.min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }
    var orderedEvents: [RecruitmentEvent] {
        events.sorted { ($0.date, $0.createdAt, $0.id.uuidString) < ($1.date, $1.createdAt, $1.id.uuidString) }
    }
    var lastActivity: Date { max(updatedAt, events.map(\.updatedAt).max() ?? createdAt) }
    var status: ProcessStatus {
        status(asOf: .now)
    }
    func noContactDeadline(calendar: Calendar = .current) -> Date? {
        let submissionID = initialEvent?.id
        // The automatic submission uses appliedAt, including for historical imports.
        // Every other event resets the clock when added, regardless of its type,
        // scheduled/historical date or state. Editing does not reset the clock.
        let anchor = events.filter { $0.id != submissionID }.reduce(appliedAt) { max($0, $1.createdAt) }
        var day = calendar.startOfDay(for: anchor)
        var remaining = 10
        while remaining > 0 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            if ![1, 7].contains(calendar.component(.weekday, from: day)) { remaining -= 1 }
        }
        // Ten full working days must finish; the application/addition day is excluded.
        return calendar.date(byAdding: .day, value: 1, to: day).map { calendar.startOfDay(for: $0) }
    }
    func status(asOf now: Date, calendar: Calendar = .current) -> ProcessStatus {
        var result: ProcessStatus = .submitted
        for event in orderedEvents where event.state != .cancelled && event.type.changesStatus {
            if event.type == .reopened && event.state == .completed { result = .resumed; continue }
            if result.isClosed { continue }
            if event.state == .scheduled && !event.type.isMeeting && event.type != .assignment { continue }
            switch event.type {
            case .applicationSent: break
            case .recruiterContact: result = .contacted
            case .hrInterview: result = .hr
            case .technicalInterview: result = .technical
            case .assignment: result = .task
            case .otherInterview: result = .interview
            case .offer: result = .offered
            case .rejection: result = .rejected
            case .withdrawal: result = .withdrawn
            case .noResponse: result = .unanswered
            default: break
            }
        }
        if !result.isClosed, let deadline = noContactDeadline(calendar: calendar), now >= deadline {
            return .noContactAutomatic
        }
        return result
    }
}

@Model final class RecruitmentEvent {
    @Attribute(.unique) var id: UUID
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
    var application: JobApplication?

    init(id: UUID = UUID(), type: RecruitmentEventType, date: Date = .now,
         includesTime: Bool = false, state: RecruitmentEventState = .completed) {
        self.id = id; self.type = type; self.date = date; self.includesTime = includesTime; self.state = state
        let now = Date.now; createdAt = now; updatedAt = now
    }
    func isOverdue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        state == .scheduled && (includesTime ? date < now : calendar.startOfDay(for: date) < calendar.startOfDay(for: now))
    }
}

enum JobTrackerSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [JobApplication.self, RecruitmentEvent.self] }
}
enum JobTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [JobTrackerSchema.self] }
    static var stages: [MigrationStage] { [] }
}
@MainActor enum Persistence {
    static func container(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: JobTrackerSchema.self)
        let config: ModelConfiguration
        if let storeURL { config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none) }
        else { config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none) }
        return try ModelContainer(for: schema, migrationPlan: JobTrackerMigrationPlan.self, configurations: config)
    }
}
