import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import VulkanGlass

final class TabGroupLayoutTests: XCTestCase {
    func testDropZonePicksTheNearestEdgeAndTheCentreInTheMiddle() {
        let size = CGSize(width: 400, height: 200)

        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 20, y: 100), in: size), .leading)
        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 390, y: 100), in: size), .trailing)
        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 200, y: 190), in: size), .bottom)
        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 200, y: 100), in: size), .center)
        XCTAssertEqual(PaneDropZone.zone(for: CGPoint(x: 10, y: 10), in: .zero), .center)
    }

    func testDropHighlightCoversTheHalfTheNewGroupWillTake() {
        let size = CGSize(width: 400, height: 200)

        XCTAssertEqual(PaneDropZone.trailing.highlightRect(in: size), CGRect(x: 200, y: 0, width: 200, height: 200))
        XCTAssertEqual(PaneDropZone.leading.highlightRect(in: size), CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(PaneDropZone.top.highlightRect(in: size), CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(PaneDropZone.bottom.highlightRect(in: size), CGRect(x: 0, y: 100, width: 400, height: 100))
        XCTAssertEqual(PaneDropZone.center.highlightRect(in: size), CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testNewTabsJoinTheFocusedGroup() {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])

        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.orderedGroups.map(\.tabIDs), [["a", "b", "c"]])
    }

    func testDraggingATabToTheRightSplitsThePaneDownTheMiddle() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])
        layout.activate("c")
        let original = layout.focusedGroupID

        let newGroup = try XCTUnwrap(layout.drop("c", on: original, zone: .trailing))

        XCTAssertEqual(layout.orderedGroups.map(\.tabIDs), [["a", "b"], ["c"]])
        XCTAssertEqual(layout.focusedGroupID, newGroup)
        XCTAssertEqual(layout.activeTabID, "c")
        XCTAssertEqual(layout.group(original)?.activeTabID, "b")
        guard case let .split(split) = layout.root else { return XCTFail("Expected a split") }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.first, .group(original))
        XCTAssertEqual(split.second, .group(newGroup))
    }

    func testLeadingTopAndBottomDropsPlaceTheNewGroupOnThatSide() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let original = layout.focusedGroupID

        let top = try XCTUnwrap(layout.drop("b", on: original, zone: .top))
        guard case let .split(split) = layout.root else { return XCTFail("Expected a split") }
        XCTAssertEqual(split.axis, .vertical)
        XCTAssertEqual(split.first, .group(top))

        layout.reconcile(with: ["a", "b", "c"])
        let leading = try XCTUnwrap(layout.drop("c", on: top, zone: .leading))
        XCTAssertEqual(layout.orderedGroups.map(\.tabIDs), [["c"], ["b"], ["a"]])
        XCTAssertEqual(layout.root.groupIDs, [leading, top, original])
    }

    func testDroppingATabIntoAnotherGroupLandsItThere() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])
        let first = layout.focusedGroupID
        let second = try XCTUnwrap(layout.drop("c", on: first, zone: .trailing))

        XCTAssertTrue(layout.canDrop("a", on: second, zone: .center))
        layout.drop("a", on: second, zone: .center)

        XCTAssertEqual(layout.group(first)?.tabIDs, ["b"])
        XCTAssertEqual(layout.group(second)?.tabIDs, ["c", "a"])
        XCTAssertEqual(layout.focusedGroupID, second)
        XCTAssertEqual(layout.activeTabID, "a")
    }

    func testEdgeDropOnAnotherGroupCollapsesAnEmptySource() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let first = layout.focusedGroupID
        let second = try XCTUnwrap(layout.drop("b", on: first, zone: .trailing))

        let third = try XCTUnwrap(layout.drop("b", on: first, zone: .top))

        XCTAssertNil(layout.group(second))
        XCTAssertEqual(layout.orderedGroups.map(\.tabIDs), [["b"], ["a"]])
        XCTAssertEqual(layout.root.groupIDs, [third, first])
        XCTAssertEqual(layout.activeTabID, "b")
    }

    func testMovingTheLastTabOutOfAGroupCollapsesTheSplit() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let first = layout.focusedGroupID
        let second = try XCTUnwrap(layout.drop("b", on: first, zone: .trailing))

        layout.move("b", to: first, at: 0)

        XCTAssertEqual(layout.groups.map(\.id), [first])
        XCTAssertEqual(layout.root, .group(first))
        XCTAssertNil(layout.group(second))
        XCTAssertEqual(layout.group(first)?.tabIDs, ["b", "a"])
        XCTAssertEqual(layout.activeTabID, "b")
    }

    func testALoneTabCannotSplitOrRejoinItsOwnGroup() {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a"])
        let only = layout.focusedGroupID

        for zone in PaneDropZone.allCases {
            XCTAssertFalse(layout.canDrop("a", on: only, zone: zone), "\(zone)")
            XCTAssertNil(layout.drop("a", on: only, zone: zone))
        }
        XCTAssertEqual(layout.root, .group(only))
    }

    func testATabCannotJoinTheCentreOfItsOwnGroup() {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let only = layout.focusedGroupID

        XCTAssertFalse(layout.canDrop("a", on: only, zone: .center))
        XCTAssertTrue(layout.canDrop("a", on: only, zone: .bottom))
        XCTAssertFalse(layout.canDrop("missing", on: only, zone: .bottom))
    }

    func testReorderingWithinAGroupAccountsForTheRemovedPosition() {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c", "d"])
        let group = layout.focusedGroupID

        layout.move("a", to: group, at: 3)
        XCTAssertEqual(layout.group(group)?.tabIDs, ["b", "c", "a", "d"])

        layout.move("d", to: group, at: 0)
        XCTAssertEqual(layout.group(group)?.tabIDs, ["d", "b", "c", "a"])

        layout.move("b", to: group, at: nil)
        XCTAssertEqual(layout.group(group)?.tabIDs, ["d", "c", "a", "b"])
    }

    func testClosingTheLastTabOfAGroupFocusesItsNeighbour() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])
        let first = layout.focusedGroupID
        let right = try XCTUnwrap(layout.drop("c", on: first, zone: .trailing))
        let bottomRight = try XCTUnwrap(layout.drop("b", on: right, zone: .bottom))
        XCTAssertEqual(layout.orderedGroups.map(\.tabIDs), [["a"], ["c"], ["b"]])

        layout.reconcile(with: ["a", "c"])

        XCTAssertNil(layout.group(bottomRight))
        XCTAssertEqual(layout.focusedGroupID, right)
        XCTAssertEqual(layout.root.groupIDs, [first, right])
    }

    func testClosingAnActiveTabActivatesTheLastRemainingTabInItsGroup() {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])
        layout.activate("b")

        layout.reconcile(with: ["a", "c"])

        XCTAssertEqual(layout.activeTabID, "c")
    }

    func testClosingEveryTabLeavesOneEmptyGroup() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let first = layout.focusedGroupID
        _ = try XCTUnwrap(layout.drop("b", on: first, zone: .trailing))

        layout.reconcile(with: [])

        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.tabIDs, [])
        XCTAssertNil(layout.activeTabID)
        XCTAssertEqual(layout.root, .group(layout.focusedGroupID))
    }

    func testActivatingATabFocusesItsGroup() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b"])
        let first = layout.focusedGroupID
        let second = try XCTUnwrap(layout.drop("b", on: first, zone: .trailing))

        layout.activate("a")
        XCTAssertEqual(layout.focusedGroupID, first)
        XCTAssertEqual(layout.group(second)?.activeTabID, "b")

        layout.focus(second)
        XCTAssertEqual(layout.activeTabID, "b")
    }

    func testRenamingATabKeepsItsGroupAndPosition() throws {
        var layout = TabGroupLayout()
        layout.reconcile(with: ["a", "b", "c"])
        let first = layout.focusedGroupID
        let second = try XCTUnwrap(layout.drop("c", on: first, zone: .trailing))
        layout.activate("a")

        layout.renameTab(from: "a", to: "z")
        layout.reconcile(with: ["z", "b", "c"])

        XCTAssertEqual(layout.group(first)?.tabIDs, ["z", "b"])
        XCTAssertEqual(layout.group(second)?.tabIDs, ["c"])
        XCTAssertEqual(layout.activeTabID, "z")
    }

    func testPaneEdgesFollowTheSplitAxis() {
        let side = PaneEdges.all.children(for: .horizontal)
        XCTAssertEqual(side.first, PaneEdges(top: true, leading: true, trailing: false))
        XCTAssertEqual(side.second, PaneEdges(top: true, leading: false, trailing: true))

        let stacked = PaneEdges.all.children(for: .vertical)
        XCTAssertEqual(stacked.first, PaneEdges(top: true, leading: true, trailing: true))
        XCTAssertEqual(stacked.second, PaneEdges(top: false, leading: true, trailing: true))
    }

    func testSplitFractionKeepsBothPanesUsable() {
        XCTAssertEqual(PaneSplitView.clampedFraction(0.5, total: 1000), 0.5)
        XCTAssertEqual(PaneSplitView.clampedFraction(0.01, total: 1000), 0.16, accuracy: 0.0001)
        XCTAssertEqual(PaneSplitView.clampedFraction(0.99, total: 1000), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PaneSplitView.clampedFraction(0.9, total: 200), 0.5)
        XCTAssertEqual(PaneSplitView.clampedFraction(0.2, total: 1000), 0.2)
        XCTAssertEqual(PaneSplitView.clampedFraction(0.8, total: 1000), 0.8)
        XCTAssertEqual(PaneSplitView.resizedFraction(origin: 500, translation: 100, total: 1000), 0.6)
        XCTAssertEqual(PaneSplitView.resizedFraction(origin: 500, translation: -500, total: 1000), 0.16)
        XCTAssertEqual(SplitHandle.translation(CGSize(width: 90, height: 15), for: .horizontal), 90)
        XCTAssertEqual(SplitHandle.translation(CGSize(width: 90, height: 15), for: .vertical), 15)
    }
}

@MainActor
final class TabGroupModelTests: XCTestCase {
    func testTabMovesAndKeyboardSplitRequestFocusForTheirActiveSourceTab() async throws {
        let model = try modelWithOpenTabs(["One", "Two", "Three"])
        for index in model.tabs.indices { model.tabs[index].editorMode = .source }
        let original = model.tabGroupLayout.focusedGroupID
        let first = model.tabs[0].id
        let second = model.tabs[1].id
        let third = model.tabs[2].id

        model.dropTab(third, on: original, zone: .trailing)
        XCTAssertEqual(model.editorFocusRequest?.tabID, third)
        let other = model.tabGroupLayout.focusedGroupID

        model.dropTab(first, on: other, zone: .center)
        XCTAssertEqual(model.editorFocusRequest?.tabID, first)

        model.moveTab(second, toGroup: other, at: 0)
        XCTAssertEqual(model.editorFocusRequest?.tabID, second)

        model.splitActiveTab(.bottom)
        XCTAssertEqual(model.editorFocusRequest?.tabID, second)
        XCTAssertEqual(model.activeTabID, second)
    }

    func testThreeTabsSplitIntoTwoGroupsAndATabMovesAcross() async throws {
        let model = try modelWithOpenTabs(["One", "Two", "Three"])
        let paths = model.tabs.map(\.path)
        let original = model.tabGroupLayout.focusedGroupID

        XCTAssertTrue(model.canDropTab(paths[2], on: original, zone: .trailing))
        model.dropTab(paths[2], on: original, zone: .trailing)

        let groups = model.tabGroupLayout.orderedGroups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(model.tabs(inGroup: groups[0].id).map(\.title), ["One", "Two"])
        XCTAssertEqual(model.tabs(inGroup: groups[1].id).map(\.title), ["Three"])
        XCTAssertEqual(model.activeTabID, paths[2])

        model.dropTab(paths[0], on: groups[1].id, zone: .center)

        XCTAssertEqual(model.tabs(inGroup: groups[0].id).map(\.title), ["Two"])
        XCTAssertEqual(model.tabs(inGroup: groups[1].id).map(\.title), ["Three", "One"])
        XCTAssertEqual(model.activeTabID, paths[0])
        XCTAssertEqual(model.tabs.count, 3, "moving a tab never closes or duplicates it")
    }

    func testOpeningANoteAddsItToTheFocusedGroup() async throws {
        let root = try temporaryDirectory()
        let model = try modelWithOpenTabs(["One", "Two"], in: root)
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .bottom)
        await model.focusGroup(original)

        let third = root.appendingPathComponent("Three.md")
        try "three".write(to: third, atomically: true, encoding: .utf8)
        await model.openTab(path: third.path, standalone: true)

        XCTAssertEqual(model.tabs(inGroup: original).map(\.title), ["One", "Three"])
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, original)
        XCTAssertEqual(model.activeTabID, third.path)
    }

    func testNewNoteUsesItsClickedGroupEvenIfFocusChangesBeforeItOpens() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("Created.md")
        var model: AppModel!
        var dependencies = AppModelDependencies.live
        dependencies.chooseNewStandaloneNoteURL = {
            model.activeTabID = model.tabs[1].id
            return destination
        }
        model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.tabs = try ["One", "Two"].map { title in
            let url = root.appendingPathComponent("\(title).md")
            try title.write(to: url, atomically: true, encoding: .utf8)
            return NoteTab(path: url.path, title: title, content: title, originalContent: title, isStandalone: true)
        }
        let clickedGroup = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].id, on: clickedGroup, zone: .trailing)
        await model.focusGroup(clickedGroup)

        await model.newNote(inGroup: clickedGroup)

        XCTAssertEqual(model.tabGroupLayout.groupID(containing: destination.path), clickedGroup)
        XCTAssertEqual(model.activeTabID, destination.path)
        XCTAssertEqual(model.editorFocusRequest?.tabID, destination.path)
    }

    func testVaultNoteKeepsItsClickedGroupAcrossIndexingAwait() async throws {
        let root = try temporaryDirectory()
        let enteredIndexing = expectation(description: "Vault indexing started")
        let gate = TabGroupSnapshotGate()
        var dependencies = AppModelDependencies.live
        dependencies.loadVaultSnapshot = { root in
            enteredIndexing.fulfill()
            await gate.wait()
            return (FileService.tree(at: root), FileService.index(at: root))
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = try ["One", "Two"].map { title in
            let url = root.appendingPathComponent("\(title).md")
            try title.write(to: url, atomically: true, encoding: .utf8)
            return NoteTab(path: url.path, title: title, content: title, originalContent: title, isStandalone: false)
        }
        let clickedGroup = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].id, on: clickedGroup, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(clickedGroup)

        let creation = Task { await model.newNote(inGroup: clickedGroup) }
        await fulfillment(of: [enteredIndexing], timeout: 2)
        await model.focusGroup(other)
        await gate.release()
        await creation.value

        let created = try XCTUnwrap(model.tabs.first { $0.title == "Untitled" })
        XCTAssertEqual(model.tabGroupLayout.groupID(containing: created.id), clickedGroup)
        XCTAssertEqual(model.activeTabID, created.id)
    }

    func testWikiLinkFromAnotherPaneOpensInItsSourceGroup() async throws {
        let root = try temporaryDirectory()
        let model = try modelWithOpenTabs(["One", "Two"], in: root)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        let source = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].id, on: source, zone: .trailing)
        XCTAssertNotEqual(model.tabGroupLayout.focusedGroupID, source)

        await model.followWikiLink("Linked", inGroup: source)

        let linked = try XCTUnwrap(model.tabs.first { $0.title == "Linked" })
        XCTAssertEqual(model.tabGroupLayout.groupID(containing: linked.id), source)
        XCTAssertEqual(model.activeTabID, linked.id)
    }

    func testMouseDownThenTabSelectionFlushesTheOutgoingGroup() async throws {
        let root = try temporaryDirectory()
        let model = try modelWithOpenTabs(["One", "Two"], in: root)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        for index in model.tabs.indices { model.tabs[index].isStandalone = false }
        let first = model.tabs[0].path
        let second = model.tabs[1].path
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(second, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(original)
        model.updateContent(first, "changed in first pane")

        await model.focusGroup(other)
        await model.setActiveTab(second)

        XCTAssertEqual(model.activeTabID, second)
        await model.awaitPendingSaves()
        XCTAssertEqual(try FileService.read(URL(fileURLWithPath: first)), "changed in first pane")
        XCTAssertFalse(model.tabs.first { $0.id == first }?.dirty ?? true)
    }

    func testFocusingAnotherGroupKeepsStandaloneEditsUnsaved() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let first = model.tabs[0].path
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(original)
        model.updateContent(first, "unsaved edit")

        await model.focusGroup(other)
        await model.awaitPendingSaves()

        XCTAssertEqual(try FileService.read(URL(fileURLWithPath: first)), "One")
        XCTAssertEqual(model.tabs.first { $0.id == first }?.content, "unsaved edit")
        XCTAssertTrue(model.tabs.first { $0.id == first }?.dirty ?? false)
    }

    func testFocusingAnotherGroupCommitsTheOutgoingTitle() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let first = model.tabs[0].path
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(original)
        model.beginEditingTitle(for: first)
        model.updateTitleDraft(for: first, draft: "Renamed")

        await model.focusGroup(other)

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, other)
        XCTAssertEqual(model.tabs(inGroup: original).map(\.title), ["Renamed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: first).deletingLastPathComponent().appendingPathComponent("Renamed.md").path))
    }

    func testSelectingATabInAnotherGroupFocusesThatGroup() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        let second = model.tabs[1].path
        model.dropTab(second, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID

        await model.setActiveTab(model.tabs[0].path)
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, original)

        await model.setActiveTab(second)
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, other)
        XCTAssertEqual(model.activeTab?.title, "Two")
    }

    func testClosingTheOnlyTabInASplitGroupRemovesThePane() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        let splitID = try XCTUnwrap(model.tabGroupLayout.root.splitIDs.first)
        model.resizePaneSplit(splitID, fraction: 0.3)

        await model.closeTab(model.tabs[1].path)

        XCTAssertEqual(model.tabGroupLayout.root, .group(original))
        XCTAssertEqual(model.activeTab?.title, "One")
        XCTAssertTrue(model.paneSplitFractions.isEmpty)
    }

    func testFocusingAnotherGroupLeavesTheGraphView() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        model.centerView = .graph

        await model.focusGroup(original)

        XCTAssertEqual(model.centerView, .editor)
        XCTAssertEqual(model.activeTab?.title, "One")
    }

    func testReadingModeStaysWithEachGroupsActiveTab() async throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        model.editorMode = .source

        await model.focusGroup(original)

        XCTAssertEqual(model.editorMode, .preview)
        XCTAssertEqual(model.tabs.first { $0.title == "Two" }?.editorMode, .source)
    }

    func testRenamingANoteKeepsItInItsGroup() async throws {
        let root = try temporaryDirectory()
        let model = try modelWithOpenTabs(["One", "Two", "Three"], in: root)
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[2].path, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID

        let renamed = await model.renameNote(path: model.tabs[0].path, newName: "First", sync: false)

        XCTAssertTrue(renamed)
        XCTAssertEqual(model.tabs(inGroup: original).map(\.title), ["First", "Two"])
        XCTAssertEqual(model.tabs(inGroup: other).map(\.title), ["Three"])
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, other)
    }

    func testReplacingEveryTabResetsToASingleGroup() throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        model.dropTab(model.tabs[1].path, on: model.tabGroupLayout.focusedGroupID, zone: .trailing)

        model.tabs = []

        XCTAssertFalse(model.tabGroupLayout.isSplit)
        XCTAssertNil(model.activeTabID)
    }

    private func modelWithOpenTabs(_ titles: [String], in root: URL? = nil) throws -> AppModel {
        let directory = try root ?? temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = try titles.map { title in
            let url = directory.appendingPathComponent("\(title).md")
            try title.write(to: url, atomically: true, encoding: .utf8)
            return NoteTab(path: url.path, title: title, content: title, originalContent: title, isStandalone: true)
        }
        model.activeTabID = model.tabs.first?.id
        return model
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VulkanGlassTabGroupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor TabGroupSnapshotGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class TabGroupCommandTests: XCTestCase {
    func testSplitCommandsMoveTheActiveTabBesideOrBelow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VulkanGlassTabGroupCommands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = ["One", "Two", "Three"].map { title in
            let path = root.appendingPathComponent("\(title).md").path
            return NoteTab(path: path, title: title, content: title, originalContent: title, isStandalone: true)
        }
        model.activeTabID = model.tabs[2].id

        XCTAssertTrue(model.canSplitActiveTab)
        model.splitActiveTab(.trailing)
        XCTAssertEqual(model.tabGroupLayout.orderedGroups.map(\.tabIDs.count), [2, 1])
        XCTAssertFalse(model.canSplitActiveTab, "a lone tab has nothing to split from")

        await model.focusGroup(model.tabGroupLayout.orderedGroups[0].id)
        model.splitActiveTab(.bottom)
        let groups = model.tabGroupLayout.orderedGroups
        XCTAssertEqual(groups.map { model.tabs(inGroup: $0.id).map(\.title) }, [["One"], ["Two"], ["Three"]])
        guard case let .split(outer) = model.tabGroupLayout.root,
              case let .split(inner) = outer.first
        else { return XCTFail("Expected nested splits") }
        XCTAssertEqual(outer.axis, .horizontal)
        XCTAssertEqual(inner.axis, .vertical)
    }
}

@MainActor
final class TabGroupInteractionTests: XCTestCase {
    func testPaneDropUsesItsMeasuredSizeAndRejectsAnInvalidZone() throws {
        let model = try modelWithTabs()
        let first = model.tabGroupLayout.focusedGroupID
        model.draggedTabID = model.tabs[1].id
        var highlight: PaneDropZone?
        let delegate = PaneDropDelegate(
            model: model,
            groupID: first,
            paneSize: CGSize(width: 400, height: 200),
            zone: Binding(get: { highlight }, set: { highlight = $0 })
        )

        XCTAssertNil(delegate.acceptedZone(at: CGPoint(x: 200, y: 100)))
        XCTAssertEqual(delegate.acceptedZone(at: CGPoint(x: 390, y: 100)), .trailing)
        XCTAssertTrue(delegate.performDrop(at: CGPoint(x: 390, y: 100)))
        XCTAssertNil(highlight)
        XCTAssertNil(model.draggedTabID)
        XCTAssertEqual(model.tabGroupLayout.orderedGroups.map(\.tabIDs.count), [2, 1])
        XCTAssertFalse(delegate.performDrop(at: CGPoint(x: 390, y: 100)))
    }

    func testStripDropInsertsAtItsTargetAndClearsDragState() throws {
        let model = try modelWithTabs()
        let group = model.tabGroupLayout.focusedGroupID
        model.draggedTabID = model.tabs[2].id
        var highlighted = true
        let delegate = TabStripDropDelegate(
            model: model,
            groupID: group,
            index: 0,
            highlighted: Binding(get: { highlighted }, set: { highlighted = $0 })
        )

        XCTAssertTrue(delegate.performDrop())
        XCTAssertEqual(model.tabs(inGroup: group).map(\.title), ["Three", "One", "Two"])
        XCTAssertFalse(highlighted)
        XCTAssertNil(model.draggedTabID)
    }

    func testOuterStripDropUsesHoveredTabWhenBothDropTargetsOverlap() throws {
        let model = try modelWithTabs()
        let group = model.tabGroupLayout.focusedGroupID
        model.draggedTabID = model.tabs[2].id
        var highlighted = false
        let outer = TabStripDropDelegate(
            model: model,
            groupID: group,
            index: nil,
            highlighted: Binding(get: { highlighted }, set: { highlighted = $0 }),
            preferredIndex: { 0 }
        )

        XCTAssertTrue(outer.performDrop())
        XCTAssertEqual(model.tabs(inGroup: group).map(\.title), ["Three", "One", "Two"])
    }

    func testOuterStripHighlightTracksTabAndFreeSpaceAsPointerMoves() throws {
        let model = try modelWithTabs()
        let group = model.tabGroupLayout.focusedGroupID
        model.draggedTabID = model.tabs[2].id
        var hoveredIndex: Int?
        var highlighted = false
        let outer = TabStripDropDelegate(
            model: model,
            groupID: group,
            index: nil,
            highlighted: Binding(get: { highlighted }, set: { highlighted = $0 }),
            preferredIndex: { hoveredIndex }
        )

        outer.updateHighlight()
        XCTAssertTrue(highlighted)
        hoveredIndex = 0
        outer.updateHighlight()
        XCTAssertFalse(highlighted)
        hoveredIndex = nil
        outer.updateHighlight()
        XCTAssertTrue(highlighted)
        model.draggedTabID = nil
        outer.updateHighlight()
        XCTAssertFalse(highlighted)
    }

    func testEndingATabDragClearsItWithoutErasingANewerOne() throws {
        let model = try modelWithTabs()
        let first = model.tabs[0].id
        let second = model.tabs[1].id
        let source = TabDragSourceView()
        source.model = model
        source.tabID = first

        model.draggedTabID = first
        source.endTabDrag()
        XCTAssertNil(model.draggedTabID)

        model.draggedTabID = second
        source.endTabDrag()
        XCTAssertEqual(model.draggedTabID, second)
    }

    func testTabDragNeitherMovesTheWindowNorOffersTypesTheEditorAccepts() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let editor = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        let source = TabDragSourceView(frame: NSRect(x: 0, y: 150, width: 120, height: 40))
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(source)
        editor.updateDragTypeRegistration()

        // Tabs live in the title bar; a press there must drag the tab, not the window. AppKit
        // ignores `mouseDownCanMoveWindow` there and moves the window from any part of the title
        // bar not covered by this private "opaque for window move" rect.
        XCTAssertFalse(source.mouseDownCanMoveWindow)
        let opaqueSelector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
        if source.responds(to: opaqueSelector),
           let implementation = class_getMethodImplementation(TabDragSourceView.self, opaqueSelector)
        {
            typealias OpaqueRect = @convention(c) (AnyObject, Selector) -> NSRect
            let opaque = unsafeBitCast(implementation, to: OpaqueRect.self)(source, opaqueSelector)
            XCTAssertEqual(opaque, source.bounds)
        }
        let offered = Set(TabDragSourceView.pasteboardItem(for: "/vault/One.md").types)
        XCTAssertEqual(offered.map(\.rawValue), [UTType.vulkanGlassNoteTab.identifier])
        XCTAssertFalse(editor.registeredDraggedTypes.isEmpty)
        // Were the editor to accept the drag, the pane underneath would never see it.
        XCTAssertTrue(offered.isDisjoint(with: editor.registeredDraggedTypes))
    }

    func testClickingATabWithoutDraggingSelectsIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let source = TabDragSourceView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView = source
        var clicks = 0
        source.onClick = { clicks += 1 }

        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: 50, y: 20),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        source.mouseDown(with: try event(.leftMouseDown))
        source.mouseDragged(with: try event(.leftMouseDragged))
        source.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(clicks, 1, "a press that stays within the drag threshold is a click")
        source.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(clicks, 1, "a release without its own press does not select")
    }

    func testPaneMouseMonitorSkipsPaletteAndSwitcherClicks() throws {
        let model = try modelWithTabs()
        let view = PaneMouseDownMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = view
        var clicks = 0
        view.canFocus = { !model.commandOpen && !model.switcherOpen }
        view.onMouseDown = { clicks += 1 }

        func mouseDown(at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        view.handle(try mouseDown(at: NSPoint(x: 100, y: 100)))
        XCTAssertEqual(clicks, 1)
        model.commandOpen = true
        view.handle(try mouseDown(at: NSPoint(x: 100, y: 100)))
        XCTAssertEqual(clicks, 1)
        model.commandOpen = false
        model.switcherOpen = true
        view.handle(try mouseDown(at: NSPoint(x: 100, y: 100)))
        XCTAssertEqual(clicks, 1)
        model.switcherOpen = false
        view.handle(try mouseDown(at: NSPoint(x: 500, y: 100)))
        XCTAssertEqual(clicks, 1)
    }

    func testFocusingAnotherPaneMovesFirstResponderToItsSourceEditor() async throws {
        let model = try modelWithTabs()
        model.tabs[0].editorMode = .source
        model.tabs[1].editorMode = .source
        let firstGroup = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].id, on: firstGroup, zone: .trailing)
        let secondGroup = model.tabGroupLayout.focusedGroupID
        await model.setActiveTab(model.tabs[0].id)
        let host = NSHostingView(rootView: TabGroupsView().environment(model).frame(width: 900, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        var editors: [SourceTextView] = []
        for _ in 0..<50 where editors.count < 2 {
            host.layoutSubtreeIfNeeded()
            editors = descendants(of: host).compactMap { $0 as? SourceTextView }
            await Task.yield()
        }
        let first = try XCTUnwrap(editors.first { $0.string == "One" }, "editors: \(editors.map(\.string))")
        let second = try XCTUnwrap(editors.first { $0.string == "Two" })
        XCTAssertTrue(window.makeFirstResponder(first))

        await model.focusGroup(secondGroup)
        for _ in 0..<50 where window.firstResponder !== second {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }

        XCTAssertTrue(window.firstResponder === second)
        XCTAssertNil(model.editorFocusRequest)
        second.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(NSApp.sendAction(#selector(SourceTextView.toggleBold(_:)), to: window.firstResponder, from: nil))
        XCTAssertEqual(second.string, "**Two**")
        XCTAssertEqual(first.string, "One")

        await model.openTab(path: model.tabs[0].path)
        for _ in 0..<50 where window.firstResponder !== first {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertTrue(window.firstResponder === first)
    }

    func testMouseFocusPreservesTheClickedEditorsSelection() async throws {
        let model = try modelWithTabs()
        model.tabs[0].editorMode = .source
        model.tabs[1].editorMode = .source
        let firstGroup = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].id, on: firstGroup, zone: .trailing)
        let secondGroup = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(firstGroup)
        let host = NSHostingView(rootView: TabGroupsView().environment(model).frame(width: 900, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        var editor: SourceTextView?
        for _ in 0..<50 where editor == nil {
            host.layoutSubtreeIfNeeded()
            editor = descendants(of: host).compactMap { $0 as? SourceTextView }.first { $0.string == "Two" }
            await Task.yield()
        }
        let destination = try XCTUnwrap(editor)
        let clickPoint = destination.convert(NSPoint(x: 10, y: 10), to: nil)
        let paneMonitor = try XCTUnwrap(
            descendants(of: host).compactMap { $0 as? PaneMouseDownMonitor.MonitorView }
                .first { $0.bounds.contains($0.convert(clickPoint, from: nil)) }
        )
        XCTAssertTrue(window.makeFirstResponder(destination))
        let clickedRange = NSRange(location: 1, length: 1)
        destination.setSelectedRange(clickedRange)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        paneMonitor.handle(event)
        for _ in 0..<50 where model.tabGroupLayout.focusedGroupID != secondGroup || model.editorFocusRequest != nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, secondGroup)
        XCTAssertTrue(window.firstResponder === destination)
        XCTAssertEqual(destination.selectedRange(), clickedRange)
    }

    func testTabDropMoveAndSplitTransferFirstResponder() async throws {
        let model = try modelWithTabs()
        for index in model.tabs.indices { model.tabs[index].editorMode = .source }
        let original = model.tabGroupLayout.focusedGroupID
        let firstID = model.tabs[0].id
        let secondID = model.tabs[1].id
        let thirdID = model.tabs[2].id
        model.dropTab(thirdID, on: original, zone: .trailing)
        let other = model.tabGroupLayout.focusedGroupID
        await model.focusGroup(original)
        let host = NSHostingView(rootView: TabGroupsView().environment(model).frame(width: 900, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        func focusedEditor(containing text: String) async -> SourceTextView? {
            for _ in 0..<80 {
                host.layoutSubtreeIfNeeded()
                if let editor = window.firstResponder as? SourceTextView, editor.string == text {
                    return editor
                }
                await Task.yield()
            }
            return nil
        }

        _ = await focusedEditor(containing: "One")
        model.dropTab(secondID, on: other, zone: .center)
        let afterDrop = await focusedEditor(containing: "Two")
        XCTAssertNotNil(afterDrop, "centre drop should focus the moved tab")

        model.moveTab(firstID, toGroup: other, at: 0)
        let afterMove = await focusedEditor(containing: "One")
        XCTAssertNotNil(afterMove, "strip move should focus the moved tab")

        model.splitActiveTab(.bottom)
        let afterSplit = await focusedEditor(containing: "One")
        XCTAssertNotNil(afterSplit, "keyboard split should focus the rebuilt pane")
    }

    func testNativeTabDragReachesPaneAndStripWithoutMovingTheWindow() async throws {
        for target in ["pane", "strip"] {
            let model = try modelWithTabs()
            for index in model.tabs.indices { model.tabs[index].editorMode = .source }
            let original = model.tabGroupLayout.focusedGroupID
            let movedID = model.tabs[0].id
            let destinationID = model.tabs[2].id
            model.dropTab(destinationID, on: original, zone: .trailing)
            let destinationGroup = model.tabGroupLayout.focusedGroupID
            let host = NSHostingView(rootView: TabGroupsView().environment(model).frame(width: 900, height: 500))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            defer { window.orderOut(nil) }
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let sources = descendants(of: host).compactMap { $0 as? TabDragSourceView }
            let source = try XCTUnwrap(sources.first { $0.tabID == movedID })
            let destination: NSView
            if target == "pane" {
                destination = try XCTUnwrap(
                    descendants(of: host).compactMap { $0 as? SourceTextView }
                        .first { $0.string == "Three" }
                )
            } else {
                destination = try XCTUnwrap(sources.first { $0.tabID == destinationID })
            }
            let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let end = destination.convert(
                NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil
            )
            let originalFrame = window.frame

            func event(_ type: NSEvent.EventType, at point: NSPoint, timestamp: TimeInterval) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: timestamp,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: Int(timestamp * 100),
                    clickCount: 1,
                    pressure: 1
                ))
            }
            let down = try event(.leftMouseDown, at: start, timestamp: 1)
            let begin = try event(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), timestamp: 1.1)
            let travel = try event(.leftMouseDragged, at: end, timestamp: 1.2)
            let up = try event(.leftMouseUp, at: end, timestamp: 1.3)
            source.mouseDown(with: down)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.postEvent(travel, atStart: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.postEvent(up, atStart: false) }
            source.mouseDragged(with: begin)
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while ContinuousClock().now < deadline,
                  model.tabGroupLayout.groupID(containing: movedID) != destinationGroup
            {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.tabGroupLayout.groupID(containing: movedID), destinationGroup, target)
            XCTAssertEqual(
                model.tabs(inGroup: destinationGroup).map(\.title),
                target == "pane" ? ["Three", "One"] : ["One", "Three"],
                target
            )
            XCTAssertEqual(window.frame, originalFrame, target)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func modelWithTabs() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VulkanGlassTabGroupInteraction-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = try ["One", "Two", "Three"].map { title in
            let url = root.appendingPathComponent("\(title).md")
            try title.write(to: url, atomically: true, encoding: .utf8)
            return NoteTab(path: url.path, title: title, content: title, originalContent: title, isStandalone: true)
        }
        return model
    }
}
