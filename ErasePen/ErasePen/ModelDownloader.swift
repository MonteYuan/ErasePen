import CoreML
import Foundation

/// 首次启动下载 LaMa 模型。模型不随 App 打包进 git（200MB+），
/// 而是首次联网时从 Hugging Face 下载到 App 的 Documents 目录。
///
/// 实测结论（2026-11-25，勿凭印象改地址）：
/// - 模型卡上写的 `LaMa.mlpackage.zip` 在仓库里不存在，
///   `…/resolve/main/LaMa.mlpackage.zip` 返回 404。
/// - 仓库里只有解包后的 .mlpackage 三个文件，逐个下载、按原目录结构重建即可：
///   1. `LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel`（1.1MB，已下载验证过输入输出）
///   2. `LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin`（约 224MB，大头）
///   3. `LaMa.mlpackage/Manifest.json`（已验证内容）
/// - 仓库总大小（HF API usedStorage）：225,511,887 字节，约 215MB。
///   模型卡表格写的 187MB 与实测不符，以实测为准。
///
/// v2（2026-11-25）下载问题修复：用户反馈点下载半天没动静。
/// 原因：① 国内直连 huggingface.co 常常很慢甚至卡住，且旧版没有任何进度、
/// 速度反馈，进度条要收到第一个字节才出现，看起来像死了；② 再点一次会被
/// isDownloading 拦住，静默无反应。修复：默认先走 hf-mirror.com（国内镜像，
/// 同一仓库同一文件），失败或 20 秒收不到字节就自动换 huggingface.co 再试；
/// 实时显示已下载 MB / 总 MB、速度 MB/s、剩余时间；支持取消；断点续传。
/// 下载完成后用 MLModel.compileModel 编译一次，编译结果缓存，下次启动直接加载。
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    struct ModelFile {
        let relativePath: String
        let repoPath: String // 主机名之后的部分
        let label: String
    }

    /// 国内镜像在前，官方在后。两个地址指向同一仓库、同一文件。
    static let hosts = ["https://hf-mirror.com", "https://huggingface.co"]
    static let repoBase = "mlboydaisuke/LaMa-CoreML/resolve/main"
    static let totalExpectedBytes: Int64 = 225_511_887

    static let files: [ModelFile] = [
        ModelFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                  repoPath: "\(repoBase)/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                  label: "模型结构"),
        ModelFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                  repoPath: "\(repoBase)/LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                  label: "模型权重"),
        ModelFile(relativePath: "LaMa.mlpackage/Manifest.json",
                  repoPath: "\(repoBase)/LaMa.mlpackage/Manifest.json",
                  label: "模型清单"),
    ]

    /// 20 秒收不到一个字节就判定线路卡住，自动换线路重试。
    private static let stallTimeout: TimeInterval = 20

    private static let compiledPathKey = "ErasePenCompiledModelPath"

    @Published var progress: Double = 0
    @Published var statusText: String = "模型未下载"
    @Published var isReady: Bool = false
    @Published var errorMessage: String?

    /// v2 新增：供界面实时显示。
    @Published var isDownloading = false
    @Published var isConnecting = false // 点了下载、还在等服务器响应的阶段
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = totalExpectedBytes
    @Published var speedBytesPerSecond: Double = 0
    @Published var etaSeconds: Double? // nil = 还算不出来（刚开始、速度为 0）
    @Published var currentFileLabel = ""
    @Published var currentFileIndex = 0 // 从 1 开始，0 表示未开始

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // 弱网时等网络恢复，不立刻报错
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600 // 224MB 大文件，资源超时放宽
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var currentIndex = 0
    private var hostIndex = 0 // 当前文件正在用的线路
    private var finishedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var resumeData: Data?
    private var switchingHost = false // 主动换线路取消任务时，忽略 -999 回调
    private var userCancelled = false

    // 速度采样与卡住检测
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private var lastBytesDate = Date()
    private var watchdog: Timer?

    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func packageURL() -> URL {
        documentsURL().appendingPathComponent("LaMa.mlpackage")
    }

    static func compiledModelURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: compiledPathKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 启动时调用：已编译过就直接就绪；包已下好但没编译就补编译。
    func checkExisting() {
        if Self.compiledModelURL() != nil {
            isReady = true
            progress = 1
            downloadedBytes = Self.totalExpectedBytes
            statusText = "模型已就绪"
            return
        }
        if allFilesPresent() {
            statusText = "正在编译模型…"
            compile()
        }
    }

    func allFilesPresent() -> Bool {
        Self.files.allSatisfy { file in
            let url = Self.packageURL().appendingPathComponent(file.relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return size > 0
        }
    }

    func startDownload() {
        guard !isDownloading else { return }
        errorMessage = nil
        userCancelled = false
        isDownloading = true
        isConnecting = true // 立刻给反馈：不是没反应，是在连接
        currentIndex = 0
        hostIndex = 0
        finishedBytes = 0
        currentFileBytes = 0
        resumeData = nil
        speedBytesPerSecond = 0
        etaSeconds = nil
        statusText = "正在连接服务器…"
        // 已下好的文件跳过，只补缺失的，断点重试不用重下。
        while currentIndex < Self.files.count {
            let dest = Self.packageURL().appendingPathComponent(Self.files[currentIndex].relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            if size > 0 {
                finishedBytes += fileSize(at: dest)
                currentIndex += 1
            } else {
                break
            }
        }
        downloadedBytes = finishedBytes
        if currentIndex >= Self.files.count {
            isConnecting = false
            statusText = "正在编译模型…"
            compile()
            return
        }
        updateProgress()
        startWatchdog()
        downloadCurrentFile()
    }

    /// 用户点「取消」：停掉当前任务，已下好的文件保留，下次继续下剩下的。
    func cancelDownload() {
        guard isDownloading else { return }
        userCancelled = true
        stopWatchdog()
        currentTask?.cancel()
        currentTask = nil
        isDownloading = false
        isConnecting = false
        speedBytesPerSecond = 0
        etaSeconds = nil
        statusText = "已取消下载"
        errorMessage = nil
    }

    private var currentTask: URLSessionDownloadTask?

    private func downloadCurrentFile() {
        let file = Self.files[currentIndex]
        let host = Self.hosts[hostIndex]
        let urlString = "\(host)/\(file.repoPath)"
        guard let url = URL(string: urlString) else {
            fail("下载地址无效")
            return
        }
        currentFileBytes = 0
        lastSampleDate = Date()
        lastSampleBytes = 0
        lastBytesDate = Date()
        let displayIndex = currentIndex + 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnecting = true
            self.currentFileLabel = file.label
            self.currentFileIndex = displayIndex
            self.statusText = "正在下载\(file.label)（\(displayIndex)/\(Self.files.count)）…"
        }
        if let resumeData, hostIndex == 0 {
            // 同一线路断点续传；换了线路则从头下（续传数据绑定原地址）。
            currentTask = session.downloadTask(withResumeData: resumeData)
            self.resumeData = nil
        } else {
            currentTask = session.downloadTask(with: url)
        }
        currentTask?.resume()
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func updateProgress() {
        let done = finishedBytes + currentFileBytes
        let total = Double(max(Self.totalExpectedBytes, 1))
        DispatchQueue.main.async { [weak self] in
            self?.downloadedBytes = done
            self?.progress = min(max(Double(done) / total, 0), 1)
        }
    }

    /// 每 2 秒检查一次：下载中但 20 秒没收到字节，判定线路卡住，自动换线路。
    private func startWatchdog() {
        stopWatchdog()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkStall()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkStall() {
        guard isDownloading, !userCancelled else { return }
        let idle = Date().timeIntervalSince(lastBytesDate)
        guard idle > Self.stallTimeout else { return }
        // 卡住了：取消当前任务（回调里会走换线路逻辑），先给用户一句话。
        statusText = "当前线路太慢，正在换备用线路…"
        switchToNextHostOrFail()
    }

    /// 换下一条线路；没有下一条了才真正报错。
    private func switchToNextHostOrFail() {
        if hostIndex + 1 < Self.hosts.count {
            switchingHost = true
            hostIndex += 1
            currentTask?.cancel()
            currentTask = nil
            // cancel 的 didCompleteWithError 回调（-999）会接着发起新线路的下载。
        } else {
            fail("下载超时：两条线路都连不上，请检查网络或换 Wi-Fi 后重试")
        }
    }

    private func compile() {
        stopWatchdog()
        Task {
            do {
                let compiled = try await MLModel.compileModel(at: Self.packageURL())
                UserDefaults.standard.set(compiled.path, forKey: Self.compiledPathKey)
                DispatchQueue.main.async { [weak self] in
                    self?.isDownloading = false
                    self?.isConnecting = false
                    self?.isReady = true
                    self?.progress = 1
                    self?.downloadedBytes = Self.totalExpectedBytes
                    self?.speedBytesPerSecond = 0
                    self?.etaSeconds = nil
                    self?.statusText = "模型已就绪"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail("模型编译失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        stopWatchdog()
        currentTask = nil
        isDownloading = false
        isConnecting = false
        speedBytesPerSecond = 0
        etaSeconds = nil
        errorMessage = message
        statusText = "下载失败"
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        currentFileBytes = totalBytesWritten
        lastBytesDate = Date()
        // 速度：每 0.5 秒采样一次，滑动平均，避免数字乱跳。
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleDate)
        if dt >= 0.5 {
            let delta = totalBytesWritten - lastSampleBytes
            let speed = dt > 0 ? Double(delta) / dt : 0
            lastSampleDate = now
            lastSampleBytes = totalBytesWritten
            let remaining = max(Self.totalExpectedBytes - finishedBytes - totalBytesWritten, 0)
            let eta = speed > 0 ? Double(remaining) / speed : nil
            DispatchQueue.main.async { [weak self] in
                self?.isConnecting = false
                self?.speedBytesPerSecond = speed
                self?.etaSeconds = eta
            }
        }
        updateProgress()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let file = Self.files[currentIndex]
        let dest = Self.packageURL().appendingPathComponent(file.relativePath)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            finishedBytes += fileSize(at: dest)
            currentFileBytes = 0
            resumeData = nil
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.fail("保存\(file.label)失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if userCancelled { return }
        if switchingHost {
            // 主动换线路取消的任务：忽略 -999，立刻用新线路重下当前文件。
            switchingHost = false
            lastBytesDate = Date()
            downloadCurrentFile()
            return
        }
        if let error = error {
            // 保存续传数据（同一线路重试时用）；换线路时不用。
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData = resume
            }
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { return }
            // 同一文件：先试另一条线路，线路用完了才报错。
            if hostIndex + 1 < Self.hosts.count {
                hostIndex += 1
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "当前线路失败，正在换备用线路…"
                }
                downloadCurrentFile()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.fail("下载失败：\(error.localizedDescription)，可点重试继续下载")
                }
            }
            return
        }
        if errorMessage != nil { return } // 前面保存失败已处理
        currentIndex += 1
        hostIndex = 0 // 下一个文件重新从最快的镜像开始
        resumeData = nil
        if currentIndex < Self.files.count {
            downloadCurrentFile()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isConnecting = false
                self?.statusText = "正在编译模型…"
            }
            compile()
        }
    }
}
