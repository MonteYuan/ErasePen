import SwiftUI
import UIKit

/// 主界面：选图 → 笔刷涂抹 → 本地消除 → 按住对比 → 保存。
/// 全部中文，全程离线（模型下载那一次除外），照片不上传。
struct ContentView: View {
    @StateObject private var viewModel = EraseViewModel()

    @State private var scale: CGFloat = 1
    @State private var panOffset = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var livePoints: [CGPoint] = [] // 画布容器坐标（未缩放）
    @State private var liveImagePoints: [CGPoint] = [] // 原图像素坐标
    @State private var previewMask: UIImage?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                modelStatusCard
                if viewModel.original == nil {
                    emptyState
                } else {
                    canvasArea
                    controlsArea
                }
            }
            .navigationTitle("消除笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("选照片") { viewModel.showPicker = true }
                }
            }
            .sheet(isPresented: $viewModel.showPicker) {
                PhotoPicker(isPresented: $viewModel.showPicker) { image in
                    viewModel.pickPhoto(image)
                    scale = 1
                    panOffset = .zero
                    previewMask = nil
                }
            }
            .alert("提示", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onChange(of: viewModel.downloader.isReady) { ready in
                if ready { viewModel.loadEngineIfReady() }
            }
        }
    }

    // MARK: - 模型状态

    private var modelStatusCard: some View {
        Group {
            if !viewModel.downloader.isReady {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "cpu")
                        Text("消除模型（LaMa）")
                            .font(.headline)
                        Spacer()
                        Text(viewModel.downloader.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if viewModel.downloader.progress > 0 && viewModel.downloader.progress < 1 {
                        ProgressView(value: viewModel.downloader.progress)
                    }
                    Text("首次使用需下载约 215MB 模型，建议用 Wi-Fi。下载一次后永久离线使用，照片只在手机本地处理，不上传、不审核。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let error = viewModel.downloader.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button(viewModel.downloader.errorMessage == nil ? "下载模型" : "重试下载") {
                        viewModel.downloader.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.downloader.progress > 0 && viewModel.downloader.progress < 1
                              && viewModel.downloader.errorMessage == nil)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("涂掉路人、杂物、水印")
                .font(.title3)
                .bold()
            Text("选一张照片，用笔刷涂掉不要的部分，\n点「消除」，AI 会按周围内容把洞补上。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("从相册选照片") { viewModel.showPicker = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("小面积、天空、墙面、地面接近无缝；大面积、复杂结构可能要修两次。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - 画布

    private var canvasArea: some View {
        GeometryReader { geo in
            if let image = viewModel.displayImage,
               let pixelSize = image.cgImage.map({ CGSize(width: $0.width, height: $0.height) }) {
                let rect = aspectFitRect(imageSize: pixelSize, in: geo.size)
                ZStack {
                    Color(.systemBackground)
                    canvasContainer(image: image, pixelSize: pixelSize, rect: rect)
                        .scaleEffect(scale)
                        .offset(panOffset)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in scale = min(max(value, 1), 4) }
                        .onEnded { _ in
                            if scale <= 1.01 { scale = 1; panOffset = .zero }
                        }
                )
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func canvasContainer(image: UIImage, pixelSize: CGSize, rect: CGRect) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: rect.width, height: rect.height)
            if let previewMask = previewMask {
                Image(uiImage: previewMask)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
            }
            if !livePoints.isEmpty {
                Path { path in
                    path.move(to: livePoints[0])
                    for point in livePoints.dropFirst() { path.addLine(to: point) }
                }
                .stroke(viewModel.brushMode == .erase ? Color.blue : Color.red,
                        style: StrokeStyle(lineWidth: viewModel.brushSize,
                                           lineCap: .round, lineJoin: .round))
                .opacity(0.7)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if viewModel.brushMode == .pan {
                        panOffset = CGSize(width: panStart.width + value.translation.width,
                                           height: panStart.height + value.translation.height)
                    } else {
                        let containerPoint = value.location
                        // 双指缩放时手指会跳变：与上一点距离过大时丢弃，避免画出 stray 长线。
                        if let last = livePoints.last,
                           hypot(containerPoint.x - last.x, containerPoint.y - last.y) > 100 {
                            return
                        }
                        let imagePoint = CGPoint(
                            x: containerPoint.x / rect.width * pixelSize.width,
                            y: containerPoint.y / rect.height * pixelSize.height)
                        guard imagePoint.x >= 0, imagePoint.x <= pixelSize.width,
                              imagePoint.y >= 0, imagePoint.y <= pixelSize.height else { return }
                        livePoints.append(containerPoint)
                        liveImagePoints.append(imagePoint)
                    }
                }
                .onEnded { _ in
                    if viewModel.brushMode == .pan {
                        panStart = panOffset
                    } else if !liveImagePoints.isEmpty {
                        let radiusPx = (viewModel.brushSize / 2) * (pixelSize.width / rect.width)
                        viewModel.maskStore.addStroke(BrushStroke(
                            points: liveImagePoints,
                            radius: max(radiusPx, 1),
                            isErase: viewModel.brushMode == .erase))
                        livePoints = []
                        liveImagePoints = []
                        refreshPreview(rect: rect, pixelSize: pixelSize)
                    }
                }
        )
    }

    private func refreshPreview(rect: CGRect, pixelSize: CGSize) {
        // 预览按显示尺寸光栅化（最长边不超 1024），不走全分辨率，省内存。
        let previewScale = min(rect.width * 2, 1024) / pixelSize.width
        let previewSize = CGSize(width: pixelSize.width * previewScale,
                                 height: pixelSize.height * previewScale)
        guard let mask = viewModel.maskStore.rasterizedMask(size: previewSize, pointScale: previewScale),
              let overlay = ImageProcessing.tintedMaskOverlay(mask, size: previewSize, color: .red) else {
            previewMask = nil
            return
        }
        previewMask = overlay
    }

    // MARK: - 底部控制

    private var controlsArea: some View {
        VStack(spacing: 10) {
            Picker("模式", selection: $viewModel.brushMode) {
                Text("涂抹").tag(BrushMode.paint)
                Text("橡皮").tag(BrushMode.erase)
                Text("移动").tag(BrushMode.pan)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("笔刷")
                Slider(value: $viewModel.brushSize, in: 10...120, step: 1)
                Text("\(Int(viewModel.brushSize))")
                    .frame(width: 32)
            }

            HStack(spacing: 12) {
                Button("撤销") {
                    viewModel.maskStore.undo()
                    refreshPreviewAfterEdit()
                }
                .disabled(viewModel.maskStore.isEmpty)
                Button("清除涂抹") {
                    viewModel.maskStore.clear()
                    previewMask = nil
                }
                .disabled(viewModel.maskStore.isEmpty)
                Spacer()
                if let message = viewModel.saveMessage {
                    Text(message).font(.caption).foregroundColor(.green)
                }
            }
            .font(.subheadline)

            HStack(spacing: 12) {
                Button("消除") { viewModel.erase() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!viewModel.canErase)
                Button("再修一次") { viewModel.rerun() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!viewModel.canRerun)
                Text("按住看原图")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in viewModel.showOriginal = true }
                            .onEnded { _ in viewModel.showOriginal = false }
                    )
                    .disabled(viewModel.result == nil)
                Button("保存") { viewModel.saveResult() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.result == nil)
            }

            if viewModel.isProcessing {
                HStack {
                    ProgressView()
                    Text(viewModel.processingMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("小面积 / 天空 / 墙面 / 地面接近无缝；大面积、复杂结构可能要修两次。未涂抹的像素原样保留。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    private func refreshPreviewAfterEdit() {
        // 撤销后重算预览：按最长边 1024 光栅化，只用于显示涂抹范围。
        guard let original = viewModel.original,
              let cg = original.cgImage else {
            previewMask = nil
            return
        }
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let scale = min(1024 / max(pixelSize.width, pixelSize.height), 1)
        let previewSize = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        guard let mask = viewModel.maskStore.rasterizedMask(size: previewSize, pointScale: scale) else {
            previewMask = nil
            return
        }
        previewMask = ImageProcessing.tintedMaskOverlay(mask, size: previewSize, color: .red)
    }
}
