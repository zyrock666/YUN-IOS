//
//  Pan123Resolver.swift
//  云析 YunX iOS —— 123 云盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//    - data/network/Pan123Api.kt           —— makeSign / getShareFiles / getShareDownloadLink /
//                                             parseInfoList / decodeToken / decodeDownloadUrl /
//                                             followRedirectUrl / getAuth / postAuth / executeJson
//    - data/network/Pan123Constants.kt     —— 域名、路径、UA、platform/app-version、签名常量
//    - data/network/Pan123DeviceId.kt      —— loginuuid 设备标识（32 位十六进制、长期复用；
//                                             iOS 上落到 KeychainStore，键 `pan123.login_uuid`）
//    - data/network/Pan123LoginSupport.kt  —— 令牌可用性校验（isValidToken）
//  只移植「分享解析 → 取直链」这条主链路；账号密码登录 / 个人盘 CRUD / 转存 / 建分享
//  不在 iOS 首版范围内（与 QuarkResolver / UCResolver 的取舍一致）。
//
//  ## 本平台的关键坑（逐条来自上游注释，改代码前先读）
//  1. **分享 Key 里有一个中划线**：形如 `2785Vv-T4Ded`。它是分享短码的一部分，
//     **不能**按 `-` 切分、也不能改成别的分隔符；列表接口里要整体作为 `shareKey` 参数传出去
//     （只做一次标准 URL 编码）。分享链接的三种形态（`www.123pan.com/s/xxx`、
//     `<uid>.share.123pan.cn/123pan/xxx`、`api/srr?sk=xxx`）解析出来的 shareId 都是这串原样。
//  2. **两个不同的域，按用途分开**：
//     - 分享列表 `https://yun.123pan.cn/b/api/share/get` —— 匿名、**无签名**，
//       UA 必须是 `Dart/3.12 (dart:io)`（服务端按 UA 走不同网关，浏览器 UA 拿不到数据）。
//     - 下载信息 `https://www.123865.com/b/api/share/download/info` —— **需登录 + 签名**，
//       platform 头是 `android`、app-version 是 `39`（与 web 系的 `3` 不同）。
//  3. **签名内部固定 web/3**：auth-value 的拼接里 OS 常量写死 `web`、VER 写死 `3`，
//     与请求头里的 platform / app-version **无关**（文档 §6.3）。签名 path 含 `/b`、不含 host、不含 query。
//  4. **auth-key 用「ts + 16 小时」的 UTC 时间**：`ts + 57600s` 后按 UTC 格式化成
//     `YYYYMMDDHHmm`，再把**每位数字**按替换表 `adefghlmyijnopkqrstubcvwsz` 换掉（下标 = 数字值），
//     最后 crc32 → 小写十六进制（**不补零**，与 `Long.toHexString` 一致）。
//     auth-value = `"<ts>-<random>-<crc32(ts|random|path|web|3|authKey)>"`。
//  5. **无提取码时不能传 `SharePwd`**：传空值会返回 400 "请输入Next"（抓包实证）。
//  6. **`Next == "-1"` 才是末页**：空串 `""` 表示「还有下一页」，数字是游标。
//     把空串当末页会导致只显示首页 100 条（文档 §5.2）。
//  7. **下载地址是包装过的，不能直接下**：`data.DownloadURL` 可能是
//     `download-v2?params=<base64url>` 中转页，也可能是整段 base64（alist 风格）。
//     必须先 `decodeDownloadUrl` 解出真实 CDN 地址；再循环跟随可能存在的
//     `auto_redirect=0` JSON 跳转（`data.redirect_url`）。
//     ⚠️ 绝不能用 `startsWith("http")` 短路判断——中转页 URL 同样以 http 开头。
//  8. **`loginuuid` 是设备指纹**：123 用它做风控，生成一次就要长期复用（存在 Keychain）。
//     每次启动换新值会被当成新设备，更容易触发验证（上游 Pan123DeviceId 的注释）。
//  9. **取链必须登录**：签名 + Bearer 缺一不可；分享**列表**却完全匿名。
//     所以本解析器允许 token 为空进入 `resolveToken` / `listFiles`，只在 `downloadLink` 处报错。
//
//  ## iOS 首版收敛
//  上游 `Pan123Api.kt` 有 36KB，含账号密码登录、个人盘 CRUD、转存（mshare 子域）、建分享。
//  iOS 首版只保留分享链路；token 由用户在设置页粘贴导入（网页 localStorage 里的 `authorToken`，
//  与上游账号密码登录拿到的 `data.token` 同源同形），存 Keychain 键 `token.pan123`。
//

import Foundation
import CryptoKit
import Security

// MARK: - 常量（Pan123Constants.kt）

/// 123 的域名、路径、请求头值与签名常量。
///
/// 放在文件级而不是 `Pan123Resolver` 的嵌套 `private enum`：签名函数
/// （`Pan123Support.makeSign`）也要读这些值，而嵌套类型即使声明成 `fileprivate`
/// 也要写全 `Pan123Resolver.Constants`，且 `private` 完全不可见。
/// 放在文件级、声明为 `fileprivate`，两处都能直接用 `Constants.xxx`。
fileprivate enum Constants {

    /// 个人盘业务 API / 分享列表（主域式）
    static let apiBase = "https://yun.123pan.cn"
    /// 分享下载信息（抓包实证；alist 用 yun.123pan.com 等价）
    static let downloadBase = "https://www.123865.com"

    /// 分享文件列表（GET /b/api/share/get，匿名、无签名）
    static let shareGetURL = "https://yun.123pan.cn/b/api/share/get"
    /// 分享下载信息（POST /b/api/share/download/info，需登录 + 签名）
    static let shareDownloadInfoURL = "https://www.123865.com/b/api/share/download/info"

    /// 签名用 path（含 /b、不含 host、不含 query，必须与请求 URL 的 path 逐字一致）
    static let shareGetPath = "/b/api/share/get"
    static let shareDownloadInfoPath = "/b/api/share/download/info"

    // —— 公共请求头（文档 §3.2）——

    /// 浏览器 UA（web 系抓包）
    static let webUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/127.0.0.0 Safari/537.36"
    /// Dart UA（分享列表匿名请求，服务端按 UA 分网关）
    static let dartUA = "Dart/3.12 (dart:io)"

    /// platform：web（个人盘 / 分享列表 / 登录）
    static let platformWeb = "web"
    /// platform：android（分享下载信息 www.123865.com）
    static let platformAndroid = "android"

    /// app-version：web 系
    static let appVersionWeb = "3"
    /// app-version：android 系（仅分享下载）
    static let appVersionAndroid = "39"

    /// 分享下载真实 CDN 直链下载时必须携带的 Referer（文档 §5.3.1）
    static let downloadReferer = "https://yun.123pan.cn/"

    // —— 签名常量（文档 §6.2）——

    /// 数字 0-9 的替换表，索引 = 数字值
    static let signTable = Array("adefghlmyijnopkqrstubcvwsz")
    /// 签名内部固定 OS
    static let signOS = "web"
    /// 签名内部固定 VER
    static let signVER = "3"
    /// timeSign 时间基准偏移：ts + 57600 秒（+16h，UTC 格式化；抓包实证，文档 §6.3）
    static let signOffsetSeconds: Int64 = 57600

    /// 分享列表每页条数（上游 limit=100）
    static let pageSize = 100

    /// 跟随 auto_redirect JSON 跳转的最大跳数（上游 repeat(5)）
    static let maxRedirectHops = 5
    /// 判为「JSON 跳转页」而非真实文件的响应体上限（8KB）
    static let redirectProbeMaxBytes = 8192
}

// MARK: - 签名 / 设备标识 / 工具（对应 Pan123Api.kt 的 §6 与 Pan123DeviceId.kt）

/// 123 的签名、CRC32、设备标识与 URL 解码工具。
///
/// 全部放在无状态 `enum` 里：`Pan123Resolver` 是 `@unchecked Sendable` 的 class，
/// Swift 6 不允许从并发上下文访问它的 `private static func`。
fileprivate enum Pan123Support {

    // MARK: §6 签名算法

    /// 生成签名头（文档 §6.2）：返回 `(auth-key, auth-value)`。
    ///
    /// - `auth-key`（timeSign）= crc32_hex(替换表映射后的 UTC "YYYYMMDDHHmm"，基准 ts + 57600s = +16h)
    /// - `auth-value` = `"<ts>-<random>-<crc32_hex(ts|random|path|web|3|auth_key)>"`
    ///
    /// - Parameters:
    ///   - path: URL 路径，含 `/b` 前缀、不含 host、不含 query（如 `/b/api/share/download/info`）
    ///   - ts: Unix 秒。默认取当前时间。
    static func makeSign(path: String, ts: Int64 = Int64(Date().timeIntervalSince1970)) -> (authKey: String, authValue: String) {
        // 1) auth-key：ts + 16h 以 UTC 格式化为 YYYYMMDDHHmm，再逐位数字替换
        let shifted = Date(timeIntervalSince1970: TimeInterval(ts + Constants.signOffsetSeconds))
        let minute = utcMinuteText(shifted)

        var substituted = ""
        substituted.reserveCapacity(minute.count)
        for character in minute {
            guard let digit = character.wholeNumberValue, digit >= 0, digit <= 9,
                  digit < Constants.signTable.count else {
                // Kotlin 的 `SIGN_TABLE[it - '0']` 越界会抛 IndexOutOfBounds；
                // 这里显式失败，避免静默拼出一个永远验不过的签名
                return ("", "")
            }
            substituted.append(Constants.signTable[digit])
        }
        let authKey = crc32Hex(substituted)

        // 2) auth-value：ts|random|path|web|3|auth_key 的 crc32（OS/VER 固定，与请求头无关）
        let random = Int.random(in: 0..<10_000_000)
        let data = "\(ts)|\(random)|\(path)|\(Constants.signOS)|\(Constants.signVER)|\(authKey)"
        let authValue = "\(ts)-\(random)-\(crc32Hex(data))"
        return (authKey, authValue)
    }

    /// 按 UTC 格式化 `%04d%02d%02d%02d%02d`（年/月/日/时/分）。
    ///
    /// 用 `Calendar(identifier: .gregorian)` + `TimeZone(identifier: "UTC")`，
    /// 与 Kotlin `Calendar.getInstance(TimeZone.getTimeZone("UTC"))` 等价；
    /// 刻意不用 DateFormatter —— 它受 Locale / 历史历法设置影响，年份可能不是公历。
    static func utcMinuteText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return String(format: "%04d%02d%02d%02d%02d", year, month, day, hour, minute)
    }

    /// 标准 CRC-32（IEEE 802.3）→ **不带前导零**的小写十六进制。
    ///
    /// 对齐 Kotlin：`java.lang.Long.toHexString(crc.value and 0xFFFFFFFFL)`
    /// —— 注意它**不补零**（Python 的 `format(crc,'x')` 同样不补零），
    /// 所以长度可能是 1~8 位，不能写成 `%08x`（那会签出不同的值）。
    static func crc32Hex(_ text: String) -> String {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in text.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        let value = crc ^ 0xFFFF_FFFF
        return String(value, radix: 16, uppercase: false)
    }

    // MARK: 设备标识（Pan123DeviceId）

    /// Keychain 里存 loginuuid 的键（对齐上游 SharedPreferences 的 `pan123_device` / `login_uuid`）
    static let deviceIdKeychainKey = "pan123.login_uuid"

    /// 取设备标识：优先 Keychain 里已存的合法值，否则生成一个并落盘。
    ///
    /// 未初始化或读写失败时退化为临时值（只影响风控观感，不影响功能）——
    /// 与上游「未初始化时 `Pan123Constants.newLoginUuid()`」一致。
    static func deviceId() -> String {
        let store = KeychainStore.shared
        if let saved = store.string(forKey: deviceIdKeychainKey), isValidDeviceId(saved) {
            return saved
        }
        let generated = newLoginUuid()
        // 存进去的必须就是以后要用的那个值，否则「换了设备」的判断会跟着一起飘。
        // 写失败不抛错：最多下次再生成一个。
        _ = store.set(generated, forKey: deviceIdKeychainKey)
        return generated
    }

    /// 32 位十六进制（对齐上游 `HEX32 = "^[0-9a-fA-F]{32}$"`）。
    static func isValidDeviceId(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.unicodeScalars.allSatisfy { hexSet.contains($0) }
    }

    /// 生成 32 位十六进制 loginuuid（文档 §3.2：设备标识，不参与签名，可固定复用）。
    static func newLoginUuid() -> String {
        let pool = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(32)
        for byte in randomBytes(32) {
            out.append(pool[Int(byte) % pool.count])
        }
        return out
    }

    /// 密码学安全随机字节；失败时退化为时间派生伪随机（仅兜底）。
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        // 用 withUnsafeMutableBytes 显式取指针，而不是依赖 `&bytes` 的隐式转换：
        // `SecRandomCopyBytes` 第三参是 `UnsafeMutableRawPointer`，数组的 inout
        // 隐式转换在不同 Swift 版本下行为不一致，显式写法没有歧义。
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        if ok {
            return bytes
        }
        var seed = UInt64(Date().timeIntervalSince1970 * 1_000_000) ^ UInt64(count)
        for index in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8((seed >> 33) & 0xFF)
        }
        return bytes
    }

    // MARK: 令牌校验（Pan123LoginSupport.isValidToken）

    /// 令牌是否可用：非空、长度合理、不含控制字符（换行/空字节混进去会污染请求头）。
    static func isValidToken(_ value: String) -> Bool {
        if value.isEmpty || value.count > 16384 { return false }
        for scalar in value.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F { return false }
        }
        return true
    }

    // MARK: 下载地址解码（文档 §5.3.1）

    /// 解码 123 的下载 URL，兼容两种形态：
    /// - 形态 1：整段 base64（alist 风格，不含协议头）→ 直接解码
    /// - 形态 2：`download-v2?params=<base64 URL-safe>` → 解码 params
    ///
    /// 解码失败返回 nil，调用方回退到原串。
    static func decodeDownloadUrl(_ downloadUrl: String) -> String? {
        let trimmed = downloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // 形态 1：整段 base64（不含协议头）
        if !trimmed.contains("://") {
            guard let data = decodeBase64Loose(trimmed),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text.lowercased().hasPrefix("http") ? text : nil
        }

        // 形态 2：download-v2?params=<base64>
        // Kotlin: indexOf("params=") 后 substringBefore("&")
        guard let range = trimmed.range(of: "params=") else { return nil }
        var params = String(trimmed[range.upperBound...])
        if let amp = params.firstIndex(of: "&") {
            params = String(params[..<amp])
        }
        // Kotlin: replace('-', '+').replace('_', '/') —— URL-safe base64 还原成标准表
        let normalized = params
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = decodeBase64Loose(normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 宽松 base64 解码：等价于 Java `Base64.decode(s, Base64.DEFAULT)`
    /// —— **忽略非法字符**（含换行与空白），缺省填充时可容忍无 `=` 的尾部。
    static func decodeBase64Loose(_ text: String) -> Data? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Java 的 DEFAULT 解码器允许省略填充；Foundation 要求长度是 4 的倍数，这里补齐
        while candidate.count % 4 != 0 {
            candidate.append("=")
        }
        return Data(base64Encoded: candidate, options: [.ignoreUnknownCharacters])
    }

    // MARK: 错误文案（Pan123Api.checkOk）

    /// 成功判定：`code == 0`（登录接口除外，是 200）。失败文案优先用服务端 `message`。
    static func errorMessage(code: Int, message: String, fallback: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return code < 0 ? fallback : "\(fallback)（code=\(code)）"
    }
}

// MARK: - 解析器

/// 123 云盘解析器。
///
/// 凭据是 Bearer token（网页登录后 localStorage 里的 `authorToken`），通过 `updateToken` 注入。
/// - `resolveToken` / `listFiles`：**匿名可走**（分享列表接口不需要登录）。
/// - `downloadLink`：**必须登录**（接口要签名 + Bearer）。
final class Pan123Resolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 状态

    private let client = HTTPClient.shared
    /// Bearer token（网页 localStorage 的 authorToken）。为空 = 未登录。
    private var token: String
    /// 设备标识 loginuuid，懒加载后缓存（对应上游 object 里的 @Volatile cached）
    private var cachedDeviceId: String?
    private let lock = NSLock()

    /// 上游 `Pan123Api(clientProvider)` 收敛成 `init(token:)`。
    ///
    /// 123 的凭据本质上是一个 authorToken，`ResolverFactory` 按 `token:` 注入。
    init(token: String = "") {
        self.token = token
    }

    /// 注入/更新 token。
    func updateToken(_ newToken: String) {
        lock.lock(); defer { lock.unlock() }
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 与 `updateToken` 等价的 Cookie 入口（保持与其他平台一致的调用形态）。
    func updateCookie(_ newCookie: String) {
        updateToken(newCookie)
    }

    /// 是否处于登录态（对齐上游 `Pan123LoginSupport.isValidToken`）。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return Pan123Support.isValidToken(token)
    }

    // MARK: - ShareResolving

    /// Step 0：换「访问凭证」。
    ///
    /// 123 的分享列表接口是匿名的，没有「用提取码换 stoken」这一步：
    /// 这里拉一次首页（`Page=1`、`next=0`）来拿**分享标题**（`data.ShareName`）与
    /// 根目录第一项 fid，填满 `ShareToken`；`stoken` 原样回传提取码，供后续调用沿用。
    ///
    /// 提取码错误 / 分享失效能在这里就地暴露（`Expired` 或 `code != 0`），
    /// 不用等到列目录才发现。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let pwd = share.pwd ?? ""
        let (files, _) = try await fetchShareList(
            shareKey: share.shareId,
            sharePwd: pwd,
            parentFileId: "0",
            next: "0",
            page: 1,
            title: { $0.optString("ShareName") }
        )
        let title = lastShareName
        return ShareToken(
            stoken: pwd,
            title: title,
            firstFid: files.first?.fid ?? "0"
        )
    }

    /// Step 1：列目录（`GET /b/api/share/get`，匿名、无签名）。
    ///
    /// - `pdirFid` 为 `"0"` / 空串 = 分享根目录。
    /// - `page` 从 1 开始；`next` 游标这里固定传 `"0"`（首屏），
    ///   上游的 `Next` 游标只有在同一目录内连续翻页才用得上，而协议签名不暴露游标，
    ///   所以按页号传 `Page` 并让服务端从头算（与上游 `getShareFiles(..., next = "0", page)` 同形态）。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let pwd = stoken.isEmpty ? (share.pwd ?? "") : stoken
        let parent = pdirFid.isEmpty ? "0" : pdirFid
        let safePage = max(1, page)

        let (files, _) = try await fetchShareList(
            shareKey: share.shareId,
            sharePwd: pwd,
            parentFileId: parent,
            next: "0",
            page: safePage,
            title: { _ in "" }
        )
        return files
    }

    /// Step 2：取下载直链（`POST /b/api/share/download/info`，需登录 + 签名）。
    ///
    /// body 字段逐条对照上游：`ShareKey / FileID / S3KeyFlag / Size / Etag`。
    /// `S3KeyFlag` 与 `Etag` 来自列表项的 `fidToken`（编码格式 `"S3KeyFlag|Etag|StorageNode"`）。
    func downloadLink(
        for file: ShareFile,
        share: ParsedShare,
        stoken: String
    ) async throws -> DownloadLink {
        let bearer = currentToken()
        guard Pan123Support.isValidToken(bearer) else {
            throw ResolveError.api("123 云盘取下载直链需要登录，请在设置页导入 authorToken")
        }

        let decoded = decodeToken(file.fidToken)
        let body: [String: Any] = [
            "ShareKey": share.shareId,
            "FileID": file.fid,
            "S3KeyFlag": decoded.s3KeyFlag,
            "Size": file.fsize,
            "Etag": decoded.etag
        ]
        // 签名 path 与请求头一致（含 /b）；分享下载信息走 android 平台头，签名内部仍固定 web/3
        let json = try await postAuth(
            url: Constants.shareDownloadInfoURL,
            path: Constants.shareDownloadInfoPath,
            body: body,
            token: bearer,
            platform: Constants.platformAndroid,
            appVersion: Constants.appVersionAndroid
        )
        try checkOk(json, fallback: "获取下载链接失败")

        guard let data = json.optObject("data") else {
            throw ResolveError.api("未返回下载链接")
        }
        let raw = data.optString("DownloadURL")
        guard !raw.isEmpty else {
            throw ResolveError.api("下载直链为空，可能是分享已失效或需要登录")
        }

        // download-v2 包装 URL → Base64 解码 params 得真实 CDN 文件 URL（文档 §5.3.1）
        let unpacked = Pan123Support.decodeDownloadUrl(raw) ?? raw
        // 再循环跟随可能存在的 redirect_url（auto_redirect=0）
        let realURL = try await followRedirectUrl(unpacked)
        guard !realURL.isEmpty else {
            throw ResolveError.api("下载直链解析失败")
        }

        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: realURL,
            size: file.fsize,
            // 123 直链靠 URL 自带的过期签名，没有游客 Cookie
            guestCookie: ""
        )
    }

    // MARK: - DownloadHeadersProviding

    /// 直链下载所需请求头。
    ///
    /// 123 的 CDN 直链必须带 `Referer: https://yun.123pan.cn/`，否则 403；
    /// token 本身不进下载头（签名已在 URL 里）。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        [
            "Referer": Constants.downloadReferer,
            "User-Agent": Constants.dartUA
        ]
    }

    // MARK: - 分享列表

    /// `resolveToken` 里临时缓存分享名（`fetchShareList` 是 async，闭包返回值不好穿出来）。
    private var lastShareNameStorage: String = ""

    /// 读缓存（线程安全）。
    private var lastShareName: String {
        lock.lock(); defer { lock.unlock() }
        return lastShareNameStorage
    }

    /// 写缓存（线程安全）。
    private func storeShareName(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        lastShareNameStorage = value
    }

    /// 拉一页分享列表（匿名、无签名），返回 `(文件列表, 下一页游标 or nil = 末页)`。
    ///
    /// - Parameter title: 从 `data` 里取标题的闭包（`resolveToken` 用 `ShareName`，`listFiles` 用完丢弃）
    private func fetchShareList(
        shareKey: String,
        sharePwd: String,
        parentFileId: String,
        next: String,
        page: Int,
        title: (([String: Any]) -> String)?
    ) async throws -> ([ShareFile], String?) {
        // 参数顺序与抓包一致（§5.2 文件夹分享 / 有提取码）；
        // ⚠️ 无提取码时**不传** SharePwd（传空值会 400 "请输入Next"）
        var components = URLComponents(string: Constants.shareGetURL)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(Constants.pageSize)),
            URLQueryItem(name: "next", value: next),
            URLQueryItem(name: "orderBy", value: "file_name"),
            URLQueryItem(name: "orderDirection", value: "asc"),
            URLQueryItem(name: "shareKey", value: shareKey),
            URLQueryItem(name: "ParentFileId", value: parentFileId),
            URLQueryItem(name: "Page", value: String(page))
        ]
        if !sharePwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "SharePwd", value: sharePwd))
        }
        components?.queryItems = items

        guard let url = components?.url?.absoluteString else {
            throw ResolveError.api("123 分享列表地址构造失败")
        }

        // 分享列表用 Dart UA，且不带任何鉴权/签名头
        let headers: [String: String] = ["User-Agent": Constants.dartUA]
        let json = try await executeJSON(HTTPClient.Request(url: url, method: "GET", headers: headers))
        try checkOk(json, fallback: "获取文件列表失败")

        guard let data = json.optObject("data") else {
            return ([], nil)
        }
        if data.optBool("Expired") {
            throw ResolveError.api("分享已失效")
        }
        if let title {
            storeShareName(title(data))
        }

        let files = parseInfoList(data)
        // 文档 §5.2：Next == "-1" 无下一页；空串 "" 表示还有下一页（需继续翻页）；数字为游标
        let nextCursor = data.optString("Next")
        return (files, nextCursor == "-1" ? nil : nextCursor)
    }

    /// 解析响应 `InfoList`（分享与个人盘结构一致，文档 §5.2/§5.4）。
    private func parseInfoList(_ data: [String: Any]) -> [ShareFile] {
        var files: [ShareFile] = []
        for item in data.optArray("InfoList") {
            let type = item.optInt("Type")
            files.append(ShareFile(
                fid: item.optString("FileId"),
                fname: item.optString("FileName"),
                fsize: item.optInt64("Size"),
                isdir: type == 1,
                pdirFid: item.optString("ParentFileId"),
                // 123 下载 / 转存需要 S3KeyFlag + Etag + StorageNode，
                // 编码进 fidToken："S3KeyFlag|Etag|StorageNode"
                fidToken: "\(item.optString("S3KeyFlag"))|\(item.optString("Etag"))|\(item.optString("StorageNode"))",
                modifyTime: item.optString("UpdateAt")
            ))
        }
        return files
    }

    /// 解码 fidToken（`"S3KeyFlag|Etag|StorageNode"`；旧格式两段时 StorageNode 为空）。
    private func decodeToken(_ fidToken: String) -> (s3KeyFlag: String, etag: String, storageNode: String) {
        // Kotlin 的 split('|') 保留空段，这里用 omittingEmptySubsequences: false 对齐
        // —— "abc||" 必须解出 ["abc", "", ""] 而不是 ["abc"]
        let parts = fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let s3KeyFlag = parts.count > 0 ? parts[0] : ""
        let etag = parts.count > 1 ? parts[1] : ""
        let storageNode = parts.count > 2 ? parts[2] : ""
        return (s3KeyFlag, etag, storageNode)
    }

    // MARK: - 鉴权请求

    /// 鉴权 POST（带 auth-key / auth-value 签名头；签名内部固定 web/3）。
    private func postAuth(
        url: String,
        path: String,
        body: [String: Any],
        token: String,
        platform: String = Constants.platformWeb,
        appVersion: String = Constants.appVersionWeb
    ) async throws -> [String: Any] {
        let sign = Pan123Support.makeSign(path: path)
        // 空签名说明替换表越界（理论不可达），先失败，避免服务端只回一个无意义的 401
        guard !sign.authKey.isEmpty else {
            throw ResolveError.api("123 签名生成失败（时间格式化异常）")
        }
        // 头部逐条对照上游 postAuth：platform / app-version / authorization / loginuuid /
        // auth-key / auth-value / Content-Type / User-Agent
        let headers: [String: String] = [
            "platform": platform,
            "app-version": appVersion,
            "authorization": "Bearer \(token)",
            "loginuuid": deviceId(),
            "auth-key": sign.authKey,
            "auth-value": sign.authValue,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Constants.webUA
        ]

        let payload = try jsonData(body)
        return try await executeJSON(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: payload
        ))
    }

    /// 发请求并解析 JSON（对应上游 `executeJson`）。
    ///
    /// 上游：响应体为空 → 「请求失败：响应为空（code）」；
    /// 非 2xx 且响应体为空 → 「请求失败（HTTP code）」。
    private func executeJSON(_ request: HTTPClient.Request) async throws -> [String: Any] {
        let (data, http) = try await client.send(request)
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !(200..<300).contains(http.statusCode) {
                throw ResolveError.network("请求失败（HTTP \(http.statusCode)）")
            }
            throw ResolveError.network("请求失败：响应为空（\(http.statusCode)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(text.prefix(120))
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）：\(preview)")
        }
        return json
    }

    /// 成功判定：`code == 0`（登录接口除外，为 200）。
    private func checkOk(_ json: [String: Any], fallback: String) throws {
        let code = json.optInt("code", -1)
        if code == 0 { return }
        throw ResolveError.api(
            Pan123Support.errorMessage(code: code, message: json.optString("message"), fallback: fallback)
        )
    }

    // MARK: - 跳转跟随

    /// 跟随 123 CDN 的 `redirect_url`。
    ///
    /// 带 `auto_redirect=0` 时 GET 直链返回 `{"code":0,"data":{"redirect_url":"https://...pd1.cjjd19.com/..."}}`
    /// 而不是文件本身，且 `redirect_url` 自己也可能带 `auto_redirect=0`（可能多跳）。
    /// 上游循环最多 5 跳，每跳只在响应体很小（≤8KB，JSON 跳转页）时才读取解析；
    /// 大响应视为真实文件流，返回当前 URL。
    private func followRedirectUrl(_ initialUrl: String) async throws -> String {
        var url = initialUrl
        for _ in 0..<Constants.maxRedirectHops {
            guard let next = try await probeJsonRedirect(url: url) else { return url }
            if next == url { return url }
            url = next
        }
        return url
    }

    /// 探测单跳：响应为小 JSON 且含 `data.redirect_url` 时返回新地址，否则 nil。
    private func probeJsonRedirect(url: String) async throws -> String? {
        let headers: [String: String] = [
            "Referer": Constants.downloadReferer,
            "User-Agent": Constants.dartUA
        ]
        // 只取响应体（上游读 Content-Length 判断大小；URLSession 不给 0 长度探针，
        // 这里直接读完再用大小判定。上限 8KB 的判定逻辑保持一致）
        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            method: "GET",
            headers: headers
        ))
        // 上游只在 `len >= 0 && len <= 8192` 时才读 body；拿不到 Content-Length 时按实际大小判断
        let headerLength = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let effectiveLength = headerLength ?? Int64(data.count)
        if effectiveLength < 0 || effectiveLength > Int64(Constants.redirectProbeMaxBytes) { return nil }
        if data.count > Constants.redirectProbeMaxBytes { return nil }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Kotlin: body.trimStart().startsWith("{")
        let trimmed = text.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard trimmed.hasPrefix("{") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = json.optObject("data") else { return nil }
        let redirect = inner.optString("redirect_url")
        return redirect.isEmpty ? nil : redirect
    }

    // MARK: - 小工具

    /// 读当前 token（线程安全）。
    private func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    /// 设备标识（懒加载后缓存，对应上游 `@Volatile cached`）。
    /// 注意：这里**不能**用 `defer { lock.unlock() }` —— 函数中间要先去访问 Keychain
    /// （可能较慢），持锁期间不能做 I/O，所以手动成对加解锁。
    private func deviceId() -> String {
        lock.lock()
        if let cached = cachedDeviceId {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = Pan123Support.deviceId()

        lock.lock()
        cachedDeviceId = value
        lock.unlock()
        return value
    }

    /// 把 `[String: Any]` 序列化成请求体。
    ///
    /// ⚠️ `JSONSerialization` 只接受 `String / NSNumber / NSNull / [Any] / [String: Any]`，
    /// 裸 `Bool` / `Int` / `Int64` 会抛 `NSInvalidArgumentException`（Swift 里 catch 不到的 ObjC 异常）。
    /// 所以先把标量转成 `NSNumber`（`Size` 是 Int64，必须在这里统一处理）。
    private func jsonData(_ body: [String: Any]) throws -> Data {
        let normalized = Pan123JSON.normalize(body)
        guard JSONSerialization.isValidJSONObject(normalized) else {
            throw ResolveError.api("123 请求体构造失败")
        }
        do {
            return try JSONSerialization.data(withJSONObject: normalized, options: [])
        } catch {
            throw ResolveError.api("123 请求体序列化失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - JSON 标量归一

/// 把 Swift 原生标量递归换成 `NSNumber`，供 `JSONSerialization` 使用。
fileprivate enum Pan123JSON {

    static func normalize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, item) in dict {
                out[key] = normalize(item)
            }
            return out
        case let array as [Any]:
            return array.map { normalize($0) }
        case let bool as Bool:
            return NSNumber(value: bool)
        case let int as Int:
            return NSNumber(value: int)
        case let int64 as Int64:
            return NSNumber(value: int64)
        case let double as Double:
            return NSNumber(value: double)
        default:
            return value
        }
    }
}

// MARK: - JSON 取值补充

/// 上游高频使用的「带默认值」取值。
///
/// 工程里 `HTTPClient.swift` 已提供 `optInt(_:)`（缺省 0）/ `optBool(_:)`，
/// 但 123 的 `code`、`Type`、`Expired` 需要**非零 / 非 false 的默认值**
/// （例如 `code` 默认 -1 才能让「响应里没有 code」被判定为失败），
/// 所以这里补上 Kotlin `optInt(key, default)` / `optBoolean(key, default)` 的等价重载。
fileprivate extension Dictionary where Key == String, Value == Any {

    /// Kotlin 的 `optInt(key, default)`。
    func optInt(_ key: String, _ defaultValue: Int) -> Int {
        switch self[key] {
        case let num as NSNumber: return num.intValue
        case let str as String: return Int(str) ?? defaultValue
        default: return defaultValue
        }
    }

    /// Kotlin 的 `optBoolean(key, default)`。
    ///
    /// org.json 语义：键存在但值既不是 `true` 也不是 `"true"` 时返回 **default**，
    /// 只有明确 `false` / `"false"` 才返回 false。
    func optBool(_ key: String, _ defaultValue: Bool) -> Bool {
        switch self[key] {
        case let flag as Bool: return flag
        case let num as NSNumber: return num.boolValue
        case let str as String:
            let lowered = str.trimmingCharacters(in: .whitespaces).lowercased()
            if lowered == "true" { return true }
            if lowered == "false" { return false }
            return defaultValue
        default: return defaultValue
        }
    }
}
