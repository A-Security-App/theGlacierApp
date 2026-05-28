//
//  UIImage+Scale.swift
//  Glacier
//
//  Created by andyfriedman on 4/8/26.
//  Copyright © 2026 Glacier. All rights reserved.
//
import UIKit
public extension UIImage {
    // Redraws itself to the new size
    func scaleImageWith(newSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let image = renderer.image { _ in
            self.draw(in: CGRect.init(origin: CGPoint.zero, size: newSize))
        }
        return image
    }
    func scalePreservingAspectRatio(targetSize: CGSize) -> UIImage {
        // Determine the scale factor that preserves aspect ratio
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let scaleFactor = min(widthRatio, heightRatio)
        // Compute the new image size that preserves aspect ratio
        let scaledImageSize = CGSize(
            width: size.width * scaleFactor,
            height: size.height * scaleFactor
        )
        // Draw and return the resized UIImage
        let renderer = UIGraphicsImageRenderer(
            size: scaledImageSize
        )
        let scaledImage = renderer.image { _ in
            self.draw(in: CGRect(
                origin: .zero,
                size: scaledImageSize
            ))
        }
        return scaledImage
    }
    static func getCircular(image: UIImage, diameter:UInt, highlightedColor:UIColor?) -> UIImage
    {
        let size = CGSizeMake(CGFloat(diameter), CGFloat(diameter))
        let imageRect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: imageRect.size)
        let newImage = renderer.image { ctx in
            let cgContext = ctx.cgContext
            let imgPath = UIBezierPath(ovalIn: imageRect)
            imgPath.addClip()
            image.draw(in: imageRect)
            if let color = highlightedColor {
                color.setFill()
                cgContext.fillEllipse(in: imageRect)
            }
        }
        return newImage
    }
    static func getImageWithInitials(_ initials: String, backgroundColor: UIColor, textColor: UIColor, font: UIFont, diameter:UInt) -> UIImage
    {
        let size = CGSizeMake(CGFloat(diameter), CGFloat(diameter))
        let frame = CGRect(origin: .zero, size: size)
        let attributes = [NSAttributedString.Key.font:font,
                          NSAttributedString.Key.foregroundColor:textColor]
        let textFrame = initials.boundingRect(with: frame.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        let frameMidPoint = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))
        let textFrameMidPoint = CGPointMake(CGRectGetMidX(textFrame), CGRectGetMidY(textFrame))
        let dx = frameMidPoint.x - textFrameMidPoint.x
        let dy = frameMidPoint.y - textFrameMidPoint.y
        let drawPoint = CGPointMake(dx, dy)
        let renderer = UIGraphicsImageRenderer(size: frame.size)
        let image = renderer.image { ctx in
            let cgContext = ctx.cgContext
            backgroundColor.setFill()
            cgContext.fill(frame)
            initials.draw(at: drawPoint, withAttributes: attributes)
        }
        return UIImage.getCircular(image:image, diameter:diameter, highlightedColor:nil)
    }
}
