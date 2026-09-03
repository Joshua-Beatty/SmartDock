import Foundation

/// Persistent two-level ordering: app groups in the bar, windows within each group.
/// Pinned apps (set via sync) are locked in place; new apps and windows append to the end.
final class OrderStore {
    var onChange: (() -> Void)?
    private var appOrder: [pid_t] = []
    private var windowOrder: [pid_t: [Int]] = [:]

    /// Register newly seen apps/windows (appended) and prune quit apps.
    func sync(runningPids: Set<pid_t>, windows: [WindowInfo]) {
        appOrder.removeAll { !runningPids.contains($0) }
        windowOrder = windowOrder.filter { runningPids.contains($0.key) }

        for w in windows {
            if !appOrder.contains(w.pid) { appOrder.append(w.pid) }
            if !(windowOrder[w.pid] ?? []).contains(w.id) { windowOrder[w.pid, default: []].append(w.id) }
        }
    }

    /// Order one screen's visible windows: apps by group order, windows by in-group order.
    /// (Pinned apps are lifted to the front afterwards by the controller.)
    func arrange(_ visible: [WindowInfo]) -> [WindowInfo] {
        let byPid = Dictionary(grouping: visible, by: \.pid)
        return appOrder.flatMap { pid -> [WindowInfo] in
            guard let wins = byPid[pid] else { return [] }
            let order = windowOrder[pid] ?? []
            return wins.sorted {
                (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
            }
        }
    }

    /// True when this pid's group may not move on this bar (pinned items carry the
    /// flag per-monitor; placeholder pseudo-pids are negative).
    private func locked(_ pid: pid_t, in visible: [WindowInfo]) -> Bool {
        pid < 0 || visible.first { $0.pid == pid }?.isPinned == true
    }

    /// The arrangement that would result from dropping now — pure, used for live drag preview.
    func previewDrop(of win: WindowInfo, from: Int, to: Int, in visible: [WindowInfo]) -> [WindowInfo] {
        guard from != to, visible.indices.contains(from), visible.indices.contains(to) else { return visible }
        let pid = win.pid
        let span = visible.indices.filter { visible[$0].pid == pid }
        guard let gStart = span.first, let gEnd = span.last else { return visible }
        var out = visible

        if (gStart...gEnd).contains(to) {
            out.insert(out.remove(at: from), at: to)
            return out
        }
        let targetPid = visible[to].pid
        guard !locked(pid, in: visible), !locked(targetPid, in: visible), targetPid != pid else { return visible }
        out.removeSubrange(gStart...gEnd)
        let tSpan = out.indices.filter { out[$0].pid == targetPid }
        guard let tStart = tSpan.first, let tEnd = tSpan.last else { return visible }
        out.insert(contentsOf: span.map { visible[$0] }, at: to > gEnd ? tEnd + 1 : tStart)
        return out
    }

    /// Drop `win` (dragged from slot `from`) onto slot `to` within one bar's visible list.
    /// Inside its own group: reorder the window. Past a group boundary: move the whole group.
    func handleDrop(of win: WindowInfo, from: Int, to: Int, in visible: [WindowInfo]) {
        guard from != to, visible.indices.contains(from), visible.indices.contains(to) else { return }
        let pid = win.pid
        let span = visible.indices.filter { visible[$0].pid == pid }
        guard let gStart = span.first, let gEnd = span.last else { return }

        if (gStart...gEnd).contains(to) {
            var ids = span.map { visible[$0].id }
            guard let i = ids.firstIndex(of: win.id) else { return }
            ids.remove(at: i)
            ids.insert(win.id, at: to - gStart)
            windowOrder[pid] = ids + (windowOrder[pid] ?? []).filter { !ids.contains($0) }
        } else {
            let targetPid = visible[to].pid
            guard !locked(pid, in: visible), !locked(targetPid, in: visible), targetPid != pid,
                  let cur = appOrder.firstIndex(of: pid) else { return }
            appOrder.remove(at: cur)
            let insertAt = appOrder.firstIndex(of: targetPid).map { to > gEnd ? $0 + 1 : $0 } ?? appOrder.count
            appOrder.insert(pid, at: min(insertAt, appOrder.count))
        }
        onChange?()
    }
}
