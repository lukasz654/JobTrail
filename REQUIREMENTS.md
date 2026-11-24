# JobTrail requirements

The application is named JobTrail. Preserve existing data and backup compatibility.

Native offline macOS 14+ recruitment archive, implemented in Swift 6 with SwiftUI, SwiftData and PDFKit, with no external dependencies.

1. Xcode project and maintainable MVVM architecture with injected services.
2. Versioned SwiftData models: JobApplication and RecruitmentEvent; language-independent types/states, cascade relationships, derived statuses, synchronized submission date, in-memory containers.
3. NavigationSplitView, active/completed sections, company/title search, date/activity sorting, status filter, contextual actions, native empty states and Cmd+N.
4. Fast add/edit application: required company/date, optional title/HTTP(S) URL/PDF, paste, picker, drop, replace/remove PDF, duplicate URL warning, Cmd+Return, Escape; cancellation is side-effect free.
5. Validated, independent PDF copies; transactional replacement/deletion, PDFKit preview with page/zoom controls, open/reveal/export. Security scoped access and background I/O.
6. Chronological editable event history with scheduled/completed/cancelled states, overdue indicators, rejection and reopening; emails/notes do not advance the recruitment stage, but newly added events reset the automatic no-contact timer described below.
7. Plain-text email storage, paste/copy/disclosure, local meeting URL detection with explicit assignment; quick email/meeting/note/rejection actions. No mail service integration.
8. PL/EN String Catalog localization from project start; system/Polish/English language and system/light/dark appearance in native Settings; persisted preferences, immediate app UI updates, native menu restart notice.
9. Chronological upcoming active scheduled meetings, optional local reminders at 5/15/30/60/1440 minutes; request permission on use, reschedule/cancel; standards-based ICS export including timezone and optional duration.
10. Versioned portable directory backup with JSON manifest, all records and PDFs. Validate format/version/IDs/relations/paths/documents; conflict detection; merge or confirmed replacement, emergency backup, failure rollback. UTF-8 escaped CSV without private message text.
11. Read-only migration of company folders: editable preview, date suggestions requiring confirmation, PDF selection, duplicate/error handling, cancellation and summary. No invented position or URL.
12. Review, unit/persistence/file/backup/reminder/ICS/UI tests, actual builds, English technical documentation and honest limitations.

User data is never translated. All user-facing strings and dates respect the chosen app language. No independent stored process status. Repeated applications and events are supported.

## Automatic no-contact status

An active recruitment displays “No contact (automatic)” after ten full business days without a new history event. Initially the anchor is appliedAt, excluding the automatically generated submission's creation timestamp. Adding any further event resets the anchor to its createdAt, including emails, notes and cancelled events; editing an existing event or application does not reset it. The anchor never precedes appliedAt.

Counting starts on the calendar day after the anchor. Business days are Monday through Friday; Saturdays and Sundays are excluded, with no country-specific holiday calendar. The status becomes effective at local midnight after the tenth business day has finished. It remains a derived active status and does not insert a history event, complete meetings, or override a completed terminal recruitment status. Removing an event recalculates from the latest remaining event. List rows, details and status filtering refresh automatically while the app runs.
