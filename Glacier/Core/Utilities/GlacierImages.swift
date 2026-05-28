//
//  GlacierImages.swift
//  Glacier
//

import UIKit

enum GlacierImages {

    static func stringInitials(withMaxCharacters str: String, maxCharacters: Int) -> String? {
        guard !str.isEmpty else { return nil }
        guard maxCharacters > 1 else { return String(str.prefix(1)) }

        let separators = CharacterSet(charactersIn: " ._-+")
        var components = str.components(separatedBy: separators)
        if components.count > maxCharacters {
            components = Array(components.prefix(maxCharacters))
        }
        let initials = components
            .filter { !$0.isEmpty }
            .compactMap { $0.first.map(String.init) }
            .joined()
        return initials.uppercased()
    }

    static func removeImage(withIdentifier identifier: String) {
        GlacierImageCache.removeImage(identifier)
    }

    static func avatarImage(
        withUniqueIdentifier identifier: String,
        avatarData data: Data?,
        displayName: String?,
        username: String?
    ) -> UIImage? {
        if let cached = GlacierImageCache.image(identifier) {
            return cached
        }

        var image: UIImage?
        if let data {
            image = UIImage(data: data)
        }

        if image == nil {
            var name = displayName ?? ""
            if name.isEmpty {
                name = username?.components(separatedBy: "@").first ?? username ?? ""
            }
            let initials = stringInitials(withMaxCharacters: name, maxCharacters: 2) ?? ""
            image = UIImage.getImageWithInitials(
                initials,
                backgroundColor: UIColor(red: 41/255, green: 54/255, blue: 62/255, alpha: 1),
                textColor: UIColor(white: 0.60, alpha: 1),
                font: .systemFont(ofSize: 30),
                diameter: 60
            )
        }

        if let image {
            GlacierImageCache.setImage(image, identifier: identifier)
        }
        return image
    }
}
