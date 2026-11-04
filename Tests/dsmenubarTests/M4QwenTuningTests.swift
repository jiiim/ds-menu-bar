// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import dsmenubar

final class M4QwenTuningTests: XCTestCase {
    private let q4Types: Set<UInt32> = [12, 39]
    // IQ2_XXS/Q2_K trunk, Q4_K/MXFP4 MTP layer.
    private let q2Types: Set<UInt32> = [10, 12, 16, 39]

    private func target(
        gpuIsM4: Bool = true,
        m4Defaults: Bool = false,
        legacyKernels: Bool = false,
        streamsQwen: Bool = false
    ) -> DS4LaunchTarget {
        DS4LaunchTarget(
            gpuIsM4: gpuIsM4,
            serverHasM4QwenDefaults: m4Defaults,
            serverHasLegacyM4QwenKernels: legacyKernels,
            serverStreamsQwenExperts: streamsQwen
        )
    }

    func testDeviceNameFollowsDS4sM4Test() {
        for name in ["Apple M4", "Apple M4 Pro", "Apple M4 Max"] {
            XCTAssertTrue(DS4M4QwenTuning.isM4(deviceName: name), name)
        }
        for name in ["", "Apple M3 Ultra", "Apple M5 Max", "Apple M40", "Apple M4Max", "AMD Radeon Pro"] {
            XCTAssertFalse(DS4M4QwenTuning.isM4(deviceName: name), name)
        }
    }

    func testSelectionFollowsTheBuild() {
        XCTAssertEqual(DS4M4QwenTuning.selection(for: target()), .full)
        XCTAssertEqual(DS4M4QwenTuning.selection(for: target(legacyKernels: true)), .compatible)
        XCTAssertEqual(DS4M4QwenTuning.selection(for: target(m4Defaults: true)), .none)
        XCTAssertEqual(DS4M4QwenTuning.selection(for: target(m4Defaults: true, legacyKernels: true)), .none)
        XCTAssertEqual(DS4M4QwenTuning.selection(for: target(gpuIsM4: false)), .none)
        XCTAssertEqual(DS4M4QwenTuning.selection(for: .unknown), .none)
    }

    func testBuildsWithoutM4TuningTakeEveryOverride() {
        let q4 = DS4M4QwenTuning.environment(routedExpertTypes: q4Types, target: target())
        XCTAssertEqual(q4.count, 12)
        XCTAssertEqual(q4["DS4_QWEN4_MOE_MV_NSG"], "16")
        XCTAssertEqual(q4["DS4_QWEN4_Q4K_MID_NR"], "1")
        XCTAssertEqual(Set(q4.keys), Set(DS4M4QwenTuning.environmentKeys))

        // Eight groups stay for the low-bit rows, and the Q4_K pair measured
        // flat on the Q2 pack's MTP layer.
        let q2 = DS4M4QwenTuning.environment(routedExpertTypes: q2Types, target: target())
        XCTAssertEqual(q2.count, 9)
        XCTAssertNil(q2["DS4_QWEN4_MOE_MV_NSG"])
        XCTAssertNil(q2["DS4_QWEN4_Q4K_MID_NR"])
        XCTAssertEqual(q2["DS4_QWEN4_MOE_MV_SPECIALIZE"], "1")
    }

    func testBuildsWithLegacyM4KernelsKeepThem() {
        let conflicting = Set(DS4M4QwenTuning.legacyConflictingEnvironment.keys)
            .union(DS4M4QwenTuning.mxfp4GroupEnvironment.keys)
        let q4 = DS4M4QwenTuning.environment(routedExpertTypes: q4Types, target: target(legacyKernels: true))
        XCTAssertEqual(q4.count, 8)
        XCTAssertTrue(Set(q4.keys).isDisjoint(with: conflicting))
        XCTAssertEqual(q4["DS4_QWEN4_Q4K_MID_NSG"], "4")

        let q2 = DS4M4QwenTuning.environment(routedExpertTypes: q2Types, target: target(legacyKernels: true))
        XCTAssertEqual(q2, DS4M4QwenTuning.compatibleEnvironment)
        XCTAssertEqual(q2.count, 6)
    }

    func testBuildsWithM4DefaultsOrOtherGPUsTakeNothing() {
        for types in [q4Types, q2Types] {
            XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: types, target: target(m4Defaults: true)), [:])
            XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: types, target: target(gpuIsM4: false)), [:])
        }
    }

    func testUnmeasuredOrMissingExpertTypesTakeNothing() {
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: nil, target: target()), [:])
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: [], target: target()), [:])
        // Q8_0 experts: no measurement covers forcing these choices on them.
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: [8, 12, 39], target: target()), [:])
    }

    func testQ4WarnsWhereItCannotLoadResident() throws {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let q4 = DS4ModelProfile(family: .qwen38, architecture: "qwen4exp", routedExpertTypes: q4Types)
        let q2 = DS4ModelProfile(family: .qwen38, architecture: "qwen4exp", routedExpertTypes: q2Types)
        let streaming = target(streamsQwen: true)
        func warning(_ model: DS4ModelProfile, _ gib: UInt64, on: DS4LaunchTarget, streamingOn: Bool = false) -> String? {
            model.residentMemoryWarning(
                ssdStreamingEnabled: streamingOn,
                target: on,
                physicalMemoryBytes: gib * gibibyte
            )
        }

        XCTAssertTrue(try XCTUnwrap(warning(q4, 64, on: streaming)).contains("Turn on SSD streaming"))
        XCTAssertTrue(try XCTUnwrap(warning(q4, 64, on: target())).contains("update ds4-server"))
        XCTAssertNil(warning(q4, 64, on: streaming, streamingOn: true))
        XCTAssertNil(warning(q4, 96, on: streaming))
        XCTAssertNil(warning(q2, 64, on: streaming))
        XCTAssertNil(warning(.from(architecture: "glm5-next"), 64, on: streaming))
    }

    func testInspectionReadsEachCapabilityFromTheExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ parts: [Data]) throws -> String {
            let url = directory.appendingPathComponent(name)
            try parts.reduce(Data("\0Apple M5\0Apple M3 Ultra\0".utf8), +).write(to: url)
            return url.path
        }

        let stock = try write("stock", [Data("Apple M4 Max\0".utf8)])
        XCTAssertEqual(
            DS4LaunchTarget.inspecting(serverPath: stock, gpuIsM4: true),
            target()
        )

        let legacy = try write("legacy", DS4LaunchTarget.legacyM4QwenKernelMarkers + [
            DS4LaunchTarget.qwenExpertStreamingMarker
        ])
        XCTAssertEqual(
            DS4LaunchTarget.inspecting(serverPath: legacy, gpuIsM4: true),
            target(legacyKernels: true, streamsQwen: true)
        )

        // A rename of the others must not make the build read as older.
        for (index, marker) in DS4LaunchTarget.legacyM4QwenKernelMarkers.enumerated() {
            let partial = try write("partial\(index)", [marker])
            XCTAssertTrue(DS4LaunchTarget.inspecting(serverPath: partial).serverHasLegacyM4QwenKernels)
        }

        let gated = try write("gated", [DS4LaunchTarget.m4QwenDefaultsMarker])
        XCTAssertTrue(DS4LaunchTarget.inspecting(serverPath: gated).serverHasM4QwenDefaults)

        let missing = directory.appendingPathComponent("missing").path
        XCTAssertEqual(
            DS4LaunchTarget.inspecting(serverPath: missing, gpuIsM4: false),
            .unknown
        )
    }
}
