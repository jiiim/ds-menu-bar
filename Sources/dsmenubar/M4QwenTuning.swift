// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// Qwen3.8 Metal kernel choices that ds4 makes by default on M3 Ultra and M5
/// but, before antirez/ds4#1184, not on M4.
///
/// Each choice already has a `DS4_*` override that turns it on for any GPU,
/// so a stock ds4-server gets it on M4 when the launch sets that variable.
/// Only overrides that reproduce #1184's M4 default are set. Choices that
/// ds4 scopes by batch or matrix size have no such override and stay with
/// ds4-servers that include #1184, as do its DeepSeek changes.
///
/// Measured on an M4 Max against stock ds4 (mean over contexts 2,048 to
/// 65,536): Qwen3.8 Flash Next Q4 prefill +8.4%, decode +9.0%, embedded MTP
/// +8.7-8.8%; Q2 prefill +9.9%, decode +6.3%, MTP +4.1-4.5%. That is 91-99%
/// of what #1184 gives, with identical output.
enum DS4M4QwenTuning {
    /// GGML types of the routed-expert tensors in the measured packs.
    enum ExpertType {
        static let q2K: UInt32 = 10
        static let q4K: UInt32 = 12
        static let iq2XXS: UInt32 = 16
        static let mxfp4: UInt32 = 39
        static let measured: Set<UInt32> = [q2K, q4K, iq2XXS, mxfp4]
    }

    /// Overrides that match ds4's M4 choice for every measured expert type.
    static let sharedEnvironment: [String: String] = [
        "DS4_QWEN4_MOE_MV_SPECIALIZE": "1",
        "DS4_QWEN4_MOE_DOWN_PREFETCH": "1",
        "DS4_QWEN4_MOE_MM_SPECIALIZE": "1",
        "DS4_QWEN4_MOE_TAILS": "1",
        "DS4_QWEN4_HC_MIX_PREFETCH": "1",
        "DS4_QWEN4_HC_PAIR_NSG": "16",
        "DS4_QWEN4_IDX_SCORE_VEC": "1",
        "DS4_QWEN4_ATTN_MERGE_WIDE": "1",
        // ds4 also reads this one in the Q8_0 prefill that DeepSeek and GLM
        // use, which is why only Qwen launches receive it.
        "DS4_QWEN4_Q8_PREFILL_UNPACK": "1",
    ]

    /// Sixteen SIMD groups for MXFP4 down rows. The override covers every
    /// specialized expert type, and on M4 ds4 keeps eight for IQ2_XXS and
    /// Q2_K, so it is set only for the Q4 pack.
    static let mxfp4GroupEnvironment = ["DS4_QWEN4_MOE_MV_NSG": "16"]

    /// One row per SIMD group, four groups, in the Q4_K gate/up matvec, for
    /// the Q4 pack. ds4's M4 default limits it to one or two rows, or three
    /// in the exact MTP verifier; the override also reaches the other batches
    /// of up to eight rows that session batching produces, where dot-product
    /// order is unchanged and speed is unmeasured. The Q2 pack's MTP layer is
    /// Q4_K too, but there the pair measured flat (+0.16% on prose, within
    /// noise on code), so Q2 launches leave it out.
    static let q4KGateUpEnvironment = [
        "DS4_QWEN4_Q4K_MID_NR": "1",
        "DS4_QWEN4_Q4K_MID_NSG": "4",
    ]

    /// Every key this type can set, in the order logs and previews list them.
    static let environmentKeys = [
        "DS4_QWEN4_MOE_MV_SPECIALIZE",
        "DS4_QWEN4_MOE_MV_NSG",
        "DS4_QWEN4_MOE_DOWN_PREFETCH",
        "DS4_QWEN4_MOE_MM_SPECIALIZE",
        "DS4_QWEN4_MOE_TAILS",
        "DS4_QWEN4_Q4K_MID_NR",
        "DS4_QWEN4_Q4K_MID_NSG",
        "DS4_QWEN4_HC_MIX_PREFETCH",
        "DS4_QWEN4_HC_PAIR_NSG",
        "DS4_QWEN4_IDX_SCORE_VEC",
        "DS4_QWEN4_ATTN_MERGE_WIDE",
        "DS4_QWEN4_Q8_PREFILL_UNPACK",
    ]

    /// The overrides for a model's routed-expert types, or none when a type
    /// falls outside the measured set: forcing a specialization ds4 has not
    /// chosen for that type on any GPU is not something these numbers cover.
    static func environment(routedExpertTypes: Set<UInt32>?) -> [String: String] {
        guard let types = routedExpertTypes, !types.isEmpty,
              types.isSubset(of: ExpertType.measured) else { return [:] }
        var environment = sharedEnvironment
        if types.isDisjoint(with: [ExpertType.q2K, ExpertType.iq2XXS]) {
            environment.merge(mxfp4GroupEnvironment) { _, added in added }
            environment.merge(q4KGateUpEnvironment) { _, added in added }
        }
        return environment
    }

    /// ds4's own test: the Metal device name begins with "Apple M4" and the
    /// next character, if any, is a space. M4, M4 Pro, and M4 Max all match.
    static func isM4(deviceName: String) -> Bool {
        guard deviceName.hasPrefix("Apple M4") else { return false }
        let rest = deviceName.dropFirst("Apple M4".count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    /// The GPU does not change while the app runs, so it is read once.
    static let gpuIsM4: Bool = MTLCreateSystemDefaultDevice().map { isM4(deviceName: $0.name) } ?? false

    /// The string ds4 compares the device name against once its own M4
    /// defaults include these choices. Stock builds before #1184 contain
    /// "Apple M5" and "M3 Ultra" but not this.
    static let serverM4Marker = Data("Apple M4\u{0}".utf8)

    /// Whether the executable at `path` carries its own M4 defaults. Read on
    /// every launch, because the file at a path can be rebuilt between
    /// launches; a 3 MB ds4-server scans in a few milliseconds. An unreadable
    /// file counts as stock: the launch fails on it either way.
    static func serverHasM4Defaults(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return false
        }
        return data.range(of: serverM4Marker) != nil
    }

    /// Whether a launch of the executable at `path` on this Mac takes the
    /// overrides. The executable is scanned only on an M4.
    static func applies(toServerAt path: String, gpuIsM4: Bool = Self.gpuIsM4) -> Bool {
        gpuIsM4 && !serverHasM4Defaults(atPath: path)
    }
}
