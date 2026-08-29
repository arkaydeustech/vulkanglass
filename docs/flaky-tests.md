# Flaky Tests

Record tests that fail in the full suite but pass when their owning file is rerun alone. Do not skip or delete a failing test to hide a flake.

## testAutosavePersistsTheEditedTabAfterSwitching (VulkanGlassTests/AppModelTests.swift)

- **Status:** open
- **Date observed:** 2026-08-28
- **Original command:** `xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath build test`
- **Worker configuration:** default serial `xcodebuild test`
- **Failure:** `XCTAssertEqual failed: ("b") is not equal to ("edited b")` after `Task.sleep(for: .milliseconds(700))` following a 400ms autosave debounce (duration: 5.851s). Previously failed in the full suite with the same assertion intent (78 tests, 1 failure).
- **Suite counts:** 87 total, 86 passed, 1 failed (earlier observation: 78 total, 77 passed, 1 failed)
- **Isolated rerun:** `xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' -derivedDataPath build -only-testing:VulkanGlassTests/AppModelTests test` → passed (15 tests, 1.843s). Earlier isolated rerun also passed (15 tests, 1.866s).
- **Hypothesis:** The 700ms wait is tight against the 400ms autosave sleep when the full suite is running, so the file read can happen before the debounced write finishes. The 5.851s suite-run duration includes AppKit startup; the isolated case finishes in 0.734s, which is essentially the sleep itself.
