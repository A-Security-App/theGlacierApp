//
//  Font+GlacierFonts.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 19/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

extension Font {
    
    /// Returns font style for header one text type
    static var headerOne: Font {
        let font = Font.neueHassGroteskThickFont(ofSize: 21)
        return font
    }
    
    /// Returns font style for header two text type
    static var headerTwo: Font {
        let font = Font.neueHassGroteskThickFont(ofSize: 17)
        return font
    }
    
    /// Returns font style for sub header text type
    static var subHeader: Font {
        let font = Font.neueHassGroteskFont(ofSize: 14)
        return font
    }
    
    /// Returns font style for body text type
    static var bodyRegular: Font {
        let font = Font.neueHassGroteskFont(ofSize: 14)
        return font
    }
    
    /// Returns font style for body thick text type
    static var bodyThick: Font {
        let font = Font.neueHassGroteskThickFont(ofSize: 14)
        return font
    }
    
    /// Returns font style for body large text type
    static var bodyLarge: Font {
        let font = Font.neueHassGroteskFont(ofSize: 15)
        return font
    }
    
    /// Returns font style for body large thick text type
    static var bodyLargeThick: Font {
        let font = Font.neueHassGroteskThickFont(ofSize: 15)
        return font
    }
    
    /// Returns font style for body small text type
    static var bodySmall: Font {
        let font = Font.neueHassGroteskFont(ofSize: 12)
        return font
    }
    
    /// Returns font style for body small thick text type
    static var bodySmallThick: Font {
        let font = Font.neueHassGroteskThickFont(ofSize: 12)
        return font
    }
    
    /// Returns regular font style with custom "NeueHaasGroteskText-55Roman" font and size
    static func neueHassGroteskFont(ofSize: CGFloat) -> Font {
        let font: Font = .custom("HaasGrotTextApp-55Roman", size: ofSize)
        return font
    }
    
    /// Returns bold font style with custom "NeueHaasGroteskText-65Medium" font and size
    static func neueHassGroteskThickFont(ofSize: CGFloat) -> Font {
        let font: Font = .custom("HaasGrotTextApp-65Medium", size: ofSize)
        return font
    }
}
