# 云析 iOS 版 · YunX-iOS

**粘贴网盘分享链接，直接高速下载 —— 云析 YunX 的 iOS 移植**

支持夸克 / UC / 迅雷分享链接解析，Range 分片并发 + 断点续传 + 全局限速。

> 本项目是 [CYQawa/YunX](https://github.com/CYQawa/YunX)（Android）与
> [tidain/YunX-Desktop](https://github.com/tidain/YunX-Desktop)（Windows）的 **iOS 移植版**，
> 遵循上游 **AGPL-3.0** 协议。上游的解析协议与下载引擎设计是本项目的基础。

---

## 当前状态

| 模块 | 状态 | 说明 |
|---|---|---|
| 分享链接解析 | ✅ 完成 | **11 个平台全覆盖**，含提取码自动识别与 115 口令形态 |
| 夸克 | ✅ 完成 | token → 列目录 → 取直链，含 `__pugs` 游客态与 `__puus` 会话刷新 |
| UC | ✅ 完成 | 与夸克同后端，域名/UA/错误码独立 |
| 迅雷 | ✅ 完成 | 10 层 MD5 captcha 签名、设备指纹、转存后取直链 |
| 百度 | ✅ 完成 | 四步链路：verify → xpan/share → transfer → locatedownload；直链候选挑明文通道 |
| 139（和彩云） | ✅ 完成 | AES-128-CBC 请求/响应加密 + `mcloud-sign` 签名 + gzip 解压 |
| 123 云盘 | ✅ 完成 | 三种分享链接形态，`Platform` 头与设备标识 |
| 115 网盘 | ✅ 完成 | 分享页解析 + 直链换签，需登录态 |
| 光鸭云盘 | ✅ 完成 | share summary → access token → files list |
| 蓝奏云 / 优享版 | ✅ 完成 | 分享页 HTML 解析 + `ajaxm.php` 换直链 |
| GitHub | ✅ 完成 | 仓库/文件直链、Releases、文件树，可选 PAT |
| 分片下载引擎 | ✅ 完成 | Range 探测降级、断点续传、侧车元数据、令牌桶限速 |
| 任务持久化 | ✅ 完成 | JSON 侧车，重启后恢复为「已暂停」 |
| 凭据存储 | ✅ 完成 | Keychain（设备绑定，不随备份迁移）+ 账号管理页 |
| SwiftUI 界面 | ✅ 完成 | 解析 / 下载 / 设置 / 账号 四页 |
| 内嵌浏览器登录 | ⬜ 未移植 | iOS 用 WKWebView 可做，但 Cookie 提取与网盘风控策略需单独验证 |
| Gopeed 外部引擎 | ❌ 不适用 | 桌面版才有的 exe 子进程方案 |

### 各平台能力对照

| 平台 | 分享解析 | 需要登录 | 取链方式 | 备注 |
|---|---|---|---|---|
| 夸克 | ✅ | 否（游客限 50MB） | 免转存 | `__puus` 会话约 3 小时需刷新 |
| UC | ✅ | 否 | 免转存 | 游客缺 `__pugs` 返回 403 |
| 迅雷 | ✅ | 否 | **转存** | captcha 签名 + 设备指纹 |
| 百度 | ✅ | **是** | **转存** | ⚠️ 有账号风控风险 |
| 139 | ✅ | 否（可选） | 免转存 | 接口加密，直链 900 秒有效 |
| 123 | ✅ | 否 | 免转存 | |
| 115 | ✅ | **是** | 免转存 | |
| 光鸭 | ✅ | 否 | 免转存 | |
| 蓝奏云 | ✅ | 否 | 免转存 | 需解析 HTML |
| 优享版 | ✅ | 否 | 免转存 | |
| GitHub | ✅ | 否（PAT 可选） | 直链 | 无「提取码」概念 |

## 快速开始

```bash
# macOS + Xcode 15 以上
open YunX.xcodeproj        # 直接跑模拟器

./build-ipa-unsigned.sh    # 免签名 IPA（Sideloadly / AltStore 自签用）
./build-ipa.sh --team-id YOURTEAMID --export-method development   # 签名 IPA
```

详细的签名、真机安装与报错排查见 **[BUILD.md](BUILD.md)**。

## 技术栈

| 分类 | 选型 |
|---|---|
| 语言 | Swift 5.9 |
| UI | SwiftUI（iOS 16+） |
| 网络 | URLSession（强制 HTTP/1.1，见下方说明） |
| 持久化 | JSON 文件（任务）+ UserDefaults（设置） |
| 凭据 | Keychain（`AfterFirstUnlockThisDeviceOnly`） |
| 加密 | CryptoKit（MD5/SHA1 等摘要）+ CommonCrypto（139 的 AES-CBC）+ Compression（gzip） |
| 构建 | xcodebuild + 手写 IPA 组装 |

无任何第三方依赖。

## 与上游的关键设计对照

### 为什么不用 Kotlin Multiplatform

上游是 Kotlin + Compose。理论上可以用 KMP 编译出 iOS framework 复用协议层，
但本项目**没有这么做**，原因：

1. 上游网络层直接依赖 OkHttp、`org.json`、`java.net.URLEncoder`，这些在
   Kotlin/Native 上都没有等价实现，需要整层重写。
2. 上游下载引擎用了 `java.io.File` / `FileChannel` 与多线程写盘，
   Kotlin/Native 的并发模型（新内存管理器下的对象冻结规则）意味着这部分同样要重写。
3. 重写后的 Kotlin 代码量不比 Swift 少，却多了一层 cinterop 与构建复杂度。

结论：**直接写 Swift 更快也更稳**。协议常量与算法逻辑逐条对照移植，
业务语义与上游保持一致（详见各文件的文件头注释）。

### 下载引擎照抄的三条约束

1. **先探测 Range 支持**：发 `Range: bytes=0-0`，只有回 206 才敢分片；
   否则退化成单流下载。上游踩过「CDN 声明支持但回 200」的坑。
2. **强制 HTTP/1.1**：上游实测 OkHttp 的 HTTP/2 每流 16MB 接收窗口，
   消费端一慢（写盘慢/限速挂起）就会把堆撑爆。iOS 版通过
   `httpMaximumConnectionsPerHost = 32` + 禁用 pipelining 配合分片。
3. **按区间写盘**：串行队列保护 `seek + write`，避免多分片写同一
   `FileHandle` 的 offset 竞争。

### 规避了上游 issue #8

上游「下载一个文件莫名出现两个甚至三个」的原因是同一目标文件被多个任务
并行写。本版在 `DownloadManager.enqueue` 里按 `直链 + 目标路径` 去重，
已存在未完成任务时直接返回原任务。

### 迅雷设备指纹

上游注释写明：开源分发后所有用户共享同一个官方抓包指纹，会被风控识别并
连带封禁。本版沿用「每台设备首次启动生成唯一指纹并持久化」的策略，
指纹存在 Keychain 而非 Data 文件。

## 合规与免责声明

1. **项目性质**：本项目仅供个人学习、研究与技术交流，非商业用途，不提供任何担保。
2. **禁止商用**：完全免费开源。若你付费购买到本项目，说明你被骗了，请立即退款并举报。
3. **内容版权**：本项目不存储、不上传、不分发任何受版权保护的文件，仅对用户自行提供的
   分享链接进行解析与下载。通过本项目下载的内容版权归原作者所有；请在下载后
   **24 小时内删除**，因未删除引发的版权纠纷与本项目无关。
4. **平台风险**：本项目与夸克、UC、迅雷等平台无任何关联。解析能力基于公开接口的
   抓包分析整理，**可能随平台调整而失效**；使用第三方工具访问平台存在账号被风控、
   限制或封禁的风险（尤其百度网盘），后果由使用者自行承担。
5. **协议逆向说明**：部分解析逻辑参考了开源项目（如 alist）的协议研究。
6. **接受即同意**：一旦下载、安装或使用本项目，即表示你已阅读并同意上述全部条款。

## 目录结构

```
YunX-iOS/
├── YunX.xcodeproj/
├── YunX/
│   ├── App/YunXApp.swift              入口，初始化顺序对齐上游
│   ├── Model/ShareModels.swift         领域模型 + ResolveError
│   ├── Network/
│   │   ├── ShareLinkParser.swift       分享链接/文案解析
│   │   ├── ShareResolving.swift        统一协议 + ResolverFactory
│   │   ├── HTTPClient.swift            URLSession 封装 + JSON 取值辅助
│   │   ├── XunleiCrypto.swift          设备指纹 + captcha 签名
│   │   └── Platforms/  11 个平台实现（Quark/UC/Xunlei/Baidu/C139/Pan123/Pan115/GuangYa/Lanzou/GitHub）
│   ├── Download/
│   │   ├── ChunkDownloader.swift       分片引擎（Range/续传/限速）
│   │   └── DownloadManager.swift       任务编排与去重
│   ├── Storage/{KeychainStore,SettingsStore,TaskStore}.swift
│   └── UI/{RootView, Screens/(Resolve,Downloads,Settings,Accounts), Components/}
├── build-ipa.sh                        签名打包
├── build-ipa-unsigned.sh               免签名打包
├── BUILD.md                            构建与安装说明
└── PORTING.md                          移植细节与决策记录
```

## 开发

新增 Swift 文件后需要重新生成工程文件（本项目未使用 Xcode 的文件系统同步分组）：

```bash
python3 tools/gen_pbxproj.py .
```

## 许可

AGPL-3.0。若你使用本项目的代码，须同样以 AGPL-3.0 开放源代码。
