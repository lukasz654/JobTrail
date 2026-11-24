# Architecture

## Platform and structure

JobTrail targets macOS 14+ with Swift 6 strict concurrency. It uses SwiftUI, SwiftData, PDFKit, UserNotifications and native Foundation/AppKit file and system integration. There is no third-party dependency or network layer.

Pragmatic MVVM separates SwiftUI rendering/drafts, `ApplicationStore` coordination and injected service actors. Domain rules stay in models rather than being reimplemented in views. DTOs isolate service work from live SwiftData objects.

## Source map

Paths are relative to the repository root.

| Location | Responsibility |
| --- | --- |
| `JobTracker/App/JobTrackerApp.swift` | Entry point, runtime composition, Window/Settings scenes, menus, AppKit lifecycle and notification delegate |
| `JobTracker/App/Preferences.swift` | Persisted language/appearance, localized formatting and Settings |
| `JobTracker/Models/Models.swift` | Entities, enums, derived status/deadlines, schema and container factory |
| `JobTracker/Models/Transfer.swift` | Validation, drafts, Sendable/Codable DTOs and backup manifest |
| `JobTracker/ViewModels/ApplicationStore.swift` | Main-actor state, queries, selection, mutations, imports/exports and reminders |
| `JobTracker/Services/DocumentService.swift` | PDF validation, canonical paths, file transactions, export and hashing |
| `JobTracker/Services/BackupService.swift` | Portable export/validation and CSV |
| `JobTracker/Services/CalendarService.swift` | Meeting snapshots, reminders and ICS |
| `JobTracker/Services/ArchiveService.swift` | Read-only scan, duplicates and explicit-label PDF suggestions |
| `JobTracker/Views/` | Navigation, details, forms, PDF preview and import review |
| `JobTracker/Resources/` | Localizations, asset catalog and sandbox entitlements |
| `JobTrackerTests/`, `JobTrackerUITests/` | Logic/persistence/service tests and native UI scenarios |

## Runtime composition and state ownership

One `@main` App declaration owns a runtime, shared preferences, store and startup-error state. Production constructs a disk-backed container and document service under Application Support/JobTracker. Test launches use a temporary document root and in-memory persistence.

The interface has one identified SwiftUI `Window` scene (`jobtracker.main`) and a separate native Settings scene. New Application opens or reuses the main window before presenting its form.

`ApplicationStore` is `@MainActor @Observable`. It owns its ModelContainer and explicit-save ModelContext, applications, selection, search/filter/sort, operation state, notices/errors and presentation state. Preferences are shared by runtime and views. Forms edit Sendable draft values until submission.

## Mutation flow

1. A view validates a draft and asks the store to perform an operation.
2. The store gates overlapping mutations and takes independent values needed by services.
3. Document changes are validated/staged with rollback material before persistence.
4. The store changes main-actor models and explicitly saves. Handled failures roll back model and file work.
5. On success, it refreshes the collection/selection, finalizes temporary files and reconciles notifications as appropriate.

Context autosave is disabled to avoid implicit persistence of partially coordinated operations. See [Data and backups](DATA_AND_BACKUPS.md) for transaction limits.

## Concurrency and service boundaries

SwiftData entities never cross actors. `ApplicationDTO`, `EventDTO`, drafts and `MeetingInfo` provide Sendable snapshots. File validation/copying/hashing, archive scanning and backup processing run in service actors. Calendar file writing uses independent text and manages destination security scope.

`DocumentService` serializes managed-file transactions with commit/rollback. `BackupService` prepares portable directories and validates incoming DTOs/PDFs. `ArchiveService` reads original folders without mutation. `ReminderService` serializes asynchronous reconciliation so earlier work cannot leave stale notifications after a later cancellation.

Inject temporary roots, containers and disabled reminder delivery in tests. Preserve cancellable scan/staging work and balanced security-scoped access. Do not pass live models to detached tasks or add global mutable service state.

## Enduring decisions

- **Local ownership:** records and independent PDFs remain useful without an account or running service.
- **Event-derived status:** one history explains the current stage; no separate value can diverge from it.
- **Explicit completion:** a passed date signals overdue work, not a completed conversation.
- **DTO backups:** exports are independent of SQLite internals and validated before mutation.
- **Stable technical identities:** storage, backup and notification identifiers remain compatible across releases.
- **Native localized UI:** system controls, accessibility and PL/EN resources are baseline requirements.
