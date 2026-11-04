// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// Qwen3.8 Metal kernel choices that ds4 makes by default on M3 Ultra and M5
/// but not on M4, turned on through the `DS4_*` override each one already
/// has. Choices that ds4 scopes by batch or matrix size have no such override.
///
/// Which overrides a launch sets depends on the ds4-server build:
///
/// - Before antirez/ds4#1056 (no M4 Qwen tuning at all): every override.
///   Measured on an M4 Max, mean over contexts 2,048 to 65,536: Q4 prefill
///   +8.4%, decode +9.0%, embedded MTP +8.7-8.8%; Q2 prefill +9.9%, decode
///   +6.3%, MTP +4.1-4.5%, with identical output.
/// - From #1056 on, ds4 runs its own M2-M4 Qwen kernels, and the overrides
///   in `legacyConflictingEnvironment` and `mxfp4GroupEnvironment` would
///   switch some of them off. With all of them set, Q2 generation with MTP
///   measured 1.6-2.1% slower than stock. Without them, mean over 2,048 to
///   16,384: prefill +8.4% on both packs, decode +2.3-3.2%, MTP +0.1-1.3%.
/// - With antirez/ds4#1184 (M4 Qwen defaults of its own): none.
enum DS4M4QwenTuning {
    /// GGML types of the routed-expert tensors in the measured packs.
    enum ExpertType {
        static let q2K: UInt32 = 10
        static let q4K: UInt32 = 12
        static let iq2XXS: UInt32 = 16
        static let mxfp4: UInt32 = 39
        static let measured: Set<UInt32> = [q2K, q4K, iq2XXS, mxfp4]
        static let lowBit: Set<UInt32> = [q2K, iq2XXS]
    }

    /// Overrides that match the M3 Ultra or M5 choice for every measured
    /// expert type and leave ds4's own M2-M4 kernels in place.
    static let compatibleEnvironment: [String: String] = [
        "DS4_QWEN4_MOE_MM_SPECIALIZE": "1",
        "DS4_QWEN4_MOE_TAILS": "1",
        "DS4_QWEN4_HC_PAIR_NSG": "16",
        "DS4_QWEN4_IDX_SCORE_VEC": "1",
        "DS4_QWEN4_ATTN_MERGE_WIDE": "1",
        // ds4 also reads this one in the Q8_0 prefill that DeepSeek and GLM
        // use, which is why only Qwen launches receive it.
        "DS4_QWEN4_Q8_PREFILL_UNPACK": "1",
    ]

    /// Overrides that replace ds4's M2-M4 kernels with the M5 ones:
    /// specialization turns off the IQ2_XXS gate/up rows, the Q2_K down-row
    /// reuse and the paired MXFP4 rows of multi-token batches, and the HC
    /// prefetch turns off the HC gate-mix reuse kernel. They win single-token
    /// decode and lose the MTP verifier's two- and three-row batches.
    static let legacyConflictingEnvironment: [String: String] = [
        "DS4_QWEN4_MOE_MV_SPECIALIZE": "1",
        "DS4_QWEN4_MOE_DOWN_PREFETCH": "1",
        "DS4_QWEN4_HC_MIX_PREFETCH": "1",
    ]

    /// Sixteen SIMD groups for specialized MXFP4 down rows. The override
    /// covers every specialized expert type, and ds4 keeps eight for IQ2_XXS
    /// and Q2_K, so only the Q4 pack takes it. It applies only with
    /// specialization, so it goes with `legacyConflictingEnvironment`.
    static let mxfp4GroupEnvironment = ["DS4_QWEN4_MOE_MV_NSG": "16"]

    /// One row per SIMD group, four groups, in the Q4_K gate/up matvec, for
    /// the Q4 pack. ds4's M3 Ultra and M5 default limits it to one or two
    /// rows, or three in the exact MTP verifier; the override also reaches
    /// the other batches of up to eight rows that session batching produces,
    /// where dot-product order is unchanged and speed is unmeasured. The Q2
    /// pack's MTP layer is Q4_K too, but there the pair measured flat, so Q2
    /// launches leave it out.
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

    /// Which overrides a launch on `target` takes.
    enum Selection: Equatable, Sendable {
        /// Not an M4, or the build has M4 Qwen defaults of its own.
        case none
        /// Every override: a build without ds4's M2-M4 Qwen kernels.
        case full
        /// The overrides that leave ds4's M2-M4 Qwen kernels in place.
        case compatible
    }

    static func selection(for target: DS4LaunchTarget) -> Selection {
        guard target.gpuIsM4, !target.serverHasM4QwenDefaults else { return .none }
        return target.serverHasLegacyM4QwenKernels ? .compatible : .full
    }

    /// The overrides for a model's routed-expert types on `target`, or none
    /// when a type falls outside the measured set: forcing a specialization
    /// ds4 has not chosen for that type on any GPU is not something these
    /// numbers cover.
    static func environment(
        routedExpertTypes: Set<UInt32>?,
        target: DS4LaunchTarget
    ) -> [String: String] {
        let selection = selection(for: target)
        guard selection != .none,
              let types = routedExpertTypes, !types.isEmpty,
              types.isSubset(of: ExpertType.measured) else { return [:] }
        let q4Pack = types.isDisjoint(with: ExpertType.lowBit)
        var environment = compatibleEnvironment
        if q4Pack {
            environment.merge(q4KGateUpEnvironment) { _, added in added }
        }
        if selection == .full {
            environment.merge(legacyConflictingEnvironment) { _, added in added }
            if q4Pack {
                environment.merge(mxfp4GroupEnvironment) { _, added in added }
            }
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
}
