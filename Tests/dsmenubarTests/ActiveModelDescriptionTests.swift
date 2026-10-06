// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

final class ActiveModelDescriptionTests: XCTestCase {

    func testKnownFamilyReportsItsTypeName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("Qwen3.8-Flash-Next-Q4.gguf")
        try makeGGUF(architecture: "qwen4exp").write(to: model)

        let info = describe(
            modelPath: model.path,
            serverPath: directory.appendingPathComponent("ds4-server").path
        )

        XCTAssertTrue(info.isAvailable)
        XCTAssertTrue(info.isInspected)
        XCTAssertEqual(info.typeName, "Qwen3.8 Flash Next")
        XCTAssertEqual(info.fileName, "Qwen3.8-Flash-Next-Q4.gguf")
        XCTAssertEqual(info.resolvedPath, model.path)
    }

    func testRelativeModelPathResolvesAgainstTheServerDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ggufDirectory = directory.appendingPathComponent("gguf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ggufDirectory,
            withIntermediateDirectories: true
        )
        let model = ggufDirectory.appendingPathComponent("glm.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: model)

        let info = describe(
            modelPath: "gguf/glm.gguf",
            serverPath: directory.appendingPathComponent("ds4-server").path
        )

        XCTAssertTrue(info.isAvailable)
        XCTAssertEqual(info.typeName, "GLM 5.3 Flash")
        XCTAssertEqual(info.resolvedPath, model.path)
    }

    func testUnrecognisedArchitectureHasNoTypeName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("mystery.gguf")
        try makeGGUF(architecture: "mystery-arch").write(to: model)

        let info = describe(
            modelPath: model.path,
            serverPath: directory.appendingPathComponent("ds4-server").path
        )

        XCTAssertTrue(info.isAvailable)
        XCTAssertTrue(info.isInspected)
        XCTAssertNil(info.typeName)
        XCTAssertEqual(info.fileName, "mystery.gguf")
    }

    func testMissingFileReportsTheConfiguredName() {
        let info = describe(
            modelPath: "/nowhere/absent.gguf",
            serverPath: "/nowhere/ds4-server"
        )

        XCTAssertFalse(info.isAvailable)
        XCTAssertNil(info.typeName)
        XCTAssertEqual(info.fileName, "absent.gguf")
        XCTAssertEqual(info.resolvedPath, "/nowhere/absent.gguf")
    }

    func testPlaceholderCarriesTheCheapFactsWithoutInspecting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "qwen4exp").write(to: model)

        let location = ActiveModelDescription.locate(
            modelPath: model.path,
            serverPath: directory.appendingPathComponent("ds4-server").path
        )
        let placeholder = ActiveModelDescription.placeholder(location: location)

        XCTAssertFalse(placeholder.isInspected)
        XCTAssertTrue(placeholder.isAvailable)
        XCTAssertNil(placeholder.typeName)
        XCTAssertEqual(placeholder.fileName, "model.gguf")
        XCTAssertEqual(placeholder.resolvedPath, model.path)
    }

    func testCacheMatchesOnlyTheLocationItWasStoredFor() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "qwen4exp").write(to: model)
        let serverPath = directory.appendingPathComponent("ds4-server").path
        let first = ActiveModelDescription.locate(
            modelPath: model.path,
            serverPath: serverPath
        )
        let info = describe(modelPath: model.path, serverPath: serverPath)
        let cache = ActiveModelCache()
        cache.store(info, for: first)
        XCTAssertEqual(cache.cachedInfo(for: first), info)

        try makeGGUF(architecture: "glm5-next").write(to: model)
        let second = ActiveModelDescription.locate(
            modelPath: model.path,
            serverPath: serverPath
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNil(cache.cachedInfo(for: second))
    }

    func testSymbolicLinkIdentityFollowsTheTarget() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.gguf")
        let link = directory.appendingPathComponent("link.gguf")
        try makeGGUF(architecture: "qwen4exp").write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let serverPath = directory.appendingPathComponent("ds4-server").path

        let before = ActiveModelDescription.locate(
            modelPath: link.path,
            serverPath: serverPath
        )
        try makeGGUF(architecture: "glm5-next").write(to: target)
        let after = ActiveModelDescription.locate(
            modelPath: link.path,
            serverPath: serverPath
        )

        XCTAssertEqual(before.resolvedPath, link.path)
        XCTAssertNotEqual(before.identity, after.identity)
        XCTAssertEqual(
            describe(modelPath: link.path, serverPath: serverPath).typeName,
            "GLM 5.3 Flash"
        )
    }

    // MARK: - Fixtures

    private func describe(modelPath: String, serverPath: String) -> ActiveModelInfo {
        let location = ActiveModelDescription.locate(
            modelPath: modelPath,
            serverPath: serverPath
        )
        let profile = GGUFModelInspector.profile(for: location.resolvedPath)
        return ActiveModelDescription.make(location: location, profile: profile)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-active-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// The header `GGUFModelInspector` needs to recognise a family: magic, a
    /// version, no tensors, and `general.architecture`.
    private func makeGGUF(architecture: String) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        append(UInt32(3), to: &data)
        append(UInt64(0), to: &data)
        append(UInt64(1), to: &data)
        append(utf8: "general.architecture", to: &data)
        append(UInt32(8), to: &data)
        append(utf8: architecture, to: &data)
        return data
    }

    private func append(utf8 value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    private func append(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }
}
