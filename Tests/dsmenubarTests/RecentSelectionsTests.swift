// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

final class RecentSelectionsTests: XCTestCase {

    func testRecordingKeepsTheFiveMostRecentServersInOrder() {
        var recents = RecentSelections()
        for index in 1...6 {
            recents.record("/servers/\(index)/ds4-server", for: .server)
        }
        XCTAssertEqual(
            recents.recentPaths(for: .server),
            [6, 5, 4, 3, 2].map { "/servers/\($0)/ds4-server" }
        )
    }

    func testRecordingAnExistingPathMovesItToTheFrontWithoutDuplicating() {
        var recents = RecentSelections()
        recents.record("/models/a.gguf", for: .model)
        recents.record("/models/b.gguf", for: .model)
        recents.record("/models/a.gguf", for: .model)
        XCTAssertEqual(
            recents.recentPaths(for: .model),
            ["/models/a.gguf", "/models/b.gguf"]
        )
    }

    func testVisionAndSupportHistoriesAreScopedToTheirFamily() {
        var recents = RecentSelections()
        recents.record("/vision/qwen.gguf", for: .vision, scope: "qwen38")
        recents.record("/vision/deepseek.gguf", for: .vision, scope: "deepSeek41")
        recents.record("/mtp/deepseek.gguf", for: .dspark, scope: "deepSeek")

        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: "qwen38"),
            ["/vision/qwen.gguf"]
        )
        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: "deepSeek41"),
            ["/vision/deepseek.gguf"]
        )
        XCTAssertEqual(recents.recentPaths(for: .vision), [])
        XCTAssertEqual(
            recents.recentPaths(for: .dspark, scope: "deepSeek"),
            ["/mtp/deepseek.gguf"]
        )
        XCTAssertEqual(recents.recentPaths(for: .dspark, scope: "deepSeek41"), [])
    }

    func testDSparkAndLegacyMTPKeepSeparateLists() {
        var recents = RecentSelections()
        recents.record("/support/dspark.gguf", for: .dspark, scope: "deepSeek")
        recents.record("/support/mtp.gguf", for: .legacyMTP, scope: "deepSeek")

        XCTAssertEqual(
            recents.recentPaths(for: .dspark, scope: "deepSeek"),
            ["/support/dspark.gguf"]
        )
        XCTAssertEqual(
            recents.recentPaths(for: .legacyMTP, scope: "deepSeek"),
            ["/support/mtp.gguf"]
        )
    }

    func testClearingForgetsOnlyThatList() {
        var recents = RecentSelections()
        recents.record("/support/dspark.gguf", for: .dspark, scope: "deepSeek")
        recents.record("/support/mtp.gguf", for: .legacyMTP, scope: "deepSeek")
        recents.record("/models/a.gguf", for: .model)

        recents.clear(.dspark, scope: "deepSeek")

        XCTAssertEqual(recents.recentPaths(for: .dspark, scope: "deepSeek"), [])
        XCTAssertEqual(
            recents.recentPaths(for: .legacyMTP, scope: "deepSeek"),
            ["/support/mtp.gguf"]
        )
        XCTAssertEqual(recents.recentPaths(for: .model), ["/models/a.gguf"])
    }

    func testPruningDropsRejectedEntriesWithTheirList() {
        var recents = RecentSelections()
        recents.record("/models/gone.gguf", for: .model)
        recents.record("/models/kept.gguf", for: .model)
        recents.record("/support/gone.gguf", for: .dspark, scope: "deepSeek")

        var judged: [RecentSelections.List] = []
        recents.prune { list, path in
            judged.append(list)
            return path.contains("gone")
        }

        XCTAssertEqual(recents.recentPaths(for: .model), ["/models/kept.gguf"])
        XCTAssertEqual(recents.recentPaths(for: .dspark, scope: "deepSeek"), [])
        XCTAssertTrue(judged.contains(RecentSelections.List(.dspark, scope: "deepSeek")!))
        XCTAssertEqual(recents, {
            var expected = RecentSelections()
            expected.record("/models/kept.gguf", for: .model)
            return expected
        }())
    }

    func testScopedPathsWithoutAScopeAreIgnored() {
        var recents = RecentSelections()
        recents.record("/vision/a.gguf", for: .vision)
        recents.record("/vision/a.gguf", for: .vision, scope: "  ")
        XCTAssertEqual(recents.recentPaths(for: .vision, scope: "qwen38"), [])
    }

    func testOneVisionListIsSharedAcrossTheQuantsOfAFamily() {
        let q2 = DS4ModelProfile.from(architecture: "qwen4exp")
        let q4 = DS4ModelProfile.from(architecture: "qwen4exp")
        XCTAssertEqual(q2.recentResourceScope, q4.recentResourceScope)
        XCTAssertNotEqual(
            q2.recentResourceScope,
            DS4ModelProfile.from(architecture: "deepseek41").recentResourceScope
        )

        var recents = RecentSelections()
        recents.record(
            "/vision/mmproj-Q8.gguf",
            for: .vision,
            scope: q2.recentResourceScope
        )
        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: q4.recentResourceScope),
            ["/vision/mmproj-Q8.gguf"]
        )
    }

    func testEmptyPathsAreIgnored() {
        var recents = RecentSelections()
        recents.record("   ", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .model), [])
    }

    func testEmptyOutgoingSelectionsAreNotRemembered() {
        var recents = RecentSelections()
        recents.record(
            "/vision/qwen.gguf",
            replacing: "",
            for: .vision,
            scope: "qwen38"
        )
        recents.record(
            "/models/model.gguf",
            replacing: "   ",
            for: .model
        )

        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: "qwen38"),
            ["/vision/qwen.gguf"]
        )
        XCTAssertEqual(recents.recentPaths(for: .model), ["/models/model.gguf"])
    }

    func testSeedingAppendsWithoutReorderingAndRecordStillMovesToTheFront() {
        var recents = RecentSelections()
        recents.seed("/models/a.gguf", for: .model)
        recents.seed("/models/b.gguf", for: .model)
        recents.seed("/models/a.gguf", for: .model)
        XCTAssertEqual(
            recents.recentPaths(for: .model),
            ["/models/a.gguf", "/models/b.gguf"]
        )

        // The seeded configuration path stays as the way back after a pick.
        recents.record("/models/c.gguf", for: .model)
        XCTAssertEqual(
            recents.recentPaths(for: .model),
            ["/models/c.gguf", "/models/a.gguf", "/models/b.gguf"]
        )
    }

    func testSeedingDropsTheOldestEntryWhenTheHistoryIsFull() {
        var recents = RecentSelections()
        for index in 1...5 {
            recents.record("/models/\(index).gguf", for: .model)
        }
        recents.seed("/models/configured.gguf", for: .model)
        XCTAssertEqual(
            recents.recentPaths(for: .model),
            [
                "/models/5.gguf",
                "/models/4.gguf",
                "/models/3.gguf",
                "/models/2.gguf",
                "/models/configured.gguf",
            ]
        )
    }

    func testASeededSelectionSurvivesTheFirstRecordedPick() {
        var recents = RecentSelections()
        for index in 1...5 {
            recents.record("/models/\(index).gguf", for: .model)
        }
        recents.seed("/models/configured.gguf", for: .model)

        recents.record(
            "/models/new.gguf",
            replacing: "/models/configured.gguf",
            for: .model
        )

        XCTAssertEqual(
            recents.recentPaths(for: .model),
            [
                "/models/new.gguf",
                "/models/5.gguf",
                "/models/4.gguf",
                "/models/3.gguf",
                "/models/configured.gguf",
            ]
        )
    }

    func testAnotherSpellingOfTheSameFileGivesWayToTheNewPick() {
        // Keys stand in for the file system: both spellings name one file.
        let fileKey: (String) -> String = {
            $0.replacingOccurrences(of: "/link/", with: "/real/")
        }
        var recents = RecentSelections()
        recents.seed("/link/a.gguf", for: .model, fileKey: fileKey)
        recents.seed("/real/a.gguf", for: .model, fileKey: fileKey)
        XCTAssertEqual(recents.recentPaths(for: .model), ["/link/a.gguf"])

        recents.record(
            "/real/a.gguf",
            replacing: "/link/a.gguf",
            for: .model,
            fileKey: fileKey
        )
        XCTAssertEqual(recents.recentPaths(for: .model), ["/real/a.gguf"])
    }

    func testAnOutgoingSelectionRememberedUnderAnotherSpellingIsNotAddedAgain() {
        let fileKey: (String) -> String = {
            $0.replacingOccurrences(of: "/link/", with: "/real/")
        }
        var recents = RecentSelections()
        recents.seed("/link/a.gguf", for: .dspark, scope: "deepSeek", fileKey: fileKey)

        recents.record(
            "/real/b.gguf",
            replacing: "/real/a.gguf",
            for: .dspark,
            scope: "deepSeek",
            fileKey: fileKey
        )
        XCTAssertEqual(
            recents.recentPaths(for: .dspark, scope: "deepSeek"),
            ["/real/b.gguf", "/link/a.gguf"]
        )
    }

    /// The reported layout: the configuration names a support GGUF through
    /// a linked `gguf` directory beside ds4-server, and the open panel
    /// returns the same file's real path.
    func testLinkedAndRealSpellingsOfASupportFileAreOneEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-recents-link-\(UUID().uuidString)")
        let store = root.appendingPathComponent("store")
        let serverDirectory = root.appendingPathComponent("ds4")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: serverDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: store.appendingPathComponent("support.gguf"))
        try Data().write(to: store.appendingPathComponent("other.gguf"))
        try FileManager.default.createSymbolicLink(
            at: serverDirectory.appendingPathComponent("gguf"),
            withDestinationURL: store
        )
        let serverPath = serverDirectory.appendingPathComponent("ds4-server").path
        let configured = serverDirectory.appendingPathComponent("gguf/support.gguf").path
        let picked = ServerConfiguration.Config.modelKey(
            for: configured,
            serverPath: serverPath
        )
        XCTAssertNotEqual(picked, configured)
        let other = store.appendingPathComponent("other.gguf").path
        let fileKey = ServerConfiguration.Config.recentFileKey(
            field: .dspark,
            serverPath: serverPath
        )

        var recents = RecentSelections()
        recents.seed(configured, for: .dspark, scope: "deepSeek", fileKey: fileKey)
        recents.record(
            other,
            replacing: configured,
            for: .dspark,
            scope: "deepSeek",
            fileKey: fileKey
        )
        recents.record(
            picked,
            replacing: other,
            for: .dspark,
            scope: "deepSeek",
            fileKey: fileKey
        )

        XCTAssertEqual(
            recents.recentPaths(for: .dspark, scope: "deepSeek"),
            [picked, other]
        )
    }

    func testAServerLinkIsComparedByTargetButStoredAsSpelled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-recents-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("ds4-server")
        try Data().write(to: server)
        let link = root.appendingPathComponent("current-server")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: server)
        let fileKey = ServerConfiguration.Config.recentFileKey(
            field: .server,
            serverPath: link.path
        )

        var recents = RecentSelections()
        recents.seed(server.path, for: .server, fileKey: fileKey)
        recents.record(link.path, for: .server, fileKey: fileKey)

        XCTAssertEqual(recents.recentPaths(for: .server), [link.path])
    }

    func testDecodingClampsAnOversizedHistory() throws {
        let json = """
        {
          "lists": {
            "server": ["1", "2", "3", "4", "5", "6"],
            "vision/qwen38": ["1", "2", "3", "4", "5", "6"]
          }
        }
        """
        let recents = try JSONDecoder().decode(
            RecentSelections.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(recents.recentPaths(for: .server), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: "qwen38"),
            ["1", "2", "3", "4", "5"]
        )
    }

    func testMissingKeysDecodeAsEmptyLists() throws {
        let recents = try JSONDecoder().decode(
            RecentSelections.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(recents, RecentSelections())
    }

    func testConfigurationPersistsRecentsAcrossInstances() throws {
        let suiteName = "dsmenubar-recents-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let files = try TemporaryFiles()
        defer { files.remove() }
        let first = try files.make("first.gguf")
        let second = try files.make("second.gguf")

        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            serverPath: files.server,
            modelPath: first,
            modelProfile: .from(architecture: "deepseek4")
        )
        let previous = configuration.snapshot()
        var next = previous
        next.modelPath = second
        configuration.replace(with: next)
        configuration.recordAppliedSelections(
            previous: previous,
            previousModel: .from(architecture: "deepseek4"),
            appliedModel: .from(architecture: "deepseek4")
        )
        configuration.clearRecentSelections(field: .server)

        let reloaded = ServerConfiguration(defaults: defaults)
        XCTAssertEqual(
            reloaded.recentSelections.recentPaths(for: .model),
            [second, first]
        )
        // Loading seeds the applied server again after the clear.
        XCTAssertEqual(reloaded.recentSelections.recentPaths(for: .server), [files.server])
    }

    func testLoadingAnExistingConfigurationSeedsItsPaths() throws {
        let suiteName = "dsmenubar-recents-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            serverPath: "/servers/ds4-server",
            modelPath: "/models/a.gguf"
        )
        // Simulate an upgrade: the configuration exists, the history does not.
        defaults.removeObject(forKey: "dsmenubar.recentSelections")

        let reloaded = ServerConfiguration(defaults: defaults)
        XCTAssertEqual(
            reloaded.recentSelections.recentPaths(for: .server),
            ["/servers/ds4-server"]
        )
        XCTAssertEqual(
            reloaded.recentSelections.recentPaths(for: .model),
            ["/models/a.gguf"]
        )
    }

    // MARK: - Recording at Apply

    private func entry(
        _ field: RecentSelections.Field,
        _ path: String,
        scope: String? = nil
    ) -> RecentSelections.Entry {
        RecentSelections.Entry(list: RecentSelections.List(field, scope: scope)!, path: path)
    }

    private func textKey(_ list: RecentSelections.List) -> (String) -> String { { $0 } }

    func testApplyRecordsAChangedPathWithTheOldOneAsTheWayBack() {
        var recents = RecentSelections()
        recents.recordApply(
            from: [entry(.model, "/models/a.gguf"), entry(.server, "/s/ds4-server")],
            to: [entry(.model, "/models/b.gguf"), entry(.server, "/s/ds4-server")],
            fileKey: textKey
        )

        XCTAssertEqual(recents.recentPaths(for: .model), ["/models/b.gguf", "/models/a.gguf"])
        // Unchanged paths are not recorded.
        XCTAssertEqual(recents.recentPaths(for: .server), [])
    }

    func testApplyFilesAPathThatLeftUseInItsOwnList() {
        var recents = RecentSelections()
        recents.recordApply(
            from: [
                entry(.dspark, "/support/dspark.gguf", scope: "deepSeek"),
                entry(.vision, "/vision/qwen.gguf", scope: "qwen38"),
            ],
            to: [entry(.legacyMTP, "/support/mtp.gguf", scope: "deepSeek")],
            fileKey: textKey
        )

        XCTAssertEqual(
            recents.recentPaths(for: .dspark, scope: "deepSeek"),
            ["/support/dspark.gguf"]
        )
        XCTAssertEqual(
            recents.recentPaths(for: .legacyMTP, scope: "deepSeek"),
            ["/support/mtp.gguf"]
        )
        XCTAssertEqual(
            recents.recentPaths(for: .vision, scope: "qwen38"),
            ["/vision/qwen.gguf"]
        )
    }

    func testOnlyPathsInEffectAreEntries() {
        var config = ServerConfiguration.Config(
            serverPath: "/s/ds4-server",
            modelPath: "/models/deepseek.gguf"
        )
        config.mtpMode = .off
        config.visionEnabled = true
        config.visionPath = "/vision/unused.gguf"
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")

        // MTP off and a model without vision: the default support path and
        // the encoder are not in use.
        XCTAssertEqual(
            RecentSelections.entries(in: config, model: deepSeek),
            [entry(.server, "/s/ds4-server"), entry(.model, "/models/deepseek.gguf")]
        )

        config.mtpMode = .dspark
        XCTAssertEqual(
            RecentSelections.entries(in: config, model: deepSeek).last,
            entry(.dspark, config.mtpPath, scope: deepSeek.recentResourceScope)
        )
        config.mtpMode = .external
        XCTAssertEqual(
            RecentSelections.entries(in: config, model: deepSeek).last,
            entry(.legacyMTP, config.mtpPath, scope: deepSeek.recentResourceScope)
        )

        // Without a known family there is no list for resource paths.
        XCTAssertEqual(RecentSelections.entries(in: config, model: nil).count, 2)
        XCTAssertEqual(RecentSelections.entries(in: config, model: .unknown).count, 2)

        let qwen = DS4ModelProfile.from(architecture: "qwen4exp")
        XCTAssertTrue(qwen.supportsVision)
        XCTAssertTrue(
            RecentSelections.entries(in: config, model: qwen)
                .contains(entry(.vision, "/vision/unused.gguf", scope: qwen.recentResourceScope))
        )
        config.visionEnabled = false
        XCTAssertFalse(
            RecentSelections.entries(in: config, model: qwen)
                .contains { $0.list.field == .vision }
        )
    }

    func testApplyDropsFilesGoneFromAMountedDisk() throws {
        let suiteName = "dsmenubar-recents-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let files = try TemporaryFiles()
        defer { files.remove() }
        let first = try files.make("first.gguf")
        let second = try files.make("second.gguf")
        let third = try files.make("third.gguf")
        let unmounted = "/Volumes/dsmenubar-absent-\(UUID().uuidString)/model.gguf"

        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            serverPath: files.server,
            modelPath: first,
            modelProfile: .from(architecture: "deepseek4")
        )
        func apply(model: String) {
            let previous = configuration.snapshot()
            var next = previous
            next.modelPath = model
            configuration.replace(with: next)
            configuration.recordAppliedSelections(
                previous: previous,
                previousModel: .from(architecture: "deepseek4"),
                appliedModel: .from(architecture: "deepseek4")
            )
        }
        apply(model: unmounted)
        apply(model: second)
        try FileManager.default.removeItem(atPath: first)
        apply(model: third)

        XCTAssertEqual(
            configuration.recentSelections.recentPaths(for: .model),
            [third, second, unmounted]
        )
    }

    func testAvailabilityTellsAnUnmountedVolumeFromAMissingFile() throws {
        let files = try TemporaryFiles()
        defer { files.remove() }
        let present = try files.make("present.gguf")
        let absentVolume = "/Volumes/dsmenubar-absent-\(UUID().uuidString)"
        let link = (files.directory as NSString).appendingPathComponent("linked.gguf")
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: "\(absentVolume)/model.gguf"
        )
        func availability(
            _ path: String,
            _ field: RecentSelections.Field = .model
        ) -> ServerConfiguration.Config.RecentPathAvailability {
            ServerConfiguration.Config.recentPathAvailability(
                path,
                field: field,
                serverPath: files.server
            )
        }

        XCTAssertEqual(availability(present), .available)
        XCTAssertEqual(availability("present.gguf"), .available)
        XCTAssertEqual(availability(files.server, .server), .available)
        XCTAssertEqual(availability(present, .server), .unusable)
        XCTAssertEqual(availability("absent.gguf"), .missing)
        XCTAssertEqual(availability("\(absentVolume)/model.gguf"), .volumeNotMounted)
        // A link onto the absent volume is judged by where it points.
        XCTAssertEqual(availability(link), .volumeNotMounted)
    }

    func testApplyRetainsAFileBehindAnInaccessibleDirectory() throws {
        let suiteName = "dsmenubar-recents-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let files = try TemporaryFiles()
        defer { files.remove() }
        let directory = (files.directory as NSString).appendingPathComponent("protected")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let first = try files.make("protected/first.gguf")
        let second = try files.make("second.gguf")
        let model = DS4ModelProfile.from(architecture: "deepseek4")
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            serverPath: files.server,
            modelPath: first,
            modelProfile: model
        )
        let previous = configuration.snapshot()
        var next = previous
        next.modelPath = second
        configuration.replace(with: next)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: first),
            "This process can traverse directories despite their permissions."
        )
        XCTAssertEqual(
            ServerConfiguration.Config.recentPathAvailability(
                first, field: .model, serverPath: files.server
            ),
            .unusable
        )
        configuration.recordAppliedSelections(
            previous: previous, previousModel: model, appliedModel: model
        )
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .model), [second, first])

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
    }

    /// A ds4-server executable and GGUF stand-ins in a throwaway directory.
    private struct TemporaryFiles {
        let directory: String
        let server: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dsmenubar-recents-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            server = (directory as NSString).appendingPathComponent("ds4-server")
            FileManager.default.createFile(
                atPath: server,
                contents: Data(),
                attributes: [.posixPermissions: 0o755]
            )
        }

        func make(_ name: String) throws -> String {
            let path = (directory as NSString).appendingPathComponent(name)
            try Data().write(to: URL(fileURLWithPath: path))
            return path
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }
}
