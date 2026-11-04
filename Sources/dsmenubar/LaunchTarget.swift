// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The ds4-server executable a launch runs and the GPU it runs on.
///
/// The executable's capabilities are read from the file itself rather than
/// inferred from a reviewed ds4 commit: users update ds4-server and the app
/// independently, and the file at a path can be rebuilt between launches.
/// Each property records whether the file contains a string found only in
/// builds with that capability. A 3 MB ds4-server scans in a few milliseconds.
struct DS4LaunchTarget: Equatable, Sendable {
    var gpuIsM4: Bool
    /// ds4 compares the device name with "Apple M4" once antirez/ds4#1184
    /// gives M4 its own Qwen kernel defaults.
    var serverHasM4QwenDefaults: Bool
    /// The Qwen kernels ds4 runs on M2 to M4 since antirez/ds4#1056, which it
    /// calls its legacy tuning. Some of the overrides measured before them
    /// would switch them off.
    var serverHasLegacyM4QwenKernels: Bool
    /// Qwen routed-expert streaming from SSD, also from antirez/ds4#1056.
    var serverStreamsQwenExperts: Bool

    /// Nothing inspected: no M4 overrides, and no Qwen SSD streaming.
    static let unknown = Self(
        gpuIsM4: false,
        serverHasM4QwenDefaults: false,
        serverHasLegacyM4QwenKernels: false,
        serverStreamsQwenExperts: false
    )

    static let m4QwenDefaultsMarker = Data("Apple M4\u{0}".utf8)
    /// Strings #1056 added: the kernels that `DS4_QWEN4_MOE_MV_SPECIALIZE` and
    /// `DS4_QWEN4_HC_MIX_PREFETCH` turn off, and the device its policy names.
    /// Any one is enough: a build reading as older takes the overrides that
    /// slow MTP on these kernels, so a single upstream rename must not do that.
    static let legacyM4QwenKernelMarkers = [
        Data("kernel_qwen4_moe_mid_iq2_nr1".utf8),
        Data("kernel_qwen4_moe_down_q2k".utf8),
        Data("kernel_qwen4_hc_gate_mix_f16_reuse".utf8),
        Data("Apple M1 Max\u{0}".utf8),
    ]
    static let qwenExpertStreamingMarker = Data("ds4: Qwen SSD".utf8)

    /// An unreadable executable reads as having none of these; the launch
    /// fails on it either way.
    static func inspecting(
        serverPath path: String,
        gpuIsM4: Bool = DS4M4QwenTuning.gpuIsM4
    ) -> Self {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return Self(
                gpuIsM4: gpuIsM4,
                serverHasM4QwenDefaults: false,
                serverHasLegacyM4QwenKernels: false,
                serverStreamsQwenExperts: false
            )
        }
        return Self(
            gpuIsM4: gpuIsM4,
            serverHasM4QwenDefaults: data.range(of: m4QwenDefaultsMarker) != nil,
            serverHasLegacyM4QwenKernels: legacyM4QwenKernelMarkers.contains { data.range(of: $0) != nil },
            serverStreamsQwenExperts: data.range(of: qwenExpertStreamingMarker) != nil
        )
    }
}
