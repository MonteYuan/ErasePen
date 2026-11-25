import Combine
import Photos
import SwiftUI
import UIKit

enum BrushMode {
    case paint
    case erase
    case pan // 移动画面（放大后用）
}

/// 主流程状态机：选图 → 涂抹 → 消除（LaMa 本地推理）→ 对比 → 保存。
/// 消除全程不联网、不上传，模型在手机本地跑。
@MainActor
final class EraseViewModel: ObservableObject {
    let downloader = ModelDownloader()
    private let engine = LaMaEngine()
    let maskStore = MaskStore()

    @Published var original: UIImage?
    @Published var result: UIImage?
    @Published var brushSize: CGFloat = 36 // 显示上的笔刷直径（点）
    @Published var brushMode: BrushMode = .paint
    @Published var isProcessing = false
    @Published var processingMessage = ""
    @Published var errorMessage: String?
    @Published var saveMessage: String?
    @Published var showOriginal = false
    @Published var showPicker = false

    /// 画布上当前显示的图：按住对比时显示原图，否则显示修复结果（没有则显示原图）。
    var displayImage: UIImage? {
        if showOriginal { return original }
        return result ?? original
    }

    var modelReady: Bool { downloader.isReady && engine.isLoaded }

    var canErase: Bool {
        original != nil && !maskStore.isEmpty && !isProcessing && modelReady
    }

    var canRerun: Bool {
        result != nil && !maskStore.isEmpty && !isProcessing && modelReady
    }

    init() {
        // mask 变化也要刷新界面（ContentView 只观察 viewModel）。
        maskStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        downloader.checkExisting()
        if let compiled = ModelDownloader.compiledModelURL() {
            try? engine.load(compiledURL: compiled)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// 模型就绪后（下载完成回调里调），加载编译好的模型。
    func loadEngineIfReady() {
        guard downloader.isReady, !engine.isLoaded else { return }
        guard let compiled = ModelDownloader.compiledModelURL() else { return }
        do {
            try engine.load(compiledURL: compiled)
        } catch {
            errorMessage = "模型加载失败：\(error.localizedDescription)"
        }
    }

    func pickPhoto(_ image: UIImage) {
        original = ImageProcessing.normalized(image)
        result = nil
        maskStore.clear()
        saveMessage = nil
        errorMessage = nil
    }

    /// 消除：对原图 + 当前涂抹跑一遍修复流水线。
    func erase() {
        guard let original = original else { return }
        runPipeline(input: original, isRerun: false)
    }

    /// 再修一次：用同样的涂抹，对上一次的结果再跑一遍。
    func rerun() {
        guard let current = result ?? original else { return }
        runPipeline(input: current, isRerun: true)
    }

    private func runPipeline(input: UIImage, isRerun: Bool) {
        guard !isProcessing else { return }
        guard let box = maskStore.boundingBox() else {
            errorMessage = "先用笔刷涂掉要消除的部分"
            return
        }
        guard let fullMask = maskStore.rasterizedMask(
            size: CGSize(width: input.cgImage?.width ?? Int(input.size.width),
                         height: input.cgImage?.height ?? Int(input.size.height))) else {
            errorMessage = "涂抹生成失败，请重新涂抹"
            return
        }
        isProcessing = true
        processingMessage = isRerun ? "正在再修一次…" : "正在消除…"
        errorMessage = nil
        let engine = engine
        Task.detached(priority: .userInitiated) {
            do {
                let output = try Self.pipeline(image: input, fullMask: fullMask, maskBox: box,
                                               engine: engine)
                await MainActor.run {
                    self.result = output
                    self.isProcessing = false
                    self.processingMessage = ""
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.processingMessage = ""
                    self.errorMessage = "消除失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 修复流水线（后台线程跑）：
    /// 膨胀 mask → 正方形裁剪（含大边距）→ 缩到 800x800 → LaMa 推理 →
    /// 羽化 mask 合成回裁剪图 → 贴回原图；涂抹面积 > 25% 时自动跑第二遍。
    nonisolated static func pipeline(image: UIImage, fullMask: CGImage, maskBox: CGRect,
                                     engine: LaMaEngine) throws -> UIImage {
        let pixelSize = CGSize(width: image.cgImage?.width ?? Int(image.size.width),
                               height: image.cgImage?.height ?? Int(image.size.height))
        let cropRect = ImageProcessing.squareCropRect(maskBox: maskBox, imageSize: pixelSize)
        let ratio = (maskBox.width * maskBox.height) / (cropRect.width * cropRect.height)
        var output = try runOnce(image: image, fullMask: fullMask, cropRect: cropRect, engine: engine)
        if ratio > 0.25 {
            // 大面积涂抹：第二遍用同一 mask 再修一次，清接缝。
            output = try runOnce(image: output, fullMask: fullMask, cropRect: cropRect, engine: engine)
        }
        return output
    }

    nonisolated private static func runOnce(image: UIImage, fullMask: CGImage, cropRect: CGRect,
                                            engine: LaMaEngine) throws -> UIImage {
        // 1. mask 膨胀 4px，盖住物体边缘残影。
        let dilated = ImageProcessing.dilatedMask(fullMask, radius: 4) ?? fullMask
        // 2. 裁剪图 + 裁剪 mask。
        guard let cropImage = ImageProcessing.cropped(image, rect: cropRect),
              let cropMask = dilated.cropping(to: cropRect.integral) else {
            throw LaMaEngine.EngineError.pixelBufferFailed
        }
        // 3. 缩到模型尺寸 800x800。
        let target = CGSize(width: LaMaEngine.inputSize, height: LaMaEngine.inputSize)
        let smallImage = ImageProcessing.resized(cropImage, to: target)
        guard let smallImageCG = smallImage.cgImage,
              let smallMaskCG = ImageProcessing.resizedCG(cropMask, to: target) else {
            throw LaMaEngine.EngineError.pixelBufferFailed
        }
        // 4. 本地推理。
        let fixedCG = try engine.predict(image: smallImageCG, mask: smallMaskCG)
        // 5. 放回裁剪尺寸，羽化合成（只动涂抹区域）。
        let fixedCrop = ImageProcessing.resized(UIImage(cgImage: fixedCG, scale: 1, orientation: .up),
                                                to: cropRect.size)
        let featherRadius = min(max(cropRect.width * 0.02, 8), 16)
        let feathered = ImageProcessing.featheredMask(cropMask, radius: featherRadius) ?? cropMask
        let composited = ImageProcessing.composite(originalCrop: cropImage,
                                                   inpaintedCrop: fixedCrop,
                                                   featheredMask: feathered)
        // 6. 贴回原图。
        return ImageProcessing.pasteBack(original: image, cropResult: composited, cropRect: cropRect)
    }

    /// 保存到相册：原图分辨率，JPEG 0.95。
    func saveResult() {
        guard let result = result else { return }
        guard let data = ImageProcessing.jpegData(result),
              let image = UIImage(data: data) else {
            errorMessage = "保存失败：图片编码失败"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.errorMessage = "保存失败：请在系统设置里允许访问相册"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.saveMessage = "已保存到相册"
                    } else {
                        self.errorMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
            }
        }
    }
}
