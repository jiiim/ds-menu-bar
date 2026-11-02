// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import dsmenubar

final class M4QwenTuningTests: XCTestCase {
    func testDeviceNameFollowsDS4sM4Test() {
        for name in ["Apple M4", "Apple M4 Pro", "Apple M4 Max"] {
            XCTAssertTrue(DS4M4QwenTuning.isM4(deviceName: name), name)
        }
        for name in ["", "Apple M3 Ultra", "Apple M5 Max", "Apple M40", "Apple M4Max", "AMD Radeon Pro"] {
            XCTAssertFalse(DS4M4QwenTuning.isM4(deviceName: name), name)
        }
    }

    func testQ4PackTakesTheMXFP4GroupsAndTheQ4KPair() {
        let environment = DS4M4QwenTuning.environment(routedExpertTypes: [12, 39])
        XCTAssertEqual(environment.count, 12)
        XCTAssertEqual(environment["DS4_QWEN4_MOE_MV_NSG"], "16")
        XCTAssertEqual(environment["DS4_QWEN4_Q4K_MID_NR"], "1")
        XCTAssertEqual(environment["DS4_QWEN4_Q4K_MID_NSG"], "4")
        XCTAssertEqual(Set(environment.keys), Set(DS4M4QwenTuning.environmentKeys))
    }

    func testQ2PackTakesOnlyTheSharedSet() {
        // IQ2_XXS/Q2_K trunk, Q4_K/MXFP4 MTP layer: eight groups stay for the
        // low-bit rows, and the Q4_K pair measured flat on the MTP layer.
        XCTAssertEqual(
            DS4M4QwenTuning.environment(routedExpertTypes: [10, 12, 16, 39]),
            DS4M4QwenTuning.sharedEnvironment
        )
        XCTAssertEqual(DS4M4QwenTuning.sharedEnvironment.count, 9)
    }

    func testUnmeasuredOrMissingExpertTypesTakeNothing() {
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: nil), [:])
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: []), [:])
        // Q8_0 experts: no measurement covers forcing these choices on them.
        XCTAssertEqual(DS4M4QwenTuning.environment(routedExpertTypes: [8, 12, 39]), [:])
    }

    func testServerScanFindsTheM4MarkerOnlyAsAString() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-m4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stock = directory.appendingPathComponent("stock")
        try Data("\0Apple M5\0M3 Ultra\0Apple M4 Max\0".utf8).write(to: stock)
        XCTAssertFalse(DS4M4QwenTuning.serverHasM4Defaults(atPath: stock.path))

        let gated = directory.appendingPathComponent("gated")
        try (Data("\0Apple M5\0".utf8) + DS4M4QwenTuning.serverM4Marker + Data("M3 Ultra\0".utf8))
            .write(to: gated)
        XCTAssertTrue(DS4M4QwenTuning.serverHasM4Defaults(atPath: gated.path))

        let missing = directory.appendingPathComponent("missing").path
        XCTAssertFalse(DS4M4QwenTuning.serverHasM4Defaults(atPath: missing))

        XCTAssertTrue(DS4M4QwenTuning.applies(toServerAt: stock.path, gpuIsM4: true))
        XCTAssertFalse(DS4M4QwenTuning.applies(toServerAt: gated.path, gpuIsM4: true))
        XCTAssertFalse(DS4M4QwenTuning.applies(toServerAt: stock.path, gpuIsM4: false))
    }
}
