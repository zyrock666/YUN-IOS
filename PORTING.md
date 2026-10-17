# 移植决策记录（Porting Notes）

本文件记录 iOS 移植过程中**为什么这么做**，对应上游
[CYQawa/YunX](https://github.com/CYQawa/YunX)（Android）与
[tidain/YunX-Desktop](https://github.com/tidain/YunX-Desktop)（Windows）。

代码层面的细节在各 Swift 文件的头部注释里；这里只留**跨文件、需要拍板**的决策。

---

## 1. 语言与框架：Swift 而非 Kotlin Multiplatform

**决策**：用 Swift + SwiftUI 重写，不引入 KMP。

**理由**：

| 上游依赖 | Kotlin/Native 可用性 | 影响 |
|---|---|---|
| OkHttp 4.12 | 无（JVM-only） | 整个 `data/network` 42 个文件需重写 |
| `org.json` | 无 | JSON 取值辅助全重写 |
| `java.net.URLEncoder` | 无 | 编码逻辑重写 |
| `java.io.File` / `FileChannel` | 无直接等价 | 下载引擎重写 |
| Room + KSP | 无 | DB 层重写 |
| Compose | 有 CMP，但 UI 仍要重做 | UI 层重写 |

也就是说，**协议层能「复用」的部分只剩正则与常量表**，而这部分复制成本极低；
真正的价值在业务语义（踩过的坑），它通过注释与结构设计继承，而不是靠共享二进制。

**结论**：KMP 会引入 cinterop、版本对齐、构建时长三份额外成本，收益为零。

## 2. 平台范围：11 个全量移植

上游 `SharePlatform` 的 11 个取值全部落地：夸克 / UC / 迅雷 / 百度 / 139 /
123 / 115 / 光鸭 / 蓝奏云 / 蓝奏云优享版 / GitHub。

各平台的协议复杂度差异很大，下表是实际移植的工作量分布：

| 平台 | 行数 | 核心难点 |
|---|---|---|
| 蓝奏云 + 优享版 | ~1230 | 无 API，分享页要解析 HTML 提取 `ajaxm.php` 参数 |
| 139（和彩云） | ~950 | AES-128-CBC 请求/响应加密 + `mcloud-sign` 签名 + gzip 解压 |
| 123 云盘 | ~810 | 自写 CRC-32 + 三位替换表签名，`ts+57600s` 时区偏移 |
| 115 | ~600 | 直链走「电脑端」加密接口，版本号需从 `appversion.115.com` 动态拉 |
| 光鸭 | ~550 | access token 三段式 + 设备指纹 |
| 迅雷 | ~420 | 10 层 MD5 captcha 签名 + 设备指纹 + 转存 |
| 百度 | ~430 | 四步链路，必须转存；直链候选要挑明文通道 |
| UC / 夸克 | ~260 each | 同后端，Cookie 会话刷新 |
| GitHub | ~330 | 不是网盘，树形仓库语义映射到三方法 |

### 协议语义映射（各平台不统一，必须知道）

`ShareResolving` 的三个方法在非网盘 / 无 token 接口的平台上需要语义映射：

| 平台 | `stoken` 实际含义 |
|---|---|
| 夸克 / UC | 真正的 `stoken` |
| 百度 | `sekey`（= verify 返回的 randsk） |
| 迅雷 | `pass_code_token` |
| 139 / 123 | **提取码本身**（这两个平台没有独立 token 接口） |
| 115 | `<提取码>\|<分享者 user_id>`（合成为导航凭证） |
| GitHub | 仓库默认分支名 |
| 光鸭 | share access token |

### 必须登录的平台

`SharePlatform.requiresLogin` 标出三个：**百度、115、123**。
- 百度：没有免转存直链接口
- 115：直链接口要求登录态 Cookie
- 123：列目录可匿名，但 `download/info` 必须带 authorToken

## 3. iOS 上砍掉的东西，以及原因

| 上游能力 | iOS 处理 | 原因 |
|---|---|---|
| 内嵌 WebView 登录 | ❌ 不做，改粘贴 Cookie / accessToken | iOS 的 WKWebView Cookie 与 `HTTPCookieStorage` 同步存在域隔离，且各网盘对非官方 UA 的风控策略需单独验证；首版先保证链路可用 |
| 账号密码 / 短信登录（迅雷） | ❌ 不做 | 需要处理活体验证（滑块），iOS 上要接 `ASWebAuthenticationSession`，属于独立子项目 |
| 个人网盘管理（上传/建目录/创建分享） | ❌ 不做 | 与「下载」主链路无关，且每家都要一套完整 CRUD |
| 系统托盘 / 通知中心进度条 | ⚠️ 部分 | 托盘不存在；通知中心进度可后加（`UNNotificationContent` 不支持进度条，需要用 Live Activity，iOS 16.1+） |
| Gopeed 外部下载引擎 | ❌ 不适用 | 依赖可执行子进程，iOS 沙盒不允许 |
| 阻止休眠（`SetThreadExecutionState`） | ❌ 不适用 | iOS 无此 API；后台下载受系统调度限制 |

## 4. 迅雷：首版砍掉登录，保留完整解析链

上游 `XunleiApi.kt` 有 47KB，其中大部分是登录态维护（密码登录、短信、
token 刷新、`__puus` 类会话）。

**决策**：`accessToken` 由用户粘贴导入，失效时提示重新导入。

**代价**：用户体验不如内嵌登录。
**收益**：砍掉了整条登录态链路，但**保留了 100% 的解析 / 转存 / 取直链能力**，
而且这部分（captcha 签名、设备指纹、转存流程）恰好是最容易做错的部分。

**关键点**（照抄上游 Agent.md §3.19）：游客态**不能**写 `Authorization` 头。
带一个失效的 `Bearer ` 会被服务端判成 unauthenticated，比不带更糟。

## 5. 下载引擎：拆开写

上游 `DownloadManager.kt` 单文件 119KB，把队列/分片/合并/限速/通知/去重全塞一起。

**决策**：拆成 `ChunkDownloader`（分片与写盘）+ `DownloadManager`（任务编排）
+ `TaskStore`（持久化）。

**直接收益**：上游 issue #8（「下载一个文件莫名出现两个甚至三个」）的根因
是同一目标被多任务并行写。拆开后，去重逻辑有唯一明确的落点
（`DownloadManager.enqueue` 的 `activeKeys`），不再散落在 119KB 里。

## 6. 写盘并发：串行队列而非按分片开句柄

上游的做法是「每片独立区间 + 汇聚成一个文件」。iOS 版用了另一种等价方案：

- 单个 `FileHandle` 打开目标文件，先 `truncate` 预分配到最终大小；
- 每个分片按自己的 `start + downloaded` 偏移写；
- `seek + write` 放在串行 `DispatchQueue` 里保证原子。

**为什么不用每片一个句柄**：iOS 上同时打开几十个文件句柄没有必要，
且 `FileHandle` 的 `seek` 是共享状态的，串行化反而是最简且正确的做法。
预分配还顺带解决了「边下边扩容」的碎片问题。

## 7. 元数据与断点续传

侧车文件 `xxx.yunx.meta` 记录每片已完成字节数，格式 `{total, chunks:[Int64]}`。

**为什么要存 total**：直链过期后重新取链，服务端返回的文件可能已变化
（分享被更新）。total 不匹配时**丢弃旧进度重新下载**，而不是按错的偏移续写
——后者会产出损坏文件，且很难察觉。

## 8. 凭据存储：Keychain 而非自造密钥文件

桌面版用「AES-GCM + 本地 `credential.key`」，Android 用 Keystore。

**iOS 决策**：直接用 Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。

**理由**：自造密钥文件在 iOS 上是**净负收益** —— 密钥文件会和 App 数据一起进入
iTunes/iCloud 备份，等于把锁和钥匙放同一个袋子里。Keychain 是进程外加密存储，
`ThisDeviceOnly` 保证不随备份迁移。

## 9. 已知风险与待验证项

1. **接口随时可能失效**：所有协议来自抓包与 alist 的公开研究，平台一改就断。
   排查入口：`ResolveError.api` 的错误码映射表。
2. **游客态限制**：夸克游客态单文件约 50MB，UC 更严格。超限必须导入 Cookie。
3. **HTTP/1.1 的实现差异**：本版靠 `httpMaximumConnectionsPerHost` 控并发，
   **未实测**是否完全等价于上游的「禁用 HTTP/2」。若出现内存暴涨，
   优先怀疑这里（见 `HTTPClient.swift` 注释）。
4. **后台下载**：iOS 会在 App 进入后台后很快挂起 `URLSession` 任务。
   本版没有配 `background` session，锁屏下载会暂停。要做需要改用
   `URLSessionConfiguration.background` 并处理 delegate 回调，属于后续工作。
5. **未在真实设备上编译验证**：本次移植的代码是在 Linux 上写的，
   只做了静态结构检查。**首次在 Mac 上编译很可能有少量报错需要修**，
   见 PORTING 末尾的「首次编译检查清单」。

## 10. 首次在 Mac 上编译的检查清单

本移植在 Linux 上编写，**未经过 swiftc 编译**。已完成的是结构级校验
（括号/注释/字符串状态机扫描、类型与成员交叉核对、签名对齐、工程文件对象图完整性），
这些能排除大部分低级错误，但**不能替代真实编译**。

按可能性从高到低，首次编译可能需要处理的点：

1. **`@MainActor` 隔离**：`DownloadManager` / `SettingsStore` 都是 `@MainActor`，
   UI 层在 `Task {}` 或 escaping 闭包里访问它们需要 `Task { @MainActor in ... }`。
   UI 代码已按此写法（见 `DownloadsScreen.pause/resume`），若仍有告警属预期。

2. **`ChunkDownloader.onProgress` 是 `@Sendable`**，在 `DownloadManager.start`
   里用 `[weak task]` 捕获 `@MainActor` 类型；闭包内部已用
   `Task { @MainActor in ... }` 回主线程赋值。若 Swift 6 严格并发下仍报
   "capture of 'task' with non-sendable type"，把该闭包标成
   `@MainActor @Sendable` 即可。

3. ~~`AsyncSemaphore` 的 `defer` 同步调用~~ —— **已修**：分片并发改为
   「窗口灌满 + 完成一个补一个」，信号量已删除（原写法在 `addTask` 前
   `await wait()` 会退化成串行，见 `ChunkDownloader.downloadInChunks` 注释）。

4. ~~`DownloadManager` 与 `SettingsStore` 各自读 UserDefaults~~ —— **已修**：
   配置收敛为单一真相 `SettingsStore`，`DownloadManager` 只接收推送。
   初始化顺序在 `YunXApp.init` 里显式固定为「先 DownloadManager 后 SettingsStore」。

5. ~~UI 层下载时漏传 Referer~~ —— **已修**：改为经 `DownloadHeadersProviding`
   由各平台解析器给完整请求头。夸克/UC 直链缺 Referer 会 403。

6. **`FileHandle.truncate(atOffset:)` / `write(contentsOf:)`** 可用性满足 iOS 16。

7. **Info.plist 与 pbxproj**：`GENERATE_INFOPLIST_FILE = NO` +
   `INFOPLIST_FILE = YunX/Info.plist` 已配好；`UILaunchScreen` 用空 dict，满足 iOS 14+。

8. **AppIcon 占位**：`Assets.xcassets/AppIcon.appiconset` 只有 `Contents.json`，
   需放入一张 1024×1024 PNG，否则打包时有警告（不影响编译与安装）。

9. **`import CommonCrypto`**：139 的 AES-CBC 依赖它。iOS SDK 自带该 module，
   但若某工具链报 `no such module 'CommonCrypto'`，在 `C139Resolver.swift` 顶部
   改为手工声明 `CCCrypt` 等四个 C 符号，或加一个 ObjC 包装类配桥接头。

10. **`Compression` 框架**：139 的 gzip 解压用 `compression_decode_buffer`。
   该框架从 iOS 13 起可用，deployment target 16.0 满足。

11. **并发安全告警**：各解析器标了 `@unchecked Sendable`，内部用 `NSLock` 保护
   可变状态（cookie / token / 缓存）。若 Swift 6 严格并发报「mutable property
   in Sendable class」，检查是否有新增的 `var` 忘了加锁。

12. **蓝奏云的 HTML 解析**：`LanzouResolver` 用 `NSRegularExpression` 提取
   页面里的 `sign` / `ves` / `ajaxm.php` 参数。若平台改版，这里最先失效 ——
   错误信息会明确说「未在页面中找到 xxx」，便于定位。

## 11. 新增文件后必须做的事

本项目未使用 Xcode 16 的文件系统同步分组，`.pbxproj` 里是显式文件列表。
**每次新增 Swift 文件后要重新生成工程**：

```bash
python3 tools/gen_pbxproj.py .
```

生成器用「路径 → 稳定 24 位 hex」的确定性映射，重复运行结果一致，不会产生 diff 噪音。
