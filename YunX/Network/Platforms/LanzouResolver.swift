//
//  LanzouResolver.swift
//  云析 YunX iOS —— 蓝奏云 + 蓝奏云优享版分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//  - data/network/LanzouApi.kt + LanzouConstants.kt         → `LanzouResolver`
//  - data/network/ILanzouApi.kt + ILanzouConstants.kt       → `ILanzouResolver`
//
//  两个平台域名族不同（lanzou*/lan[zs]o[ux].com|net|org|cn 与 ilanzou.com|net|org|cn）、
//  协议也完全不同（前者没有 API，全靠解析 HTML；后者是规规矩矩的 JSON 接口），但因为
//  「都是蓝奏系、都只有文件没有目录树」而放在同一个文件里，便于对照。
//
//  ============================ 一、蓝奏云（LanzouResolver） ============================
//
//  ## 关键坑（本节是全项目最容易坏的地方 —— 上游靠正则吃饭）
//
//  1. **分享页没有 API，只有 HTML**。下载要走的链路是：
//     分享页 HTML → 同源 iframe（下载页）→ 从 JS 变量里抠 `wp_sign`/`sign`、
//     `ajaxdata`/`websignkey`/`signs`/`websign`、`kdns` → POST `ajaxm.php`(有提取码)
//     或 `ajaxfile.php`(无提取码) 的 `action=downprocess` → 拿到 `dom` + `url`
//     → 拼 `{dom}/file/{url}` → HEAD 探测 → 得到最终直链。
//     **每一步的正则都照抄上游**，别自作聪明简化：蓝奏改版频繁，宽松正则会误匹配。
//
//  2. **`ves` 字段只在无提取码时出现**（值固定 "1"）。有提取码时传的是 `p` + `kd=1`，
//     没有 `ves`。上游 1011 行 `getShareDownloadLink` 里对这个分支写得很清楚。
//
//  3. **下载接口可能跨域**：新版页面在 `apifile.woozooo.com`。优先取页面里的
//     `domain1`/`domain2`（必须含 `/ajax`），其次页面里出现的绝对 `ajaxm/ajaxfile.php` 地址，
//     最后才回退同源。
//
//  4. **`acw_sc__v2` 人机校验**：蓝奏的 CDN/WAF 会返回一段 JS 校验页（含 40 位 hex `arg1`），
//     算出 Cookie 再重放即可。算法是固定公开变换（40 个位置重排 + 与掩码逐字节异或），
//     纯字符串运算、不执行页面脚本 —— 见 `acwScV2`。
//
//  5. **下载节点要求 `down_ip=1` Cookie**，且 HEAD 有时不给 `Content-Length`，
//     要回退成 `Range: bytes=0-8191` 读 `Content-Range` 拿总大小。
//
//  6. **`zt` 是业务码不是 HTTP 码**：1=成功、2=列表结束、3=提取码错误、4=请求频繁。
//
//  ## iOS 版的收敛
//  只保留匿名分享解析（`resolveShare` / `listShareFolder` / `getShareDownloadLink`）。
//  个人盘（Cookie + doupload.php 的那一堆 task）与账号密码登录（含 `acw_sc__v2` 重放）
//  都没有移植 —— 登录成功后要拿 `uid`/`vei` 调 10 多个 doupload task，属于「网盘管理」，
//  iOS 首版不做。`cookie` 参数保留在构造器里是为了与其它平台签名一致（个人盘能力将来可加）。
//
//  ========================== 二、蓝奏云优享版（ILanzouResolver） ==========================
//
//  ## 关键坑
//
//  1. **认证参数全走 URL query**，而且 `appToken` 有特殊编码：标准 query 编码后
//     把 `%3A` 还原成字面冒号。
//  2. **`timestamp` 是 AES 加密后的 hex**：`AES-128-ECB + PKCS5Padding`，密钥
//     `lanZouY-disk-app`（16 字节），明文是毫秒时间戳字符串，输出 32 位小写 hex。
//     `downloadId` = AES("<fileId>|<userId>")、`auth` = AES("<fileId>|<毫秒ts>")，
//     两者与 `timestamp` 用**同一个** ts。
//  3. **分享用 `apix.ilanzou.com`，个人盘用 `apis.ilanzou.com`** —— 两个不同主机，
//     分享页 JS 里的 `apiBaseURL` 就是 apix。混用会 404。
//  4. **必须带 Chrome 客户端提示头**（`sec-ch-ua` 那一串）：该站 CDN/WAF（ESA + acw_tc）
//     对浏览器式请求放行、对「裸」HTTP 客户端返回空列表 —— 缺了 `share/list` 恒为空数组。
//  5. **访问验证 409 + text/html**：服务端要求 Cookie 校验，上游做法是「重放一次」，
//     两次都失败就提示改用网页登录（iOS 无 JS 环境算不了 `acw_sc__v2`，只能到这步）。
//  6. **文件大小单位是 KiB**：`fileSize` 要 `* 1024` 才是字节；`pdirFid` 上游一律填空串。
//

import Foundation
// 蓝奏云优享版的直链接口对参数做 AES-ECB 加密，走 CommonCrypto 的 CCCrypt。
// ⚠️ CommonCrypto 不会由 Security 自动导出，必须显式 import，
// 否则 CCCrypt / kCCKeySizeAES128 等都找不到（编译期报 cannot find in scope）。
import CommonCrypto
import Security

// =====================================================================================
// MARK: - 蓝奏云（lanzou* / lan[zs]o[ux]）
// =====================================================================================

final class LanzouResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量（逐字对齐 LanzouConstants.kt）

    enum Constants {
        static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        /// 个人盘登录入口（文档 §1.2）
        static let mydiskURL = "https://pc.woozooo.com/mydisk.php"
        static let douploadURL = "https://pc.woozooo.com/doupload.php"
        static let origin = "https://pc.woozooo.com"

        /// 下载节点注入的 Cookie
        static let downIpCookie = "down_ip=1"

        /// 文件夹 id 前缀 d: / 文件 id 前缀 f:
        static let folderPrefix = "d:"
        static let filePrefix = "f:"

        static let maxFilePages = 1000
        static let maxFolderPages = 500

        /// 域名族：lanzou*、lan[zs]o[ux]，后缀 com/net/org/cn
        /// 上游正则：^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\.(?:com|net|org|cn)$
        static func isLanzouHost(_ host: String) -> Bool {
            let pattern = #"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\.(?:com|net|org|cn)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(location: 0, length: (host as NSString).length)
            return regex.firstMatch(in: host, options: [], range: range) != nil
        }

        /// 将分享链接规范为 https、去掉 fragment、去掉尾部斜杠
        static func normalizeShareUrl(_ url: String) -> String {
            var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("http://") {
                value = "https://" + String(value.dropFirst("http://".count))
            }
            if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<hashIndex])
            }
            while value.hasSuffix("/") {
                value.removeLast()
            }
            return value
        }
    }

    // MARK: - 状态

    private let client = HTTPClient.shared

    /// 个人盘 Cookie（`ylogin=..; phpdisk_info=..`）。分享解析用不到，保留以对齐构造器约定。
    private var cookie: String = ""

    /// 蓝奏可能返回 acw_sc__v2 校验页并下发 down_ip 等 Cookie：按 host 记 Cookie，
    /// 遇到校验页时本地算出 Cookie 后重放一次。
    private var cookieJar: [String: [String: String]] = [:]

    /// 分享页解析结果缓存：`downloadLink` 需要复用 `resolveToken` 时拿到的 HTML，
    /// 否则每个文件都要重新抓一次分享页（蓝奏对频繁请求会直接 429）。
    private var pageCache: [String: LanzouSharePage] = [:]

    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入/更新个人盘 Cookie（分享解析不需要它）。
    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否已导入个人盘 Cookie。
    ///
    /// 注意：蓝奏的**分享解析全流程匿名可用**，这里是 false 也不影响下载。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookie.contains("ylogin") && cookie.contains("phpdisk_info")
    }

    // MARK: - ShareResolving

    /// 换访问凭证。
    ///
    /// 蓝奏没有 token 概念：这里抓一次分享页 + 同源 iframe，把「是否文件夹 / 是否要密码 /
    /// 文件 id / 文件夹分页参数」一次性解析出来，并把提取码原样作为 stoken 带走
    /// （后续列目录与取直链都要它）。这与上游 `resolveShare` 的产物 `LanzouSharePage` 一致。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let page = try await resolveShare(share: share)
        if page.needsPwd && (share.pwd ?? "").isEmpty {
            throw ResolveError.needPassword
        }
        // stoken 用「规范化后的分享 URL」：蓝奏的会话状态全在这一条 URL + 提取码里
        return ShareToken(
            stoken: page.shareUrl,
            title: page.title,
            firstFid: page.singleFile?.fid ?? ""
        )
    }

    /// 列目录。
    ///
    /// 蓝奏有两种分享：
    /// - **单文件分享**：没有目录概念，`pdirFid` 传什么都返回那一个文件；
    /// - **文件夹分享**：走 `filemoreajax.php` 分页，`pdirFid` 上游固定传空（接口只认
    ///   页面里的 `lx/fid/t/k` 参数，不支持进子目录 —— 蓝奏文件夹分享本身是扁平的）。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let page1 = try await resolveShare(share: share, stokenHint: stoken)
        if !page1.isFolder {
            // 单文件分享：把解析结果当作唯一一条记录返回（与上游 `singleFile` 对齐）
            if let single = page1.singleFile {
                return page == 1 ? [single] : []
            }
            return []
        }
        return try await listShareFolder(page: page1, pwd: share.pwd ?? "", dirFid: pdirFid, pageIndex: page)
    }

    /// 取下载直链。
    ///
    /// 链路（对应上游 A2–A6）：iframe 下载页 → 抠 sign / websignkey → POST ajaxm/ajaxfile
    /// → 拼 `{dom}/file/{url}` → HEAD 探测（含 acw_sc__v2 与「验证并下载」处理）。
    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        let page = try await resolveShare(share: share, stokenHint: stoken)
        return try await downloadLink(page: page, file: file)
    }

    /// 下载请求所需的额外头。
    ///
    /// 蓝奏直链是节点 CDN 的临时地址：要带 Referer（分享站根）与 `down_ip=1` Cookie。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA
        ]
        if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
        }
        return headers
    }

    // MARK: - 分享页解析（上游 A1/A2）

    private struct LanzouSharePage {
        var shareUrl: String
        var baseUrl: String
        var title: String
        var isFolder: Bool
        var needsPwd: Bool
        var iframeUrl: String?
        var fileId: String?
        var folderParams: FolderParams?
        var html: String
        var singleFile: ShareFile?

        struct FolderParams {
            var lx: String
            var fid: String
            var t: String
            var k: String
        }
    }

    /// 抓分享页并解析。`stokenHint` 是 `resolveToken` 拿到的规范化 URL（为空时按 shareId 拼）。
    private func resolveShare(share: ParsedShare, stokenHint: String = "") async throws -> LanzouSharePage {
        let shareUrl = Self.shareURL(from: share, stokenHint: stokenHint)

        lock.lock()
        let cached = pageCache[shareUrl]
        lock.unlock()
        if let cached { return cached }

        let html = try await fetchPageFollowingLanzou(shareUrl)
        guard let origin = Self.origin(of: shareUrl) else {
            throw ResolveError.api("蓝奏分享链接无效")
        }
        let title = Self.extractTitle(html)
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"")
            || html.contains("input_password") || html.contains("密码不正确")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"")
            || html.contains("file_more")

        // iframe 的 src（同源下载页）；只接受 http(s) 绝对地址或绝对路径
        var iframeUrl: String? = Self.firstGroup(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html)
        if let raw = iframeUrl {
            iframeUrl = Self.absolutize(base: origin, target: raw)
        }

        // 文件 id：先找 ajaxm/ajaxfile 的 file= 参数，再找 name="file" 的 input，最后兜底
        var fileId = Self.firstGroup(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
        if fileId == nil {
            fileId = Self.firstGroup(#"name=["']file["']\s+value=["'](\d+)["']"#, in: html)
        }
        if fileId == nil {
            fileId = Self.firstGroup(#"file=(\d+)"#, in: html)
        }

        var folderParams: LanzouSharePage.FolderParams? = nil
        if isFolder {
            let lx = Self.jsVar(html, name: "lx")
            // 上游：fid 取 JS 变量，取不到时用 URL 路径末段
            let fid = Self.jsVar(html, name: "fid") ?? Self.lastPathSegment(shareUrl)
            let t = Self.jsVar(html, name: "t")
            let k = Self.jsVar(html, name: "k")
            if let lx, let t, let k, let fid {
                folderParams = LanzouSharePage.FolderParams(lx: lx, fid: fid, t: t, k: k)
            }
        }

        let shareId = Self.shareIdOf(shareUrl)
        // 单文件分享的展示大小：页面文本「文件大小：1.5 M」（参考 wenxi LanzouPage.displaySize）
        let displaySize = Self.displaySize(in: html)
        let singleFile: ShareFile? = isFolder ? nil : ShareFile(
            fid: shareId,
            fname: title,
            fsize: displaySize,
            isdir: false,
            pdirFid: "",
            fidToken: "",
            modifyTime: ""
        )

        let page = LanzouSharePage(
            shareUrl: shareUrl,
            baseUrl: origin,
            title: title.isEmpty ? "蓝奏分享" : title,
            isFolder: isFolder,
            needsPwd: needsPwd,
            iframeUrl: iframeUrl,
            fileId: fileId,
            folderParams: folderParams,
            html: html,
            singleFile: singleFile
        )
        lock.lock()
        pageCache[shareUrl] = page
        lock.unlock()
        return page
    }

    /// 分享链接 → 规范化 URL。`stokenHint` 已经是 URL 时直接用。
    private static func shareURL(from share: ParsedShare, stokenHint: String) -> String {
        if stokenHint.lowercased().hasPrefix("http") {
            return Constants.normalizeShareUrl(stokenHint)
        }
        // 单段 id：用最常见的分享域拼（上游 `buildShareInfo` 同一套兜底逻辑）
        return "https://pan.lanzoui.com/\(share.shareId)"
    }

    /// 取域名根（scheme://host）
    private static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        return "\(scheme)://\(host)"
    }

    /// 取主机名（小写）
    private static func host(of url: String) -> String {
        URLComponents(string: url)?.host?.lowercased() ?? ""
    }

    private static func shareIdOf(_ url: String) -> String {
        let path = URLComponents(string: url)?.path ?? ""
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? trimmed : last
    }

    private static func lastPathSegment(_ url: String) -> String? {
        let path = URLComponents(string: url)?.path ?? ""
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    // MARK: - 文件夹分页（上游 A7）

    private func listShareFolder(
        page: LanzouSharePage,
        pwd: String,
        dirFid: String,
        pageIndex: Int
    ) async throws -> [ShareFile] {
        guard let params = page.folderParams else {
            throw ResolveError.api("蓝奏分享分页异常，请重试")
        }
        let all = try await listShareFolderAll(page: page, params: params, pwd: pwd)
        // 上游是一次性把全部页拉完再返回；这里按「页大小」切片以支持 page 参数。
        // 页大小无法从响应得知，取上游实测的 20 条（filemoreajax 每页 20）
        let pageSize = 20
        let start = max(0, (max(1, pageIndex) - 1) * pageSize)
        if start >= all.count { return [] }
        let end = min(all.count, start + pageSize)
        return Array(all[start..<end])
    }

    /// 拉完整个文件夹的所有分页（上游 `listShareFolder` 的行为）。
    private func listShareFolderAll(
        page: LanzouSharePage,
        params: LanzouSharePage.FolderParams,
        pwd: String
    ) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen: Set<String> = []
        var pg = 1
        while pg <= Constants.maxFolderPages {
            var attempt = 0
            var body: [String: Any]? = nil
            while attempt <= 2 {
                do {
                    body = try await formPostJSON(
                        url: "\(page.baseUrl)/filemoreajax.php",
                        fields: [
                            ("lx", params.lx),
                            ("fid", params.fid),
                            ("t", params.t),
                            ("k", params.k),
                            ("pwd", pwd),
                            ("pg", String(pg))
                        ],
                        referer: page.shareUrl,
                        origin: page.baseUrl,
                        cookie: nil
                    )
                    break
                } catch {
                    attempt += 1
                    if attempt > 2 { throw ResolveError.api("蓝奏请求过于频繁，请稍后再试") }
                    // 上游 delay(300)；这里用 Task.sleep 让出线程
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    body = nil
                }
            }
            guard let json = body else { break }

            let zt = json.optInt("zt")
            switch zt {
            case 1:
                break
            case 2:
                return all
            case 3:
                throw ResolveError.wrongPassword
            case 4:
                // zt=4 是「请求频繁」：上游退一页重试，最多 2 次
                pg -= 1
                if attempt >= 2 { throw ResolveError.api("蓝奏请求过于频繁，请稍后再试") }
            default:
                throw ResolveError.api("蓝奏解析失败，请确认分享链接和提取码后重试")
            }

            let items = json.optArray("text")
            if items.isEmpty { break }
            var added = 0
            for item in items {
                let id = item.optString("id")
                if id.isEmpty || seen.contains(id) { continue }
                seen.insert(id)
                all.append(ShareFile(
                    fid: id,
                    fname: Self.firstNonBlank(item.optString("name_all"), item.optString("name")),
                    fsize: Self.parseDisplaySize(item.optString("size")),
                    isdir: false,
                    pdirFid: "",
                    fidToken: "",
                    modifyTime: item.optString("time")
                ))
                added += 1
            }
            if added == 0 { throw ResolveError.api("蓝奏分页重复，请重新打开目录") }
            pg += 1
        }
        return all
    }

    // MARK: - 取直链（上游 A2–A6）

    private func downloadLink(page: LanzouSharePage, file: ShareFile) async throws -> DownloadLink {
        let origin = page.baseUrl

        // A2：同源 iframe 下载页
        var html = page.html
        if let iframe = page.iframeUrl {
            let iframeHost = Self.host(of: iframe)
            let shareHost = Self.host(of: page.shareUrl)
            if !iframeHost.isEmpty && iframeHost == shareHost {
                html = try await fetchPage(iframe, referer: page.shareUrl)
            } else if !iframeHost.isEmpty {
                throw ResolveError.api("蓝奏下载页面地址异常，请检查分享链接")
            }
        }

        // 文件 id：页面解析的优先，其次在下载页里再找一遍
        var fileId = page.fileId
        if fileId == nil {
            fileId = Self.firstGroup(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
        }
        if fileId == nil {
            fileId = Self.firstGroup(#"file=(\d+)"#, in: html)
        }
        guard let fileId else {
            throw ResolveError.api("蓝奏解析失败，请确认分享链接和提取码后重试")
        }

        // A3：取下载参数。pwd 从 page 里拿不到（它是调用方的输入），
        // 因此这里用 URL 上的 pwd 参数或「页面是否需要密码」判定
        let pwd = Self.pwdOf(page.shareUrl)
        let withPwd = !pwd.isEmpty

        let ajaxUrl = resolveAjaxUrl(html: html, origin: origin, fileId: fileId, withPwd: withPwd)

        // 新版页面签名变量为 wp_sign（旧版为 sign）
        guard let sign = Self.jsVar(html, name: "wp_sign")
            ?? Self.jsVar(html, name: "sign")
            ?? Self.inputValue(html, name: "sign") else {
            throw ResolveError.api("蓝奏分享页缺少下载参数，请重新解析")
        }

        var fields: [(String, String)] = []
        fields.append(("action", "downprocess"))
        fields.append(("sign", sign))
        if withPwd {
            fields.append(("p", pwd))
            fields.append(("kd", "1"))
        } else {
            // 新版无密码协议：websignkey/signs 用 ajaxdata，websign 空，kd 用 kdns
            let ajaxData = Self.jsVar(html, name: "ajaxdata")
            let key = ajaxData
                ?? Self.jsVar(html, name: "websignkey")
                ?? Self.inputValue(html, name: "websignkey")
                ?? ""
            fields.append(("signs", Self.jsVar(html, name: "signs") ?? key))
            fields.append(("websignkey", key))
            fields.append(("websign", Self.jsVar(html, name: "websign") ?? ""))
            fields.append(("kd", Self.jsVarRaw(html, name: "kdns") ?? "1"))
            fields.append(("ves", "1"))
        }

        let ajaxJson = try await formPostJSON(
            url: ajaxUrl,
            fields: fields,
            referer: page.shareUrl,
            origin: origin,
            cookie: nil
        )
        try validateAjax(ajaxJson)

        let dom = ajaxJson.optString("dom")
        let rel = ajaxJson.optString("url")
        if dom.isEmpty || rel.isEmpty || rel.hasPrefix("/") || rel.contains("://") {
            throw ResolveError.api("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        guard let domOrigin = Self.origin(of: dom) else {
            throw ResolveError.api("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let jump = "\(domOrigin)/file/\(rel)"
        let (finalUrl, size) = try await probeAndVerify(jump: jump, shareOrigin: origin)

        return DownloadLink(
            fid: file.fid,
            filename: file.fname.isEmpty ? ajaxJson.optString("inf") : file.fname,
            downloadUrl: finalUrl,
            size: size > 0 ? size : file.fsize,
            // 蓝奏直链靠节点 Cookie（down_ip / acw_sc__v2）过校验
            guestCookie: cookieHeader(host: Self.host(of: finalUrl))
        )
    }

    /// 下载接口 URL：优先页面里的 `domain1`/`domain2`（新版在 apifile.woozooo.com，跨域），
    /// 其次页面中出现的绝对 ajaxm/ajaxfile 地址，最后回退同源。
    private func resolveAjaxUrl(html: String, origin: String, fileId: String, withPwd: Bool) -> String {
        if let domain1 = Self.jsVar(html, name: "domain1"), domain1.contains("/ajax") {
            return domain1
        }
        if let domain2 = Self.jsVar(html, name: "domain2"), domain2.contains("/ajax") {
            return domain2
        }
        if let absolute = Self.firstMatch(#"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#, in: html) {
            return absolute
        }
        // 有提取码走 ajaxfile.php，无提取码走 ajaxm.php（与上游一致，别弄反）
        return withPwd
            ? "\(origin)/ajaxfile.php?file=\(fileId)"
            : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    /// 直链探测：跟随 302、处理 acw_sc__v2 校验页与「验证并下载」，返回最终地址与大小。
    private func probeAndVerify(jump: String, shareOrigin: String) async throws -> (String, Int64) {
        var url = jump
        // 下载节点要求注入 down_ip=1 Cookie（文档 §A4）
        setCookie(host: Self.host(of: jump), name: "down_ip", value: "1")
        var confirmedHosts: Set<String> = []
        var challenges: Set<String> = []
        var visited: Set<String> = []

        for _ in 0..<8 {
            let host = Self.host(of: url)
            if host.isEmpty { throw ResolveError.api("蓝奏下载地址暂时不可用，请稍后重试") }
            if visited.contains(url) { throw ResolveError.api("蓝奏下载地址循环跳转，请重新解析") }
            visited.insert(url)

            let result = try await headRequest(url, shareOrigin: shareOrigin)
            switch result.code {
            case 300...399:
                guard let location = result.location else {
                    throw ResolveError.api("蓝奏下载地址暂时不可用，请稍后重试")
                }
                url = Self.absolutize(base: url, target: location)
            case 200, 206:
                let contentType = result.contentType
                let isHtml = contentType.lowercased().contains("text/html")
                if isHtml {
                    let body = try await httpGetText(url, referer: shareOrigin + "/")
                    // 下载节点可能先返回 acw_sc__v2 人机校验页：计算 Cookie 后重放
                    if let challenge = Self.lanzouChallengeCookie(body) {
                        if challenges.contains(host) {
                            throw ResolveError.api("蓝奏需要进一步验证，请在分享页完成验证后重试")
                        }
                        challenges.insert(host)
                        setCookie(host: host, name: "acw_sc__v2", value: challenge)
                        continue
                    }
                    if body.contains("验证并下载") {
                        if !confirmedHosts.contains(host) {
                            confirmedHosts.insert(host)
                            if let verified = try await submitVerify(nodeUrl: url, html: body, shareOrigin: shareOrigin) {
                                url = verified
                                continue
                            }
                        }
                        throw ResolveError.api("蓝奏需要进一步验证，请在分享页完成验证后重试")
                    }
                    throw ResolveError.api("蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试")
                }
                // HEAD 未给大小或缺少 content-type：回退 GET Range
                if result.size <= 0 {
                    let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                    if fallback > 0 { return (url, fallback) }
                }
                return (url, result.size)
            case 403, 404, 410:
                throw ResolveError.api("蓝奏下载地址已失效，请稍后重新解析")
            case 429:
                throw ResolveError.api("蓝奏下载请求过于频繁，请稍后再试")
            default:
                let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                if fallback > 0 { return (url, fallback) }
                throw ResolveError.api("蓝奏下载地址暂时不可用，请稍后重试")
            }
        }
        throw ResolveError.api("蓝奏下载地址暂时不可用，请稍后重试")
    }

    /// 提交「验证并下载」，返回新的直链 URL 或 nil（上游 A6）。
    private func submitVerify(nodeUrl: String, html: String, shareOrigin: String) async throws -> String? {
        guard let nodeOrigin = Self.origin(of: nodeUrl) else { return nil }

        // 新版确认页：data : { 'file':'<base64>','el':el,'sign':'<base64>' }
        let dataBlocks = Self.allGroups(#"data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#, in: html)
        let dataBlock = dataBlocks.first { $0.contains("'file'") || $0.contains("\"file\"") }

        var file: String? = nil
        if let dataBlock {
            file = Self.firstGroup(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: dataBlock)
        }
        if file == nil {
            file = Self.firstGroup(#"name=["']file["'][^>]*value=["']([^"']+)["']"#, in: html)
        }
        guard let file else { return nil }

        var sign: String? = nil
        if let dataBlock {
            sign = Self.firstGroup(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: dataBlock)
        }
        if sign == nil { sign = Self.jsVar(html, name: "sign") }
        if sign == nil { sign = Self.inputValue(html, name: "sign") }
        guard let sign else { return nil }

        // 节点页面 2 秒后才显示按钮，需等同样时长再提交（上游 Thread.sleep(2000)）
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let ajaxUrl = "\(nodeOrigin)/ajax.php"
        let json: [String: Any]
        do {
            json = try await formPostJSON(
                url: ajaxUrl,
                fields: [("file", file), ("el", "2"), ("sign", sign)],
                referer: nodeUrl,
                origin: nodeOrigin,
                cookie: nil
            )
        } catch {
            throw ResolveError.api("蓝奏下载验证服务暂时不可用，请稍后重试")
        }

        let zt = json.optInt("zt")
        let url = json.optString("url")
        if zt != 1 || url.isEmpty {
            // zt!=1 时 url 字段承载错误文案（如「验证码错误」）
            throw ResolveError.api(url.isEmpty ? "蓝奏需要进一步验证，请在分享页完成验证后重试" : url)
        }
        if url == "?SignError" {
            throw ResolveError.api("蓝奏下载验证已过期，请重新解析")
        }
        return url
    }

    // MARK: - 底层请求（蓝奏专用：需要「不跟随跳转」与手动重定向）

    private struct HeadResult {
        var code: Int
        var location: String?
        var size: Int64
        var contentType: String
    }

    /// HTTPClient 的 `send` 会跟随重定向，而蓝奏的探测逻辑必须自己看 302 的 Location。
    /// 这里用「同一份 URLSession 语义 + redirect 关闭」的独立会话。
    private lazy var rawSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// 关闭自动重定向的 delegate（307/308 也不跟，交给调用方判断）
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// 发一次「不跟随跳转」的请求，返回 (Data, HTTPURLResponse)
    private func rawSend(url: String, method: String, headers: [String: String], body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = URL(string: url) else {
            throw ResolveError.network("链接格式不合法：\(url)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await rawSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ResolveError.network("响应不是 HTTP 响应")
            }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw ResolveError.cancelled }
            throw ResolveError.network(error.localizedDescription)
        } catch let error as ResolveError {
            throw error
        } catch {
            throw ResolveError.network(error.localizedDescription)
        }
    }

    private func headRequest(_ url: String, shareOrigin: String) async throws -> HeadResult {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": "\(shareOrigin)/"
        ]
        let merged = mergedCookie(host: Self.host(of: url), extra: Constants.downIpCookie)
        if !merged.isEmpty { headers["Cookie"] = merged }

        let (_, http) = try await rawSend(url: url, method: "HEAD", headers: headers, body: nil)
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        var size: Int64 = 0
        if let contentRange {
            size = Self.sizeFromContentRange(contentRange)
        } else if http.statusCode == 200 {
            size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        }
        return HeadResult(
            code: http.statusCode,
            location: http.value(forHTTPHeaderField: "Location"),
            size: size,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? ""
        )
    }

    /// GET Range 探测总大小（HEAD 不给 Content-Length 时的兜底）
    private func rangeProbe(_ url: String, shareOrigin: String) async throws -> Int64 {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": "\(shareOrigin)/",
            "Range": "bytes=0-8191"
        ]
        let merged = mergedCookie(host: Self.host(of: url), extra: Constants.downIpCookie)
        if !merged.isEmpty { headers["Cookie"] = merged }

        let (_, http) = try await rawSend(url: url, method: "GET", headers: headers, body: nil)
        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range") else { return 0 }
        return Self.sizeFromContentRange(contentRange)
    }

    private static func sizeFromContentRange(_ value: String) -> Int64 {
        // `bytes 0-8191/1234567` → 取最后一个 '/' 之后的数字
        guard let slash = value.lastIndex(of: "/") else { return 0 }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// 抓页面文本（跟随跳转，用于 iframe 下载页 / 校验页）
    private func httpGetText(_ url: String, referer: String?) async throws -> String {
        var headers: [String: String] = ["User-Agent": Constants.webUA]
        if let referer { headers["Referer"] = referer }
        let merged = mergedCookie(host: Self.host(of: url), extra: Constants.downIpCookie)
        if !merged.isEmpty { headers["Cookie"] = merged }

        let (data, http) = try await rawSend(url: url, method: "GET", headers: headers, body: nil)
        if http.statusCode >= 400 {
            throw ResolveError.api("蓝奏文件已取消分享或不存在")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 抓分享页：手动跟随跳转并对 acw_sc__v2 校验页重放（上游 `fetchPageFollowingLanzou`）
    private func fetchPageFollowingLanzou(_ url: String) async throws -> String {
        var current = url
        var challenged: Set<String> = []

        for _ in 0..<8 {
            let host = Self.host(of: current)
            var headers: [String: String] = [
                "User-Agent": Constants.webUA,
                "Referer": current
            ]
            let jarCookie = cookieHeader(host: host)
            if !jarCookie.isEmpty { headers["Cookie"] = jarCookie }

            let (data, http) = try await rawSend(url: current, method: "GET", headers: headers, body: nil)
            if (300...399).contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location") else {
                    throw ResolveError.api("蓝奏页面跳转次数过多，请重新解析")
                }
                let next = Self.absolutize(base: current, target: location)
                let nextHost = Self.host(of: next)
                if nextHost.isEmpty || !Constants.isLanzouHost(nextHost) {
                    throw ResolveError.api("蓝奏分享链接无效")
                }
                current = next
                continue
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            if body.count > 2_000_000 { throw ResolveError.api("蓝奏分享页面过大或异常") }

            // 分享页可能先返回 acw_sc__v2 人机校验页：计算 Cookie 后重放
            if let challenge = Self.lanzouChallengeCookie(body) {
                if challenged.contains(host) {
                    throw ResolveError.api("蓝奏需要进一步验证，请在分享页完成验证后重试")
                }
                challenged.insert(host)
                setCookie(host: host, name: "acw_sc__v2", value: challenge)
                continue
            }
            if body.contains("文件已取消") || body.contains("不存在") {
                throw ResolveError.api("蓝奏文件已取消分享或不存在")
            }
            if body.contains("请求过于频繁") || body.contains("稍后再试") {
                throw ResolveError.api("蓝奏请求过于频繁，请稍后再试")
            }
            return body
        }
        throw ResolveError.api("蓝奏页面跳转次数过多，请重新解析")
    }

    /// 抓同源 iframe 页面（跟随跳转）
    private func fetchPage(_ url: String, referer: String?) async throws -> String {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": referer ?? url
        ]
        let merged = mergedCookie(host: Self.host(of: url), extra: nil)
        if !merged.isEmpty { headers["Cookie"] = merged }

        let (data, http) = try await rawSend(url: url, method: "GET", headers: headers, body: nil)
        if http.statusCode >= 400 {
            throw ResolveError.api("蓝奏文件已取消分享或不存在")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 表单 POST → JSON（不跟随跳转；429 与超大响应单独报错）
    private func formPostJSON(
        url: String,
        fields: [(String, String)],
        referer: String,
        origin: String,
        cookie: String?
    ) async throws -> [String: Any] {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": referer,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        let merged = mergedCookie(host: Self.host(of: url), extra: cookie)
        if !merged.isEmpty { headers["Cookie"] = merged }

        let bodyText = fields
            .map { "\(URLCodec.formEncode($0.0))=\(URLCodec.formEncode($0.1))" }
            .joined(separator: "&")

        let (data, http) = try await rawSend(
            url: url,
            method: "POST",
            headers: headers,
            body: Data(bodyText.utf8)
        )
        if http.statusCode == 429 { throw ResolveError.api("蓝奏请求过于频繁，请稍后再试") }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.count > 4_000_000 { throw ResolveError.api("蓝奏解析服务返回内容过大，请稍后重试") }
        if http.statusCode >= 400 && text.isEmpty {
            throw ResolveError.api("蓝奏解析服务响应异常（HTTP \(http.statusCode)），请稍后重试")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                throw ResolveError.api("蓝奏返回了验证页面，请稍后重试或在分享页完成验证")
            }
            throw ResolveError.api("蓝奏解析服务响应异常，请稍后重试")
        }
        return json
    }

    // MARK: - Cookie 罐

    private func hostOf(_ url: String) -> String { Self.host(of: url) }

    private func setCookie(host: String, name: String, value: String) {
        if host.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        var jar = cookieJar[host] ?? [:]
        jar[name] = value
        cookieJar[host] = jar
    }

    private func cookieHeader(host: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let jar = cookieJar[host] else { return "" }
        return jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 合并「按域 Cookie 罐」与调用方追加的 Cookie 串（如 down_ip=1）
    private func mergedCookie(host: String, extra: String?) -> String {
        var parts: [String] = []
        let jar = cookieHeader(host: host)
        if !jar.isEmpty { parts.append(jar) }
        if let extra, !extra.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(extra)
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - 业务校验

    private func validateAjax(_ json: [String: Any]) throws {
        if json.optInt("zt") == 1 { return }
        let inf = json.optString("inf")
        if inf.contains("密码") || inf.contains("提取码") {
            throw ResolveError.wrongPassword
        }
        if inf.contains("不存在") || inf.contains("取消") || inf.contains("过期") || inf.contains("删除") {
            throw ResolveError.api("蓝奏文件已取消分享或不存在")
        }
        if inf.contains("频繁") || inf.contains("次数") || inf.contains("稍后") {
            throw ResolveError.api("蓝奏请求过于频繁，请稍后再试")
        }
        throw ResolveError.api("蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    // MARK: - acw_sc__v2

    /// 计算 JS 人机校验 Cookie `acw_sc__v2`（固定公开变换，仅字符串运算、不执行页面脚本）：
    /// 页面给 40 位十六进制 `arg1`，按固定位置重排后与掩码逐字节异或。
    static func acwScV2(_ arg1: String) -> String {
        let positions = [
            15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
            39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36
        ]
        let mask = "3000176000856006061501533003690027800375"
        let source = Array(arg1)
        var reordered = [Character](repeating: "\0", count: positions.count)
        for x in 0..<source.count {
            for z in 0..<positions.count where positions[z] == x + 1 {
                reordered[z] = source[x]
            }
        }
        let shuffled = String(reordered)
        let shuffledChars = Array(shuffled)
        let maskChars = Array(mask)

        var out = ""
        var index = 0
        while index + 2 <= shuffledChars.count && index + 2 <= maskChars.count {
            let a = Int(String(shuffledChars[index..<(index + 2)]), radix: 16) ?? 0
            let b = Int(String(maskChars[index..<(index + 2)]), radix: 16) ?? 0
            out += String(format: "%02x", a ^ b)
            index += 2
        }
        return out
    }

    /// 页面若是 acw_sc__v2 校验页则返回应设置的 Cookie 值。
    private static func lanzouChallengeCookie(_ source: String) -> String? {
        guard let arg1 = firstGroup(#"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#, in: source) else { return nil }
        return acwScV2(arg1)
    }

    // MARK: - 页面抽取工具（正则逐字对齐上游）

    /// 2010-01 起 Swift 的 NSRegularExpression 与 Kotlin Regex 语法一致（ICU），
    /// 上游所有正则可原样搬运；捕获组统一取第 1 组。
    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[groupRange])
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard let groupRange = Range(match.range, in: text) else { return nil }
        return String(text[groupRange])
    }

    /// 所有匹配的第 1 捕获组（上游 `findAll` + `map { groupValues[1] }`）
    static func allGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[groupRange])
        }
    }

    /// JS 变量（带引号）：`(?:(?:var|let|const)\s+)?NAME\s*=\s*['"]([^'"]*)['"]`
    static func jsVar(_ html: String, name: String) -> String? {
        firstGroup(#"(?:(?:var|let|const)\s+)?"# + NSRegularExpression.escapedPattern(for: name)
                   + #"\s*=\s*['"]([^'"]*)['"]"#, in: html)
    }

    /// 读取未加引号的 JS 变量值（如 `var kdns = 0`）。
    static func jsVarRaw(_ html: String, name: String) -> String? {
        guard let value = firstGroup(#"(?:var|let|const)\s+"# + NSRegularExpression.escapedPattern(for: name)
                                     + #"\s*=\s*([^;,\n\r]+)"#, in: html) else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// input 的 value（两种属性顺序都兜住）
    static func inputValue(_ html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstGroup(#"<input[^>]*name=["']"# + escaped + #"["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? firstGroup(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']"# + escaped + #"["']"#, in: html)
    }

    static func extractTitle(_ html: String) -> String {
        if let raw = firstGroup(#"<title>([^<]*)</title>"#, in: html) {
            var clean = raw.replacingOccurrences(of: " - 蓝奏云", with: "")
            clean = clean.replacingOccurrences(of: "蓝奏云", with: "")
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains("密码") { return clean }
        }
        if let name = firstGroup(#"class=["']n["']>([^<]+)<"#, in: html) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let filename = firstGroup(#"var\s+filename\s*=\s*['"]([^'"]+)['"]"#, in: html) {
            return filename
        }
        return ""
    }

    /// 页面对应「文件大小：1.5 M」这类展示文本
    static func displaySize(in html: String) -> Int64 {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?"#,
            options: [.caseInsensitive]
        ) else { return 0 }
        let range = NSRange(location: 0, length: (html as NSString).length)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else { return 0 }
        guard let valueRange = Range(match.range(at: 1), in: html) else { return 0 }
        let number = String(html[valueRange])
        var unit = ""
        if match.numberOfRanges > 2, let unitRange = Range(match.range(at: 2), in: html) {
            unit = String(html[unitRange])
        }
        return parseDisplaySize("\(number) \(unit)")
    }

    /// `"1.5 M"` → 字节数（上游 `parseDisplaySize`）
    static func parseDisplaySize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let regex = try? NSRegularExpression(
            pattern: #"([\d.]+)\s*([KMGT]?)"#,
            options: [.caseInsensitive]
        ) else { return 0 }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: trimmed) else { return 0 }
        guard let value = Double(String(trimmed[valueRange])) else { return 0 }
        var unit = ""
        if match.numberOfRanges > 2, let unitRange = Range(match.range(at: 2), in: trimmed) {
            unit = String(trimmed[unitRange]).uppercased()
        }
        let factor: Int64
        switch unit {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        let result = value * Double(factor)
        if result <= 0 { return 0 }
        return Int64(result)
    }

    /// 分享 URL 上的 pwd 参数
    static func pwdOf(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return "" }
        for item in components.queryItems ?? [] where item.name == "pwd" {
            return item.value ?? ""
        }
        return ""
    }

    /// 相对地址 → 绝对地址（上游 `absolutize`：只拼 scheme://host，忽略 path）
    static func absolutize(base: String, target: String) -> String {
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://") {
            return target
        }
        guard let origin = origin(of: base) else { return target }
        if target.hasPrefix("/") { return origin + target }
        return "\(origin)/\(target)"
    }

    static func firstNonBlank(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

// =====================================================================================
// MARK: - 蓝奏云优享版（ilanzou）
// =====================================================================================

final class ILanzouResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量（逐字对齐 ILanzouConstants.kt）

    enum Constants {
        static let apiBase = "https://apis.ilanzou.com"
        static let webSite = "https://www.ilanzou.com"

        /// 分享业务主机（分享页 JS config.apiBaseURL = https://apix.ilanzou.com/）
        static let shareApiBase = "https://apix.ilanzou.com"
        static let shareList = "\(shareApiBase)/unproved/share/list"
        static let shareRedirect = "\(shareApiBase)/unproved/file/redirect"
        /// 分享页 Referer（分享页地址为 {WEB_SITE}/s/<shareId>）
        static let shareRefererPrefix = "\(webSite)/s/"

        /// 下载请求头（文档 §4.1）
        static let downloadReferer = "\(webSite)/"
        static let downloadOrigin = webSite

        static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        static let devType = "6"
        static let devModel = "chrome"
        static let devVersion = "125"
        /// 分享页 devModel 与网页一致（首字母大写）
        static let shareDevModel = "Chrome"

        /// 页大小固定 60（文档 §3.1）
        static let pageSize = 60

        static let fileRedirect = "\(apiBase)/unproved/file/redirect"

        /// 根目录 id
        static let rootFolderId = "0"

        /// AES 密钥（文档 §6.1）：16 字节，正好是 AES-128
        static let aesKey = "lanZouY-disk-app"

        static let folderPrefix = "d:"
        static let filePrefix = "f:"

        static func newUuid() -> String {
            let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            var out = ""
            out.reserveCapacity(16)
            for _ in 0..<16 {
                out.append(chars[Int.random(in: 0..<chars.count)])
            }
            return out
        }
    }

    // MARK: - 状态

    private let client = HTTPClient.shared

    /// 优享版的 appToken（个人盘能力用；分享解析匿名可用）。
    private var cookie: String = ""

    /// 设备标识：优享版要求每次会话带同一个 uuid；首次用到时惰性生成并缓存。
    private var uuidCache: String = ""

    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入/更新 appToken。
    func updateCookie(_ newToken: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同 `updateCookie`，语义更清楚的名字。
    func updateToken(_ newToken: String) {
        updateCookie(newToken)
    }

    /// 是否已导入 appToken。
    ///
    /// 注意：优享版**分享解析（share/list + share/download）匿名可用**，false 也能解析分享。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookie.count >= 16
    }

    // MARK: - ShareResolving

    /// 换访问凭证。
    ///
    /// 优享版的分享接口不需要 token（`/unproved/*` 就是「未验证/匿名」前缀），
    /// 只需要 `shareId` + 设备参数。所以这里打一次 `share/list` 拿首屏，
    /// 既校验分享是否有效，又拿到标题候选与首条 fid。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let files = try await shareList(shareId: share.shareId, folderId: nil, pageIndex: 1)
        // 上游不返回分享标题；用「首个条目名」做标题，比空串对用户友好
        let title = files.first?.fname ?? "蓝奏优享分享"
        return ShareToken(
            stoken: share.shareId,
            title: title,
            firstFid: files.first?.fid ?? ""
        )
    }

    /// 列目录。
    ///
    /// `folderId` 为空（或 "0"）时返回分享根条目；传数字目录 id 时返回该目录内容。
    /// 条目 fid 带前缀：目录 `d:<id>`、文件 `f:<id>`（文档 §3.1 ID 规范）。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let folderId: String?
        if pdirFid.isEmpty || pdirFid == "0" || pdirFid == "d:0" {
            folderId = nil
        } else {
            // 去掉 d: / f: 前缀：接口只认裸 id
            folderId = Self.stripPrefix(pdirFid)
        }
        let shareId = stoken.isEmpty ? share.shareId : stoken
        return try await shareList(shareId: shareId, folderId: folderId, pageIndex: page)
    }

    /// 取下载直链。
    ///
    /// `/unproved/file/redirect` 返回 302 Location（也可能是 JSON）：
    /// `downloadId` = AES("<fileId>|<userId>")、`auth` = AES("<fileId>|<ts>")，`userId` 未登录为空串。
    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        let shareId = stoken.isEmpty ? share.shareId : stoken
        let fileId = Self.stripPrefix(file.fid)
        let uuid = deviceUuid()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let tsText = String(ts)

        let params: [(String, String)] = [
            ("downloadId", Self.aesHex("\(fileId)|")),   // 未登录：userId 为空串
            ("enable", "1"),
            ("devType", Constants.devType),
            ("uuid", uuid),
            ("timestamp", Self.aesHex(tsText)),
            ("auth", Self.aesHex("\(fileId)|\(tsText)")),
            ("shareId", shareId)
        ]
        // 注意：这里用 encodeToken（会把 %3A 还原成冒号），与 buildUrl 的编码一致
        let query = params
            .map { "\($0.0)=\(Self.encodeToken($0.1))" }
            .joined(separator: "&")
        let url = "\(Constants.shareRedirect)?\(query)"

        var headers = commonHeaders(json: false)
        headers["Referer"] = "\(Constants.shareRefererPrefix)\(shareId)"

        let (data, http) = try await client.send(HTTPClient.Request(url: url, headers: headers))

        if (300...399).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           !location.isEmpty {
            let resolved = Self.resolve(against: Constants.shareApiBase, location: location)
            return DownloadLink(
                fid: Constants.filePrefix + fileId,
                filename: file.fname,
                downloadUrl: resolved,
                size: file.fsize,
                guestCookie: ""
            )
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResolveError.api("蓝奏优享未返回下载地址")
        }
        let link = Self.firstNonBlank(
            json.optString("url"),
            json.optObject("data")?.optString("url") ?? ""
        )
        if link.isEmpty {
            let reason = Self.firstNonBlank(json.optString("msg"), "蓝奏优享未返回下载地址，请检查文件权限")
            throw ResolveError.api(reason)
        }
        return DownloadLink(
            fid: Constants.filePrefix + fileId,
            filename: file.fname,
            downloadUrl: link,
            size: file.fsize,
            guestCookie: ""
        )
    }

    /// 下载请求所需的额外头（文档 §4.1：Referer + Origin 都要）。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": Constants.downloadReferer,
            "Origin": Constants.downloadOrigin
        ]
        if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
        }
        return headers
    }

    // MARK: - 分享接口

    /// 分享文件列表（匿名可用）。自动翻页（页大小 60），按 `pageIndex` 只返回目标页。
    private func shareList(shareId: String, folderId: String?, pageIndex: Int) async throws -> [ShareFile] {
        let target = max(1, pageIndex)
        var all: [ShareFile] = []
        var seen: Set<String> = []
        var page = 1

        while page <= 1000 {
            var params: [(String, String)] = []
            if let folderId, !folderId.isEmpty {
                params.append(("folderId", folderId))
            }
            params.append(("offset", String(page)))
            params.append(("limit", String(Constants.pageSize)))

            let url = shareUrl(path: Constants.shareList, shareId: shareId, params: params)
            let json = try await execShare(url: url, referer: "\(Constants.shareRefererPrefix)\(shareId)")

            let items = json.optArray("list")
            if items.isEmpty { break }

            var added = 0
            for item in items {
                guard let parsed = Self.parseItem(item) else { continue }
                if seen.contains(parsed.fid) { continue }
                seen.insert(parsed.fid)
                all.append(parsed)
                added += 1
            }
            if added == 0 { break }
            if page == target { break }

            let totalPage = json.optInt("totalPage")
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && items.count < Constants.pageSize { break }
            page += 1
        }
        return all
    }

    // MARK: - 请求

    /// 分享专用 URL 组装：公共参数 + shareId + 业务参数（不带 appToken，devModel 首字母大写）。
    private func shareUrl(path: String, shareId: String, params: [(String, String)]) -> String {
        let uuid = deviceUuid()
        var parts: [(String, String)] = []
        parts.append(("uuid", uuid))
        parts.append(("devType", Constants.devType))
        parts.append(("devCode", uuid))
        parts.append(("devModel", Constants.shareDevModel))
        parts.append(("devVersion", Constants.devVersion))
        parts.append(("appVersion", ""))
        parts.append(("timestamp", Self.aesHex(String(Int64(Date().timeIntervalSince1970 * 1000)))))
        parts.append(("extra", "2"))
        parts.append(("shareId", shareId))
        parts.append(contentsOf: params)

        let query = parts
            .map { "\($0.0)=\(Self.encodeToken($0.1))" }
            .joined(separator: "&")
        return "\(path)?\(query)"
    }

    /// 该站 CDN/WAF（ESA + acw_tc）会对浏览器式请求放行、对「裸」HTTP 客户端返回空列表，
    /// 故补全 Chrome 客户端提示头（与网页端一致），否则 share/list 恒为空。
    private func commonHeaders(json: Bool) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Origin": Constants.webSite,
            "Referer": Constants.downloadReferer,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-fetch-dest": "empty",
            "sec-fetch-mode": "cors",
            "sec-fetch-site": "same-site"
        ]
        if json { headers["Content-Type"] = "application/json; charset=utf-8" }
        return headers
    }

    /// 分享接口执行：非 200 时用服务端 msg（如「分享id不能为空」「参数缺失」），不当成登录失效。
    private func execShare(url: String, referer: String) async throws -> [String: Any] {
        var headers = commonHeaders(json: false)
        headers["Referer"] = referer

        let (data, http) = try await client.send(HTTPClient.Request(url: url, headers: headers))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResolveError.api("蓝奏优享分享请求失败（\(http.statusCode)）")
        }
        // 上游 `optInt("code", -1) != 200`：缺 code 字段也算失败
        let code = json.optInt("code")
        if code != 200 {
            throw ResolveError.api(Self.firstNonBlank(
                json.optString("msg"),
                "蓝奏优享分享请求失败（\(code)）"
            ))
        }
        return json
    }

    /// 设备 uuid：优享版要求「一次会话内稳定」，这里惰性生成 16 位并缓存
    /// （`ILanzouConstants.newUuid` 与线上 `unproved/getUuid` 同形）。
    private func deviceUuid() -> String {
        lock.lock(); defer { lock.unlock() }
        if uuidCache.isEmpty {
            uuidCache = Constants.newUuid()
        }
        return uuidCache
    }

    // MARK: - 条目解析

    /// 条目 → 统一 ShareFile（`fileType == 2` 为目录）。
    ///
    /// 注意两处单位：目录大小为 0；**文件大小 `fileSize` 是 KiB，要 ×1024**。
    static func parseItem(_ item: [String: Any]) -> ShareFile? {
        let fileType = item.optInt("fileType")
        if fileType == 2 {
            let rawId = firstNonBlank(item.optString("folderId"), String(item.optInt("folderId")))
            if rawId.isEmpty || rawId == "0" { return nil }
            return ShareFile(
                fid: Constants.folderPrefix + rawId,
                fname: item.optString("folderName"),
                fsize: 0,
                isdir: true,
                // 上游一律填空串（分享接口不返回父 id）
                pdirFid: "",
                fidToken: "",
                modifyTime: firstNonBlank(item.optString("updTime"), item.optString("addTime"))
            )
        }
        let rawId = firstNonBlank(item.optString("fileId"), String(item.optInt("fileId")))
        if rawId.isEmpty || rawId == "0" { return nil }
        return ShareFile(
            fid: Constants.filePrefix + rawId,
            fname: item.optString("fileName"),
            fsize: item.optInt64("fileSize") * 1024,
            isdir: false,
            pdirFid: "",
            fidToken: "",
            modifyTime: firstNonBlank(item.optString("updTime"), item.optString("addTime"))
        )
    }

    static func stripPrefix(_ fid: String) -> String {
        if fid.hasPrefix(Constants.folderPrefix) {
            return String(fid.dropFirst(Constants.folderPrefix.count))
        }
        if fid.hasPrefix(Constants.filePrefix) {
            return String(fid.dropFirst(Constants.filePrefix.count))
        }
        return fid
    }

    // MARK: - AES / URL 编码

    /// AES-128-ECB + PKCS5Padding（= PKCS7，块 16 字节），输出 32 位小写 hex。
    ///
    /// 为什么不用 CryptoKit：CryptoKit 只提供 CBC / GCM，**没有 ECB**；优享版的
    /// `timestamp` / `downloadId` / `auth` 三个参数恰恰是 `AES/ECB/PKCS5Padding`。
    /// 所以这里走 Security 框架导出的 CommonCrypto（`CCCrypt`，iOS 自带，无需第三方库），
    /// 一次调用完成「PKCS7 填充 + 加密」，与 Android 侧 Cipher 的行为一致。
    static func aesHex(_ plain: String) -> String {
        let keyData = Data(Constants.aesKey.utf8)
        guard keyData.count == kCCKeySizeAES128 else { return "" }
        let inputData = Data(plain.utf8)

        var outLength = 0
        // PKCS7 最多补满一整块，所以输出缓冲留 input + 一个块
        let outCapacity = inputData.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)

        // ⚠️ 所有尺寸必须提前取成局部常量。
        // 若在 `outData.withUnsafeMutableBytes { ... }` 闭包里再写 `outData.count`，
        // 就是「写访问未结束又发起读访问」，Swift 的独占访问检查会直接报
        // error: overlapping accesses to 'outData', but modification requires exclusive access。
        let inputCount = inputData.count
        let keyCount = keyData.count

        // 注意：Data.withUnsafeBytes 对空 Data 也给非 nil 的 baseAddress（长度 0 的哨兵），
        // 所以这里不需要为「空明文」写额外分支；CCCrypt 会只输出一个填充块。
        let status = outData.withUnsafeMutableBytes { outBytes -> Int32 in
            guard let outBase = outBytes.baseAddress else { return Int32(kCCParamError) }
            return keyData.withUnsafeBytes { keyBytes -> Int32 in
                guard let keyBase = keyBytes.baseAddress else { return Int32(kCCParamError) }
                return inputData.withUnsafeBytes { inBytes -> Int32 in
                    guard let inBase = inBytes.baseAddress else { return Int32(kCCParamError) }
                    return CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBase, keyCount,
                        nil,
                        inBase, inputCount,
                        outBase, outCapacity,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outLength > 0 else { return "" }

        var hex = ""
        hex.reserveCapacity(outLength * 2)
        for byte in outData.prefix(outLength) {
            hex += String(format: "%02x", byte)
        }
        return hex
    }

    /// 标准 query 编码后把 `%3A` 还原为字面冒号（对齐 `encodeToken`）。
    ///
    /// 这些参数全部拼在 URL query 上，不用 `formEncode`：后者按表单语义把空格编成 `+`，
    /// 放进 query 会被服务端当成字面加号。`queryEncode` 编成 `%20`，与 URL 语义一致。
    static func encodeToken(_ value: String) -> String {
        URLCodec.queryEncode(value).replacingOccurrences(of: "%3A", with: ":")
    }

    /// 相对 Location → 绝对地址（对齐 `URI(base).resolve(location)`）
    static func resolve(against base: String, location: String) -> String {
        if location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://") {
            return location
        }
        guard let baseURL = URL(string: base) else { return location }
        return URL(string: location, relativeTo: baseURL)?.absoluteString ?? location
    }

    static func firstNonBlank(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
