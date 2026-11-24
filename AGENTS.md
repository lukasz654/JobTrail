# JobTrail contributor and agent context

These instructions apply to the entire repository. Technical documentation, identifiers and comments use English.

## Read before changing the project

1. [README.md](README.md): overview and setup.
2. [REQUIREMENTS.md](REQUIREMENTS.md): authoritative functional scope.
3. [docs/README.md](docs/README.md): documentation map; read product and architecture, then the data/development sections relevant to the task.

Implement only the requested requirements. Resolve discrepancies between documentation and source before relying on either.

## Product boundaries

- JobTrail is a native, offline personal recruitment archive for macOS 14+.
- Use Swift 6 strict concurrency, SwiftUI, SwiftData, PDFKit and UserNotifications, with pragmatic MVVM and dependency injection.
- No networking, telemetry, accounts, AI features, mail integrations, external dependencies or production sample data.
- The user-facing app name is JobTrail.

## Domain and compatibility invariants

- Keep the `JobTracker` Swift module, `local.JobTracker` bundle identifier and existing storage/backup identifiers stable unless an explicit migration is requested. The visible product is `JobTrail.app`.
- Store language-independent enum values. Derive recruitment status from ordered events; do not add a separate persisted status.
- Elapsed time never completes an event. Preserve scheduled/completed/cancelled distinctions and explicit reopening after a terminal event.
- Keep the initial submission event synchronized with `appliedAt` through application editing.
- Automatic no-contact uses ten full Monday–Friday days, excluding the anchor day. Every newly added noninitial event resets the anchor through `createdAt`; edits do not. Closed processes are exempt. Follow [Product](docs/PRODUCT.md#automatic-no-contact) for the exact rules.

## Data and concurrency

- Preserve user data and unrelated changes. Never read `App/ProjectSecrets.swift`.
- SwiftData models and `ApplicationStore` stay on the main actor. Pass independent Sendable drafts/DTOs to service actors, never live models.
- Use explicit saves; validate and stage PDF changes before saving models. Roll back files and model changes on handled persistence failures.
- Store canonical relative PDF paths only: `Documents/<application UUID>/job-offer.pdf` below Application Support/JobTracker. Reject traversal and symlink escapes, including dangling symlinks.
- Backups contain versioned Codable DTOs and PDFs, never a copy of a live SQLite store. Validate format, version, identifiers, ownership, enums and documents before import. Replacement requires confirmation and an emergency backup.
- Treat schema, stored raw enum values and backup changes as compatibility work. Document migration implications before changing them.

## Interface

- All visible strings, errors, commands and accessibility labels use `Localizable.xcstrings` with Polish and English translations. Never translate user-entered data.
- Use semantic system colors, native controls, keyboard navigation and VoiceOver labels. Maintain Polish/English and light/dark previews.
- Edit local drafts until Save. Cancelling a draft must not mutate records or managed files.
- Request notification permission only when the user saves an enabled reminder.

## Verification and documentation

- Run builds and tests appropriate to the change, fix failures and report only observed results. Recommended commands are in [Development](docs/DEVELOPMENT.md#build-and-test).
- Keep README, requirements and relevant `docs/` pages consistent with actual behavior and limitations.
- Keep tests isolated from production records.
- Keep generated build products, test results, local Xcode state and personal recruitment data out of version control.
