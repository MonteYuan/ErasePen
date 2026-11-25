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
/// 下载完成后用 MLModel.compileModel 编译一次，编译结果缓存，下次启动直接加载。
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    struct ModelFile {
        let relativePath: String
        let urlString: String
        let label: String
    }

    static let repoBase = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main"
    static let totalExpectedBytes: Int64 = 225_511_887

    static let files: [ModelFile] = [
        ModelFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                  urlString: "\(repoBase)/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                  label: "模型结构"),
        ModelFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                  urlString: "\(repoBase)/LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                  label: "模型权重"),
        ModelFile(relativePath: "LaMa.mlpackage/Manifest.json",
                  urlString: "\(repoBase)/LaMa.mlpackage/Manifest.json",
                  label: "模型清单"),
    ]

    private static let compiledPathKey = "ErasePenCompiledModelPath"

    @Published var progress: Double = 0
    @Published var statusText: String = "模型未下载"
    @Published var isReady: Bool = false
    @Published var errorMessage: String?

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private var currentIndex = 0
    private var finishedBytes: Int64 = 0
    private var isDownloading = false

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
        isDownloading = true
        currentIndex = 0
        finishedBytes = 0
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
        if currentIndex >= Self.files.count {
            statusText = "正在编译模型…"
            compile()
            return
        }
        updateProgress(currentFileBytes: 0)
        downloadCurrentFile()
    }

    private func downloadCurrentFile() {
        let file = Self.files[currentIndex]
        guard let url = URL(string: file.urlString) else {
            fail("下载地址无效")
            return
        }
        let displayIndex = currentIndex + 1
        DispatchQueue.main.async { [weak self] in
            self?.statusText = "正在下载\(file.label)（\(displayIndex)/\(Self.files.count)）…"
        }
        session.downloadTask(with: url).resume()
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func updateProgress(currentFileBytes: Int64) {
        let total = Double(Self.totalExpectedBytes)
        let done = Double(finishedBytes + currentFileBytes)
        DispatchQueue.main.async { [weak self] in
            self?.progress = min(max(done / total, 0), 1)
        }
    }

    private func compile() {
        Task {
            do {
                let compiled = try await MLModel.compileModel(at: Self.packageURL())
                UserDefaults.standard.set(compiled.path, forKey: Self.compiledPathKey)
                DispatchQueue.main.async { [weak self] in
                    self?.isDownloading = false
                    self?.isReady = true
                    self?.progress = 1
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
        isDownloading = false
        errorMessage = message
        statusText = "下载失败"
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        updateProgress(currentFileBytes: totalBytesWritten)
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
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.fail("保存\(file.label)失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.fail("下载失败：\(error.localizedDescription)，可点重试继续下载")
            }
            return
        }
        if errorMessage != nil { return } // 前面保存失败已处理
        currentIndex += 1
        if currentIndex < Self.files.count {
            downloadCurrentFile()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "正在编译模型…"
            }
            compile()
        }
    }
}
