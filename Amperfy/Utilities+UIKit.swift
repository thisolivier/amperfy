//
//  Utilities+UIKit.swift
//  Amperfy
//
//  Moved from AmperfyKit/Common/Utilities.swift during Sep-5 UIKit removal.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import CoreImage
import UIKit

extension UIColor {
  public convenience init(hue: CGFloat, saturation: CGFloat, lightness: CGFloat, alpha: CGFloat) {
    precondition(
      0 ... 1 ~= hue &&
        0 ... 1 ~= saturation &&
        0 ... 1 ~= lightness &&
        0 ... 1 ~= alpha,
      "input range is out of range 0...1"
    )

    // from HSL TO HSB
    var newSaturation: CGFloat = 0.0
    let brightness = lightness + saturation * min(lightness, 1 - lightness)
    if brightness == 0 {
      newSaturation = 0.0
    } else {
      newSaturation = 2 * (1 - lightness / brightness)
    }
    self.init(hue: hue, saturation: newSaturation, brightness: brightness, alpha: alpha)
  }

  public func getHue(
    _ hue: UnsafeMutablePointer<CGFloat>?,
    saturation targetSaturation: UnsafeMutablePointer<CGFloat>?,
    lightness targetLightness: UnsafeMutablePointer<CGFloat>?,
    alpha targetAlpha: UnsafeMutablePointer<CGFloat>?
  )
    -> Bool {
    var saturation, brightness, alpha: CGFloat
    (saturation, brightness, alpha) = (0.0, 0.0, 0.0)
    getHue(hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    // from HSB TO HSL
    var newSaturation: CGFloat = 0.0
    let lightness = brightness * (1 - saturation / 2)
    if lightness == 0 || lightness == 1 {
      newSaturation = 0.0
    } else {
      newSaturation = (brightness - lightness) / min(lightness, 1 - lightness)
    }

    targetSaturation?.pointee = newSaturation
    targetLightness?.pointee = lightness
    targetAlpha?.pointee = alpha
    return true
  }

  public func getWithLightness(of: CGFloat) -> UIColor {
    precondition(0 ... 1 ~= of, "input range is out of range 0...1")
    var hue, saturation, lightness, alpha: CGFloat
    (hue, saturation, lightness, alpha) = (0.0, 0.0, 0.0, 0.0)
    _ = getHue(&hue, saturation: &saturation, lightness: &lightness, alpha: &alpha)
    return UIColor(hue: hue, saturation: saturation, lightness: of, alpha: alpha)
  }

  // 007AFF
  // r:0 g:122 b:255
  public static var defaultBlue: UIColor {
    UIColor(displayP3Red: 0 / 255, green: 122 / 255, blue: 1.0, alpha: 1.0)
  }

  public static var gold: UIColor {
    UIColor(displayP3Red: 241 / 255, green: 194 / 255, blue: 66 / 255, alpha: 1.0)
  }

  public static var labelColor: UIColor {
    UIColor.label
  }

  public static var redHeart: UIColor {
    .red.withAlphaComponent(0.8)
  }

  public static var fillColor: UIColor {
    UIColor.systemFill
  }

  public static var secondaryLabelColor: UIColor {
    UIColor.secondaryLabel
  }

  static func fromHexString(_ hex: String) -> UIColor? {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: 1.0
    )
  }

  public static var backgroundColor: UIColor {
    // Check custom theme (reads UserDefaults directly to avoid cross-module dependency)
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "amperfy.fork.theme.enabled") {
      return UIColor { traits in
        let key = traits.userInterfaceStyle == .dark
          ? "amperfy.fork.theme.dark.bg"
          : "amperfy.fork.theme.light.bg"
        if let hex = defaults.string(forKey: key),
           let color = UIColor.fromHexString(hex) {
          return color
        }
        return .systemBackground
      }
    }
    return UIColor.systemBackground
  }
}

extension UIActivityIndicatorView {
  public static var defaultStyle: Style {
    .medium
  }
}

extension UIView {
  public func setGradientBackground(colorTop: UIColor, colorBottom: UIColor) {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [colorBottom.cgColor, colorTop.cgColor]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
    gradientLayer.locations = [0, 1]
    gradientLayer.frame = bounds
    layer.insertSublayer(gradientLayer, at: 0)
  }

  public var screenshot: UIImage? {
    UIGraphicsBeginImageContextWithOptions(layer.frame.size, false, 0)
    defer {
      UIGraphicsEndImageContext()
    }
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    layer.render(in: context)
    return UIGraphicsGetImageFromCurrentImageContext()
  }
}

extension UIAlertAction {
  public convenience init(
    title: String?,
    image: UIImage,
    style: Style,
    handler: ((UIAlertAction) -> ())? = nil
  ) {
    self.init(title: title, style: style, handler: handler)
    self.image = image
  }

  public var image: UIImage {
    get { value(forKey: "image") as? UIImage ?? UIImage() }
    set(image) { setValue(image, forKey: "image") }
  }
}

extension UIImage {
  public func averageColor() -> UIColor {
    var bitmap = [UInt8](repeating: 0, count: 4)

    let context = CIContext(options: nil)
    let cgImg = context.createCGImage(
      CoreImage.CIImage(cgImage: cgImage!),
      from: CoreImage.CIImage(cgImage: cgImage!).extent
    )

    let inputImage = CIImage(cgImage: cgImg!)
    let extent = inputImage.extent
    let inputExtent = CIVector(
      x: extent.origin.x,
      y: extent.origin.y,
      z: extent.size.width,
      w: extent.size.height
    )
    let filter = CIFilter(
      name: "CIAreaAverage",
      parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: inputExtent]
    )!
    let outputImage = filter.outputImage!
    let outputExtent = outputImage.extent
    assert(outputExtent.size.width == 1 && outputExtent.size.height == 1)

    // Render to bitmap.
    context.render(
      outputImage,
      toBitmap: &bitmap,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: CIFormat.RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )

    // Compute result.
    let result = UIColor(
      red: CGFloat(bitmap[0]) / 255.0,
      green: CGFloat(bitmap[1]) / 255.0,
      blue: CGFloat(bitmap[2]) / 255.0,
      alpha: CGFloat(bitmap[3]) / 255.0
    )
    return result
  }

  public func invertedImage() -> UIImage {
    guard let cgImage = cgImage else { return UIImage() }
    let ciImage = CoreImage.CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIColorInvert") else { return UIImage() }
    filter.setDefaults()
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    let context = CIContext(options: nil)
    guard let outputImage = filter.outputImage else { return UIImage() }
    guard let outputImageCopy = context.createCGImage(outputImage, from: outputImage.extent)
    else { return UIImage() }
    return UIImage(cgImage: outputImageCopy, scale: scale, orientation: .up)
  }
}

extension UIDevice {
  public var totalDiskCapacityInByte: Int64? {
    let fileURL = URL(fileURLWithPath: "/")
    guard let values = try? fileURL.resourceValues(forKeys: [.volumeTotalCapacityKey]),
          let capacity = values.volumeTotalCapacity else { return nil }
    return Int64(capacity)
  }

  public var availableDiskCapacityInByte: Int64? {
    let fileURL = URL(fileURLWithPath: "/")
    guard let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
          let capacity = values.volumeAvailableCapacity else { return nil }
    return Int64(capacity)
  }
}
