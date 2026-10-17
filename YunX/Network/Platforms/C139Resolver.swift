//
//  C139Resolver.swift
//  云析 YunX iOS —— 139 网盘（中国移动·和彩云）分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//    - data/network/C139Api.kt        —— calSign / signHeader / encryptBody / decryptBody /
//                                        getOutLinkTitle / getOutLinkPassword / getShareFiles /
//                                        getShareDownloadLink / sharePostAnonymous / sharePostEncrypted
//    - data/network/C139Constants.kt  —— 分享端点、AES 固定密钥、设备/渠道头、extractAuthorization 等
//  只移植「分享解析 → 取直链」这条主链路；个人网盘管理（转存 / 建目录 / 重命名 / 移动 / 删除 /
//  创建分享 / 空间详情 / 任务轮询）不在 iOS 首版范围内，与 QuarkResolver / UCResolver 的取舍一致。
//
//  ## 本平台的关键坑（逐条来自上游注释，改代码前先读）
//  1. **分享接口全链路加密**：7.13+ 起 share host 的请求体与响应体都走 AES-128-CBC/PKCS7，
//     密钥固定 `PVGDwmcvfs1uV3d1`，IV 随机 16 字节并前置：
//         传输串 = base64( IV(16B) ‖ AES_CBC_PKCS7(KEY, IV, 明文) )
//     解密后的明文若是 gzip（首两字节 0x1F 0x8B）还必须先解压（alist YunCrypto 同款）。
//     Kotlin 用 `AES/CBC/PKCS5Padding`，JCE 的 PKCS5 在 16 字节块上就是 PKCS7，Swift 侧按 PKCS7 处理。
//  2. **mcloud-sign 必须按「明文」算**：加密只是传输包装，签名基于实际发送前那份明文 JSON
//     （字段顺序、无空格）。算法：正文经 encodeURIComponent → **逐字符 ASCII 升序** → base64
//     → md5(base64) + md5("ts:rand") → md5 → 转大写。头值格式 `<ts>,<rand>,<sign>`，
//     ts 为 `yyyy-MM-dd HH:mm:ss`，rand 16 位字母数字。
//     ⚠️ encodeURIComponent 这一步**不能**省：`{ } [ ] : , "` 等编码后变成 `%7B` 之类，
//     直接拿明文排序算出的 md5 完全不同（详见 `C139Crypto.calSign` 的注释）。
//  3. **必须带 `hcy-cool-flag: 1`**：这是 139 网关选择「解密方案」的开关，缺了业务层拿不到明文，
//     或直接返回 9530（上游《9530修复文档》§3/§5）。
//  4. **列目录 / 标题接口是「匿名」调用**：不带 Authorization、不带 mcloud-sign、不带任何 mcloud-* 头；
//     body 里的 `account` 固定空串。带上鉴权头反而会被判无效。
//  5. **列目录 body 字段一个都不能少**：`caSrt / coSrt / srtDr / bNum / eNum` 缺任一个即 9530；
//     提取码填错返回 9188。
//  6. **文件夹可能在 caLst，也可能在 coLst**：139 把子文件夹放在 `caLst`，文件放在 `coLst`，
//     且 `coLst` 里 `coType == 2` 的项同样是文件夹。上游早期只读 coLst，导致「顶层是文件夹」
//     的分享显示为空 —— 本移植同时读两个列表并合并（文件夹在前）。
//  7. **根目录的 pCaID 必须是字符串 "root"**，不能传空串；子目录传父级 caID，
//     或 `coType == 2` 的 coID（上游 §16.2）。
//  8. **提取码可以免填**：`getOutLinkGeneral` 会明文回吐 `outLinkGeneral[].passwd`，
//     官方 Web 也拿它自动填充。本移植在 `resolveToken` 里用它补全缺失的提取码，
//     避免列目录时才因缺密码报 9188。
//  9. **直链是 OBS S3 预签名，只有 900 秒**：拿到 `data.redrUrl` 后应立即入队下载，不要缓存。
//
//  ## 关于 CommonCrypto（AES-CBC）
//  CryptoKit **没有 CBC 模式**，所以 AES-CBC 只能走 CommonCrypto 的 `CCCrypt`。
//  iOS SDK 自带 `CommonCrypto` module map，Swift 里直接 `import CommonCrypto` 即可，
//  **不需要**配置桥接头文件；其符号来自 libSystem，Xcode 会自动链接。
//  若某个旧工具链上 `import CommonCrypto` 报 "no such module"（iOS SDK 12 之前才会出现），
//  可以改为在工程里加一个 ObjC 的 `CCCrypt` 包装类并配桥接头，或手工声明四个 C 符号。
//  解压走 `Compression` 框架的 `compression_decode_buffer`，无额外依赖。
//
//  ## iOS 首版收敛
//  上游 `C139Api.kt` 有 41KB，绝大多数是个人网盘 CRUD。iOS 首版只保留分享链路；
//  Cookie 仅用于两处：从 authorization 里解出手机号填 `account`，以及给直链请求补 Authorization。
//  **用户完全没导入 Cookie 时，分享解析同样能走通**（上游列目录 / 取链都是匿名或可选鉴权的）。
//

import Foundation
import CryptoKit
import CommonCrypto
import Compression
import Security

// MARK: - 加密 / 签名（对应 C139Api.kt 的 §4、§14）

/// 139 的算法与 Cookie 工具。
///
/// 做成无状态 `enum` 命名空间里的 static 方法，而不是挂在 `C139Resolver` 的
/// `private static` 上：`C139Resolver` 是 `@unchecked Sendable` 的 class，
/// Swift 6 会拒绝从「并发上下文」访问它的 `private static func`
/// （报 "static method is not concurrency-safe"）。放这里也能脱离网络单独测试。
///
/// 密钥常量在本 enum 内独立声明（而不是引用 C139Resolver.Constants），
/// 是为了让算法层不依赖解析器——文件内声明顺序不影响跨类型访问，但少一层耦合更稳。
fileprivate enum C139Crypto {

    /// §14 分享接口 AES-CBC 固定密钥（16 字节，所有账号共用），对应 C139Constants.SHARE_AES_KEY
    static let shareAESKey = "PVGDwmcvfs1uV3d1"

    // MARK: §14 AES-CBC 加解密（固定密钥 + IV 前置）

    /// 明文 JSON → 加密 base64 文本：`base64(IV(16B) ‖ AES-CBC-PKCS7(KEY, IV, 明文))`。
    static func encryptBody(_ plaintext: String) throws -> Data {
        let keyData = Data(shareAESKey.utf8)
        guard keyData.count == kCCKeySizeAES128 else {
            throw ResolveError.api("139 分享密钥长度异常（应为 16 字节）")
        }
        // Kotlin: SecureRandom().nextBytes(ByteArray(16))
        let iv = randomBytes(kCCBlockSizeAES128)
        let cipher = try aesCBC(encrypt: true, key: keyData, iv: iv, input: Data(plaintext.utf8))
        var payload = Data(iv)
        payload.append(cipher)
        return Data(payload.base64EncodedString().utf8)
    }

    /// 加密 base64 → 明文 JSON；解密后若为 gzip（首两字节 0x1F 0x8B）先解压。
    /// 失败返回 nil —— 调用方会回退到「网关透传明文」分支（上游同样用 runCatching 兜底）。
    static func decryptBody(_ text: String) -> String? {
        // Kotlin 的 Base64.decode(b64, NO_WRAP) 会忽略换行/空白
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let raw = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
              raw.count > kCCBlockSizeAES128 else { return nil }

        let iv = Array(raw.prefix(kCCBlockSizeAES128))
        let cipherText = Data(raw.dropFirst(kCCBlockSizeAES128))
        let keyData = Data(shareAESKey.utf8)
        guard var plain = try? aesCBC(encrypt: false, key: keyData, iv: iv, input: cipherText) else {
            return nil
        }

        // alist YunCrypto 同款：解密后若为 gzip 则解压
        if plain.count > 2 && plain[plain.startIndex] == 0x1F && plain[plain.startIndex + 1] == 0x8B {
            guard let unzipped = gunzip(plain) else { return nil }
            plain = unzipped
        }
        return String(data: plain, encoding: .utf8)
    }

    /// `CCCrypt` 薄封装：AES-128-CBC + PKCS7 填充。
    ///
    /// 对齐 Kotlin 的 `Cipher.getInstance("AES/CBC/PKCS5Padding")`：
    /// JCE 的 PKCS5Padding 在 16 字节块上等价于 PKCS7，所以这里用 `kCCOptionPKCS7Padding`。
    /// 解密时 CommonCrypto 会自动去填充（与 JCE 一致）。
    static func aesCBC(encrypt: Bool, key: Data, iv: [UInt8], input: Data) throws -> Data {
        guard iv.count == kCCBlockSizeAES128 else {
            throw ResolveError.api("139 分享 IV 长度异常（应为 16 字节）")
        }
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        var outLength = 0
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        // 三个缓冲区各自 withUnsafe… 嵌套，才拿得到有效地址
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            input.withUnsafeBytes { inputBytes -> CCCryptorStatus in
                out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        iv,                                  // IV：数组隐式转 UnsafeRawPointer
                        inputBytes.baseAddress,
                        input.count,
                        outBytes.baseAddress,
                        outCapacity,
                        &outLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            let stage = encrypt ? "加密" : "解密"
            throw ResolveError.api("139 分享请求\(stage)失败（CCCrypt \(status)）")
        }
        out.removeSubrange(outLength..<out.count)
        return out
    }

    // MARK: gzip 解压

    /// gzip 解压。
    ///
    /// Foundation / CryptoKit 都不提供 gunzip，这里用 `Compression` 框架的 `COMPRESSION_ZLIB`：
    /// Apple 的实现会按输入魔数识别 gzip 封装（0x1F 0x8B），把**整段** gzip 数据原样交给它即可
    /// （自行剥掉 2 字节头反而会被当成非法 deflate 流）。
    /// 解压失败返回 nil，调用方 `decryptBody` 随之返回 nil，走「网关透传明文」兜底 ——
    /// 与上游 alist 版的容错方向一致。
    ///
    /// 若目标系统的 Compression 不认 gzip 封装（目前 iOS 13+ 均支持），
    /// 替代方案是引入 zlib（`zlib.h` 的 `inflateInit2(&zs, 15 + 16)`），或把这段换成 ObjC 包装。
    static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return inflate(data)
    }

    /// 用 `compression_decode_buffer` 一次性解压；缓冲区不够就 4 倍扩容重试，上限 256MB。
    ///
    /// 刻意先把 `Data` 转成 `[UInt8]`：`Data` 的切片（SubSequence）用 `withUnsafeBytes` 时
    /// 起始地址不随切片偏移，直接传指针会读到错误区域。
    static func inflate(_ source: Data) -> Data? {
        let input = [UInt8](source)
        guard !input.isEmpty else { return nil }

        var capacity = max(64 * 1024, input.count * 4)
        let maxCapacity = 256 * 1024 * 1024
        while capacity <= maxCapacity {
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { out.deallocate() }
            let written = compression_decode_buffer(
                out,
                capacity,
                input,
                input.count,
                nil,
                COMPRESSION_ZLIB
            )
            if written > 0 {
                return Data(bytes: out, count: written)
            }
            capacity *= 4
        }
        return nil
    }

    // MARK: §4 mcloud-sign 签名

    /// calSign：`body' 逐字符 ASCII 升序 → base64 → md5(base64) + md5("ts:rand") → md5 → upper`。
    ///
    /// 必须基于与实际发送一致的明文 JSON（字段顺序、无空格）。
    ///
    /// 上游 Kotlin：
    /// ```kotlin
    /// val encoded = encodeURIComponent(bodyJson)          // +→%20，并还原 ! ' ( ) *
    /// val sorted  = encoded.toCharArray().sorted().joinToString("")
    /// val b64     = Base64.encodeToString(sorted.toByteArray(UTF_8), Base64.NO_WRAP)
    /// md5(md5(b64) + md5("$ts:$rand")).uppercase()
    /// ```
    /// 这里的 encodeURIComponent **不能省**：`{` `}` `[` `]` `:` `,` `"` 都会被编码成 `%7B` 这类三元组，
    /// 排序后的字符序列与明文排序完全不同，md5 也就完全不同。本实现逐字符精确复刻。
    static func calSign(bodyJson: String, ts: String, rand: String) -> String {
        let sorted = sortedCharacters(encodeURIComponent(bodyJson))
        let b64 = Data(sorted.utf8).base64EncodedString()
        let combined = md5Hex(b64) + md5Hex("\(ts):\(rand)")
        return md5Hex(combined).uppercased()
    }

    /// §4.1 encodeURIComponent（+→%20，并还原 ! ' ( ) *）。
    ///
    /// 与 `java.net.URLEncoder.encode(s, "UTF-8")` 对齐：unreserved 集合是
    /// `A-Z a-z 0-9 - _ . *`，空格编成 `+`；随后上游再把 `+` 换回 `%20`，
    /// 并把 `%21 %27 %28 %29 %2A` 还原成原字符。
    /// 注意它**不**保留 `~`（这是 Java URLEncoder 与 JS encodeURIComponent 的差异点），
    /// 所以 `~` 会被编成 `%7E` —— 本实现照 Java 行为走，与上游一致。
    static func encodeURIComponent(_ text: String) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(text.utf8.count * 2)
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x2A:
                // A-Z a-z 0-9 - _ . * —— 这七个区间/字符不编码（与 Kotlin 的 URLEncoder 一致）
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                // UTF-8 字节 → %XX（大写十六进制，与 URLEncoder 一致）。
                // 注意 Kotlin 的 URLEncoder 对非 ASCII 也是逐字节编码，所以这里按 bytes 走没错。
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        // 上游的六个还原
        return out
            .replacingOccurrences(of: "+", with: "%20")
            .replacingOccurrences(of: "%21", with: "!")
            .replacingOccurrences(of: "%27", with: "'")
            .replacingOccurrences(of: "%28", with: "(")
            .replacingOccurrences(of: "%29", with: ")")
            .replacingOccurrences(of: "%2A", with: "*")
    }

    /// 生成 mcloud-sign 头值：`<ts>,<rand>,<sign>`。
    static func signHeader(bodyJson: String) -> String {
        let ts = timestampText(Date())
        let rand = randomAlphaNumeric(length: 16)
        return "\(ts),\(rand),\(calSign(bodyJson: bodyJson, ts: ts, rand: rand))"
    }

    /// 逐字符按码位升序排序（对应 Kotlin `CharArray.sorted()`，按 UTF-16 码元比较）。
    ///
    /// 用 `unicodeScalars` 而不是 `Character`：Swift 的 `Character` 是多标量字形簇，
    /// 不能拿来比对单个码位。编码后的正文是纯 ASCII，因此标量序 == UTF-16 码元序。
    static func sortedCharacters(_ text: String) -> String {
        var values = text.unicodeScalars.map { $0.value }
        values.sort()
        var view = String.UnicodeScalarView()
        for value in values {
            if let scalar = UnicodeScalar(value) {
                view.append(scalar)
            }
        }
        return String(view)
    }

    /// 上游 `SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())`。
    ///
    /// - 用 `Calendar(identifier: .gregorian)` 取分量再手工拼串，而不是 `DateFormatter`：
    ///   - Locale 方面：`Locale.current` 在部分区域（如 th_TH）会让 `yyyy` 输出佛历年份，
    ///     签名时间戳会整体错位；固定 `en_US_POSIX` 虽然能规避，但依赖 `dateFormat` 与
    ///     Locale 的叠加规则，不如直接取分量可靠。
    ///   - 时区用 `.current`：上游用的是默认时区，即本地时间，服务端按本地时间校验。
    static func timestampText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        func pad(_ value: Int) -> String {
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(year)-\(pad(month))-\(pad(day)) \(pad(hour)):\(pad(minute)):\(pad(second))"
    }

    /// 16 位字母数字随机串（字符池与上游一致）。
    static func randomAlphaNumeric(length: Int) -> String {
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        out.reserveCapacity(length)
        for byte in randomBytes(length) {
            // 62 不整除 256，取模有极小偏差；这里只是一次性随机串，不影响服务端校验
            out.append(pool[Int(byte) % pool.count])
        }
        return out
    }

    /// md5 小写十六进制（对应上游 `"%02x".format(it)` 拼接）。
    static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 密码学安全随机字节；`SecRandomCopyBytes` 失败时退化为时间派生的伪随机（仅兜底）。
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
            return bytes
        }
        var seed = UInt64(Date().timeIntervalSince1970 * 1_000_000) ^ UInt64(count)
        for index in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8((seed >> 33) & 0xFF)
        }
        return bytes
    }
}

// MARK: - Cookie 解析（C139Constants.kt）

/// 上游 `C139Constants` 的 extract* / isValidCookie。
fileprivate enum C139Cookie {

    /// 上游 `extractAuthorization`：从 Cookie 里取第一个非空 `authorization=`。
    /// 形如 `authorization=Basic cGM6...`（= base64("pc:<account>:<authToken>")）。
    static func extractAuthorization(from cookie: String) -> String {
        for kv in cookie.split(separator: ";") {
            let trimmed = kv.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("authorization=") {
                let value = String(trimmed.dropFirst("authorization=".count))
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    /// 上游 `accountFromAuthorization`：解码 `[Basic ]base64(pc:账号:authToken)`，取第 2 段（下标 1）。
    static func accountFromAuthorization(_ authorization: String) -> String {
        var b64 = authorization
        if b64.hasPrefix("Basic") { b64 = String(b64.dropFirst("Basic".count)) }
        b64 = b64.trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8) else { return "" }
        // Kotlin: decoded.split(":").getOrNull(1)
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// 上游 `extractAccountFull`（解析接口用，必须完整手机号）：
    /// 1) `ORCHES-I-ACCOUNT-ENCRYPT`（base64 手机号）→ 2) authorization 解码 → 3) `Login_UserNumber`。
    static func accountFull(from cookie: String) -> String {
        if cookie.isEmpty { return "" }

        // 1) ORCHES-I-ACCOUNT-ENCRYPT：base64 手机号
        for kv in cookie.split(separator: ";") {
            let trimmed = kv.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ORCHES-I-ACCOUNT-ENCRYPT=") {
                let value = String(trimmed.dropFirst("ORCHES-I-ACCOUNT-ENCRYPT=".count))
                if !value.isEmpty,
                   let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]),
                   let decoded = String(data: data, encoding: .utf8),
                   !decoded.isEmpty {
                    return decoded
                }
            }
        }

        // 2) authorization："Basic base64(pc:账号:authToken)"
        let account = accountFromAuthorization(extractAuthorization(from: cookie))
        if !account.isEmpty { return account }

        // 3) Login_UserNumber：手机号/账号
        for kv in cookie.split(separator: ";") {
            let trimmed = kv.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Login_UserNumber=") {
                let value = String(trimmed.dropFirst("Login_UserNumber=".count))
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    /// 上游 `isValidCookie`：路径 B（authorization 非空）或路径 A（Os_SSo_Sid + RMKEY 齐全）。
    static func isValidCookie(_ cookie: String) -> Bool {
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCookie.isEmpty { return false }
        let pairs = trimmedCookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

        // 路径 B：网页版直接给的 authorization
        for kv in pairs where kv.hasPrefix("authorization=") {
            if kv.count > "authorization=".count { return true }
        }

        // 路径 A：fast login 双字段（`Os_SSo_Sid` 与 `RMKEY` 都要有值）
        for key in ["Os_SSo_Sid", "RMKEY"] {
            let prefix = "\(key)="
            let hit = pairs.contains { $0.hasPrefix(prefix) && $0.count > prefix.count }
            if !hit { return false }
        }
        return true
    }
}

// MARK: - 解析器

/// 139 网盘（和彩云）解析器。
///
/// Cookie 通过 `updateCookie` 注入（形如 `authorization=Basic xxx; skey=yyy; ...`）。
/// 分享链路本身是匿名 + 提取码鉴权，Cookie 为空只意味着 `account` 退化成空串。
final class C139Resolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量（逐条对照 C139Constants.kt）

    private enum Constants {
        /// 分享专用 host（上游 §9/§12）
        static let shareBase = "https://share-kd-njs.yun.139.com"

        /// 分享列目录（7.13+ 请求/响应加密）
        static let shareListURL =
            "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6"
        /// 分享取直链（7.13+ 请求/响应加密）
        static let shareLinkURL =
            "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3"
        /// 分享标题 / 提取码（outLinkGeneral[].lkName / outLinkGeneral[].passwd）
        static let shareGeneralURL =
            "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkGeneral"

        /// 根目录 pCaID 固定值（不能为空串，§16.2）
        static let rootCatalogId = "root"

        // —— 分享接口必带的设备/渠道上下文头（设备头修复文档 §3：缺任一即 9530）——
        static let shareXDeviceInfo = "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"
        static let shareXHuaweiChannelsrc = "10245500"
        static let shareXMMSource = "0002"

        /// 分享接口 UA：必须是浏览器/WebView UA，不能用 okhttp/4.x（设备头修复文档 §3.1）
        static let shareMobileUA =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/150.0.0.0 Mobile Safari/537.36"

        /// 分享页 Origin / Referer（取链与下载都带）
        static let origin = "https://yun.139.com"
        static let referer = "https://yun.139.com/"

        /// 列目录每页条数（上游 `getShareFiles(begin = 1, end = 200)`）
        static let listPageSize = 200
    }

    // MARK: - 状态

    private let client = HTTPClient.shared
    /// 账号 Cookie。为空 = 未登录（分享链路仍然可用）。
    private var cookie: String
    private let lock = NSLock()

    /// 上游 `C139Api(clientProvider)` 收敛成 `init(cookie:)`（与 Quark / UC 一致）。
    init(cookie: String = "") {
        self.cookie = cookie
    }

    /// 注入/更新账号 Cookie。
    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否处于登录态（对齐上游 `C139Constants.isValidCookie`）：
    /// Cookie 里有非空 `authorization=`（路径 B），或 `Os_SSo_Sid` 与 `RMKEY` 同时齐全（路径 A）。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return C139Cookie.isValidCookie(cookie)
    }

    // MARK: - ShareResolving

    /// Step 0：换「访问凭证」。
    ///
    /// 139 没有独立的 token 接口（其他平台要换 stoken，139 直接拿 linkID + 提取码列目录），
    /// 所以这里做上游在进入列表页之前会做的两件事：
    /// 1. `getOutLinkGeneral` 拿分享标题（`outLinkGeneral[].lkName`）；
    /// 2. 顺手拿明文提取码（`outLinkGeneral[].passwd`），用户没填就自动补全 ——
    ///    与官方 Web 的自动填充一致，避免列目录时才因缺提取码报 9188。
    ///
    /// 返回的 `stoken` 就是提取码本身（无提取码为空串），后两次调用沿用。
    /// `firstFid` 固定为根目录 `"root"`（139 列目录响应里没有「首个文件 fid」这个概念）。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let info = try await generalInfo(linkId: share.shareId)

        let userPwd = share.pwd ?? ""
        let effectivePwd = userPwd.isEmpty ? info.passwd : userPwd

        return ShareToken(
            stoken: effectivePwd,
            title: info.title,
            firstFid: Constants.rootCatalogId
        )
    }

    /// Step 1：列目录（`getOutLinkInfoV6`）。
    ///
    /// - `pdirFid` 为 `"0"` 或空串时视作分享根目录，按上游约定换写成 `"root"`。
    /// - `page` 从 1 开始。上游 `bNum`（起始）/`eNum`（结束）是**条数区间**而不是页号，
    ///   这里按页换算：`bNum = (page - 1) * 200 + 1`、`eNum = page * 200`。
    /// - `stoken` 由 `resolveToken` 返回（即提取码）；为空时回退到 `ParsedShare.pwd`，
    ///   再为空就是「该分享无提取码」。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let pcaId = normalizedCatalogId(pdirFid)
        let passwd = stoken.isEmpty ? (share.pwd ?? "") : stoken
        let safePage = max(1, page)
        let begin = (safePage - 1) * Constants.listPageSize + 1
        let end = safePage * Constants.listPageSize

        // 字段与顺序逐条对照上游 getShareFiles 的 JSONObject.put 序列
        let req: [String: Any] = [
            // 列表端点 account 必须为空串，且本调用不带鉴权头（§3）
            "account": "",
            "linkID": share.shareId,
            "passwd": passwd,
            "caSrt": 1,              // 排序：目录按创建时间
            "coSrt": 1,              // 排序：文件按创建时间
            "srtDr": 0,              // 排序方向：降序
            "bNum": begin,           // 分页起始
            "pCaID": pcaId,
            "eNum": end              // 分页结束
        ]
        let plain = try C139JSONBody.build(rootKey: "getOutLinkInfoReq", payload: req)

        // 匿名 POST：body 加密、响应解密（兼容明文透传）
        let json = try await sharePostAnonymous(Constants.shareListURL, plainBody: plain)
        try checkShareResult(json, fallback: "获取文件列表失败")

        guard let data = json.optObject("data") else {
            // 上游：data 缺失按「空目录」处理，而不是报错
            return []
        }

        var result: [ShareFile] = []

        // 1) 子文件夹列表 caLst（上游踩过的坑：早期完全忽略 → 含子文件夹的分享显示为空）
        for item in data.optArray("caLst") {
            result.append(ShareFile(
                fid: item.optString("caID"),
                fname: item.optString("caName"),
                fsize: 0,
                isdir: true,
                pdirFid: pcaId,
                fidToken: "",
                modifyTime: C139Text.firstNonBlank(item.optString("udTime"), item.optString("ctTime"))
            ))
        }

        // 2) 文件列表 coLst（含 coType == 2 的文件夹）
        for item in data.optArray("coLst") {
            // Kotlin: isdir = optBoolean("isdir", optInt("coType", 1) == 2)
            // —— 显式 isdir=true 优先；否则看 coType，coType 缺失按 1（文件）
            let isdir = item.optBool("isdir", item.optInt("coType", 1) == 2)
            result.append(ShareFile(
                fid: item.optString("coID"),
                fname: item.optString("coName"),
                fsize: item.optInt64("coSize"),
                isdir: isdir,
                pdirFid: pcaId,
                fidToken: "",
                modifyTime: C139Text.firstNonBlank(item.optString("udTime"), item.optString("ctTime"))
            ))
        }

        // 空目录返回 []，UI 显示「此目录为空」（保持上游语义）
        return result
    }

    /// Step 2：取下载直链（`dlFromOutLinkV3` → `data.redrUrl`，OBS 预签名 900 秒有效）。
    func downloadLink(
        for file: ShareFile,
        share: ParsedShare,
        stoken: String
    ) async throws -> DownloadLink {
        // 取 Cookie 快照，避免请求途中被 updateCookie 改掉
        lock.lock()
        let cookieSnapshot = cookie
        lock.unlock()

        let authorization = C139Cookie.extractAuthorization(from: cookieSnapshot)
        let account = C139Cookie.accountFull(from: cookieSnapshot)

        let reqV3: [String: Any] = [
            "account": account,
            "linkID": share.shareId,
            "coIDLst": ["item": [file.fid]],
            "commonAccountInfo": ["account": account, "accountType": 1]
        ]
        let plain = try C139JSONBody.build(rootKey: "dlFromOutLinkReqV3", payload: reqV3)

        // 上游传 authorization（`String?`）：为空则不加这个头
        let json = try await sharePostEncrypted(
            Constants.shareLinkURL,
            plainBody: plain,
            authorization: authorization
        )
        try checkShareResult(json, fallback: "获取下载链接失败")

        guard let data = json.optObject("data") else {
            throw ResolveError.api("未返回下载链接（分享可能已失效）")
        }
        let url = data.optString("redrUrl")
        guard !url.isEmpty else {
            throw ResolveError.api("下载直链为空，可能是分享已失效或提取码已变更")
        }

        // Kotlin: filename = data.fileName ifEmpty { data.coName ifEmpty { coId } }
        var filename = data.optString("fileName")
        if filename.isEmpty { filename = data.optString("coName") }
        if filename.isEmpty { filename = data.optString("coID") }
        if filename.isEmpty { filename = file.fname }

        // Kotlin: size = optLong("coSize", optLong("size"))
        var size = data.optInt64("coSize")
        if size == 0 { size = data.optInt64("size") }
        if size == 0 { size = file.fsize }

        return DownloadLink(
            fid: file.fid.isEmpty ? data.optString("coID") : file.fid,
            filename: filename,
            downloadUrl: url,
            size: size,
            // 139 没有夸克那套 __pugs 游客令牌，直链本身就是 OBS 预签名
            guestCookie: ""
        )
    }

    // MARK: - DownloadHeadersProviding

    /// 直链下载所需请求头。
    ///
    /// OBS 预签名直链自带鉴权（URL 里带 AK / Signature / Expires），但 139 的 OBS 桶
    /// 对空 Referer / 非浏览器 UA 会返回 403，所以按分享页的 Origin / Referer 补齐。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        [
            "User-Agent": Constants.shareMobileUA,
            "Referer": Constants.referer,
            "Origin": Constants.origin,
            "Accept": "application/json, text/plain, */*"
        ]
    }

    // MARK: - 分享接口（加密传输）

    /// 匿名 POST（列表 / 标题专用，上游 `sharePostAnonymous`）：
    /// 不带 Authorization、不带 mcloud-sign、不带 mcloud-* 头；body 仍加密；
    /// 必须带 `hcy-cool-flag: 1`（网关解密开关）；响应解密（兼容明文透传）。
    private func sharePostAnonymous(_ url: String, plainBody: String) async throws -> [String: Any] {
        let bodyData = try C139Crypto.encryptBody(plainBody)
        let headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": Constants.shareXDeviceInfo,
            "x-huawei-channelsrc": Constants.shareXHuaweiChannelsrc,
            "x-mm-source": Constants.shareXMMSource,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Constants.shareMobileUA,
            "Origin": Constants.origin,
            "Referer": Constants.referer,
            "Accept": "application/json, text/plain, */*"
        ]
        return try await sendEncrypted(url: url, body: bodyData, headers: headers)
    }

    /// 分享专用 POST（上游 `sharePostEncrypted`）：body 加密发送，mcloud-sign 按**明文**算，
    /// 必须带 `hcy-cool-flag: 1`，响应解密（兼容明文透传）。
    private func sharePostEncrypted(
        _ url: String,
        plainBody: String,
        authorization: String
    ) async throws -> [String: Any] {
        let bodyData = try C139Crypto.encryptBody(plainBody)
        var headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": Constants.shareXDeviceInfo,
            "x-huawei-channelsrc": Constants.shareXHuaweiChannelsrc,
            "x-mm-source": Constants.shareXMMSource,
            "mcloud-sign": C139Crypto.signHeader(bodyJson: plainBody),
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Constants.shareMobileUA,
            "Origin": Constants.origin,
            "Referer": Constants.referer,
            "Accept": "application/json, text/plain, */*"
        ]
        // 上游：authorization 非空白才加这个头
        let trimmedAuth = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAuth.isEmpty {
            headers["Authorization"] = trimmedAuth
        }
        return try await sendEncrypted(url: url, body: bodyData, headers: headers)
    }

    /// 发加密请求并解出明文 JSON。
    ///
    /// 等价于上游 `runCatching { JSONObject(decryptBody(body)) }.getOrElse { JSONObject(body) }`：
    /// 网关偶尔直接透传明文响应，此时解密必然失败，改为直接解析原文。
    private func sendEncrypted(
        url: String,
        body: Data,
        headers: [String: String]
    ) async throws -> [String: Any] {
        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: body
        ))
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ResolveError.network("请求失败：响应为空（HTTP \(http.statusCode)）")
        }

        // 1) 先按加密响应解
        if let plain = C139Crypto.decryptBody(text),
           let json = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any] {
            return json
        }
        // 2) 兜底：网关透传明文
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        // 3) 都不是（风控页 / HTML 错误页）：带上状态码与前缀，便于分辨 9530 与 HTTP 层故障
        let preview = String(text.prefix(120))
        throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）：\(preview)")
    }

    /// 分享标题 / 提取码（上游 `getOutLinkTitle` + `getOutLinkPassword` 合并，只发一次请求）。
    ///
    /// 上游对两者都做「失败返回 null」的容错，本移植同样宽容：
    /// - 网络层故障（含用户取消）**上抛** —— 用户点取消必须立即停下；
    /// - 业务失败（resultCode 非 0、success=false、data 缺失）返回空串 ——
    ///   标题接口挂了不该阻断整条解析链路。
    private func generalInfo(linkId: String) async throws -> (title: String, passwd: String) {
        let req: [String: Any] = [
            "linkID": linkId,
            "isPasswd": 1,
            "account": ""
        ]
        let plain = try C139JSONBody.build(rootKey: "getOutLinkGeneralReq", payload: req)

        let json: [String: Any]
        do {
            json = try await sharePostAnonymous(Constants.shareGeneralURL, plainBody: plain)
        } catch let error as ResolveError {
            switch error {
            case .cancelled, .network:
                throw error
            default:
                return ("", "")
            }
        }

        // 上游：resultCode 非空且非 "0" → null；success 显式 false → null；data 缺失 → null
        let resultCode = json.optString("resultCode")
        if !resultCode.isEmpty && resultCode != "0" { return ("", "") }
        if !json.optBool("success", true) { return ("", "") }
        guard let data = json.optObject("data"),
              let general = data.optObject("getOutLinkGeneralResp"),
              let first = general.optArray("outLinkGeneral").first else {
            return ("", "")
        }
        return (first.optString("lkName"), first.optString("passwd"))
    }

    /// 分享响应的成功判定（上游：`resultCode` 为空或 "0"，且 `success` 默认 true）。
    private func checkShareResult(_ json: [String: Any], fallback: String) throws {
        let resultCode = json.optString("resultCode")
        let failedByCode = !resultCode.isEmpty && resultCode != "0"
        let failedByFlag = !json.optBool("success", true)
        if failedByCode || failedByFlag {
            throw ResolveError.api(
                C139Text.errorMessage(
                    code: resultCode,
                    desc: json.optString("desc"),
                    fallback: fallback
                )
            )
        }
    }

    // MARK: - 小工具

    /// `"0"` / 空串 → `"root"`（上游 §16.2：根目录 pCaID 不能为空）。
    private func normalizedCatalogId(_ pdirFid: String) -> String {
        let trimmed = pdirFid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" { return Constants.rootCatalogId }
        return trimmed
    }
}

// MARK: - 请求体构造

/// 上游形态的明文 body：`{"<rootKey>": {...}}`。
///
/// 用 `JSONSerialization` 而不是字符串拼装，保证转义正确。
/// ⚠️ `JSONSerialization` 只接受 `String / NSNumber / NSNull / [Any] / [String: Any]`，
/// 裸 `Bool` / `Int` 放进去会抛 **ObjC 异常**（`NSInvalidArgumentException`，
/// Swift 里 catch 不到，直接闪退）。所以这里先把所有标量统一转成 `NSNumber`。
fileprivate enum C139JSONBody {

    static func build(rootKey: String, payload: [String: Any]) throws -> String {
        let object: [String: Any] = [rootKey: normalize(payload)]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ResolveError.api("139 请求体构造失败（\(rootKey)）")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            throw ResolveError.api("139 请求体序列化失败：\(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResolveError.api("139 请求体编码失败")
        }
        return text
    }

    /// 递归把 Swift 原生标量换成 `NSNumber`（`NSNumber` / `NSNull` / `String` 原样保留）。
    private static func normalize(_ value: Any) -> Any {
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

// MARK: - 文本与错误文案

/// 上游的 `ifBlank` / 空白判定 / 错误文案。
fileprivate enum C139Text {

    /// 上游 `ifBlank { }`：前者非空白则取前者，否则取 fallback。
    static func firstNonBlank(_ primary: String, _ fallback: String) -> String {
        if !isBlank(primary) { return primary }
        return fallback
    }

    /// 对齐 Kotlin `CharSequence.isBlank()`：空串或全为空白（含换行、制表）。
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 分享接口错误码 → 用户可读文案（上游优先用 `desc`，本移植再补两个已知码的说明）。
    ///
    /// - `9188`：提取码错误（上游注释明确：passwd 填错返回 9188）
    /// - `9530`：请求头或 body 字段不全导致网关解密失败（设备头修复文档 §3）
    static func errorMessage(code: String, desc: String, fallback: String) -> String {
        let serverText = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "9188":
            return serverText.isEmpty ? "提取码错误" : "提取码错误（\(serverText)）"
        case "9530":
            return serverText.isEmpty ? "139 接口校验失败（9530），请稍后重试或升级 App" : serverText
        default:
            if !serverText.isEmpty { return serverText }
            return code.isEmpty ? fallback : "\(fallback)（\(code)）"
        }
    }
}

// MARK: - JSON 取值补充

/// 上游高频使用的「带默认值」取值。
///
/// 说明：工程里 `HTTPClient.swift` 已提供 `optInt(_:)` / `optBool(_:)`（缺省值固定 0 / false），
/// 但 139 的 `coType`、`success` 需要**非零 / 非 false 的默认值**，
/// 所以这里补上对应 Kotlin `optInt(key, default)` / `optBoolean(key, default)` 的重载
/// （参数个数不同，与扩展里的方法不冲突）。
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
    /// 注意 org.json 语义：键存在但值既不是 `true` 也不是字符串 `"true"` 时返回 **default**，
    /// 只有明确 `false` / `"false"` 才返回 false。上游正是靠这个「宽容判定」
    /// 让缺失 `success` 的响应不被误判成失败。
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
