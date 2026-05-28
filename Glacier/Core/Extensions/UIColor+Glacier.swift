//
//  UIColor+Glacier.swift
//  Glacier
//
//  Created by andyfriedman on 4/8/26.
//  Copyright © 2026 Glacier. All rights reserved.
//
import UIKit

public extension UIColor {
    static let solids = [UIColor(rgb: 0x34C986), UIColor(rgb: 0xFE8747), UIColor(rgb: 0x8228ED), UIColor(rgb: 0xFE6550), UIColor(rgb: 0x3352C6), UIColor(rgb: 0x472CB6)]
    
    static func StringFromUIColor(color: UIColor) -> String {
        var colorString = ""
        if let components = color.cgColor.components {
            colorString = "\(components[0]), \(components[1]), \(components[2]), \(components[3])"
        }
        return colorString
    }
    
    static func UIColorFromString(string: String) -> UIColor {
        let components = string.components(separatedBy:", ")
        return UIColor(red: CGFloat((components[0] as NSString).floatValue),
                       green: CGFloat((components[1] as NSString).floatValue),
                       blue: CGFloat((components[2] as NSString).floatValue),
                       alpha: CGFloat((components[3] as NSString).floatValue))
    }
    
    convenience init(rgb: Int) {
        self.init(
            red: (rgb >> 16) & 0xFF,
            green: (rgb >> 8) & 0xFF,
            blue: rgb & 0xFF
        )
    }
    
    convenience init(red: Int, green: Int, blue: Int) {
        assert(red >= 0 && red <= 255, "Invalid red component")
        assert(green >= 0 && green <= 255, "Invalid green component")
        assert(blue >= 0 && blue <= 255, "Invalid blue component")
        
        self.init(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1.0)
    }
}
