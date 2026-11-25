import CoreGraphics
import Foundation

/// 一笔涂抹：points / radius 均为原图像素坐标。
struct BrushStroke {
    var points: [CGPoint]
    var radius: CGFloat // 笔刷半径（像素）
    var isErase: Bool // true = 橡皮，擦掉已涂的 mask
}

/// 涂抹记录 + 光栅化。mask 为灰度图：白 = 要消除，黑 = 保留。
/// 笔画只存坐标列表，撤销 = 弹出最后一笔，内存占用小。
final class MaskStore: ObservableObject {
    @Published private(set) var strokes: [BrushStroke] = []

    var isEmpty: Bool { strokes.isEmpty }

    func addStroke(_ stroke: BrushStroke) {
        guard !stroke.points.isEmpty else { return }
        strokes.append(stroke)
    }

    func undo() {
        _ = strokes.popLast()
    }

    func clear() {
        strokes.removeAll()
    }

    /// 所有笔画的外接矩形（原图像素坐标），没有笔画时返回 nil。
    func boundingBox() -> CGRect? {
        guard !strokes.isEmpty else { return nil }
        var box: CGRect?
        for stroke in strokes {
            for point in stroke.points {
                let r = CGRect(x: point.x - stroke.radius, y: point.y - stroke.radius,
                               width: stroke.radius * 2, height: stroke.radius * 2)
                box = box == nil ? r : box!.union(r)
            }
        }
        return box
    }

    /// 把笔画光栅化为指定尺寸的灰度 CGImage（黑底白 mask）。
    /// pointScale 用于预览：按比例缩小坐标和笔刷半径再画。
    func rasterizedMask(size: CGSize, pointScale: CGFloat = 1) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 原点在左下角，笔画坐标是 UIKit 原点在左上角，翻转 Y 再画。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for stroke in strokes {
            let radius = stroke.radius * pointScale
            let points = stroke.points.map { CGPoint(x: $0.x * pointScale, y: $0.y * pointScale) }
            context.setStrokeColor(gray: stroke.isErase ? 0 : 1, alpha: 1)
            context.setFillColor(gray: stroke.isErase ? 0 : 1, alpha: 1)
            context.setLineWidth(radius * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if points.count == 1 {
                let p = points[0]
                context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                               width: radius * 2, height: radius * 2))
            } else {
                context.beginPath()
                context.move(to: points[0])
                for point in points.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
            }
        }
        return context.makeImage()
    }
}
