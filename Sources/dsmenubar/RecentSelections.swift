// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Paths the user applied recently, most recent first.
///
/// Entries are stored in the same form the configuration stores them, so a
/// remembered path can be compared and re-applied without touching the file
/// system. This is display recall only: the tuning profile for a model stays
/// in `ServerConfiguration.Config.modelProfiles`, keyed by the model path.
struct RecentSelections: Codable, Equatable {
    /// Enough to cover a working set without turning the picker into a list.
    static let limit = 5

    /// The path rows that keep a history.
    enum Field: String, Equatable, CaseIterable {
        case server
        case model
        case vision
        /// DSpark and legacy MTP support GGUFs share one configuration path
        /// but are different files, so each mode keeps its own list.
        case dspark
        case legacyMTP

        /// Vision and support paths are remembered for one model family at a
        /// time, so a list of them is meaningless without that family's scope.
        var isScoped: Bool {
            switch self {
            case .vision, .dspark, .legacyMTP: return true
            case .server, .model: return false
            }
        }
    }

    /// One history: a field and, for the scoped fields, a model family.
    struct List: Hashable {
        let field: Field
        let scope: String?

        /// Nil for a scoped field without a scope: there is no row that could
        /// offer such a list.
        init?(_ field: Field, scope: String? = nil) {
            let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isScoped {
                guard let scope, !scope.isEmpty else { return nil }
                self.scope = scope
            } else {
                self.scope = nil
            }
            self.field = field
        }

        fileprivate var storageKey: String {
            scope.map { "\(field.rawValue)/\($0)" } ?? field.rawValue
        }
    }

    private var lists: [String: [String]] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lists
    }

    /// A missing key decodes as empty and an oversized history from a
    /// hand-edited blob is clamped, so a future field cannot discard the
    /// whole value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lists = (try container.decodeIfPresent([String: [String]].self, forKey: .lists) ?? [:])
            .mapValues { Array($0.prefix(Self.limit)) }
    }

    func recentPaths(for field: Field, scope: String? = nil) -> [String] {
        guard let list = List(field, scope: scope) else { return [] }
        return lists[list.storageKey] ?? []
    }

    /// Move `path` to the front of its list, dropping the oldest entry past the
    /// cap. `outgoing` is the selection the change replaces; it is kept even
    /// when the list is full, because it is the way back to what the user just
    /// changed away from. Empty paths are ignored.
    ///
    /// `fileKey` names the file a path refers to, so two spellings of one
    /// file are one entry and the newer spelling replaces the older: the row
    /// shows what was just stored, and the menu should match it. The default
    /// compares the text.
    mutating func record(
        _ path: String,
        replacing outgoing: String? = nil,
        for field: Field,
        scope: String? = nil,
        fileKey: (String) -> String = { $0 }
    ) {
        guard let list = List(field, scope: scope),
              let path = Self.nonEmpty(path)
        else { return }
        var paths = lists[list.storageKey] ?? []
        let pathKey = fileKey(path)
        paths.removeAll { fileKey($0) == pathKey }
        paths.insert(path, at: 0)
        var kept = Array(paths.prefix(Self.limit))
        if let outgoing = Self.nonEmpty(outgoing) {
            let outgoingKey = fileKey(outgoing)
            if outgoingKey != pathKey, !kept.contains(where: { fileKey($0) == outgoingKey }) {
                // Keep the outgoing selection in the last slot instead of the
                // entry that would be dropped; the new pick is the only thing
                // more recent.
                kept = Array(kept.prefix(Self.limit - 1)) + [outgoing]
            }
        }
        lists[list.storageKey] = kept
    }

    /// Add `path` at the end of its list when it is not remembered yet, without
    /// disturbing the order of anything already there. Seeding is how a
    /// configuration that predates the history becomes reachable again: the
    /// next change adds itself in front, leaving the configured path as the
    /// way back. A path whose file is already remembered under another
    /// spelling is not added.
    mutating func seed(
        _ path: String,
        for field: Field,
        scope: String? = nil,
        fileKey: (String) -> String = { $0 }
    ) {
        guard let list = List(field, scope: scope),
              let path = Self.nonEmpty(path)
        else { return }
        var paths = lists[list.storageKey] ?? []
        let pathKey = fileKey(path)
        guard !paths.contains(where: { fileKey($0) == pathKey }) else { return }
        // The configured path takes the oldest slot when the history is full:
        // the current selection has to stay reachable, and the least recent
        // entry is the one worth dropping.
        if paths.count >= Self.limit {
            paths.removeLast(paths.count - Self.limit + 1)
        }
        paths.append(path)
        lists[list.storageKey] = paths
    }

    /// Forget one row's history.
    mutating func clear(_ field: Field, scope: String? = nil) {
        guard let list = List(field, scope: scope) else { return }
        lists[list.storageKey] = nil
    }

    /// Drop every entry `isGone` rejects, judged with its list's field and
    /// scope.
    mutating func prune(where isGone: (List, String) -> Bool) {
        for storageKey in lists.keys {
            guard let list = Self.list(storageKey: storageKey) else { continue }
            let kept = (lists[storageKey] ?? []).filter { !isGone(list, $0) }
            lists[storageKey] = kept.isEmpty ? nil : kept
        }
    }

    private static func list(storageKey: String) -> List? {
        let parts = storageKey.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let field = Field(rawValue: first) else { return nil }
        return List(field, scope: parts.count > 1 ? parts[1] : nil)
    }

    /// A selection that was never set (the empty default) is not a path worth
    /// remembering: keeping it would spend a history slot on nothing.
    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

extension RecentSelections {
    /// A path an applied configuration uses, and the list it belongs to.
    struct Entry: Equatable {
        let list: List
        let path: String
    }

    /// The remembered paths `config` puts into effect. A vision path counts
    /// only when vision is on and the model takes an encoder, and a support
    /// path only in the mode that loads it, so an unused default is never
    /// remembered. `model` is the main model's profile, or nil when it is not
    /// known; without a known family there is no list to file vision or
    /// support paths in.
    static func entries(
        in config: ServerConfiguration.Config,
        model: DS4ModelProfile?
    ) -> [Entry] {
        var entries: [Entry] = []
        func add(_ field: Field, _ path: String, scope: String? = nil) {
            guard let list = List(field, scope: scope),
                  let path = nonEmpty(path)
            else { return }
            entries.append(Entry(list: list, path: path))
        }
        add(.server, config.serverPath)
        add(.model, config.modelPath)
        guard let model, model.isKnown else { return entries }
        let scope = model.recentResourceScope
        if config.visionEnabled, model.supportsVision {
            add(.vision, config.visionPath, scope: scope)
        }
        switch config.mtpMode {
        case .dspark: add(.dspark, config.mtpPath, scope: scope)
        case .external: add(.legacyMTP, config.mtpPath, scope: scope)
        case .off, .embedded: break
        }
        return entries
    }

    /// Remember what an Apply changed. A path that replaced another in the
    /// same list goes in front with the old one kept as the way back. A path
    /// that left use without a successor — a mode switched off, a family
    /// changed — goes in front of its own list, where it is now the most
    /// recent choice. Paths that did not change are left alone.
    mutating func recordApply(
        from previous: [Entry],
        to applied: [Entry],
        fileKey: (List) -> (String) -> String
    ) {
        for entry in applied {
            let key = fileKey(entry.list)
            let outgoing = previous.first { $0.list == entry.list }
            if let outgoing, key(outgoing.path) == key(entry.path) { continue }
            record(
                entry.path,
                replacing: outgoing?.path,
                for: entry.list.field,
                scope: entry.list.scope,
                fileKey: key
            )
        }
        for entry in previous where !applied.contains(where: { $0.list == entry.list }) {
            record(
                entry.path,
                for: entry.list.field,
                scope: entry.list.scope,
                fileKey: fileKey(entry.list)
            )
        }
    }
}
