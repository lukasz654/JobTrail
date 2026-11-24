# Development workflow

## Local setup

Use macOS 14+ and Xcode with Swift 6 support (Xcode 16+). Open `JobTracker.xcodeproj`, select the shared `JobTracker` scheme and My Mac, and configure local development signing as needed. The product is `JobTrail.app`; tests import `JobTracker`.

There are no package installs, service accounts, backend processes or production fixtures. Sandbox entitlements allow user-selected file access. No network entitlement is needed.

## Build and test

From the repository root:

```sh
xcodebuild -project JobTracker.xcodeproj -scheme JobTracker -destination 'platform=macOS' build
xcodebuild -project JobTracker.xcodeproj -scheme JobTracker -destination 'platform=macOS' test
```

Run builds and tests appropriate to the change and fix failures.

### Coverage map

| Source | Coverage |
| --- | --- |
| `JobTrackerTests/ModelTests.swift` | Status/history, no-contact/reset/weekends/DST, validation, URLs, reminders, ICS, CSV and PL/EN |
| `JobTrackerTests/PersistenceTests.swift` | Saves, submission synchronization, cascade deletion, reload, merge/replacement and archive confirmation |
| `JobTrackerTests/ServiceTests.swift` | Independent PDFs, validation/rollback/export, paths/symlinks, backup round trips, scanning and explicit-label suggestions |
| `JobTrackerUITests/JobTrackerUITests.swift` | Create/search/edit/cancel and Polish validation/interface |

Use temporary directories, in-memory containers or dedicated temporary stores. Reminder delivery can be disabled through injection. Date-sensitive logic accepts date/calendar parameters; deterministic model checks should not rely on the wall clock.

UI tests use `--uitesting` to select temporary document storage and in-memory persistence. They set an explicit language and check application entry, editing, search, cancellation and validation.

### Manual verification

For interface/platform changes, verify relevant paths on a Mac:

- Both languages and appearances; Settings and restart-sensitive native menus/panels.
- Keyboard navigation, Cmd+N, Cmd+Return, Escape and VoiceOver labels.
- PDF selection/drop/preview and backup/import through temporary selected folders.
- Notification permission, rescheduling/cancellation and actual delivery.

## Making changes

Read [AGENTS.md](../AGENTS.md) and [Requirements](../REQUIREMENTS.md) first. Keep domain rules in models, cross-resource coordination in the store, file work in actors and editable input in drafts. Maintain strict concurrency; do not pass SwiftData models across actors.

Update relevant documentation when rules, architecture or formats change. Schema/identity changes require compatibility planning. Preserve user data and unrelated changes; never read `App/ProjectSecrets.swift`.

### Localization and appearance

Put visible strings, errors, commands and accessibility labels in `JobTracker/Resources/Localizable.xcstrings` with Polish/English values. Keep stored enums language independent. Use Preferences/localized formatting consistently, preserve user text and support plural forms.

Use semantic colors/native controls and maintain the four language/appearance previews. PDF pages retain their document colors in dark UI.

Keep build products, DerivedData, `.xcresult` bundles, Xcode user state and personal recruitment data out of version control. Production data lives outside the repository.
