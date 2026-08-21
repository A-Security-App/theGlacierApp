//
//  DNSProfileHealer.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 Repoints devices that are stuck on the shared backup DNS profile at the user's own profile.

 `getDNSProfile` used to substitute the hard-coded backup profile whenever the account had no
 `profile_id` yet (or the fetch failed). That string was stored permanently and never re-fetched,
 so the device kept resolving through a profile that isn't the user's: DNS worked and filtered, so
 nothing looked broken except a tracker count frozen at zero and the user's own blocklist settings
 never applying. Reinstalling was the only fix anyone found. Failing closed stopped new devices
 from being pinned; this heals the ones already stuck.

 The rules it follows, in order of how much they matter:

 - **It only ever acts on a configuration that is pinned to the backup profile.** A device already
   on its own profile is never touched, so a wrong, empty, or rotated `profile_id` from the server
   cannot migrate the fleet off working profiles — the blast radius is limited to devices that are
   already misconfigured.
 - **It never writes a configuration it can't justify.** No personal profile available means leave
   the working fallback exactly as it is and try again later. `users/get` both reports *and*
   provisions, so an account with no profile today often has one on the next attempt — which is why
   this retries across launches instead of running once.
 - **It verifies, and reverts if the swap didn't take.** These devices are filtering through the
   shared profile today; a heal that left them resolving through nothing would be worse than the
   bug it fixes.
 */
final class DNSProfileHealer {

    // MARK: - Public properties

    static let shared = DNSProfileHealer()

    // MARK: - Private properties

    /// Minimum spacing between attempts for a device that stays pinned (i.e. the account still has
    /// no profile). One `users/get` per hour of app use is cheap, and short enough that a device
    /// picks up a server-side backfill the same day it lands.
    private static let minimumRetryInterval: TimeInterval = 60 * 60

    private let stateQueue = DispatchQueue(label: "com.theglacierapp.dnsProfileHealer")
    private var isHealing = false

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// True when `urlString` points at the shared backup profile, in either the bare
    /// (`tls://62b3da.dns…`) or device-labelled (`tls://glr-<hash>-62b3da.dns…`) form.
    ///
    /// Matches the leftmost DNS label rather than searching the whole string, so a personal
    /// profile id that happens to contain those characters elsewhere is never mistaken for the
    /// backup profile.
    static func isPinnedToBackupProfile(_ urlString: String?) -> Bool {
        guard let label = profileLabel(of: urlString) else { return false }
        return label == SecurityCenter.DNS_BACKUP || label.hasSuffix("-" + SecurityCenter.DNS_BACKUP)
    }

    /// The profile label a DoT URL resolves through — `62b3da` for `tls://62b3da.dns.glcr.me`.
    /// Used for logging so a support log says which profile a device is actually on.
    static func profileLabel(of urlString: String?) -> String? {
        guard let urlString,
              let host = URLComponents(string: urlString)?.host, !host.isEmpty,
              let label = host.split(separator: ".").first else {
            return nil
        }
        return String(label)
    }

    /// Heals this device if it is pinned to the shared backup profile. Safe to call on every
    /// launch and foreground: it returns immediately unless the device is actually stuck, and
    /// rate-limits its own retries.
    ///
    /// Call it only from a settled state — either DNS is off, or DoT has just been verified as the
    /// live resolver. A verified baseline is what makes the post-swap check meaningful, and it
    /// keeps this off the shared DNS-probe work item while the launch-time verification chain is
    /// still running.
    func healIfNeeded(securityCenter: SecurityCenter,
                      dnsController: DnsOverTlsController = .shared) {
        let saved = dnsController.loadSavedConfiguration()

        // Nothing stored: this device never completed DNS setup, so there is nothing to repoint.
        // The normal provisioning paths (`ensureEnabledForVPN`, `prefetchAndStoreDNSProfile`) own
        // that case and now write a real profile.
        guard let currentURLString = saved.urlString else { return }

        guard Self.isPinnedToBackupProfile(currentURLString) else { return }

        // Don't touch an enabled profile until DoT is known to be live. Without a verified
        // baseline, a failed check after the swap can't be told apart from a device that was
        // already not routing through DoT, and the revert below would be guesswork.
        guard !saved.isEnabled || securityCenter.isDoTVerifiedActive else { return }

        guard beginAttempt() else { return }

        // `allowCachedFallback: false` — the cached id is a per-install value, so on a device that
        // has changed accounts it could belong to the previous user. Pointing someone's DNS at
        // another account's profile would leak their queries into that account's logs, so a heal
        // only ever acts on a profile the server just confirmed for the signed-in user.
        securityCenter.getDNSProfile(allowCachedFallback: false) { [weak self] fetchedURLString in
            guard let self else { return }
            guard let fetchedURLString,
                  !Self.isPinnedToBackupProfile(fetchedURLString),
                  URLComponents(string: fetchedURLString)?.host?.isEmpty == false else {
                // Still nothing better to point at — the account isn't provisioned yet, or the
                // fetch failed. Leave the working fallback alone and try again later.
                Log.vpn.notice("DNS profile heal: no personal profile available yet — leaving the shared profile in place.")
                self.endAttempt()
                return
            }
            self.repoint(to: fetchedURLString,
                         from: currentURLString,
                         wasEnabled: saved.isEnabled,
                         securityCenter: securityCenter,
                         dnsController: dnsController)
        }
    }

    // MARK: - Private methods

    private func repoint(to healedURLString: String,
                         from previousURLString: String,
                         wasEnabled: Bool,
                         securityCenter: SecurityCenter,
                         dnsController: DnsOverTlsController) {
        Log.vpn.notice("DNS profile heal: device is pinned to the shared profile; repointing it at this account's own profile (enabled=\(wasEnabled, privacy: .public)).")

        guard wasEnabled else {
            // No system DoT profile is being steered by this configuration — DNS is off, or this
            // device only ever carried the packet tunnel's default. Persist the corrected URL and
            // stop there: the extension reads the same app-group keys and picks it up on its next
            // start, and the app applies it when the user turns DNS on. Calling `apply` here would
            // install a system DNS profile the user never asked for, which *does* raise an iOS
            // permission prompt (removal doesn't, adding does).
            dnsController.storeNewConfiguration(healedURLString)
            Log.vpn.notice("DNS profile heal: stored the corrected profile for a disabled configuration; no system profile was touched.")
            endAttempt()
            return
        }

        dnsController.apply(configuration: DnsOverTlsConfiguration(urlString: healedURLString, isEnabled: true)) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                // `apply` fails before it writes anything, so the previous configuration is still
                // in place and there is nothing to roll back. The next attempt retries.
                Log.vpn.error("DNS profile heal: applying the healed profile failed — the shared profile is still in place.")
                self.endAttempt()
                return
            }

            // With the tunnel up, its DNS proxy owns resolution and the system DoT profile isn't
            // the live resolver, so there is nothing meaningful to probe. The extension picks the
            // healed profile up on its next start.
            guard !securityCenter.isVpnTunnelConnected() else {
                Log.vpn.notice("DNS profile heal: applied while the tunnel is connected; the extension will pick it up on its next start.")
                self.endAttempt()
                return
            }

            self.verify(previousURLString: previousURLString,
                        securityCenter: securityCenter,
                        dnsController: dnsController)
        }
    }

    private func verify(previousURLString: String,
                        securityCenter: SecurityCenter,
                        dnsController: DnsOverTlsController) {
        // `suppressEarlyPrompt` — the probe is expected to fail for a beat while iOS re-establishes
        // the profile under its new server name. Letting the usual "select Glacier DNS in Settings"
        // prompt fire mid-swap would alarm a user whose DNS is about to be fine.
        securityCenter.doDNSCheck(retryUntilVerified: true, suppressEarlyPrompt: true) { [weak self] verified in
            guard let self else { return }

            // A concurrent probe (foreground refresh, VPN status change) cancels the work item this
            // chain runs on and reports `false` for the cancelled chain, so confirm against the
            // live verdict before treating a `false` as a real failure.
            if verified || securityCenter.isDoTVerifiedActive {
                Log.vpn.notice("DNS profile heal: verified — this device now resolves through its own profile.")
                self.endAttempt()
                return
            }

            // The healed profile doesn't resolve. This device was filtering through the shared
            // profile before the swap, so put it back rather than leave it worse off than the bug.
            Log.vpn.error("DNS profile heal: the healed profile did not verify — reverting to the previous configuration.")
            dnsController.apply(configuration: DnsOverTlsConfiguration(urlString: previousURLString, isEnabled: true)) { [weak self] revertResult in
                if case .failure(let error) = revertResult {
                    Log.vpn.error("DNS profile heal: reverting the configuration failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.endAttempt()
            }
        }
    }

    /// Claims the right to attempt a heal: one at a time, and no more often than
    /// `minimumRetryInterval` for a device that stays pinned. The stamp is written up front so a
    /// crash or a hung request can't turn into a retry loop.
    private func beginAttempt() -> Bool {
        return stateQueue.sync {
            guard !isHealing else { return false }
            let lastAttempt: Date? = UserDefaultsService.shared.get(for: \.lastDNSProfileHealAttempt)
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.minimumRetryInterval {
                return false
            }
            isHealing = true
            UserDefaultsService.shared.set(Date(), for: \.lastDNSProfileHealAttempt)
            return true
        }
    }

    private func endAttempt() {
        stateQueue.sync { isHealing = false }
    }
}
