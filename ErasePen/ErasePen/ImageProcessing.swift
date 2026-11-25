import CoreGraphics
import CoreImage
import UIKit

/// 纯图像处理工具：方向矫正、裁剪、缩放、mask 膨胀 / 羽化、合成。
/// 全部在原图分辨率上操作，只在模型推理时才缩到 800x800。
enum ImageProcessing {

    /// 把 UIImage 的 EXIF 方向烤进像素，返回 orientation == .up 的图。
    static func normalized(_ image: UIImage) -> UIImage {
        guard let ci = CIImage(image: image)?.oriented(.up) else { return image }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// 按矩形裁剪（像素坐标），返回 orientation == .up 的图。
    static func cropped(_ image: UIImage, rect: CGRect) -> UIImage? {
        guard let cg = image.cgImage, let cut = cg.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: cut, scale: 1, orientation: .up)
    }

    /// 高质量缩放到指定像素尺寸（不保持比例，调用方保证裁剪已是正方形）。
    static func resized(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// CGImage 缩放到指定像素尺寸。
    static func resizedCG(_ cgImage: CGImage, to size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    /// 以 mask 外接矩形为中心取正方形裁剪框：边长 = 最长边 + 2 倍 padding，
    /// padding = max(128px, 最长边的 25%)，框被夹在原图范围内。
    /// 正方形裁剪避免缩到 800x800 时拉伸变形。
    static func squareCropRect(maskBox: CGRect, imageSize: CGSize) -> CGRect {
        let longest = max(maskBox.width, maskBox.height)
        let padding = max(128, longest * 0.25)
        var side = longest + padding * 2
        side = min(side, min(imageSize.width, imageSize.height))
        var x = maskBox.midX - side / 2
        var y = maskBox.midY - side / 2
        x = min(max(x, 0), imageSize.width - side)
        y = min(max(y, 0), imageSize.height - side)
        // 取整，避免 CGImage.cropping(to:) 因越界返回 nil。
        let ix = floor(x), iy = floor(y), iside = floor(side)
        let clampedSide = min(iside, min(imageSize.width - ix, imageSize.height - iy))
        return CGRect(x: ix, y: iy, width: clampedSide, height: clampedSide)
    }

    /// 用形态学膨胀把 mask 边缘向外扩 radius 像素，盖住物体边缘残影。
    static func dilatedMask(_ mask: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: mask)
        guard let filter = CIFilter(name: "CIMorphologyRectangle") else { return mask }
        filter.setValue(ci, forKey: kCIInputImageKey)
        let diameter = max(3, Int(radius * 2) | 1) // 取奇数
        filter.setValue(diameter, forKey: "inputWidth")
        filter.setValue(diameter, forKey: "inputHeight")
        guard let output = filter.outputImage else { return mask }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: ci.extent, format: .L8,
                                     colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 对 mask 做高斯羽化，边缘过渡 8-16px，合成时不留硬边。
    static func featheredMask(_ mask: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: mask)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return mask }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return mask }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        // 高斯模糊会扩大 extent，裁回原图范围。
        return context.createCGImage(output, from: ci.extent, format: .L8,
                                     colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 只在羽化 mask 区域内把修复图贴回原裁剪图，未涂抹像素保持原样。
    static func composite(originalCrop: UIImage, inpaintedCrop: UIImage, featheredMask: CGImage) -> UIImage {
        let size = CGSize(width: originalCrop.cgImage?.width ?? Int(originalCrop.size.width),
                          height: originalCrop.cgImage?.height ?? Int(originalCrop.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            originalCrop.draw(in: CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: size), mask: featheredMask)
            inpaintedCrop.draw(in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    /// 把修复好的裁剪图贴回原图对应位置。
    static func pasteBack(original: UIImage, cropResult: UIImage, cropRect: CGRect) -> UIImage {
        let size = CGSize(width: original.cgImage?.width ?? Int(original.size.width),
                          height: original.cgImage?.height ?? Int(original.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
            cropResult.draw(in: cropRect)
        }
    }

    /// 把灰度 mask 画成半透明红色预览图（画布上显示涂抹范围）。
    static func tintedMaskOverlay(_ mask: CGImage, size: CGSize, color: UIColor) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: size), mask: mask)
            color.withAlphaComponent(0.45).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    /// JPEG 数据，质量 0.95，用于保存到相册。
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.95) -> Data? {
        image.jpegData(compressionQuality: quality)
    }
}
