import CoreGraphics
import Foundation

/// Direction in which a split lays out its two panes.
enum SplitAxis: String, Sendable {
    /// Panes sit side by side, divided by a vertical line.
    case horizontal
    /// Panes are stacked, divided by a horizontal line.
    case vertical
}

/// Where a dragged tab would land when released over a pane.
enum PaneDropZone: Equatable, Sendable, CaseIterable {
    case center
    case leading
    case trailing
    case top
    case bottom

    /// Fraction of a pane's width or height, measured from each edge, that splits the pane.
    static let edgeFraction: CGFloat = 0.25

    /// The split axis an edge zone creates; nil for the centre, which joins the group.
    var axis: SplitAxis? {
        switch self {
        case .center: nil
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// True when the new group takes the first (leading or top) half of the split.
    var placesNewGroupFirst: Bool { self == .leading || self == .top }

    /// Picks the zone for a pointer location in a pane: the nearest edge when the pointer is
    /// within `edgeFraction` of it, otherwise the centre.
    static func zone(for location: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = min(max(location.x / size.width, 0), 1)
        let y = min(max(location.y / size.height, 0), 1)
        let distances: [(PaneDropZone, CGFloat)] = [
            (.leading, x),
            (.trailing, 1 - x),
            (.top, y),
            (.bottom, 1 - y)
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeFraction else {
            return .center
        }
        return nearest.0
    }

    /// The part of the pane the dropped tab would occupy, used for the drop highlight.
    func highlightRect(in size: CGSize) -> CGRect {
        let width = max(0, size.width)
        let height = max(0, size.height)
        switch self {
        case .center: return CGRect(x: 0, y: 0, width: width, height: height)
        case .leading: return CGRect(x: 0, y: 0, width: width / 2, height: height)
        case .trailing: return CGRect(x: width / 2, y: 0, width: width / 2, height: height)
        case .top: return CGRect(x: 0, y: 0, width: width, height: height / 2)
        case .bottom: return CGRect(x: 0, y: height / 2, width: width, height: height / 2)
        }
    }
}

/// An ordered set of note tabs shown together in one pane.
struct TabGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var tabIDs: [String]
    var activeTabID: String?

    init(id: UUID = UUID(), tabIDs: [String] = [], activeTabID: String? = nil) {
        self.id = id
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID
    }
}

/// A split between two panes. The first pane is leading (horizontal) or top (vertical).
struct PaneSplit: Equatable, Sendable {
    let id: UUID
    var axis: SplitAxis
    var first: PaneNode
    var second: PaneNode
}

/// Binary tree describing how the main display area is divided into tab groups.
indirect enum PaneNode: Equatable, Sendable {
    case group(UUID)
    case split(PaneSplit)

    /// Group IDs in reading order: leading before trailing, top before bottom.
    var groupIDs: [UUID] {
        switch self {
        case let .group(id): [id]
        case let .split(split): split.first.groupIDs + split.second.groupIDs
        }
    }

    func contains(group id: UUID) -> Bool {
        switch self {
        case let .group(groupID): groupID == id
        case let .split(split): split.first.contains(group: id) || split.second.contains(group: id)
        }
    }

    /// Replaces the leaf for `target` with a split holding it and `newGroup`.
    func splitting(_ target: UUID, with newGroup: UUID, axis: SplitAxis, newGroupFirst: Bool) -> PaneNode {
        switch self {
        case let .group(id):
            guard id == target else { return self }
            let existing = PaneNode.group(id)
            let added = PaneNode.group(newGroup)
            return .split(PaneSplit(
                id: UUID(),
                axis: axis,
                first: newGroupFirst ? added : existing,
                second: newGroupFirst ? existing : added
            ))
        case var .split(split):
            split.first = split.first.splitting(target, with: newGroup, axis: axis, newGroupFirst: newGroupFirst)
            split.second = split.second.splitting(target, with: newGroup, axis: axis, newGroupFirst: newGroupFirst)
            return .split(split)
        }
    }

    /// Removes the leaf for `target`, letting its sibling take the parent split's place.
    /// Returns nil when the tree held nothing but that leaf. `neighbor` is the group nearest
    /// to the removed one, so focus can move somewhere that visually makes sense.
    func removing(_ target: UUID) -> (node: PaneNode?, neighbor: UUID?) {
        switch self {
        case let .group(id):
            return id == target ? (nil, nil) : (self, nil)
        case var .split(split):
            if split.first.contains(group: target) {
                let result = split.first.removing(target)
                guard let node = result.node else { return (split.second, split.second.groupIDs.first) }
                split.first = node
                return (.split(split), result.neighbor)
            }
            if split.second.contains(group: target) {
                let result = split.second.removing(target)
                guard let node = result.node else { return (split.first, split.first.groupIDs.last) }
                split.second = node
                return (.split(split), result.neighbor)
            }
            return (self, nil)
        }
    }

    /// Split IDs anywhere in the tree.
    var splitIDs: [UUID] {
        switch self {
        case .group: []
        case let .split(split): [split.id] + split.first.splitIDs + split.second.splitIDs
        }
    }
}

/// Which note tabs live in which tab group, and how the groups divide the main pane.
///
/// Every open tab belongs to exactly one group. `AppModel` keeps its flat `tabs` store and calls
/// `reconcile(with:)` whenever that store changes, so groups never reference a closed tab and a
/// newly opened tab always lands in the focused group.
struct TabGroupLayout: Equatable, Sendable {
    private(set) var groups: [TabGroup]
    private(set) var root: PaneNode
    private(set) var focusedGroupID: UUID

    init() {
        let group = TabGroup()
        groups = [group]
        root = .group(group.id)
        focusedGroupID = group.id
    }

    /// Groups in reading order.
    var orderedGroups: [TabGroup] {
        root.groupIDs.compactMap { id in groups.first { $0.id == id } }
    }

    var focusedGroup: TabGroup? { group(focusedGroupID) }

    /// The focused group's active tab, which is the app-wide active tab.
    var activeTabID: String? { focusedGroup?.activeTabID }

    var isSplit: Bool { groups.count > 1 }

    func group(_ id: UUID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    func groupID(containing tabID: String) -> UUID? {
        groups.first { $0.tabIDs.contains(tabID) }?.id
    }

    /// Focuses a group without changing any group's active tab.
    mutating func focus(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        focusedGroupID = id
    }

    /// Makes `tabID` the active tab of its group and focuses that group. An ID that is not in
    /// any group (yet) becomes the focused group's active tab until the next reconcile.
    mutating func activate(_ tabID: String?) {
        if let tabID, let owner = groupID(containing: tabID) {
            focusedGroupID = owner
            update(owner) { $0.activeTabID = tabID }
        } else {
            update(focusedGroupID) { $0.activeTabID = tabID }
        }
    }

    /// Brings the groups in line with the open tabs: drops closed tabs, adds new tabs to the
    /// focused group, repairs active tabs, and collapses groups left empty.
    mutating func reconcile(with tabIDs: [String]) {
        let open = Set(tabIDs)
        var seen: Set<String> = []
        for index in groups.indices {
            groups[index].tabIDs = groups[index].tabIDs.filter { open.contains($0) && seen.insert($0).inserted }
        }
        let unassigned = tabIDs.filter { !seen.contains($0) }
        if !unassigned.isEmpty {
            if !groups.contains(where: { $0.id == focusedGroupID }) {
                focusedGroupID = groups.first?.id ?? focusedGroupID
            }
            update(focusedGroupID) { group in
                for id in unassigned where !group.tabIDs.contains(id) {
                    group.tabIDs.append(id)
                }
            }
        }
        for index in groups.indices {
            if let active = groups[index].activeTabID, !groups[index].tabIDs.contains(active) {
                groups[index].activeTabID = groups[index].tabIDs.last
            }
        }
        collapseEmptyGroups()
    }

    /// Whether dropping `tabID` on `zone` of `target` would change the layout.
    func canDrop(_ tabID: String, on target: UUID, zone: PaneDropZone) -> Bool {
        guard let source = groupID(containing: tabID), group(target) != nil else { return false }
        if source != target { return true }
        // Within its own group a tab can only split off when others remain behind.
        return zone != .center && (group(source)?.tabIDs.count ?? 0) > 1
    }

    /// Drops a dragged tab onto a pane: the centre moves it into the group, an edge splits the
    /// group and gives the tab a new group on that side. Returns the group now holding the tab.
    @discardableResult
    mutating func drop(_ tabID: String, on target: UUID, zone: PaneDropZone) -> UUID? {
        guard canDrop(tabID, on: target, zone: zone) else { return nil }
        guard let axis = zone.axis else {
            move(tabID, to: target, at: nil)
            return target
        }
        return split(target, axis: axis, newGroupFirst: zone.placesNewGroupFirst, moving: tabID)
    }

    /// Moves a tab into `target` at `index` (appending when nil), making it that group's active
    /// tab and focusing the group. Moving within one group reorders it.
    mutating func move(_ tabID: String, to target: UUID, at index: Int?) {
        guard let source = groupID(containing: tabID), group(target) != nil else { return }
        var insertion = index
        if source == target, let from = group(source)?.tabIDs.firstIndex(of: tabID),
           let requested = index, requested > from
        {
            // Removing the tab first shifts later positions left by one.
            insertion = requested - 1
        }
        removeTab(tabID, from: source)
        update(target) { group in
            let position = min(max(insertion ?? group.tabIDs.count, 0), group.tabIDs.count)
            group.tabIDs.insert(tabID, at: position)
            group.activeTabID = tabID
        }
        focusedGroupID = target
        collapseEmptyGroups()
    }

    /// Splits `target` in two and moves `tabID` into the new half. Returns the new group.
    @discardableResult
    mutating func split(_ target: UUID, axis: SplitAxis, newGroupFirst: Bool, moving tabID: String) -> UUID? {
        guard let source = groupID(containing: tabID), group(target) != nil else { return nil }
        if source == target, (group(source)?.tabIDs.count ?? 0) < 2 { return nil }
        removeTab(tabID, from: source)
        let newGroup = TabGroup(tabIDs: [tabID], activeTabID: tabID)
        groups.append(newGroup)
        root = root.splitting(target, with: newGroup.id, axis: axis, newGroupFirst: newGroupFirst)
        focusedGroupID = newGroup.id
        collapseEmptyGroups()
        return newGroup.id
    }

    /// Follows a note to its new path after a rename, keeping its place and group.
    mutating func renameTab(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        for index in groups.indices {
            groups[index].tabIDs = groups[index].tabIDs.map { $0 == oldID ? newID : $0 }
            if groups[index].activeTabID == oldID {
                groups[index].activeTabID = newID
            }
        }
    }

    private mutating func removeTab(_ tabID: String, from groupID: UUID) {
        update(groupID) { group in
            guard let index = group.tabIDs.firstIndex(of: tabID) else { return }
            group.tabIDs.remove(at: index)
            if group.activeTabID == tabID {
                // Prefer the tab that slides into the removed one's place, then the one before it.
                group.activeTabID = group.tabIDs.indices.contains(index)
                    ? group.tabIDs[index]
                    : group.tabIDs.last
            }
        }
    }

    /// Removes empty groups from the tree while at least one other group remains.
    private mutating func collapseEmptyGroups() {
        while groups.count > 1,
              let empty = groups.first(where: { $0.tabIDs.isEmpty && $0.id != focusedGroupID })
                ?? groups.first(where: { $0.tabIDs.isEmpty })
        {
            let removal = root.removing(empty.id)
            guard let node = removal.node else { break }
            root = node
            groups.removeAll { $0.id == empty.id }
            if focusedGroupID == empty.id {
                focusedGroupID = removal.neighbor ?? root.groupIDs.first ?? focusedGroupID
            }
        }
        if !groups.contains(where: { $0.id == focusedGroupID }), let first = root.groupIDs.first {
            focusedGroupID = first
        }
    }

    private mutating func update(_ id: UUID, _ mutate: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[index])
    }
}
