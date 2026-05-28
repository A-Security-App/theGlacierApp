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
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral)
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
            let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1"
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
    func queryForProfiles(region: String = "us-east-1", onDemandOption: ActivateOnDemandOption = .off, responseHandler: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { responseHandler?(false); return }
        if WireGuardManager.isSimulatorBuild {
            responseHandler?(false)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                responseHandler?(false)
                return
            }
            //print(WireGuardManager.PROFILE_ENDPOINT)
            self.sessionManager.request(WireGuardManager.PROFILE_ENDPOINT, method: .post, parameters: ["region": region], encoding: JSONEncoding.default, headers: headers)
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success(let value):
                    if let profiles = String(data: value, encoding: .utf8) {
                        Log.vpn.debug("\(profiles)")
                        self.handleProfiles(profiles, region: region, onDemandOption: onDemandOption) { didLoadProfiles in
                            responseHandler?(didLoadProfiles)
                        }
                    } else {
                        //self.handleNoCoreProfiles()
                        responseHandler?(false)
                    }
                    return
                case .failure(let error):
                    Log.vpn.error("Error accessing wireguard profiles: \(error)")
                    responseHandler?(false)
                    return
                }
            }
        }
    }
    func handleProfiles(_ profiles: String, region: String, onDemandOption: ActivateOnDemandOption = .off, responseHandler: ((Bool) -> Void)? = nil) {
        if WireGuardManager.isSimulatorBuild {
            return
        }
        if let jsonData = profiles.data(using: .utf8) {
            do {
                if let jsonDictionary = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                    if let profileStr = jsonDictionary["data"] as? String, let url = URL(string: profileStr) {
                        if let existingTunnel = self.tunnelsManager?.tunnel(named: region) {
                            self.downloadAndApply(configFrom: url, region: region, onDemandOption: onDemandOption, to: existingTunnel) { success in
                                responseHandler?(success)
                            }
                        } else {
                            self.downloadAndAdd(configFrom: url, region: region, onDemandOption: onDemandOption) { success in
                                responseHandler?(success)
                            }
                        }
                    } else {
                        Log.vpn.error("Invalid URL string: \(profiles)")
                        responseHandler?(false)
                    }
                } else {
                    Log.vpn.error("Failed to cast JSON object to dictionary.")
                    responseHandler?(false)
                }
            } catch {
                Log.vpn.error("Error deserializing JSON: \(error.localizedDescription)")
                responseHandler?(false)
            }
        } else {
            Log.vpn.error("Failed to convert JSON string to Data.")
            responseHandler?(false)
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
    private func downloadAndApply(configFrom url: URL, region: String?, onDemandOption: ActivateOnDemandOption, to existingTunnel: TunnelContainer, responseHandler: ((Bool) -> Void)?) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fileContents = try String(contentsOf: url)
                let newConfig = try TunnelConfiguration(fromWgQuickConfig: fileContents, called: region ?? "us-east-1")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tunnelsManager = self.tunnelsManager else {
                        responseHandler?(false)
                        return
                    }
                    tunnelsManager.modify(tunnel: existingTunnel, tunnelConfiguration: newConfig, onDemandOption: onDemandOption) { error in
                        responseHandler?(error == nil)
                    }
                }
            } catch {
                Log.vpn.error("Error downloading or parsing WireGuard config: \(error)")
                DispatchQueue.main.async { responseHandler?(false) }
            }
        }
    }

    private func downloadAndAdd(configFrom url: URL, region: String, onDemandOption: ActivateOnDemandOption, responseHandler: ((Bool) -> Void)?) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fileContents = try String(contentsOf: url)
                let newConfig = try TunnelConfiguration(fromWgQuickConfig: fileContents, called: region)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tunnelsManager = self.tunnelsManager else {
                        responseHandler?(false)
                        return
                    }
                    tunnelsManager.add(tunnelConfiguration: newConfig, region: region, onDemandOption: onDemandOption) { result in
                        switch result {
                        case .success: responseHandler?(true)
                        case .failure: responseHandler?(false)
                        }
                    }
                }
            } catch {
                Log.vpn.error("Error downloading or parsing WireGuard config: \(error)")
                DispatchQueue.main.async { responseHandler?(false) }
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
                /*if tunnelsManager.numberOfTunnels() > 0 {
                    let tunnel = tunnelsManager.tunnel(at: 0)
                    if tunnel.status == .inactive {
                        //tunnelsManager.startActivation(of: tunnel)
                    }
                }*/
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
