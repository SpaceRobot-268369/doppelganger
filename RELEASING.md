# Local Release Process

Doppelganger uses a reviewed local release flow. GitHub Release CI and an
automatic update channel are intentionally outside the current product scope.

## Prerequisites

- A clean, reviewed release commit and annotated version tag.
- Xcode and the macOS SDK version documented for the release.
- A `Developer ID Application` certificate available to `codesign`.
- A notarytool keychain profile created with `xcrun notarytool store-credentials`.
- `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` exported in the shell.

## Build and verify

Run the full test suite first, then invoke:

```sh
Scripts/release-local.sh 1.0.0
```

The script archives Release configuration, exports the app, creates a DMG,
submits it to Apple notarization, staples the ticket, and runs Gatekeeper and
signature verification. Outputs live under `build/release/<version>/` and are
not committed.

Before publishing, manually confirm:

- the version and bundle identifier are correct;
- onboarding and Help open on a clean user account;
- source, destination, Profile, Project, Settings package, and drag/drop flows;
- Fast ends yellow and Standard/Maximum end green only after verification;
- JSON, Markdown, MHL, logs, and local catalog attribution are correct;
- no source delete, format, or automatic erase capability is present;
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, source dependency pins, and any bundled
  dynamic-library source offer match the shipped artifact.
