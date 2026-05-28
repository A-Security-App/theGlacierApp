//
//  VoicemailDetailsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import AVFoundation
import SwiftUI

/**
 VoiceMailDetailsViewModel defines requirements for VoiceMailDetailsScreen view models
 */
protocol VoiceMailDetailsViewModel: GlacierViewModelWithRootCoordinator {
    
    var activeColorScheme: ColorScheme { get set }
    var voiceMail: VoicemailRecord { get }
    var isPlaying: Bool { get }
    var currentTime: Double { get set }
    var duration: Double { get }
    var isSpeakerOn: Bool { get }
    
    var playButtonTintColor: Color? { get set }
    var playButtonBackgroundColor: Color? { get set }
    
    var speakerButtonTintColor: Color? { get set }
    var speakerButtonBackgroundColor: Color? { get set }
    
    init(rootCoordinator: any GlacierRootCoordinator, voiceMail: VoicemailRecord)
    
    @MainActor
    func initialize()
    
    @MainActor
    func togglePlayback()
    
    @MainActor
    func seek(to time: Double)
    
    @MainActor
    func beginScrubbing()
    
    @MainActor
    func endScrubbing(at time: Double)
    
    @MainActor
    func rewind()
    
    @MainActor
    func toggleSpeakerOutput()
    
    @MainActor
    func formatTime(_ seconds: Double) -> String
    
    @MainActor
    func tearDownPlayer()
    
    @MainActor
    func presentDeleteVoiceMailConfirmationPopup()
    
    @MainActor
    func startCall()
}

/**
 VoiceMailDetailsVM defines data/state and business logic for VoiceMailDetailsScreen UI/UX and workflows.
 */
class VoiceMailDetailsVM: VoiceMailDetailsViewModel, ObservableObject, PhoneNumberMenuCoordinator {
    
    // MARK: - Public properties
    
    var activeColorScheme: ColorScheme = .light {
        didSet {
            setPlayButtonColors()
            setSpeakerButtonColors()
        }
    }
    
    @Published var voiceMail: VoicemailRecord
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isSpeakerOn = false
    
    @Published var playButtonTintColor: Color?
    @Published var playButtonBackgroundColor: Color?
    
    @Published var speakerButtonTintColor: Color?
    @Published var speakerButtonBackgroundColor: Color?
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Private properties
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var wasPlayingBeforeScrub = false
    private var hasListened = false
    
    // MARK: - Initializer
    
    required init(rootCoordinator: any GlacierRootCoordinator, voiceMail: VoicemailRecord) {
        self.rootCoordinator = rootCoordinator
        self.voiceMail = voiceMail
    }
    
    // MARK: - Public methods
    
    @MainActor
    func initialize() {
        markVMAsRead()
        setupPlayer()
        setPlayButtonColors()
        setSpeakerButtonColors()
    }
    
    @MainActor
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    @MainActor
    private func play() {
        guard let player else { return }

        if currentTime >= (duration - 0.3) {
            seek(to: 0)
        }

        if !hasListened {
            hasListened = true
        }

        player.play()
        isPlaying = true
        setPlayButtonColors()
    }
    
    @MainActor
    private func pause() {
        player?.pause()
        isPlaying = false
        setPlayButtonColors()
    }
    
    @MainActor
    func seek(to time: Double) {
        guard let player else { return }
        
        currentTime = time
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        
        player.seek(
            to: cmTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
    
    @MainActor
    func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
    }
    
    @MainActor
    func endScrubbing(at time: Double) {
        seek(to: time)
        
        if wasPlayingBeforeScrub {
            player?.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        
        setPlayButtonColors()
    }
    
    @MainActor
    func rewind() {
        seek(to: 0)
    }
    
    @MainActor
    func toggleSpeakerOutput() {
        isSpeakerOn.toggle()
        setSpeakerButtonColors()
        
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
            try session.setActive(true)
        } catch {
            Log.calls.error("Audio route error: \(error)")
        }
    }
    
    @MainActor
    func tearDownPlayer() {
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        player?.pause()
        player = nil
    }
    
    @MainActor
    func formatTime(_ seconds: Double) -> String {
        
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    @MainActor
    func presentDeleteVoiceMailConfirmationPopup() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString(
                "Delete this voicemail?",
                comment: "Voicemail detail screen delete voicemail title"
            ),
            description: NSLocalizedString(
                "You won’t be able to recover it after deleting.",
                comment: "Voicemail detail screen delete voicemail description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Delete", comment: "Delete button title"),
                    onTap: {
                        self.dismissPopup()
                        self.pause()
                        
                        guard let sid = self.voiceMail.recordingSid else { return }
                        TwilioBackendManager.sharedMgr().deleteVM(sid)
                        self.dismissPresentedScreen()
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    @MainActor
    func startCall() {
        hidePhoneNumberMenu()
        
        var phoneNumber: String = ""
        var personName: String?
        
        if let contact = voiceMail.contact {
            phoneNumber = contact.phoneNumber
            personName = contact.name
        } else if let fromNumber = voiceMail.from {
            phoneNumber = fromNumber
        }
        
        guard !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let popupConfiguration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString("Start call?", comment: "Phone screen call confirmation prompt description"),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Call", comment: "Call button title"),
                    onTap: {
                        self.dismissPopup()
                        self.pause()
                        
                        // Let's send notification for call initialization
                        NotificationCenter.default.post(
                            name: .startPhoneCall,
                            object: nil,
                            userInfo: [
                                GlacierNotificationProperties.phoneNumber: phoneNumber,
                                GlacierNotificationProperties.personName: personName ?? ""
                            ]
                        )
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    // MARK: - Private methods
    
    private func markVMAsRead() {
        guard let sid = voiceMail.recordingSid else {
            return
        }
        TwilioBackendManager.sharedMgr().listenedToVM(sid)
    }
    
    private func setupPlayer() {
        
        guard let urlString = voiceMail.url,
              let url = URL(string: urlString) else { return }
        
        let item = AVPlayerItem(url: url)
        
        player = AVPlayer(playerItem: item)
        
        observeDuration(url: url)
        addPeriodicTimeObserver()
    }
    
    private func observeDuration(url: URL) {
        Task { @MainActor in
            
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                self.duration = duration.seconds
            } catch {
                Log.calls.error("Duration load error: \(error)")
            }
        }
    }
    
    private func addPeriodicTimeObserver() {
        
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            
            guard let self else { return }
            
            let seconds = time.seconds
            
            self.currentTime = seconds
            
            if seconds >= self.duration {
                self.handlePlaybackFinished()
            }
        }
    }
    
    private func handlePlaybackFinished() {
        isPlaying = false
        currentTime = duration
        player?.pause()
        setPlayButtonColors()
    }
    
    private func setPlayButtonColors() {
        
        if isPlaying {
            playButtonTintColor = activeColorScheme == .dark ? .black : .white
            playButtonBackgroundColor = activeColorScheme == .dark ? .white : .grey95
        } else {
            playButtonTintColor = activeColorScheme == .dark ? .white : .black
            playButtonBackgroundColor = activeColorScheme == .dark ? .grey70 : .grey30
        }
    }
    
    private func setSpeakerButtonColors() {
        
        if isSpeakerOn {
            speakerButtonTintColor = activeColorScheme == .dark ? .black : .white
            speakerButtonBackgroundColor = activeColorScheme == .dark ? .white : .grey95
        } else {
            speakerButtonTintColor = activeColorScheme == .dark ? .white : .black
            speakerButtonBackgroundColor = activeColorScheme == .dark ? .grey70 : .grey30
        }
    }
}
