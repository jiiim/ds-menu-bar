// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// The status menu must never read a GGUF header on its own thread: the cheap
/// description is published first, and the type arrives from a background
/// read, primed by the profile Apply already inspected.
@MainActor
final class ActiveModelRefreshTests: XCTestCase {

    func testRefreshPublishesTheCheapDescriptionBeforeInspecting() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }

        harness.manager.refreshActiveModelInfo()

        XCTAssertEqual(harness.manager.activeModelInfo.fileName, "model.gguf")
        XCTAssertTrue(harness.manager.activeModelInfo.isAvailable)
        XCTAssertFalse(harness.manager.activeModelInfo.isInspected)
        XCTAssertEqual(harness.counter.value, 0)

        await waitForInspection(harness.manager)

        XCTAssertTrue(harness.manager.activeModelInfo.isInspected)
        XCTAssertEqual(
            harness.manager.activeModelInfo.typeName,
            "Qwen3.8 Flash Next"
        )
        XCTAssertEqual(harness.counter.value, 1)
    }

    func testRefreshReusesTheCachedDescriptionForAnUnchangedFile() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }
        harness.manager.refreshActiveModelInfo()
        await waitForInspection(harness.manager)

        harness.manager.refreshActiveModelInfo()

        XCTAssertTrue(harness.manager.activeModelInfo.isInspected)
        XCTAssertEqual(harness.counter.value, 1)
    }

    func testApplyPrimesTheDescriptionFromTheInspectedProfile() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }
        let profile = DS4ModelProfile.from(architecture: "qwen4exp")
        let draft = harness.manager.configurationSnapshot()
        let history = await harness.manager.inspectModelHistory(for: draft, model: profile)

        let result = harness.manager.applyConfiguration(
            draft,
            inspected: ServerManager.InspectedProfiles(
                model: profile,
                support: .unavailable,
                vision: .unavailable
            ),
            history: history
        )

        guard case .applied = result.kind else {
            return XCTFail("expected the configuration to apply: \(result.kind)")
        }
        XCTAssertTrue(harness.manager.activeModelInfo.isInspected)
        XCTAssertEqual(
            harness.manager.activeModelInfo.typeName,
            "Qwen3.8 Flash Next"
        )
        XCTAssertEqual(harness.counter.value, 0)
    }

    func testApplyRecordsRecentPathsAndAnUnappliedDraftDoesNot() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }
        let profile = DS4ModelProfile.from(architecture: "qwen4exp")
        let second = try harness.makeModel(named: "second.gguf")
        let vision = try harness.makeModel(named: "vision.gguf")
        var draft = harness.manager.configurationSnapshot()
        draft.modelPath = second.path
        draft.visionEnabled = true
        draft.visionPath = vision.path
        XCTAssertEqual(
            harness.manager.recentSelections.recentPaths(for: .model),
            [harness.model.path]
        )

        let history = await harness.manager.inspectModelHistory(for: draft, model: profile)
        let result = harness.manager.applyConfiguration(
            draft,
            inspected: ServerManager.InspectedProfiles(
                model: profile,
                support: .unavailable,
                vision: DS4VisionProfile(
                    kind: .qwen38,
                    architecture: "clip",
                    projectionDimension: nil
                )
            ),
            history: history
        )

        guard case .applied = result.kind else {
            return XCTFail("expected the configuration to apply: \(result.kind)")
        }
        XCTAssertEqual(
            harness.manager.recentSelections.recentPaths(for: .model),
            [second.path, harness.model.path]
        )
        XCTAssertEqual(
            harness.manager.recentSelections.recentPaths(
                for: .vision,
                scope: profile.recentResourceScope
            ),
            [vision.path]
        )
        // The model changed, so the previous one's profile was read to file
        // whatever resources it used.
        XCTAssertEqual(harness.counter.value, 1)
    }

    func testMissingFileIsReportedWithoutInspectionAndRefreshesWhenItAppears() async throws {
        let harness = try Harness(architecture: "qwen4exp", writeModel: false)
        defer { harness.tearDown() }

        harness.manager.refreshActiveModelInfo()
        XCTAssertFalse(harness.manager.activeModelInfo.isAvailable)
        XCTAssertEqual(harness.counter.value, 0)

        try harness.writeModel()
        harness.manager.refreshActiveModelInfo()
        XCTAssertFalse(harness.manager.activeModelInfo.isInspected)

        await waitForInspection(harness.manager)

        XCTAssertTrue(harness.manager.activeModelInfo.isAvailable)
        XCTAssertTrue(harness.manager.activeModelInfo.isInspected)
        XCTAssertEqual(harness.counter.value, 1)
    }

    func testChangingModelsDoesNotInspectTheOutgoingModelOnMainThread() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }
        let second = try harness.makeModel(named: "second.gguf")
        let vision = try harness.makeModel(named: "previous-vision.gguf")
        var previous = harness.manager.configurationSnapshot()
        previous.visionEnabled = true
        previous.visionPath = vision.path
        harness.configuration.replace(with: previous)
        var draft = previous
        draft.modelPath = second.path
        draft.visionEnabled = false
        let profile = DS4ModelProfile.from(architecture: "qwen4exp")
        let history = await harness.manager.inspectModelHistory(for: draft, model: profile)

        let result = harness.manager.applyConfiguration(
            draft,
            inspected: .init(
                model: profile,
                support: .unavailable,
                vision: .unavailable
            ),
            history: history
        )

        guard case .applied = result.kind else {
            return XCTFail("expected the configuration to apply: \(result.kind)")
        }
        XCTAssertEqual(harness.counter.value, 1)
        XCTAssertEqual(harness.counter.mainThreadValue, 0)
        XCTAssertEqual(harness.manager.recentSelections.recentPaths(for: .model), [
            second.path, harness.model.path,
        ])
        XCTAssertEqual(
            harness.manager.recentSelections.recentPaths(
                for: .vision, scope: profile.recentResourceScope
            ),
            [vision.path]
        )
    }

    func testChangingModelsReusesTheOutgoingModelsCachedProfile() async throws {
        let harness = try Harness(architecture: "qwen4exp")
        defer { harness.tearDown() }
        harness.manager.refreshActiveModelInfo()
        await waitForInspection(harness.manager)
        let second = try harness.makeModel(named: "second.gguf")
        var draft = harness.manager.configurationSnapshot()
        draft.modelPath = second.path
        let profile = DS4ModelProfile.from(architecture: "qwen4exp")

        let history = await harness.manager.inspectModelHistory(for: draft, model: profile)
        let result = harness.manager.applyConfiguration(
            draft,
            inspected: .init(model: profile, support: .unavailable, vision: .unavailable),
            history: history
        )

        guard case .applied = result.kind else {
            return XCTFail("expected the configuration to apply: \(result.kind)")
        }
        XCTAssertEqual(harness.counter.value, 1)
        XCTAssertEqual(harness.manager.configurationSnapshot().modelPath, second.path)
    }

    func testHistoryInspectionDoesNotMutateStateAndAStaleApplyIsRefused() async throws {
        let harness = try Harness(architecture: "qwen4exp", waitsForGate: true)
        defer { harness.tearDown() }
        let second = try harness.makeModel(named: "second.gguf")
        let third = try harness.makeModel(named: "third.gguf")
        let previous = harness.manager.configurationSnapshot()
        let recents = harness.manager.recentSelections
        var draft = previous
        draft.modelPath = second.path
        let candidate = draft
        let profile = DS4ModelProfile.from(architecture: "qwen4exp")
        let inspection = Task {
            await harness.manager.inspectModelHistory(for: candidate, model: profile)
        }
        await waitForInspectionStart(harness)
        XCTAssertEqual(harness.manager.configurationSnapshot(), previous)
        XCTAssertEqual(harness.manager.recentSelections, recents)

        harness.setModel(third.path)
        harness.gate.release()
        let history = await inspection.value
        XCTAssertEqual(harness.manager.configurationSnapshot().modelPath, third.path)
        XCTAssertEqual(harness.manager.recentSelections, recents)

        let result = harness.manager.applyConfiguration(
            candidate,
            inspected: .init(model: profile, support: .unavailable, vision: .unavailable),
            history: history
        )

        guard case .invalid = result.kind else {
            return XCTFail("expected the stale configuration to be refused: \(result.kind)")
        }
        XCTAssertEqual(harness.manager.configurationSnapshot().modelPath, third.path)
        XCTAssertEqual(harness.manager.recentSelections, recents)
    }

    func testALateInspectionCannotOverwriteAPrimedDescription() async throws {
        let harness = try Harness(architecture: "qwen4exp", waitsForGate: true)
        defer { harness.tearDown() }

        harness.manager.refreshActiveModelInfo()
        await waitForInspectionStart(harness)

        let primed = DS4ModelProfile.from(architecture: "glm5-next")
        let draft = harness.manager.configurationSnapshot()
        let history = await harness.manager.inspectModelHistory(for: draft, model: primed)
        let result = harness.manager.applyConfiguration(
            draft,
            inspected: ServerManager.InspectedProfiles(
                model: primed,
                support: .unavailable,
                vision: .unavailable
            ),
            history: history
        )
        guard case .applied = result.kind else {
            return XCTFail("expected the configuration to apply: \(result.kind)")
        }
        XCTAssertEqual(harness.manager.activeModelInfo.typeName, "GLM 5.3 Flash")

        harness.gate.release()
        await assertDescriptionStays(
            typeName: "GLM 5.3 Flash",
            fileName: "model.gguf",
            in: harness
        )
    }

    func testAMissingFileRefreshInvalidatesAPendingInspection() async throws {
        let harness = try Harness(architecture: "qwen4exp", waitsForGate: true)
        defer { harness.tearDown() }

        harness.manager.refreshActiveModelInfo()
        await waitForInspectionStart(harness)

        harness.setModel("/nowhere/absent.gguf")
        harness.manager.refreshActiveModelInfo()
        XCTAssertFalse(harness.manager.activeModelInfo.isAvailable)

        harness.gate.release()
        await assertDescriptionStays(
            typeName: nil,
            fileName: "absent.gguf",
            available: false,
            in: harness
        )
    }

    func testACacheHitInvalidatesAPendingInspectionForAnotherFile() async throws {
        let harness = try Harness(architecture: "qwen4exp", waitsForGate: true)
        defer { harness.tearDown() }
        let primed = DS4ModelProfile.from(architecture: "glm5-next")
        let draft = harness.manager.configurationSnapshot()
        let history = await harness.manager.inspectModelHistory(for: draft, model: primed)
        _ = harness.manager.applyConfiguration(
            draft,
            inspected: ServerManager.InspectedProfiles(
                model: primed,
                support: .unavailable,
                vision: .unavailable
            ),
            history: history
        )
        XCTAssertEqual(harness.manager.activeModelInfo.typeName, "GLM 5.3 Flash")

        let other = try harness.makeModel(named: "other.gguf")
        harness.setModel(other.path)
        harness.manager.refreshActiveModelInfo()
        await waitForInspectionStart(harness)
        XCTAssertFalse(harness.manager.activeModelInfo.isInspected)

        harness.setModel(harness.model.path)
        harness.manager.refreshActiveModelInfo()
        XCTAssertEqual(harness.manager.activeModelInfo.typeName, "GLM 5.3 Flash")

        harness.gate.release()
        await assertDescriptionStays(
            typeName: "GLM 5.3 Flash",
            fileName: "model.gguf",
            in: harness
        )
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let directory: URL
        let configuration: ServerConfiguration
        let manager: ServerManager
        let counter = InspectionCounter()
        let gate = InspectionGate()
        let model: URL
        private let architecture: String
        private let waitsForGate: Bool
        private let suiteName: String

        init(
            architecture: String,
            writeModel: Bool = true,
            waitsForGate: Bool = false
        ) throws {
            self.architecture = architecture
            self.waitsForGate = waitsForGate
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dsmenubar-active-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            model = directory.appendingPathComponent("model.gguf")
            if writeModel {
                try Self.makeGGUF(architecture: architecture).write(to: model)
            }

            suiteName = "dsmenubar-active-model-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let configuration = ServerConfiguration(defaults: defaults)
            self.configuration = configuration
            configuration.completeInitialSetup(
                serverPath: directory.appendingPathComponent("ds4-server").path,
                modelPath: model.path,
                modelProfile: DS4ModelProfile.from(architecture: architecture)
            )

            let counter = self.counter
            let gate = self.gate
            let waits = self.waitsForGate
            manager = ServerManager(
                config: configuration,
                inspectModelProfile: { _ in
                    counter.increment()
                    if waits { gate.wait() }
                    return DS4ModelProfile.from(architecture: architecture)
                }
            )
        }

        func makeModel(named name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Self.makeGGUF(architecture: architecture).write(to: url)
            return url
        }

        func setModel(_ path: String) {
            var values = configuration.snapshot()
            values.modelPath = path
            configuration.replace(with: values)
        }

        func writeModel() throws {
            try Self.makeGGUF(architecture: architecture).write(to: model)
        }

        func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        private static func makeGGUF(architecture: String) -> Data {
            var data = Data([0x47, 0x47, 0x55, 0x46])
            append(UInt32(3), to: &data)
            append(UInt64(0), to: &data)
            append(UInt64(1), to: &data)
            append(utf8: "general.architecture", to: &data)
            append(UInt32(8), to: &data)
            append(utf8: architecture, to: &data)
            return data
        }

        private static func append(utf8 value: String, to data: inout Data) {
            let bytes = Array(value.utf8)
            append(UInt64(bytes.count), to: &data)
            data.append(contentsOf: bytes)
        }

        private static func append(_ value: UInt32, to data: inout Data) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
        }

        private static func append(_ value: UInt64, to data: inout Data) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
        }
    }

    private final class InspectionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var mainThreadCount = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            if Thread.isMainThread { mainThreadCount += 1 }
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var mainThreadValue: Int {
            lock.lock()
            defer { lock.unlock() }
            return mainThreadCount
        }
    }

    private final class InspectionGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            semaphore.wait()
        }

        func release() {
            semaphore.signal()
        }
    }

    private func waitForInspection(_ manager: ServerManager) async {
        for _ in 0..<400 {
            if manager.activeModelInfo.isInspected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the model inspection did not finish")
    }

    private func waitForInspectionStart(_ harness: Harness) async {
        for _ in 0..<400 {
            if harness.counter.value >= 1 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the model inspection did not start")
    }

    /// The description must not change again once the released read lands.
    private func assertDescriptionStays(
        typeName: String?,
        fileName: String,
        available: Bool = true,
        in harness: Harness
    ) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(harness.manager.activeModelInfo.typeName, typeName)
            XCTAssertEqual(harness.manager.activeModelInfo.fileName, fileName)
            XCTAssertEqual(harness.manager.activeModelInfo.isAvailable, available)
        }
    }
}
