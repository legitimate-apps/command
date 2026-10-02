# Observed verification — 2026-10-02

Synthetic account and local disposable server only. No production data, release, or deployment.
All Apple work used one leased iPhone 17 Pro simulator (iOS 26.5), leased DerivedData,
Xcode 26.6, and at most two build jobs. Screenshots are compressed JPEGs from the actual app.

## Integrated result

```text
Test Suite 'All tests' passed at 2026-10-02 12:10:51.010.
Executed 316 tests, with 0 failures (0 unexpected) in 16.127 (16.229) seconds
** TEST SUCCEEDED **

Mac Catalyst (after final code change): ** BUILD SUCCEEDED **

Server: 778 passed in 266.09s (0:04:26)
Ruff: All checks passed!
Mypy: Success: no issues found in 102 source files
```

Full iOS command (paths represented by the owned lease variables):

```sh
xcodebuild -project ios/Command.xcodeproj -scheme Command -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$LEASED_DD" \
  -clonedSourcePackagesDirPath "$SPM_CACHE" -parallel-testing-enabled NO -jobs 2 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- GENERATE_INFOPLIST_FILE=YES test
```

Catalyst used the same project/scheme/DerivedData, destination
`platform=macOS,variant=Mac Catalyst`, `-jobs 2 CODE_SIGNING_ALLOWED=NO build`.
Server verification: `uv lock --check`, `uv run --frozen ruff check .`,
`uv run --frozen mypy src`, `uv run pytest -q`. CI independently passed the server gate.

## Terminate/relaunch capture walkthrough

1. Typed `Recovery verification draft 1002` in Calendar. Terminated the app and relaunched.
   Accessibility value and rendered input exactly matched. [Recovered draft](draft-recovered.jpg).
2. Stopped the local server. Typed an editor title and body. UI reported
   `Not saved — Could not connect to the server.` Inspected recovery JSON: original create
   payload/key retained alongside the complete later text.
3. Terminated the app, restored the server, relaunched Notes. The recovery banner appeared;
   Review showed the complete text. [Recovery banner](recovery-banner.jpg).
4. Tapped Retry. Wire log: `POST /api/notes` → `201 Created`, followed by
   `PATCH /api/notes/1` → `200 OK`. SQLite returned exactly one note:

```text
id: 1
title: Offline recovery title
body: Offline recovery title
This unsent body survives process termination.
```

5. UI showed the saved row and no recovery banner. The editor recovery file was removed;
   the independent quick draft remained. [Saved note](recovery-saved.jpg).

## Discriminating controls

- Native recovery/transport harness: 54 tests passed. Disabling disk writes and stale-response
  rejection in copied sources caused six assertion failures in two selected tests; restoring
  protection made both pass.
- Native voice suite: 20 passed. Original production baseline failed 35 assertions across
  11 methods among 16 compatible tests; fixed source passed all 20.
- Original server completion logger failed both hidden-activity regressions; fixed code passed.
- MCP real-wire, timezone, invalid-key, and deduplication evidence is in
  [the MCP state](../../ASTRA-MCP-1002.md).

## Limits

Physical microphone prompts/AVAudioSession, visual Mac/iPad multiwindow interaction, deployment,
and production behavior were not exercised. Multiwindow recovery ownership is covered by iOS
XCTest and Catalyst compilation. Voice capture changes protect asynchronous state; durable
voice-audio recovery across process termination remains future work. Historical completion
activity visibility is unchanged; newly generated completions inherit the parent visibility.
