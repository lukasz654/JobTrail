# JobTrail

A native, offline macOS app for keeping track of personal job applications, recruitment history and original job-offer PDFs. Records and managed documents stay on the Mac. There are no accounts, servers, analytics, mail integrations or external dependencies.

## Main workflows

- Save an application with a company, application date, optional position, offer URL and PDF. Repeated applications to the same company are supported.
- Find applications through active/completed sections, company/position search, status filtering and date/activity sorting.
- Record interviews, emails, notes, offers, rejection and reopening in a chronological history. Recruitment status is derived from events.
- See upcoming interviews, enable optional local reminders and export calendar events as ICS.
- Preview, replace, open, reveal and export independent managed PDF copies.
- Export portable backups, restore through merge or confirmed replacement, export basic records as CSV, or import an existing company-folder archive.
- Use Polish or English and system, light or dark appearance.

Active applications show **No contact (automatic)** after ten full Monday–Friday days without a newly added history event. Counting starts the day after applying or adding the latest event. Editing an event does not restart the timer. See [product rules](docs/PRODUCT.md#automatic-no-contact) for the exact boundary and exceptions.

## Run from source

Requires macOS 14+ and Xcode with a Swift 6 toolchain (Xcode 16+).

1. Open `JobTracker.xcodeproj`.
2. Select the shared **JobTracker** scheme and **My Mac** destination.
3. Configure local development signing if needed, then run the app.

The app product is **JobTrail.app**; the Xcode project and scheme are named **JobTracker**. See [Development](docs/DEVELOPMENT.md) for build and test commands.

## Data and backups

Use **File → Show data folder** to find the actual sandbox data location. PDFs are copied into app-managed storage, so moving the original file does not break the application record.

For a portable backup, choose **File → Export backup…**, select a parent folder and preserve the complete generated `.jobtrackerbackup` directory. Restore it with **File → Import backup…**. Merge skips conflicting identifiers; replacement requires confirmation and an emergency backup. Backups include private messages and are not encrypted by the app.

[Data and backups](docs/DATA_AND_BACKUPS.md) describes storage, restoration and recovery limitations.

## Project documentation

Start with the [documentation map](docs/README.md):

- [Requirements](REQUIREMENTS.md): authoritative functional scope.
- [Product](docs/PRODUCT.md): purpose, workflows and domain rules.
- [Architecture](docs/ARCHITECTURE.md): source map, responsibilities and concurrency.
- [Data and backups](docs/DATA_AND_BACKUPS.md): persistence, documents and compatibility.
- [Development](docs/DEVELOPMENT.md): local setup, tests and localization.

[AGENTS.md](AGENTS.md) contains shared contributor/agent rules. [CLAUDE.md](CLAUDE.md) points Claude to the same context.

## AI-assisted development

JobTrail was built with OpenAI Codex, which generated the implementation and documentation from the project author's requirements and feedback.
