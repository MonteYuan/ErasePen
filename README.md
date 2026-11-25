# ErasePen — iPhone 离线照片消除笔

对标 PrettyUp 消除笔的同类功能：涂掉路人、杂物、水印、文字，AI 按周围内容把洞补上。
**只做照片版，全程离线，不上传、不审核、不走云端 API。**

不走 App Store，只做未签名 IPA，自签名安装。

## 功能

| 功能 | 实现 |
|---|---|
| 选照片 | 系统 PHPicker，只读选中的一张图 |
| 笔刷涂抹 | 可调笔刷大小；涂抹模式画 mask，橡皮模式擦掉 mask；撤销、清除 |
| 缩放 / 移动 | 双指缩放 1–4 倍；「移动」模式下单指拖动画布 |
| 消除 | 本地 LaMa 模型推理，见下「修复流水线」 |
| 再修一次 | 用同一 mask 对上一次结果再跑一遍 |
| 按住看原图 | 按住按钮显示原图，松开回修复结果 |
| 保存 | 原图分辨率，JPEG 0.95，保存到相册 |

## 修复流水线（效果的关键）

1. **膨胀 mask**：涂抹边缘向外扩 4px，盖住物体边缘残影。
2. **正方形裁剪**：以涂抹外接矩形为中心取正方形框，边距 = max(128px, 最长边的 25%)，避免缩放到模型尺寸时拉伸变形。
3. **缩到 800×800**：裁剪图 + mask 一起缩到模型输入尺寸。
4. **LaMa 本地推理**：CoreML，computeUnits = `.all`。
5. **羽化合成**：mask 边缘高斯羽化 8–16px，只在涂抹区域内把修复图贴回裁剪图，**未涂抹像素保持原样**。
6. **贴回原图**：全分辨率输出。
7. **大面积自动第二遍**：涂抹面积 > 裁剪面积 25% 时，自动再跑一遍清接缝；「再修一次」按钮可手动再跑。

## 模型：LaMa CoreML（已核实，2026-11-25）

- 来源：Hugging Face `mlboydaisuke/LaMa-CoreML`，上游 `advimman/lama`，许可证 **Apache-2.0**。
- 文件（仓库实测，`usedStorage` 225,511,887 字节，约 215MB）：
  - `LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel`（1.1MB）
  - `LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin`（约 224MB，大头）
  - `LaMa.mlpackage/Manifest.json`
- 输入 / 输出（**下载 model.mlmodel 后解析 protobuf 实测**，不是猜的）：
  - 输入 `image`：800×800，RGB 彩色图
  - 输入 `mask`：800×800，灰度图，白 = 要修复，黑 = 保留
  - 输出 `output`：800×800，RGB 彩色图
- computeUnits：模型卡注明的验证配置是 `.all`，代码里用的就是 `.all`。
- 最低 iOS **17.0**（模型卡注明）。本工程 Deployment Target 因此设为 **17.0**，
  不是 16.0；iPhone 15 Pro 出厂就是 iOS 17，可以用。

### 两个与任务初稿不符的实测结果（已按实测改代码）

1. 模型卡表格写的 `LaMa.mlpackage.zip`（187MB）在仓库里**不存在**，
   `…/resolve/main/LaMa.mlpackage.zip` 实测返回 **404**。App 因此不走 zip，
   而是逐个下载上面三个文件、按原目录结构重建 `.mlpackage` 再编译。
   模型卡里另一处下载命令还写了另一个仓库名 `mlboydaisuke/coreml-zoo`，同样不可信，没采用。
2. 模型卡表格写下载大小 187MB，但仓库实际总大小是 225,511,887 字节（约 215MB）。
   App 首次下载显示约 215MB，建议用 Wi-Fi。

### 模型怎么进手机

模型**不**随工程进 git（200MB+）。首次打开 App 时点「下载模型」，
App 从 Hugging Face 下载上面三个文件到 Documents 目录，编译一次后缓存，
以后永久离线使用。下载支持断点续传（已下好的文件跳过）、失败重试。
模型没下好时 App 不会假装修图：消除按钮不可用，界面明确显示「模型未下载」和重试按钮，
绝不用模糊填充冒充修复结果。

v2（2026-11-25）下载体验改进：首版用户反馈「点了下载半天没动静」。
原因是国内直连 huggingface.co 经常很慢甚至卡住，而旧版没有任何进度、
速度反馈、进度条要收到第一个字节才出现，看起来像死了；再点一次还会被
下载锁静默拦住。v2 改为：默认先走 **hf-mirror.com**（国内镜像，同一仓库
同一文件），失败或 20 秒收不到字节就自动换 huggingface.co 再试；实时显示
**已下载 MB / 总 MB、下载速度 MB/s、剩余时间**，点下下载立刻显示「正在
连接服务器…」；下载中可以点「取消」，已下好的文件保留，下次继续下剩下的。

## 技术

- SwiftUI，Swift 5，Deployment Target **iOS 17.0**（见上，模型要求）
- Bundle ID：`com.meng.erasepen`
- 只用系统框架：SwiftUI、CoreML、CoreImage、Photos、PhotosUI
- 无第三方依赖，无 CocoaPods / SPM
- 全中文界面；不收集、不上传任何照片

## 工程结构

```
erasepen-ios-app/
├── ErasePen/
│   ├── ErasePen.xcodeproj/
│   │   ├── project.pbxproj
│   │   └── xcshareddata/xcschemes/ErasePen.xcscheme
│   └── ErasePen/
│       ├── ErasePenApp.swift      # @main 入口
│       ├── ContentView.swift     # 主界面：画布、笔刷、工具栏、模型下载卡片
│       ├── EraseViewModel.swift  # 状态机 + 修复流水线编排
│       ├── LaMaEngine.swift      # CoreML 加载与推理（image/mask → output）
│       ├── ModelDownloader.swift # 首次启动下载 3 个模型文件、编译、缓存
│       ├── ImageProcessing.swift # 方向矫正、裁剪、缩放、膨胀、羽化、合成
│       ├── MaskStore.swift       # 笔画记录 + 光栅化为灰度 mask
│       ├── PhotoPicker.swift     # PHPicker 封装
│       ├── Info.plist
│       └── Assets.xcassets/      # AppIcon 为纯色占位（无真实图片文件）
├── .github/workflows/build-ipa.yml  # GitHub Actions 云编译未签名 IPA（复用 IPCheck 验证过的流程）
├── build-ipa.sh                  # 有 Mac 时本地打包脚本
└── README.md
```

## 方法一：用 GitHub Actions 云编译拿 IPA（不用 Mac）

1. 在 GitHub 新建一个空仓库 `MonteYuan/ErasePen`（github.com/new，公开即可），
   把本目录全部文件上传（或 `git push`）。
2. 打开仓库页面 → **Actions** → 左侧 **Build unsigned IPA** → 点 **Run workflow**
   （也可以直接 push 到 main 分支触发）。
3. 等待运行完成（约 3–8 分钟），点进那次运行 → 底部 **Artifacts** →
   下载 **`ErasePen-unsigned-ipa`**。
4. 解压下载的 zip，里面就是 `ErasePen-unsigned.ipa`。

注意：GitHub Actions 免费额度通常够用；artifact 默认保留 30 天。

## 方法二：有 Mac 时本地打包

```bash
chmod +x build-ipa.sh
./build-ipa.sh
# 产物：./ErasePen-unsigned.ipa
```

也可以在 Xcode 里打开 `ErasePen/ErasePen.xcodeproj`，选真机或 Any iOS Device，
Product → Build（Release），再按脚本打包。

## 自签名安装（未签名 IPA → 装到 iPhone）

未签名 IPA 不能直接点开安装，需要用自己的 Apple ID 签名后再装。选一种：

### A. AltStore（最常用，免费 Apple ID 可用）

1. 电脑安装 AltServer（Windows / Mac 均可），iPhone 安装 AltStore。
2. 用数据线连 iPhone，AltServer 里登录你的 Apple ID，安装 AltStore 到手机。
3. 手机上打开 AltStore → 我的 App → 点 `+` → 选择 `ErasePen-unsigned.ipa` 安装。
4. 免费 Apple ID 签名有效期 **7 天**，到期前在同一 Wi-Fi 下打开 AltStore 刷新即可续签；付费开发者账号（99 美元/年）有效期 1 年。

### B. Sideloadly（Windows / Mac）

1. 电脑安装 Sideloadly，iPhone 用数据线连接并信任电脑。
2. Sideloadly 里选 `ErasePen-unsigned.ipa`，输入 Apple ID，按提示安装。
3. 有效期同样是免费 7 天 / 付费 1 年；首次打开 App 前，去手机「设置 → 通用 → VPN 与设备管理」里信任你的 Apple ID 证书。

### C. TrollStore（有条件，长期有效但不是所有系统都支持）

仅当你的 iOS 版本存在 TrollStore 支持的漏洞时可用，需查 TrollStore 官方兼容表。

### 首次打开前的通用步骤

安装后如果打不开，提示“未受信任的开发者”：去「设置 → 通用 → VPN 与设备管理 → 开发者 App → 你的 Apple ID → 信任」。

## 首次使用

1. 打开 App，点「下载模型」，约 215MB，建议 Wi-Fi 下下载，下载一次即可。
2. 点「选照片」，涂掉不要的部分（笔刷可调大小，涂错了用橡皮或撤销）。
3. 点「消除」，等几秒；不满意点「再修一次」。
4. 按住「按住看原图」对比，满意点「保存」。

## 诚实说明（App 里也写了同样的话）

- 小面积、天空、墙面、地面接近无缝；大面积、复杂结构（重复纹理、直线透视、人脸、手）可能要修两次，仍可能看出痕迹。
- 模型输入固定 800×800：裁剪图是正方形所以不变形，但超大原图细节会先压缩再修复，极端细节不如云端大模型。
- 模型峰值内存约 600MB（模型卡数据），iPhone 15 Pro 的 8GB 够用；旧款小内存机型大图可能更慢。
- AppIcon 已是真实图标：白色橡皮擦擦掉金色星星、紫色渐变底（1024×1024 原图 + 各尺寸切图在 `Assets.xcassets/AppIcon.appiconset`）。

## 未验证（实话）

- 本机没有 Mac，没有跑过 Xcode 编译；GitHub Actions 构建**还没跑过**，
  工程是否一次通过、模型首次下载编译是否顺利，都要等云端构建 + 真机实测才知道。
- LaMa 的 0.5–2 秒推理速度是 wudijimao/Inpaint-iOS 项目在 iPhone 12+ 上的经验值，
  本工程用的 800×800 模型在 iPhone 15 Pro 上的实际耗时还没测过。
- 模型文件本身已下载验证过输入输出（见上），但**还没在真机上跑通过一次完整消除**。
