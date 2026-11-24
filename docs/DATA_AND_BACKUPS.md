# Data, documents and backups

## Compatibility identities

These are persistent contracts. Changing them requires an explicit compatibility/migration plan.

| Concern | Current value |
| --- | --- |
| Visible name and product | `JobTrail`, `JobTrail.app` |
| Project, target, scheme and Swift module | `JobTracker` |
| App bundle identifier | `local.JobTracker` |
| Application Support subdirectory | `JobTracker` |
| SwiftData store/schema | `JobTracker.store`, version `1.0.0` |
| Backup manifest format/version | `JobTrackerBackup`, `1` |
| Backup extension | `.jobtrackerbackup` |
| Notification identifier prefix | `JobTracker.` |
| Calendar UID suffix | `@jobtracker.local` |
| Main Window scene identifier | `jobtracker.main` |

New backup filenames use `JobTrail-<date>-<identifier>.jobtrackerbackup`; the internal manifest format is unchanged.

## Persistence model

`JobApplication` has a unique UUID, company, optional position, `appliedAt`, optional offer URL/relative PDF path, creation/update timestamps and owned events. Its inverse relationship uses cascade deletion. Repeated company applications are independent records.

`RecruitmentEvent` has a unique UUID, language-independent type/state, optional title, date, time-presence flag, optional meeting URL/email/notes, creation/update timestamps, optional reminder offset/duration/direction and application ownership.

The initial submission is the earliest created `applicationSent` event, with UUID as a tie-breaker. It is completed and synchronized with `appliedAt`; application editing owns this date change. History orders by date, creation timestamp and UUID. Status, last activity and no-contact are computed values, not independent database columns. See [Product](PRODUCT.md) for exact domain rules.

`JobTrackerSchema` and `JobTrackerMigrationPlan` currently expose version 1.0.0 and no migration stages. Future breaking changes must preserve a frozen prior schema and define an explicit migration. Preserve stored enum raw values. CloudKit is disabled. Preferences live separately in UserDefaults.

## Production storage

The sandboxed app normally stores files at:

```text
~/Library/Containers/local.JobTracker/Data/Library/Application Support/JobTracker/
  JobTracker.store
  JobTracker.store-shm                  # when present
  JobTracker.store-wal                  # when present
  Documents/
    <application UUID>/
      job-offer.pdf
  EmergencyBackups/
    <UUID>.jobtrackerbackup/
  Transactions/
    <transaction UUID>/
```

Use File → Show data folder for the actual root. Do not edit a running app's store or managed files manually. Tests use isolated roots/containers; production has no seeded records.

Persist only `Documents/<application UUID>/job-offer.pdf`, never an absolute selected path. Managed PDFs are independent copies. Input must be a readable, unlocked, nonempty PDF. Path checks reject traversal and symlinks at every relative component, including dangling links, and verify resolved containment.

## File transaction contract

`DocumentService.begin` validates/stages all incoming files in a transaction directory before moving existing document directories aside. Staged copies are validated again. The store then explicitly saves model changes.

- On successful persistence, commit removes transaction material.
- On handled failure or staging cancellation, rollback restores previous files and the store rolls back model changes.
- If restoration fails, recovery material is preserved, its path is reported and further transactions are blocked in that service instance.

This handles thrown failures. SwiftData and files are not one power-failure-atomic transaction. Abrupt termination between steps may require manual inspection/recovery from preserved transaction folders. Automatic journal replay is not implemented; do not delete recovery material without understanding which database save completed.

## Portable backup format

A backup is a complete directory:

```text
<name>.jobtrackerbackup/
  manifest.json
  Documents/
    <application UUID>/job-offer.pdf
```

The versioned Codable manifest contains application/event DTOs, IDs, relationships, timestamps and relative PDF paths. Export encodes Unix seconds with subsecond precision. The version-1 reader also accepts ISO 8601 timestamps. PDFs are copied; a live SQLite store is never exported.

Export selects a parent folder, stages a complete directory and publishes it under a unique name. Preserve the entire directory. Backups include messages/notes and are not encrypted by the app.

Import validates format/version, unique application/event IDs, ownership, enums, URLs, required fields, submission consistency, reminders/durations, canonical paths and referenced PDFs before modifying records. Input is validated again during import, not only during preview.

### Merge and replacement

Merge adds nonconflicting applications and skips records with conflicting application or event UUIDs. It does not overwrite existing history. The preview reports conflicts.

Replacement requires confirmation and a complete emergency export under `EmergencyBackups` first. If that export fails, replacement stops. Existing identities are reused/reassigned as needed to preserve SwiftData unique-ID/relationship consistency. Model/file work follows the handled-failure rollback protocol.

Restore emergency backups through the same File → Import backup action. Do not copy over a running SQLite store.

## CSV and old-folder import

CSV is a summary, not a restorable backup: company, position, application date, offer URL, derived status and last activity. Encoding uses UTF-8 with BOM, quoted/escaped fields and formula-prefix neutralization. Email bodies/notes are excluded.

Archive import reads immediate company subfolders. Each PDF is an editable candidate. Company comes from the folder name; metadata dates require confirmation. SHA-256 content matches produce warnings and initially deselected rows. Originals stay untouched. Optional suggestions accept only unambiguous explicit labels on the first three pages; there is no OCR, fetching or guessed position/URL.
