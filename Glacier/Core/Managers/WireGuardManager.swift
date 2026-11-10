//
//  WireGuardManager.swift
//  Glacier
//
//  Created by andyfriedman on 8/13/24.
//  Copyright © 2024 Glacier. All rights reserved.
//
import UIKit
import Foundation
import WireGuardKit
import Alamofire
public protocol TunnelListDelegate {
    func showTunnelDetail(for tunnel: TunnelContainer, animated: Bool)
}
public protocol VPNStorageListener {
    func handleNoStorageAccess()
    func handleNoCoreProfiles()
    func endLogin()
}
open class WireGuardManager: NSObject
{
    private static let sharedWGMgr = WireGuardManager()
    static let PROFILE_ENDPOINT = (EndpointService.shared.consoleBaseEndpoint ?? "") + (EndpointService.shared.wgProfileEndpoint ?? "")
    private var tunnelListDelegate:TunnelListDelegate?
    private var uiDelegate:UIViewController?
    var tunnelsManager: TunnelsManager?
    var onTunnelsManagerReady: ((TunnelsManager) -> Void)?
    var vpnIsActive = false
    /// Pinned like every other backend session: covers both the authenticated profile POST
    /// (which carries the Cognito access token) and the config download (which carries the
    /// WireGuard private key).
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral,
                                           serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager())
    let internalQueue = DispatchQueue(label: "WG Internal Queue")
    private static var isSimulatorBuild: Bool {
        #if SIMULATOR_BUILD
        return true
        #else
        return false
        #endif
    }
    private override init() {
        super.init()
        self.initWGClient()
        //setVpnIsActive()
    }
    func initWGClient() {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        TunnelsManager.create { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                if let uiDel = self.uiDelegate {
                    ErrorPresenter.showErrorAlert(error: error, from: uiDel)
                }
            case .success(let tunnelsManager):
                self.tunnelsManager = tunnelsManager
                //self.tunnelsListVC?.setTunnelsManager(tunnelsManager: tunnelsManager)
                self.onTunnelsManagerReady?(tunnelsManager)
                self.onTunnelsManagerReady = nil
            }
        }
    }
    func checkExistingProfiles() {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        let checkBlock: (TunnelsManager) -> Void = { manager in
            let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
            if manager.tunnel(named: installedRegion) == nil {
                // No profile found – fetch from server
                self.queryForProfiles(region: installedRegion)
            } else {
                // Profile already installed – skip download
            }
        }
        if let manager = self.tunnelsManager {
            checkBlock(manager)
        } else {
            self.onTunnelsManagerReady = checkBlock
        }
    }
    /// Computes the initial default VPN region for a brand-new profile install,
    /// from the device time zone alone — no location permission, no network call.
    ///
    /// - Pacific time zones  → a random pick between us-west-1 and us-west-2 (spreads load).
    /// - Everything else (Central, Eastern, Mountain, and any unrecognised zone) → us-east-2.
    /// - us-east-1 is intentionally never auto-selected here (it is being offloaded), but the
    ///   user can still choose it — or any other region — manually in VPN Settings.
    ///
    /// IMPORTANT: the Pacific branch is non-deterministic. Call this EXACTLY ONCE per setup
    /// flow, capture the result in a local, and reuse that value for BOTH the profile download
    /// (`queryForProfiles(region:)`) and the persisted `glacier_vpn_installed_region`. Never
    /// call it again to "re-read" the default — a second call could return the other western
    /// region and no longer match the installed tunnel's name.
    static func defaultInitialRegion(timeZone: TimeZone = .current) -> String {
        switch timeZone.identifier {
        case "America/Los_Angeles", "America/Tijuana", "America/Vancouver":
            return ["us-west-1", "us-west-2"].randomElement() ?? "us-west-2"
        default:
            return "us-east-2"
        }
    }

    func queryForProfiles(region: String = "us-east-2", onDemandOption: ActivateOnDemandOption = .off, responseHandler: ((Bool) -> Void)? = nil) {
        // Every path below ends in exactly one `finish` call, delivered on main.
        let finish = WireGuardManager.onceOnMain(responseHandler)
        guard !SecurityCenter.isProxyDetected else { finish(false); return }
        if WireGuardManager.isSimulatorBuild {
            finish(false)
            return
        }
        Task { [weak self] in
            guard let self else { finish(false); return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                finish(false)
                return
            }
            self.sessionManager.request(WireGuardManager.PROFILE_ENDPOINT, method: .post, parameters: ["region": region], encoding: JSONEncoding.default, headers: headers)
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success(let value):
                    // Never log the body: its `data` field is a presigned URL, a bearer
                    // link to this device's WireGuard private key.
                    self.handleProfiles(value, region: region, onDemandOption: onDemandOption, responseHandler: finish)
                case .failure(let error):
                    Log.vpn.error("Error accessing wireguard profiles: \(error)")
                    finish(false)
                }
            }
        }
    }
    func handleProfiles(_ profiles: Data, region: String, onDemandOption: ActivateOnDemandOption = .off, responseHandler: ((Bool) -> Void)? = nil) {
        let finish = WireGuardManager.onceOnMain(responseHandler)
        if WireGuardManager.isSimulatorBuild {
            finish(false)
            return
        }
        let url: URL
        switch WireGuardProfileDownload.configURL(fromProfileResponse: profiles) {
        case .success(let configURL):
            url = configURL
        case .failure(let error):
            Log.vpn.error("Rejected WireGuard profile response: \(String(describing: error), privacy: .public)")
            finish(false)
            return
        }
        downloadConfig(from: url, region: region) { [weak self] result in
            guard let self, let tunnelsManager = self.tunnelsManager else {
                finish(false)
                return
            }
            switch result {
            case .failure(let error):
                // localizedDescription only: the full error can carry the presigned URL
                // (URLError's failing-URL key) or a config line holding the private key.
                Log.vpn.error("Error downloading or parsing WireGuard config: \(error.localizedDescription, privacy: .public)")
                finish(false)
            case .success(let newConfig):
                if let existingTunnel = tunnelsManager.tunnel(named: region) {
                    tunnelsManager.modify(tunnel: existingTunnel, tunnelConfiguration: newConfig, onDemandOption: onDemandOption) { error in
                        finish(error == nil)
                    }
                } else {
                    tunnelsManager.add(tunnelConfiguration: newConfig, region: region, onDemandOption: onDemandOption) { result in
                        switch result {
                        case .success: finish(true)
                        case .failure: finish(false)
                        }
                    }
                }
            }
        }
    }
    func setTunnelListDelegate(_ del: TunnelListDelegate) {
        self.tunnelListDelegate = del
    }
    func setUIDelegate(_ del: UIViewController) {
        self.uiDelegate = del
    }
    func getWGView() -> UIViewController? {
        return self.uiDelegate
    }
    /// Fetches the wg-quick config on the pinned session and parses it. `completion` runs on main.
    ///
    /// The URL is the backend's short link on tinyurl.theglacierapp.com (validated as https by
    /// `WireGuardProfileDownload`), which 302s to a presigned S3 URL; the pinned session checks
    /// both hops (Amazon RSA 2048 M04 → Amazon Root CA 1 as of Nov 2026). The link carries its
    /// own authorization, so no Cognito headers are sent: the access token would leak to the
    /// storage host, and S3 rejects a presigned request that also has an Authorization header.
    private func downloadConfig(from url: URL, region: String, completion: @escaping (Result<TunnelConfiguration, Error>) -> Void) {
        sessionManager.request(url, method: .get)
            .validate()
            .responseData(queue: internalQueue) { response in
                let result: Result<TunnelConfiguration, Error>
                switch response.result {
                case .failure(let error):
                    result = .failure(error)
                case .success(let data):
                    if let fileContents = String(data: data, encoding: .utf8) {
                        result = Result { try TunnelConfiguration(fromWgQuickConfig: fileContents, called: region) }
                    } else {
                        result = .failure(WireGuardProfileDownload.Failure.unreadableConfig)
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }
    }
    /// Wraps a completion so it fires at most once and always on the main thread.
    private static func onceOnMain(_ handler: ((Bool) -> Void)?) -> (Bool) -> Void {
        let lock = NSLock()
        var didFire = false
        return { success in
            lock.lock()
            let isFirst = !didFire
            didFire = true
            lock.unlock()
            guard isFirst else { return }
            if Thread.isMainThread {
                handler?(success)
            } else {
                DispatchQueue.main.async { handler?(success) }
            }
        }
    }
    func importFromFile(urls: [URL], region: String? = nil) {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        //guard let uiDelegate = self.uiDelegate else { return }
        let importFromFileBlock: (TunnelsManager) -> Void = { tunnelsManager in
            // probably check if we already have?
            TunnelImporter.importFromFile(urls: urls, region: region, into: tunnelsManager, sourceVC: self.uiDelegate, errorPresenterType: ErrorPresenter.self) {
                //for url in urls {
                    //_ = FileManager.deleteFile(at: url)
                //}
                //self.refreshTunnelConnectionStatuses()
            }
        }
        if let tunnelsManager = tunnelsManager {
            importFromFileBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = importFromFileBlock
        }
    }
    func refreshTunnelConnectionStatuses() {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        if let tunnelsManager = tunnelsManager {
            tunnelsManager.refreshStatuses()
        }
    }
    func turnOffCore() {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        if let ontunnel = tunnelsManager?.tunnelInOperation(), let mgr = self.tunnelsManager {
            mgr.setOnDemandEnabled(false, on: ontunnel, completionHandler: { _ in
                mgr.startDeactivation(of: ontunnel)
            })
        }
    }

    /// Permanently removes all VPN profiles from device preferences.
    /// Does NOT require a user permission prompt — only adding a profile does.
    func removeAllTunnels(completionHandler: (() -> Void)? = nil) {
        if WireGuardManager.isSimulatorBuild {
            completionHandler?()
            return
        }
        guard let mgr = tunnelsManager else {
            completionHandler?()
            return
        }
        let all = mgr.getTunnels()
        guard !all.isEmpty else {
            completionHandler?()
            return
        }
        mgr.removeMultiple(tunnels: all) { _ in
            completionHandler?()
        }
    }
    func showTunnelDetailForTunnel(named tunnelName: String, animated: Bool, shouldToggleStatus: Bool) {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        let showTunnelDetailBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            guard let self = self else { return }
            guard let tunnelsListVC = self.tunnelListDelegate else { return }
            if let tunnel = tunnelsManager.tunnel(named: tunnelName) {
                tunnelsListVC.showTunnelDetail(for: tunnel, animated: false)
                if shouldToggleStatus {
                    if tunnel.status == .inactive {
                        tunnelsManager.startActivation(of: tunnel)
                    } else if tunnel.status == .active {
                        tunnelsManager.startDeactivation(of: tunnel)
                    }
                }
            }
        }
        if let tunnelsManager = tunnelsManager {
            showTunnelDetailBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = showTunnelDetailBlock
        }
    }
    func setVpnIsActive() -> Void {
        if WireGuardManager.isSimulatorBuild {
            vpnIsActive = false
            return
        }
        let vpnIsActiveBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            if let tunMgr = self?.tunnelsManager, tunMgr.numberOfTunnels() > 0 {
                let first = tunMgr.tunnel(at: 0)
                if first.status == .active {
                    self?.vpnIsActive = true
                    return
                }
            }
            self?.vpnIsActive = false
        }
        if let tunnelsManager = tunnelsManager {
            vpnIsActiveBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = vpnIsActiveBlock
        }
    }
    public class func shared() -> WireGuardManager {
        return sharedWGMgr
    }
}

/// Validation of the profile endpoint's response, kept apart from `WireGuardManager` so it can
/// be unit tested without a tunnels manager.
enum WireGuardProfileDownload {
    enum Failure: Error, Equatable {
        case notJSONObject
        case missingDataURL
        case insecureScheme
        case unreadableConfig
    }

    /// Extracts the config URL from `{"data": "<url>"}`. Only an absolute https URL with a host
    /// is accepted: anything else (http, file, a custom scheme) would fetch the private key
    /// outside pinned TLS, so it is rejected before any request is made.
    static func configURL(fromProfileResponse data: Data) -> Result<URL, Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return .failure(.notJSONObject)
        }
        guard let urlString = dictionary["data"] as? String,
              let url = URL(string: urlString) else {
            return .failure(.missingDataURL)
        }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return .failure(.insecureScheme)
        }
        return .success(url)
    }
}
