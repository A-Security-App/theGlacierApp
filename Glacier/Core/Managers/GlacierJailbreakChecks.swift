//
//  GlacierJailbreakChecks.swift
//  Glacier
//
//  Supplementary jailbreak indicators layered on top of IOSSecuritySuite.
//

import Foundation

/// Additional jailbreak fingerprints that IOSSecuritySuite 1.9.11 does not cover.
///
/// IOSSecuritySuite is pinned to 1.9.11 — the last BSD-2-Clause release; 2.x is
/// under a proprietary EULA (see `THIRD_PARTY_NOTICES.md`). That version predates
/// the modern *rootless* jailbreaks (palera1n rootless, Dopamine, XinaA15) which
/// install under `/var/jb` instead of the system root, and tools like TrollStore.
/// 1.9.11 checks the older `/jb/` location but not `/var/jb`, so those devices
/// slip past it. This type adds those markers.
///
/// It is purely **additive**: callers OR this result with
/// `IOSSecuritySuite.amIJailbrokenWithFailMessage()`, so it can only ever flag
/// *more*, never mask a real detection from the library.
///
/// All checks are read-only `stat` probes — no writes, no network — so this is
/// safe to run on every foreground and from a background queue. The filesystem
/// probe is injectable so the logic is unit-testable without a jailbroken device.
enum GlacierJailbreakChecks {

    struct Result {
        /// True when at least one supplementary indicator matched.
        let jailbroken: Bool
        /// Matched indicators (paths), for inclusion in `compromised_detail`.
        let indicators: [String]
    }

    /// Paths that only exist on a compromised device and that 1.9.11 misses.
    ///
    /// `/var/jb` is the rootless bind-mount root shared by palera1n (rootless),
    /// Dopamine, and XinaA15. The entries beneath it are common bootstrap
    /// artifacts. The TrollStore bundle paths are best-effort: TrollStore is a
    /// permanent-signing tool rather than a jailbreak, and sandboxed detection of
    /// it is inherently limited, but these locations are stat-able when present
    /// and never exist on a stock device (so they don't cause false positives).
    static let suspiciousPaths: [String] = [
        // Rootless jailbreak root + bootstrap artifacts.
        "/var/jb",
        "/var/jb/usr/bin/sshd",
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/var/jb/usr/lib/TweakInject",
        "/var/jb/etc/apt",
        "/var/jb/private/preboot",
        "/var/jb/Applications/Sileo.app",
        "/var/jb/Applications/Zebra.app",
        // TrollStore (best-effort; see note above).
        "/Applications/TrollStore.app",
        "/var/jb/Applications/TrollStore.app",
    ]

    /// Injectable existence probe. Signature matches a filesystem `stat`.
    typealias PathProbe = (String) -> Bool

    /// Runs the supplementary checks.
    /// - Parameter pathExists: existence probe; defaults to the live filesystem.
    static func run(pathExists: PathProbe = defaultPathExists) -> Result {
        let hits = suspiciousPaths.filter(pathExists)
        return Result(jailbroken: !hits.isEmpty, indicators: hits)
    }

    /// Live filesystem probe. `fileExists` uses `stat(2)` under the hood, so it
    /// reports paths the sandbox can see even when it cannot read them.
    static let defaultPathExists: PathProbe = { path in
        FileManager.default.fileExists(atPath: path)
    }
}
