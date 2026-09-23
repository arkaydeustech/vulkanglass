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
    }
}

@MainActor
final class TabGroupModelTests: XCTestCase {
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
        model.focusGroup(original)

        let third = root.appendingPathComponent("Three.md")
        try "three".write(to: third, atomically: true, encoding: .utf8)
        await model.openTab(path: third.path, standalone: true)

        XCTAssertEqual(model.tabs(inGroup: original).map(\.title), ["One", "Three"])
        XCTAssertEqual(model.tabGroupLayout.focusedGroupID, original)
        XCTAssertEqual(model.activeTabID, third.path)
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

    func testFocusingAnotherGroupLeavesTheGraphView() throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        model.centerView = .graph

        model.focusGroup(original)

        XCTAssertEqual(model.centerView, .editor)
        XCTAssertEqual(model.activeTab?.title, "One")
    }

    func testReadingModeStaysWithEachGroupsActiveTab() throws {
        let model = try modelWithOpenTabs(["One", "Two"])
        let original = model.tabGroupLayout.focusedGroupID
        model.dropTab(model.tabs[1].path, on: original, zone: .trailing)
        model.editorMode = .source

        model.focusGroup(original)

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

@MainActor
final class TabGroupCommandTests: XCTestCase {
    func testSplitCommandsMoveTheActiveTabBesideOrBelow() throws {
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

        model.focusGroup(model.tabGroupLayout.orderedGroups[0].id)
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
