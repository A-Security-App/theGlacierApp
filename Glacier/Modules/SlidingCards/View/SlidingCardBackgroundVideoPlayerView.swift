//
//  SlidingCardBackgroundVideoPlayerView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import AVFoundation

/**
 SlidingCardBackgroundVideoPlayerView loads and plays the video assets for swiping cards.
 It uses AVFoundation API for video playback.
 */
struct SlidingCardBackgroundVideoPlayerView: UIViewRepresentable {
    
    // MARK: - Public properties
    
    let fileName: String
    
    // MARK: - Lifecycle methods
    
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "mp4") else {
            return view
        }
        
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        
        view.playerLayer.player = player
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        
        player.play()
        
        return view
    }
    
    func updateUIView(_ uiView: PlayerView, context: Context) {}
}

/**
 PlayerView works as the conainer of the AV player for video asset playback and placement.
 */
final class PlayerView: UIView {
    
    // MARK: - Public properties
    
    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
    
    // MARK: - Initalizer
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    // MARK: - Lifecycle methods
    
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
    
    // MARK: - Private methods
    
    private func setup() {
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.masksToBounds = true
    }
}
