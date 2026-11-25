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

    private var theme: LinearGradient {
        LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    modelStatusCard
                    if viewModel.original == nil {
                        emptyState
                    } else {
                        canvasArea
                        controlsArea
                    }
                }
            }
            .navigationTitle("消除笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { viewModel.showPicker = true } label: {
                        Label("选照片", systemImage: "photo.on.rectangle.angled")
                    }
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
                let d = viewModel.downloader
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(theme).frame(width: 44, height: 44)
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("消除模型 · LaMa")
                                .font(.headline)
                            Text(d.isDownloading
                                 ? (d.isConnecting ? "正在连接服务器…" : "正在下载 \(d.currentFileLabel)")
                                 : "首次使用需下载一次")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(d.isReady ? "已就绪" : "\(Int(d.progress * 100))%")
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.indigo)
                    }

                    // 进度条：渐变填充，始终可见，点下下载立刻有反馈。
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.systemFill))
                                .frame(height: 10)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme)
                                .frame(width: max(geo.size.width * d.progress, d.progress > 0 ? 10 : 0),
                                       height: 10)
                        }
                    }
                    .frame(height: 10)

                    HStack {
                        Text("\(formatBytes(d.downloadedBytes)) / \(formatBytes(d.totalBytes))")
                        Spacer()
                        if d.isDownloading && !d.isConnecting && d.speedBytesPerSecond > 0 {
                            Text(formatSpeed(d.speedBytesPerSecond))
                        }
                        if let eta = d.etaSeconds, d.isDownloading, !d.isConnecting {
                            Text("还剩约 \(formatETA(eta))")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                    Text("约 215MB，建议用 Wi-Fi。下载一次后永久离线使用，照片只在手机本地处理，不上传、不审核。下载慢会自动换备用线路，也可取消后重试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let error = d.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    HStack(spacing: 10) {
                        Button(d.errorMessage == nil ? "下载模型" : "重试下载") {
                            d.startDownload()
                        }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(d.isDownloading)
                        if d.isDownloading {
                            Button("取消") { d.cancelDownload() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
                .padding(.horizontal)
                .padding(.top, 10)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(theme).frame(width: 110, height: 110)
                    .shadow(color: .indigo.opacity(0.35), radius: 20, x: 0, y: 8)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 48))
                    .foregroundColor(.white)
            }
            VStack(spacing: 8) {
                Text("涂掉路人、杂物、水印")
                    .font(.title2)
                    .bold()
                Text("选一张照片，用笔刷涂掉不要的部分，\n点「消除」，AI 会按周围内容把洞补上。")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                featureChip("天空接近无缝", icon: "cloud.sun")
                featureChip("本地处理", icon: "lock.shield")
                featureChip("不上传", icon: "eye.slash")
            }
            Button("从相册选照片") { viewModel.showPicker = true }
                .buttonStyle(GradientButtonStyle())
                .controlSize(.large)
            Text("小面积、天空、墙面、地面接近无缝；大面积、复杂结构可能要修两次。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func featureChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
    }

    // MARK: - 画布

    private var canvasArea: some View {
        GeometryReader { geo in
            if let image = viewModel.displayImage,
               let pixelSize = image.cgImage.map({ CGSize(width: $0.width, height: $0.height) }) {
                let rect = aspectFitRect(imageSize: pixelSize, in: geo.size)
                ZStack {
                    Color(.systemGroupedBackground)
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
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
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
        VStack(spacing: 12) {
            Picker("模式", selection: $viewModel.brushMode) {
                Label("涂抹", systemImage: "paintbrush").tag(BrushMode.paint)
                Label("橡皮", systemImage: "eraser").tag(BrushMode.erase)
                Label("移动", systemImage: "hand.draw").tag(BrushMode.pan)
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: "circle.circle")
                    .foregroundColor(.secondary)
                Text("笔刷")
                Slider(value: $viewModel.brushSize, in: 10...120, step: 1)
                    .tint(.indigo)
                Text("\(Int(viewModel.brushSize))")
                    .frame(width: 32)
                    .font(.subheadline.monospacedDigit())
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
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .font(.subheadline)

            HStack(spacing: 12) {
                Button("消除") { viewModel.erase() }
                    .buttonStyle(GradientButtonStyle())
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
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(10)
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
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: -4)
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

    // MARK: - 格式化

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond / 1_000_000
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 10 { return "不到 10 秒" }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m) 分 \(s) 秒"
    }
}

/// 渐变主按钮：靛蓝→紫，圆角 14，白字。
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: [.indigo, .purple],
                               startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// 只给顶部两个角加圆角（底部工具栏用）。
struct RoundedCorner: Shape {
    var radius: CGFloat = 20
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
