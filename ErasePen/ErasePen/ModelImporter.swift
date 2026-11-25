import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// 本地导入模型包。用户自己下载模型（电脑上下载好传到手机，或直接在手机
/// Safari 里下），在 App 里选进来，不用走 App 内下载。以后换别的模型包也走这里。
///
/// 支持三种输入（统一入口）：
/// 1. `.mlpackage` 文件夹：从“文件”App 里直接选文件夹
/// 2. 包含 `.mlpackage` 的 `.zip`：微信/QQ 传 zip 到手机最方便
/// 3. `model.mlmodel` + `weight.bin` + `Manifest.json` 三个散文件：多选一次选完
///
/// 导入后校验清单、拷到 Documents/LaMa.mlpackage、清掉旧编译缓存，
/// 由 ModelDownloader 接着编译并设为当前模型。
enum ModelImporter {
    enum ImportError: LocalizedError {
        case noValidPackage

        var errorDescription: String? {
            switch self {
            case .noValidPackage:
                return "没找到有效的模型包。请选 .mlpackage 文件夹、包含它的 zip，或 model.mlmodel、weight.bin、Manifest.json 这 3 个文件。"
            }
        }
    }

    /// 标准 .mlpackage 结构里的三个文件（相对包内路径）。
    static let looseFileNames = ["model.mlmodel", "weight.bin", "Manifest.json"]

    /// 把用户选的东西装成当前模型包，返回显示名和总字节数。
    /// destPackageURL 是 Documents/LaMa.mlpackage（替换旧包）。
    static func install(from urls: [URL], to destPackageURL: URL) throws
        -> (displayName: String, totalBytes: Int64)
    {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ErasePenImport-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var candidate: URL?
        var loose = [String: URL]() // 文件名 -> 选中的文件

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, url.pathExtension == "mlpackage" {
                // 1. 直接选了模型包文件夹
                let staged = staging.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: staged)
                if isValidPackage(at: staged) { candidate = staged }
            } else if !isDir.boolValue, url.pathExtension.lowercased() == "zip" {
                // 2. zip：解开，在里面找模型包（有的 zip 外面还套一层文件夹）
                let unzipDir = staging.appendingPathComponent("unzipped-\(UUID().uuidString)")
                try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: unzipDir)
                if let found = findPackage(in: unzipDir, depth: 2),
                   isValidPackage(at: found)
                {
                    candidate = found
                }
            } else if !isDir.boolValue, looseFileNames.contains(url.lastPathComponent) {
                // 3. 三个散文件之一，先收起来，最后拼成包
                loose[url.lastPathComponent] = url
            }
        }

        if candidate == nil, loose.count == 3 {
            // 三个散文件拼成标准包结构
            let assembled = staging.appendingPathComponent("LaMa.mlpackage")
            let coreML = assembled.appendingPathComponent("Data/com.apple.CoreML")
            let weights = coreML.appendingPathComponent("weights")
            try fm.createDirectory(at: weights, withIntermediateDirectories: true)
            try fm.copyItem(at: loose["model.mlmodel"]!,
                            to: coreML.appendingPathComponent("model.mlmodel"))
            try fm.copyItem(at: loose["weight.bin"]!,
                            to: weights.appendingPathComponent("weight.bin"))
            try fm.copyItem(at: loose["Manifest.json"]!,
                            to: assembled.appendingPathComponent("Manifest.json"))
            if isValidPackage(at: assembled) { candidate = assembled }
        }

        guard let package = candidate else { throw ImportError.noValidPackage }
        let displayName = package.deletingPathExtension().lastPathComponent
        let total = directorySize(at: package)

        if fm.fileExists(atPath: destPackageURL.path) {
            try fm.removeItem(at: destPackageURL)
        }
        try fm.createDirectory(at: destPackageURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try fm.moveItem(at: package, to: destPackageURL)
        return (displayName, total)
    }

    /// 校验一个目录是不是有效的模型包：清单是合法 JSON 且含必需字段，
    /// 模型结构和权重文件都在且非空。
    static func isValidPackage(at packageURL: URL) -> Bool {
        let fm = FileManager.default
        let manifest = packageURL.appendingPathComponent("Manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["fileFormatVersion"] != nil,
              json["itemInfoEntries"] is [String: Any],
              json["rootModelIdentifier"] != nil
        else { return false }
        let model = packageURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let weights = packageURL.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        return fileSize(at: model) > 0 && fileSize(at: weights) > 0
    }

    /// 在目录里找 .mlpackage（先看顶层，再往下找一层，有的 zip 外面套了文件夹）。
    static func findPackage(in dir: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for item in items where item.pathExtension == "mlpackage" {
            return item
        }
        guard depth > 0 else { return nil }
        for item in items {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
               let found = findPackage(in: item, depth: depth - 1)
            {
                return found
            }
        }
        return nil
    }

    static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// 目录总字节数（递归）。
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

/// 系统文件选择器：选模型包文件夹、zip，或三个散文件（可多选）。
struct ModelPackagePicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true，选中的东西会拷到 App 的临时目录，不用处理安全域权限。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder, .zip, .data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
