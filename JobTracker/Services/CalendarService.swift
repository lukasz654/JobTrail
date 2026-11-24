import Foundation
import UserNotifications

struct MeetingInfo: Sendable {
    var id: UUID
    var company: String
    var typeName: String
    var date: Date
    var includesTime: Bool
    var durationMinutes: Int?
    var meetingURL: URL?
    var notes: String?
    var reminderMinutes: Int?
    var isEligible: Bool
}
enum CalendarExport {
    static func reminderDate(for meeting: MeetingInfo, now: Date = .now) -> Date? {
        guard meeting.isEligible, meeting.includesTime, let minutes = meeting.reminderMinutes,
              [5,15,30,60,1440].contains(minutes) else { return nil }
        let date = meeting.date.addingTimeInterval(-Double(minutes) * 60)
        return date > now ? date : nil
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
    }
    static func fold(_ line: String) -> String {
        var result = ""; var length = 0
        for scalar in line.unicodeScalars {
            let piece = String(scalar)
            let count = piece.utf8.count
            if length + count > 75 { result += "\r\n "; length = 1 }
            result += piece; length += count
        }
        return result
    }
    static func ics(_ meeting: MeetingInfo, timeZone: TimeZone = .current, now: Date = .now) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//JobTrail//Recruitment//EN", "CALSCALE:GREGORIAN",
                     "X-WR-TIMEZONE:\(escape(timeZone.identifier))", "BEGIN:VEVENT",
                     "UID:\(meeting.id.uuidString)@jobtracker.local", "DTSTAMP:\(formatter.string(from: now))"]
        if meeting.includesTime {
            lines.append("DTSTART:\(formatter.string(from: meeting.date))")
            if let duration = meeting.durationMinutes { lines.append("DTEND:\(formatter.string(from: meeting.date.addingTimeInterval(Double(duration) * 60)))") }
        } else {
            formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd"
            lines.append("DTSTART;VALUE=DATE:\(formatter.string(from: meeting.date))")
        }
        lines += ["SUMMARY:\(escape(meeting.company + " · " + meeting.typeName))"]
        if let url = meeting.meetingURL { lines.append("URL:\(url.absoluteString)") }
        if let notes = meeting.notes { lines.append("DESCRIPTION:\(escape(notes))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
    static func write(_ text: String, to url: URL) throws {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
actor ReminderService {
    private let enabled: Bool
    private var synchronization: Task<Void, Error>?
    init(enabled: Bool = true) { self.enabled = enabled }
    func authorize() async throws -> Bool {
        guard enabled else { return false }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func synchronize(_ meetings: [MeetingInfo], title: String) async throws {
        guard enabled else { return }
        // Finish earlier asynchronous notification-center requests before reconciling
        // the next snapshot; actor isolation alone does not prevent reentrancy.
        let previous = synchronization
        let work = Task {
            _ = await previous?.result
            try await self.apply(meetings, title: title)
        }
        synchronization = work
        try await work.value
    }
    private func apply(_ meetings: [MeetingInfo], title: String) async throws {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("JobTracker.") }.map(\.identifier))
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for meeting in meetings {
            guard let fireDate = CalendarExport.reminderDate(for: meeting) else { continue }
            let content = UNMutableNotificationContent(); content.title = title
            content.body = meeting.company + " · " + meeting.typeName; content.sound = .default
            var components = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: fireDate)
            components.timeZone = .current
            let request = UNNotificationRequest(identifier: "JobTracker." + meeting.id.uuidString, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try await center.add(request)
        }
    }
}
