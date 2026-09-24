# Flaky tests

This file records tests that fail during a normal aggregate or parallel run but
pass when their owning test file is rerun in isolation. Entries remain here when
resolved so the failure history and verification are preserved. Do not skip or
delete a failing test to hide a flake.

## TabGroupInteractionTests.testNativeTabDragReachesPaneAndStripWithoutMovingTheWindow (VulkanGlassTests/TabGroupTests.swift)

- **Status:** open
- **Date observed:** 2026-09-24
- **Original command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' test`
- **Worker configuration:** Xcode default `xcodebuild test`
- **Failure:** `XCTAssertEqual failed` at `TabGroupTests.swift:998-999`: the dragged tab stayed in its source group (`["Three"]` instead of `["One", "Three"]`/`["Three", "One"]`) for the `strip` and, in one run, the `pane` drop target.
- **Suite counts:** 440 total, 435 passed, 5 failed (4 of them this test, 1 an unrelated assertion that was fixed); an earlier aggregate run also failed only this test. Two further aggregate runs passed 440/440.
- **Isolated rerun:** `-only-testing:VulkanGlassTests/TabGroupInteractionTests/testNativeTabDragReachesPaneAndStripWithoutMovingTheWindow` → passed 3/3 on the reading code block branch and 3/3 on unmodified `449e1eb`. Later the same day, alternating isolated runs failed 2/3 on unmodified `449e1eb` and 1/3 on the branch, so it also fails in isolation without any branch changes.
- **Hypothesis:** No evidence-backed root cause yet. The test drives native drag sessions against a real window, so it may depend on window-server timing, focus, or pointer activity on the host. Failing runs take about 4.8s against about 1.1s for passing ones, which suggests the drag session sometimes never delivers its drop. The failure reproduces on unmodified `449e1eb`, so it predates the Markdown rendering changes during which it was observed.

## MarkdownResourceTests.testRedirectDelegateRejectsPrivateDestination (VulkanGlassTests/ParserAndMarkdownTests.swift)

- **Status:** open
- **Date observed:** 2026-09-01
- **Original command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath /tmp/vg-review-dd test`
- **Worker configuration:** Xcode default `xcodebuild test`
- **Failure:** The test runner exited with code 0 before finishing the test; the app test host exited and Xcode restarted it. No assertion failure was reported.
- **Suite counts:** 227 total, 226 passed, 1 failed
- **Isolated rerun:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath /tmp/vg-review-dd -only-testing:VulkanGlassTests/MarkdownResourceTests test` → passed, 4/4
- **Hypothesis:** No evidence-backed root cause yet. The failure did not reproduce in an identical aggregate rerun, which passed 227/227; the affected production and test code was unchanged by the Quick Look overlay.

## AppModelTests.testAutosavePersistsTheEditedTabAfterSwitching (VulkanGlassTests/AppModelTests.swift)

- **Status:** resolved 2026-08-29
- **Date observed:** 2026-08-28; reproduced 2026-08-29
- **Original command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath build/test test`
- **Worker configuration:** Xcode default serial `xcodebuild test`
- **Failure:** `XCTAssertEqual failed: ("b") is not equal to ("edited b")` after `Task.sleep(for: .milliseconds(700))` following a 400ms autosave debounce (durations: 5.851s on 2026-08-28 and 9.824s on 2026-08-29)
- **Suite counts:** 87 total, 86 passed, 1 failed on 2026-08-28 (earlier observation: 78 total, 77 passed, 1 failed); 79 total, 78 passed, 1 failed on 2026-08-29
- **Isolated rerun:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath build/test -only-testing:VulkanGlassTests/AppModelTests test` → passed, 17/17 on 2026-08-29; two earlier isolated reruns passed 15/15 (1.843s and 1.866s)
- **Hypothesis:** The assertion followed a fixed 700ms wait for asynchronously scheduled autosave work. The wait was tight against the 400ms debounce under aggregate-suite load, while unchanged isolated runs passed.
- **Root cause:** Confirmed. `AppModel.updateContent` debounces each write behind a 400ms
  sleep, leaving only about 300ms of margin for two tasks plus two disk writes; under aggregate-run
  load the second write had not landed when the assertion ran. Separately,
  `AppModel.setActiveTab` spawned an untracked `Task` to flush the outgoing tab, so that write
  was neither cancellable nor awaitable.
- **Fix:** Commit `afbd188` stores the `setActiveTab` flush in `saveTasks` (superseding that
  tab's pending debounce), adds `AppModel.awaitPendingSaves()` to await every in-flight autosave,
  and changes the test to await that signal instead of sleeping.
- **Verification:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath build/review-test test` → 83 tests, 0 failures, run 4x consecutively with no intermittent failure.
