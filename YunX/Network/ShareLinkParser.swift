//
//  ShareLinkParser.swift
//  云析 YunX iOS —— 分享链接 / 分享文案解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/ShareLinkParser.kt。
//  逻辑与上游保持一致：先从整段文案里抠出第一个 http(s) 链接，再按平台正则
//  依次匹配；提取码优先取 URL 里的参数，取不到再扫文案里的「提取码：xxxx」。
//
//  ## 匹配顺序是有讲究的（照抄上游，不要随意重排）
//  1. **蓝奏云优享版（ilanzou）必须先于蓝奏云匹配**：`www.ilanzou.com` 里含
//     `lanzou` 子串，若先匹配蓝奏云会误判。上游用 `(?:^|[/.])` 前置边界解决，
//     这里同样保留该边界。
//  2. **115 口令形式（code-提取码）要在普通链接之后**：它是「路径里带中划线」的
//     特殊形态，先匹配普通形态更稳。
//  3. 百度要**去掉 surl 开头的 "1"**：链接里是 `1abcdef`，接口要的是 `abcdef`。
//
//  ## 提取码参数的差异
//  大多数平台用 `?pwd=`，但：
//  - 115 用 `?password=`
//  - 蓝奏云用 `?pwd=` / `?pass=` / `?passcode=` / `?password=` 四种
//  上游为此单独写了 `pwdIn115UrlRegex` 和 `pwdInLanzouUrlRegex`。
//

import Foundation

enum ShareLinkParser {

    // MARK: - 通用正则

    /// 从整段文案里抠出第一个链接。与上游一致：按空白切。
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s]+"#, options: [])

    /// 文案里的提取码：「提取码：xxxx」「访问码: xxxx」「密码：xxxx」
    private static let pwdInTextRegex = try! NSRegularExpression(
        pattern: #"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#, options: [])

    /// 多数平台的提取码参数：?pwd=xxxx
    private static let pwdInUrlRegex = try! NSRegularExpression(
        pattern: #"[?&]pwd=([A-Za-z0-9]+)"#, options: [])

    /// 115 的提取码参数：?password=xxxx
    private static let pwdIn115UrlRegex = try! NSRegularExpression(
        pattern: #"[?&]password=([A-Za-z0-9]+)"#, options: [])

    /// 蓝奏云的提取码参数：?pwd= / ?pass= / ?passcode= / ?password=
    private static let pwdInLanzouUrlRegex = try! NSRegularExpression(
        pattern: #"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#,
        options: [.caseInsensitive])

    // MARK: - 各平台识别正则

    /// 夸克：pan.quark.cn/s/<id>
    private static let quarkRegex = try! NSRegularExpression(
        pattern: #"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, options: [.caseInsensitive])

    /// UC：drive.uc.cn/s/<id>
    private static let ucRegex = try! NSRegularExpression(
        pattern: #"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, options: [.caseInsensitive])

    /// 迅雷：pan.xunlei.com/s/<id>（id 可能带下划线和横线）
    private static let xunleiRegex = try! NSRegularExpression(
        pattern: #"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, options: [.caseInsensitive])

    /// 百度：pan.baidu.com/s/1<id>
    private static let baiduRegex = try! NSRegularExpression(
        pattern: #"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, options: [.caseInsensitive])

    /// 139：yun.139.com/shareweb/#/w/i/<linkID>
    private static let c139Regex = try! NSRegularExpression(
        pattern: #"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, options: [.caseInsensitive])

    /// 123 云盘：www.123pan.com/s/<ShareKey>（ShareKey 含一个中划线）
    private static let pan123Regex = try! NSRegularExpression(
        pattern: #"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, options: [.caseInsensitive])

    /// 123 云盘子域形态：<UID>.share.123pan.cn/123pan/<ShareKey>
    private static let pan123SubRegex = try! NSRegularExpression(
        pattern: #"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, options: [.caseInsensitive])

    /// 123 云盘 API 形态：api/srr?sk=<ShareKey>&st=s
    private static let pan123SrrRegex = try! NSRegularExpression(
        pattern: #"api/srr\?sk=([A-Za-z0-9-]+)"#, options: [.caseInsensitive])

    /// 115：115.com/s/<share_code>（share_code 为 11 位 sw 开头）
    private static let pan115Regex = try! NSRegularExpression(
        pattern: #"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, options: [.caseInsensitive])

    /// 115 口令形式：115.com/<code>-<提取码>/
    private static let pan115CommandRegex = try! NSRegularExpression(
        pattern: #"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, options: [.caseInsensitive])

    /// 光鸭云盘：guangyapan.com/s/<shareId>
    private static let guangyaRegex = try! NSRegularExpression(
        pattern: #"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, options: [.caseInsensitive])

    /// 蓝奏云优享版：ilanzou.com/s/<id>
    /// 前置边界 `(?:^|[/.])` 防止把 `www.ilanzou.com` 里的 `lanzou.com` 误判成蓝奏云
    private static let ilanzouRegex = try! NSRegularExpression(
        pattern: #"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, options: [.caseInsensitive])

    /// 蓝奏云：<lanzou 系域名>/<shareId>（i 开头是文件，b 开头是文件夹）
    /// 同样带前置边界，且必须在 ilanzou 之后匹配
    private static let lanzouRegex = try! NSRegularExpression(
        pattern: #"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#,
        options: [.caseInsensitive])

    /// GitHub 仓库 / 文件 / Releases：github.com/<owner>/<repo>/...
    private static let githubRegex = try! NSRegularExpression(
        pattern: #"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"#, options: [.caseInsensitive])

    // MARK: - 公开接口

    /// 解析分享文案或链接。
    ///
    /// - Parameter text: 用户粘贴的原始文本，可以是纯链接，也可以是
    ///   「【标题】 https://pan.quark.cn/s/xxx 提取码：abcd」这种整段分享文案。
    /// - Returns: 解析成功时返回 `ParsedShare`；文本里没有可识别的链接时返回 nil。
    static func parse(_ text: String) throws -> ParsedShare? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard var url = firstMatch(urlRegex, in: trimmed) else { return nil }
        // 去掉中文文案里常见的尾随标点（与上游 trimEnd 列表一致）
        url = url.trimmingCharacters(in: CharacterSet(charactersIn: "。，,；;)]}\"'"))

        // 文案里的提取码（所有平台通用兜底）
        let pwdInText = firstMatch(pwdInTextRegex, in: trimmed)

        // ---- 阿里系 ----
        if let sid = firstMatch(quarkRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .quark, rawURL: url)
        }
        if let sid = firstMatch(ucRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .uc, rawURL: url)
        }

        // ---- 迅雷 ----
        if let sid = firstMatch(xunleiRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .xunlei, rawURL: url)
        }

        // ---- 百度（surl 去掉开头的 "1"）----
        if let sid = firstMatch(baiduRegex, in: url) {
            let surl = sid.hasPrefix("1") ? String(sid.dropFirst()) : sid
            return ParsedShare(shareId: surl, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .baidu, rawURL: url)
        }

        // ---- 139 ----
        if let sid = firstMatch(c139Regex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .c139, rawURL: url)
        }

        // ---- 123 云盘（三种形态，按优先级）----
        if let sid = firstMatch(pan123Regex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .pan123, rawURL: url)
        }
        if let sid = firstMatch(pan123SubRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .pan123, rawURL: url)
        }
        if let sid = firstMatch(pan123SrrRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .pan123, rawURL: url)
        }

        // ---- 115（普通形态 → 口令形态）----
        if let sid = firstMatch(pan115Regex, in: url) {
            // 115 的提取码可能只在文案「访问码：xxxx」里，链接不带 password 不代表不需要码
            return ParsedShare(shareId: sid, pwd: pwd(pwdIn115UrlRegex, in: url) ?? pwdInText,
                               platform: .pan115, rawURL: url)
        }
        if let match = firstCaptures(pan115CommandRegex, in: url), match.count >= 2 {
            return ParsedShare(shareId: match[0], pwd: match[1], platform: .pan115, rawURL: url)
        }

        // ---- 光鸭云盘 ----
        if let sid = firstMatch(guangyaRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInUrlRegex, in: url) ?? pwdInText,
                               platform: .guangya, rawURL: url)
        }

        // ---- 蓝奏云优享版（必须先于蓝奏云）----
        if let sid = firstMatch(ilanzouRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInLanzouUrlRegex, in: url) ?? pwdInText,
                               platform: .ilanzou, rawURL: url)
        }

        // ---- 蓝奏云 ----
        if let sid = firstMatch(lanzouRegex, in: url) {
            return ParsedShare(shareId: sid, pwd: pwd(pwdInLanzouUrlRegex, in: url) ?? pwdInText,
                               platform: .lanzou, rawURL: url)
        }

        // ---- GitHub（shareId 用 owner/repo 便于展示）----
        if let caps = firstCaptures(githubRegex, in: url), caps.count >= 2 {
            return ParsedShare(shareId: "\(caps[0])/\(caps[1])", pwd: nil,
                               platform: .github, rawURL: url)
        }

        return nil
    }

    /// 宽松版解析：不抛错，仅用于「粘贴后自动识别」这种不该弹错的场景。
    static func parseQuietly(_ text: String) -> ParsedShare? {
        try? parse(text)
    }

    /// 判断一段文本看起来是不是分享链接（用于剪贴板智能提示）。
    static func looksLikeShareLink(_ text: String) -> Bool {
        parseQuietly(text) != nil
    }

    // MARK: - 内部工具

    /// 返回第一个捕获组的内容（无捕获组时返回整个匹配）。
    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let caps = firstCaptures(regex, in: text) else { return nil }
        return caps.first
    }

    /// 返回所有捕获组（不含整段匹配）。第 1 组为 caps[0]。
    private static func firstCaptures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) else {
            return nil
        }
        if match.numberOfRanges <= 1 {
            guard let range = Range(match.range, in: text) else { return nil }
            return [String(text[range])]
        }
        var result: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: text) else { continue }
            result.append(String(text[range]))
        }
        return result.isEmpty ? nil : result
    }

    /// 取提取码，空串归一成 nil。
    private static func pwd(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let value = firstMatch(regex, in: text), !value.isEmpty else { return nil }
        return value
    }
}
