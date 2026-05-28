//
//  UserPermissionManager.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import CoreLocation
import Contacts
import UserNotifications

/*
 UserPermissionManaging defines requirements for user permission managers.
 */
protocol UserPermissionManaging {

    var hasUserLocationPermission: Bool { get }
    var hasContactsPermission: Bool { get }
    var hasPushNotificationPermission: Bool { get }

    func requestUserLocationPermission(completion: @escaping (Bool) -> Void)
    func requestContactsPermission(completion: @escaping (Bool) -> Void)
    func requestPushNotificationPermission(completion: @escaping (Bool) -> Void)
}

/**
 UserPermissionManager provides easy to use API for checking user permission states and requesting permission for,
 - User location access
 - Push notification
 - Contacts access
 */
final class UserPermissionManager: NSObject, UserPermissionManaging {
    
    // MARK: - Public properties
    
    static let shared = UserPermissionManager()
    
    var hasUserLocationPermission: Bool {
        guard let permission = userLocationPermission else {
            return false
        }
        return permission == .granted
    }
    
    var hasContactsPermission: Bool {
        guard let permission = contactsPermission else {
            return false
        }
        return permission == .granted
    }
    
    var hasPushNotificationPermission: Bool {
        guard let permission = pushNotificationPermission else {
            return false
        }
        return permission == .granted
    }

    // MARK: - Private properties
    
    private let locationManager = CLLocationManager()
    private var locationCompletion: ((Bool) -> Void)?
    
    private var userLocationPermission: UserPermissionState?
    private var contactsPermission: UserPermissionState?
    private var pushNotificationPermission: UserPermissionState?

    // MARK: - Initializer
    
    override init() {
        super.init()
        
        getUserPermissionStates()
        locationManager.delegate = self
    }

    // MARK: - Public methods

    func requestUserLocationPermission(completion: @escaping (Bool) -> Void) {
        let status = locationManager.authorizationStatus

        switch status {
        case .notDetermined:
            locationCompletion = completion
            locationManager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse, .authorizedAlways:
            update(.granted, for: .location)
            completion(true)

        case .denied, .restricted:
            update(.denied, for: .location)
            completion(false)

        @unknown default:
            update(.denied, for: .location)
            completion(false)
        }
    }

    func requestContactsPermission(completion: @escaping (Bool) -> Void) {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, _ in
                let state: UserPermissionState = granted ? .granted : .denied
                self.update(state, for: .contacts)
                DispatchQueue.main.async {
                    completion(granted)
                }
            }

        case .authorized, .limited:
            update(.granted, for: .contacts)
            completion(true)

        case .denied, .restricted:
            update(.denied, for: .contacts)
            completion(false)

        @unknown default:
            update(.denied, for: .contacts)
            completion(false)
        }
    }

    func requestPushNotificationPermission(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    let state: UserPermissionState = granted ? .granted : .denied
                    self.update(state, for: .notifications)

                    DispatchQueue.main.async {
                        completion(granted)
                    }
                }

            case .authorized, .provisional, .ephemeral:
                self.update(.granted, for: .notifications)
                DispatchQueue.main.async {
                    completion(true)
                }

            case .denied:
                self.update(.denied, for: .notifications)
                DispatchQueue.main.async {
                    completion(false)
                }

            @unknown default:
                self.update(.denied, for: .notifications)
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
    
    // MARK: - Private methods
    
    private func getUserPermissionStates() {
        if let locationPermission: String = UserDefaultsService.shared.get(for: \.userLocationPermission),
           let locationPermissionState = UserPermissionState(rawValue: locationPermission) {
            self.userLocationPermission = locationPermissionState
        }
        
        if let contactsPermission: String = UserDefaultsService.shared.get(for: \.contactsPermission),
           let contactsPermissionState = UserPermissionState(rawValue: contactsPermission) {
            self.contactsPermission = contactsPermissionState
        }
        
        if let pushNotificationPermission: String = UserDefaultsService.shared.get(for: \.pushNotificationsPermission),
           let pushNotificationPermissionState = UserPermissionState(rawValue: pushNotificationPermission) {
            self.pushNotificationPermission = pushNotificationPermissionState
        }
    }
    
    private func update(_ state: UserPermissionState, for type: UserPermissionType) {
        switch type {
        case .location:
            userLocationPermission = state
            UserDefaultsService.shared.set(state.rawValue, for: \.userLocationPermission)

        case .contacts:
            contactsPermission = state
            UserDefaultsService.shared.set(state.rawValue, for: \.contactsPermission)

        case .notifications:
            pushNotificationPermission = state
            UserDefaultsService.shared.set(state.rawValue, for: \.pushNotificationsPermission)
        }
    }
}

// MARK: - CLLocationManagerDelegate methods

extension UserPermissionManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state: UserPermissionState

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            state = .granted

        case .denied, .restricted:
            state = .denied

        case .notDetermined:
            state = .notDetermined

        @unknown default:
            state = .denied
        }

        update(state, for: .location)
        locationCompletion?(state == .granted)
    }
}
