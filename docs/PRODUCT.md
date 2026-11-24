# Product and domain rules

## Purpose and scope

JobTrail replaces manually maintained company folders with a local archive of job applications, original offer PDFs and recruitment history. It is for a person managing their own applications on a Mac. Records remain useful after a process ends and after the original offer disappears.

[REQUIREMENTS.md](../REQUIREMENTS.md) is the authoritative scope. There are no accounts, backend, telemetry, synchronization, AI features, mail integration or external dependencies. Opening a user-selected URL in the system browser is supported; the app does not retrieve online content. Production starts with no sample records.

## Application workflow

An application requires a company and application date. Position, HTTP(S) offer URL and PDF are optional. Repeated applications to one company are independent records. Duplicate offer URLs warn without blocking an intentional repeat application.

Forms edit local drafts. Choosing a PDF does not persist a record or replace a managed document until Save. Escape cancels; Cmd+Return saves. Cancellation is disabled during an actual save. Cmd+N opens the main window and presents a new application form.

The interface groups active and completed applications, searches company and position, filters by derived status and sorts by application date or last activity. Last activity is the most recent application/event edit timestamp, distinct from the no-contact clock.

## Recruitment history and status

Each application owns an ordered history. Types may repeat. Events can include a title, date, optional time, meeting URL, plain-text email, notes, direction, reminder offset and duration. States are scheduled, completed or cancelled.

Ordering is event date, then creation timestamp, then UUID for deterministic ties. A completed submission event is created with a new application. Its date is changed through application editing and stays synchronized with `appliedAt`.

Status is derived, never independently stored. Noncancelled stage events determine submitted/contacted/HR/technical/assignment/interview stages. Email, notes, follow-up and generic events do not advance the stage. Scheduled meetings or assignments may establish a stage, but elapsed time never marks an event complete. Overdue scheduled events require a user update.

A completed offer, rejection, withdrawal or explicit no-response event closes the process. A completed reopening event resumes it; later stage events otherwise do not override a closed process. Automatic no-contact is distinct from explicit terminal no-response.

## Automatic no-contact

An active application displays **No contact (automatic)** / **Brak kontaktu (automatycznie)** after ten full business days without a newly added history event.

1. Initially the anchor is `appliedAt`, not the creation time of the automatic submission event. Historical imports preserve the original waiting period.
2. Any additional event resets the anchor through `createdAt`, including emails, notes and cancelled events. The anchor is the latest of `appliedAt` and remaining noninitial event creation timestamps.
3. The scheduled/historical date does not determine this reset. Editing an application or existing event does not reset it. Removing an event recalculates from remaining history.
4. Counting begins on the calendar day after the anchor. Only Monday–Friday count; weekday public holidays count too.
5. The status takes effect at local midnight after the tenth counted day finishes.
6. The status stays in the active group, never overrides a closed process, creates no synthetic event and does not complete scheduled events.

Calendar-day arithmetic respects local timezone and daylight-saving changes. Visible statuses and filters refresh each minute and when the app becomes active.

## Meetings and messages

Upcoming meetings are active, scheduled interview events ordered chronologically. Timed future meetings can have local reminders 5, 15, 30, 60 or 1440 minutes before the start; the default is 15 minutes. Date-only meetings do not have timed reminders. Permission is requested only when saving an enabled reminder. Editing, cancelling, deleting or closing the process reconciles pending reminders.

ICS export writes a calendar file without calendar-account access. Email content remains plain text with original Unicode and newlines. Meeting-link detection runs locally for known providers and only proposes an assignment; replacing an existing URL requires confirmation. There is no inbox access, HTML execution or content fetching.

## Documents and portability

The app owns an independent validated PDF copy and supports preview, page/zoom controls, replacement, removal, opening, Finder reveal and export. White PDF content stays white in dark appearance.

Backups include all records and managed PDFs. CSV contains basic application fields without email bodies or notes. Existing archive import reads immediate company folders and treats each PDF as a candidate. File metadata dates require confirmation; content duplicates are initially deselected but can be selected deliberately. Optional suggestions read explicit Polish/English labels on the first three PDF pages, leave ambiguous fields blank and never overwrite input. No source file is modified.

See [Data and backups](DATA_AND_BACKUPS.md) for storage and restoration rules.

## Language and accessibility

Polish and English use a String Catalog. Language and appearance can follow the system or be chosen explicitly. User data is never translated. App content updates immediately; native menus/panels can follow system language and may require a restart.

Use native controls, semantic colors, keyboard navigation and VoiceOver labels. Preserve system/light/dark behavior and previews covering Polish/English in both light and dark appearances.
