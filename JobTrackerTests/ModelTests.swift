import Foundation
import Testing
@testable import JobTracker

@Suite @MainActor struct ModelTests {
    private var businessCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }
    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        businessCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    @Test func automaticNoContactWaitsForTenFullWeekdaysAfterApplication() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 9, hour: 18))
        // Tuesday 10 November is day 1; Monday 23 November is day 10.
        // Weekday public holidays are counted; only Saturdays/Sundays are excluded.
        #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 11, 24, hour: 0))
        #expect(app.status(asOf: day(2026, 11, 23, hour: 23, minute: 59), calendar: businessCalendar) == .submitted)
        #expect(app.status(asOf: day(2026, 11, 24, hour: 0), calendar: businessCalendar) == .noContactAutomatic)
        #expect(app.events.count == 1)
        #expect(!ProcessStatus.noContactAutomatic.isClosed)
    }
    @Test func automaticNoContactSkipsWeekendsAndCanStartOnSaturday() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 6))
        #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 11, 21, hour: 0))
        #expect(app.status(asOf: day(2026, 11, 20, hour: 23, minute: 59), calendar: businessCalendar) == .submitted)
        #expect(app.status(asOf: day(2026, 11, 21, hour: 0), calendar: businessCalendar) == .noContactAutomatic)
    }
    @Test func addingHistoricalNoteResetsClockButEditingDoesNot() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 2))
        let note = RecruitmentEvent(type: .note, date: day(2026, 11, 3))
        note.createdAt = day(2026, 11, 20)
        app.events.append(note)
        #expect(app.status(asOf: day(2026, 11, 24), calendar: businessCalendar) == .submitted)
        #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 12, 5, hour: 0))
        note.updatedAt = day(2026, 12, 7)
        note.date = day(2026, 12, 7)
        app.updatedAt = day(2026, 12, 7)
        #expect(app.status(asOf: day(2026, 12, 7), calendar: businessCalendar) == .noContactAutomatic)
    }
    @Test func everyNewEventRestartsTheFullWaitingPeriod() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 2))
        let contact = RecruitmentEvent(type: .recruiterContact, date: day(2026, 11, 20))
        contact.createdAt = day(2026, 11, 20)
        app.events.append(contact)
        let email = RecruitmentEvent(type: .email, date: day(2026, 11, 25))
        email.createdAt = day(2026, 11, 30)
        app.events.append(email)
        #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 12, 15, hour: 0))
        #expect(app.status(asOf: day(2026, 12, 5), calendar: businessCalendar) == .contacted)
        #expect(app.status(asOf: day(2026, 12, 15), calendar: businessCalendar) == .noContactAutomatic)
    }
    @Test func cancelledEventsOfEveryTypeAlsoResetTheClock() {
        for type in RecruitmentEventType.allCases {
            let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 2))
            app.initialEvent?.createdAt = day(2026, 11, 2)
            let event = RecruitmentEvent(type: type, date: day(2026, 10, 1), state: .cancelled)
            event.createdAt = day(2026, 11, 20)
            app.events.append(event)
            #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 12, 5, hour: 0))
            #expect(app.status(asOf: day(2026, 11, 24), calendar: businessCalendar) == .submitted)
        }
    }
    @Test func automaticNoContactDoesNotOverrideClosedRecruitments() {
        let endings: [(RecruitmentEventType, ProcessStatus)] = [(.rejection, .rejected), (.offer, .offered), (.withdrawal, .withdrawn), (.noResponse, .unanswered)]
        for (type, status) in endings {
            let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 2))
            let event = RecruitmentEvent(type: type, date: day(2026, 11, 3))
            event.createdAt = day(2026, 11, 3)
            app.events.append(event)
            #expect(app.status(asOf: day(2027, 2, 1), calendar: businessCalendar) == status)
        }
    }
    @Test func deletingLatestEventRestoresPreviousClockAnchor() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 11, 2))
        let note = RecruitmentEvent(type: .note)
        note.createdAt = day(2026, 11, 20)
        app.events.append(note)
        #expect(app.status(asOf: day(2026, 11, 24), calendar: businessCalendar) == .submitted)
        app.events.removeAll { $0.id == note.id }
        #expect(app.status(asOf: day(2026, 11, 24), calendar: businessCalendar) == .noContactAutomatic)
    }
    @Test func businessDayClockHandlesDaylightSavingTime() {
        let app = JobApplication(companyName: "A", appliedAt: day(2026, 3, 20))
        #expect(app.noContactDeadline(calendar: businessCalendar) == day(2026, 4, 4, hour: 0))
    }
    @Test func submissionAndRepeatedApplications() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = JobApplication(companyName: "Łódź", appliedAt: date)
        let second = JobApplication(companyName: "Łódź", appliedAt: date)
        #expect(first.id != second.id)
        #expect(first.events.count == 1)
        #expect(first.initialEvent?.date == date)
        #expect(first.initialEvent?.application === first)
        #expect(first.status(asOf: date) == .submitted)
    }
    @Test func overdueNeverCompletesAndCancellationDoesNotChangeStatus() {
        let app = JobApplication(companyName: "A", appliedAt: .distantPast)
        let event = RecruitmentEvent(type: .hrInterview, date: .now.addingTimeInterval(-3600), includesTime: true, state: .scheduled)
        app.events.append(event)
        #expect(event.isOverdue())
        #expect(event.state == .scheduled)
        #expect(app.status == .hr)
        event.state = .cancelled
        #expect(app.status == .submitted)
    }
    @Test func rejectionReopeningAndEmails() {
        let app = JobApplication(companyName: "A", appliedAt: .distantPast)
        let now = Date.now
        app.events.append(RecruitmentEvent(type: .rejection, date: now))
        app.events.append(RecruitmentEvent(type: .email, date: now.addingTimeInterval(1)))
        app.events.append(RecruitmentEvent(type: .note, date: now.addingTimeInterval(2)))
        app.events.append(RecruitmentEvent(type: .hrInterview, date: now.addingTimeInterval(3), state: .scheduled))
        #expect(app.status == .rejected)
        app.events.append(RecruitmentEvent(type: .reopened, date: now.addingTimeInterval(4)))
        #expect(app.status == .resumed)
        app.events.append(RecruitmentEvent(type: .technicalInterview, date: now.addingTimeInterval(5)))
        #expect(app.status == .technical)
    }
    @Test func historyIsChronologicalAndAllowsRepeatedTypes() {
        let app = JobApplication(companyName: "A", appliedAt: .distantPast)
        let later = RecruitmentEvent(type: .hrInterview, date: Date(timeIntervalSince1970: 200))
        let earlier = RecruitmentEvent(type: .hrInterview, date: Date(timeIntervalSince1970: 100))
        app.events += [later, earlier]
        #expect(app.orderedEvents.map(\.id) == [app.initialEvent!.id, earlier.id, later.id])
    }
    @Test func validationRejectsInvalidURLsAndBlankCompanies() throws {
        #expect(throws: AppFailure.self) { try Validation.company(" \n ") }
        for input in ["file:///tmp/a", "javascript:alert(1)", "https://", "https://a b.com", "ftp://example.com"] {
            #expect(throws: AppFailure.self) { try Validation.url(input) }
        }
        #expect(try Validation.url(" https://example.com/a?q=1 ")?.host == "example.com")
        #expect(try Validation.url(" ") == nil)
        #expect(try Validation.company(" Żółć ") == "Żółć")
    }
    @Test func detectsOnlyLocalMeetingCandidates() {
        let text = "Witaj!\nhttps://meet.google.com/abc-defg-hij\nhttps://example.com\nhttps://evilzoom.us/a\nhttps://us02web.zoom.us/j/123"
        #expect(Validation.detectedMeetingURLs(in: text).count == 2)
    }
    @Test func remindersAreFutureOnlyAndRespectEligibility() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var info = MeetingInfo(id: UUID(), company: "A", typeName: "HR", date: now.addingTimeInterval(3600), includesTime: true,
                               reminderMinutes: 15, isEligible: true)
        #expect(CalendarExport.reminderDate(for: info, now: now) == now.addingTimeInterval(2700))
        info.reminderMinutes = 60
        #expect(CalendarExport.reminderDate(for: info, now: now) == nil)
        info.reminderMinutes = 5; info.isEligible = false
        #expect(CalendarExport.reminderDate(for: info, now: now) == nil)
        info.isEligible = true; info.includesTime = false
        #expect(CalendarExport.reminderDate(for: info, now: now) == nil)
    }
    @Test func allSupportedReminderOffsets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for minutes in [5, 15, 30, 60, 1440] {
            let info = MeetingInfo(id: UUID(), company: "A", typeName: "HR", date: now.addingTimeInterval(172800), includesTime: true,
                                   reminderMinutes: minutes, isEligible: true)
            #expect(CalendarExport.reminderDate(for: info, now: now) == info.date.addingTimeInterval(-Double(minutes) * 60))
        }
    }
    @Test func icsEscapesFoldsAndUsesUnambiguousUTC() {
        let info = MeetingInfo(id: UUID(), company: String(repeating: "Żółć, ", count: 30), typeName: "HR", date: Date(timeIntervalSince1970: 1_700_000_000), includesTime: true,
                               durationMinutes: 45, meetingURL: URL(string: "https://meet.google.com/abc"), notes: "A;B\nC\\D", isEligible: true)
        let text = CalendarExport.ics(info, timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        #expect(text.contains("DTSTART:20231114T221320Z\r\n"))
        #expect(text.contains("DTEND:20231114T225820Z\r\n"))
        #expect(text.contains("DESCRIPTION:A\\;B\\nC\\\\D"))
        #expect(text.contains("X-WR-TIMEZONE:Europe/Warsaw"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        #expect(text.hasSuffix("END:VCALENDAR\r\n"))
    }
    @Test func csvEscapesUnicodeQuotesAndExcludesMessagesByConstruction() {
        let csv = BackupService.csv(rows: [["Firma", "Stanowisko"], ["Żółć, \"A\"", "a\nb"], ["=1+1", "@formula"]])
        #expect(csv.hasPrefix("\u{FEFF}"))
        #expect(csv.contains("\"Żółć, \"\"A\"\"\""))
        #expect(csv.contains("\"'="))
        #expect(csv.contains("\"a\nb\""))
    }
    @Test func localizationResolvesBothLanguages() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let p = Preferences(defaults: defaults)
        p.language = .pl
        #expect(p.text("company") == "Firma")
        #expect(p.text("noContactAutomatic") == "Brak kontaktu (automatycznie)")
        #expect(p.applicationCount(1) == "1 aplikacja")
        #expect(p.applicationCount(2) == "2 aplikacje")
        #expect(p.applicationCount(5) == "5 aplikacji")
        #expect(p.text("invalidPDF").contains("PDF"))
        p.language = .en
        #expect(p.text("company") == "Company")
        #expect(p.text("noContactAutomatic") == "No contact (automatic)")
        #expect(p.applicationCount(1) == "1 application")
        #expect(p.applicationCount(2) == "2 applications")
        #expect(p.text("rejection") == "Rejection")
    }
}
