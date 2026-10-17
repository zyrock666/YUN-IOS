//
//  Pan115Resolver.swift
//  云析 YunX iOS —— 115 网盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//  - data/network/Pan115Api.kt（分享解析 → 取直链主链路 + 取链协议）
//  - data/network/Pan115Constants.kt（基址、请求头、错误码、Cookie 解析）
//  - data/network/Pan115Crypto.kt（电脑端下载接口的 RSA/XOR 包装，见文件末的 Pan115LinkCrypto）
//
//  ## 本平台的关键坑（照抄上游注释，改之前先读）
//
//  1. **分享链路的 stoken 是合成的**：115 没有「换 token」接口，列目录与取直链都要
//     `share_code` + `receive_code` + **分享者 user_id** 三样东西，而 user_id 只能从
//     `share/snap` 的响应里拿到。上游于是把 stoken 定义成 `<receive_code>|<分享者 user_id>`
//     （`Pan115Constants.encodeShareToken`），iOS 版逐字沿用 —— 所以本类的 `stoken`
//     不是服务端令牌，而是「提取码|分享者UID」。别在旁边另发明一个凭据类型。
//
//  2. **大文件直链必须走「电脑端」加密接口**：网页端 `GET /files/download` 对大文件
//     直接拒发（实测 482MB 就 `50028 文件大小超出限制，请使用115电脑端下载`）。
//     分享直链 `GET /share/downurl` 则是按 UA 判客户端：浏览器 UA 一律
//     `50029 当前版本过低`。所以取链与随后的下载请求都用 `Mozilla/5.0 115Browser/<版本>`，
//     而版本号不能写死 —— 115 会因为版本过低连直链都不给。上游的做法是从
//     `appversion.115.com` 拉当前 Windows 版版本号；这里同样实现（拉不到才用兜底值）。
//     注意：`ShareResolving` 没有 C2C 的能力位，所以本文件实现了那个私有协议
//     （`Pan115Crypto`）但主链路按上游「分享取链」走网页接口，理由见
//     `downloadLink(for:share:stoken:)` 与文件末的说明。
//
//  3. **直链 CDN 认响应头里下发的 900 秒 Cookie**：取链响应的 Set-Cookie 里有一条
//     path 绑定到对象路径的 Cookie（32 位 hex 名值），缺了 CDN 直接 403 `no cookie value`。
//     上游 `downloadCookie()` 会跳过 `expires/path/domain` 这类属性、优先取带非 `/` path 的那条。
//     这条 Cookie 放进 `DownloadLink.guestCookie`，下载时与账号 Cookie 一起发。
//
//  4. **业务成功判定是 `state == true`，不是 HTTP 200**：失败时看 `errno`
//     （见 `Pan115Constants` 的错误码），`error`/`msg` 只是兜底文案。
//
//  5. **Cookie 只要 UID 就算登录态**，但真正缺字段时服务端会以 `errno=990001` 明确报错；
//     不要自己拿 SEID/KID 判断（它们是 HttpOnly 且会轮换）。
//
//  ## iOS 版的收敛
//  只保留「解析 → 列目录 → 取直链」。个人盘 CRUD（建目录/移动/重命名/删除）、
//  创建分享、转存都没移植：它们与下载主链路无关，且要额外的协议确认与轮询。
//  `refreshClientVersion()` 拉版本号是取链正确性的一部分，**保留**。
//

import Foundation

final class Pan115Resolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量（逐字对齐 Pan115Constants.kt）

    enum Constants {
        /// 业务 API 主域（个人盘 + 分享接口同域）
        static let apiBase = "https://webapi.115.com"
        /// 分享链接域名（新分享默认 115cdn.com）
        static let shareHost = "https://115cdn.com"
        /// 通用 Referer（文档 §1：请求头需带对应页面 Referer）
        static let referer = "https://115.com/"
        /// 直链下载必须携带的 Referer（文档 §4.3）
        static let downloadReferer = "https://115.com/"

        /// 分享列目录（cid=0 为分享根）
        static let shareSnapURL = "\(apiBase)/share/snap"
        /// 分享直链（user_id 为分享者 UID）
        static let shareDownloadURL = "\(apiBase)/share/downurl"
        /// 个人盘直链（pickcode）。仅小文件可用，大文件 50028
        static let fileDownloadURL = "\(apiBase)/files/download"
        /// 「电脑端」直链接口（加密协议）
        static let appDownloadURL = "https://proapi.115.com/app/chrome/downurl"
        /// 115 客户端版本接口（data.win.version_code，免登录可用）
        static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"

        /// 根目录 cid
        static let rootCid = "0"
        /// 分享列目录每页条数（文档 §3 抓包用 20，放宽到 100）
        static let sharePageLimit = 100

        /// 桌面 Chrome UA（115 对非浏览器 UA 有风控）
        static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
        /// 携带 Cookie 时必须声明（文档 §1）
        static let xRequestedWith = "XMLHttpRequest"

        /// 下载专用客户端 UA 的版本号兜底值（alist 默认 27.0.5.7 已被判过低）
        static let clientUAVersionFallback = "36.0.1"

        // ---------- 错误码（115_share_api.md §7） ----------
        static let errnoLoginTimeout = 990001
        static let errnoNeedCode = 4100012
        static let errnoWrongCode = 4100008
        static let errnoShareGone = 4100026
        static let errnoWebSizeLimit = 50028
        static let errnoClientTooOld = 50029

        /// 拼客户端 UA
        static func clientUa(version: String) -> String { "Mozilla/5.0 115Browser/\(version)" }

        /// 分享页 Referer（alist 实践：`https://115cdn.com/s/<code>?password=<code>&`）
        static func shareReferer(shareCode: String, receiveCode: String) -> String {
            if receiveCode.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(shareHost)/s/\(shareCode)"
            }
            return "\(shareHost)/s/\(shareCode)?password=\(receiveCode)&"
        }
    }

    // MARK: - 状态

    private let client = HTTPClient.shared

    /// 账号 Cookie（形如 `UID=103616022_A1_169; CID=xxx; SEID=...; KID=...`）。为空 = 游客态。
    private var cookie: String = ""

    /// 下载专用客户端 UA 的版本号（进程级缓存，取链与下载读同一个值）
    private var clientVersion: String = Constants.clientUAVersionFallback
    /// 版本号只往服务端拉一次（拉不到就保留兜底值，下次仍会重试）
    private var clientVersionFetched = false

    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入/更新账号 Cookie。
    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否处于登录态。
    ///
    /// 上游 `hasLoginCookie` 只校验 `UID`：SEID/KID 是 HttpOnly 且会轮换，
    /// 缺失时让服务端用 `errno=990001` 明确报错更好定位。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.cookieValue(cookie, name: "UID") != nil
    }

    // MARK: - ShareResolving

    /// 换访问凭证。
    ///
    /// 115 没有独立的「换 token」端点，所以这里直接打一次 `share/snap`（分享根目录）：
    /// 既校验分享是否可用/是否需要提取码/提取码是否正确，又顺带拿到标题与分享者 UID ——
    /// 拿不到 UID 后面取直链必然失败（`share/downurl` 的 `user_id` 必须是分享者）。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let page = try await fetchSharePage(
            shareCode: share.shareId,
            receiveCode: share.pwd ?? "",
            cid: Constants.rootCid,
            offset: 0,
            limit: Constants.sharePageLimit
        )
        // 上游把「提取码 + 分享者 UID」整体塞进 stoken（见文件头坑 1）
        let stoken = Self.encodeShareToken(receiveCode: share.pwd ?? "", userId: page.userId)
        return ShareToken(
            stoken: stoken,
            title: page.title,
            firstFid: page.files.first?.fid ?? ""
        )
    }

    /// 列目录。`pdirFid` 传 "0" 表示分享根目录，`page` 从 1 开始。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let (receiveCode, _) = Self.decodeShareToken(stoken)
        // 上游 offset 是「已加载条数」的索引分页；接口没有页码概念，用 (page-1)*limit 换算
        let offset = max(0, (page - 1) * Constants.sharePageLimit)
        let result = try await fetchSharePage(
            shareCode: share.shareId,
            receiveCode: receiveCode,
            cid: pdirFid.isEmpty ? Constants.rootCid : pdirFid,
            offset: offset,
            limit: Constants.sharePageLimit
        )
        return result.files
    }

    /// 取下载直链。
    ///
    /// 走分享专用接口 `GET /share/downurl`（`user_id` 必须是分享者 UID，从 stoken 里解）。
    /// **必须用客户端 UA**：浏览器 UA 会被判「版本过低」直接 50029。
    /// 响应头会下发 900 秒 CDN Cookie，缺了直链 403 `no cookie value`。
    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        let (receiveCode, userId) = Self.decodeShareToken(stoken)
        if userId.isEmpty {
            throw ResolveError.api("缺少分享者标识，请重新解析分享链接")
        }
        await refreshClientVersion()
        let ua = currentClientUA()

        var url = Constants.shareDownloadURL
        url += "?dl=1"
        url += "&user_id=\(Self.encode(userId))"
        url += "&share_code=\(Self.encode(share.shareId))"
        url += "&file_id=\(Self.encode(file.fid))"
        if !receiveCode.isEmpty {
            url += "&receive_code=\(Self.encode(receiveCode))"
        }

        let (json, cdnCookie) = try await executeJson(
            url: url,
            cookie: currentCookie(),
            referer: Constants.shareReferer(shareCode: share.shareId, receiveCode: receiveCode),
            userAgent: ua
        )
        try checkState(json, fallback: "获取下载链接失败")

        guard let data = json.optObject("data") else {
            throw ResolveError.api("未返回下载链接")
        }
        // 网页 JS 取的是 file_url_302 || url.url，这里三种形态都兜住
        var fileUrl = data.optString("file_url_302")
        if fileUrl.isEmpty { fileUrl = data.optString("file_url") }
        if fileUrl.isEmpty { fileUrl = data.optObject("url")?.optString("url") ?? "" }
        if fileUrl.isEmpty {
            throw ResolveError.api("下载直链为空，可能是分享已失效或该文件不允许外部下载")
        }

        let size = Int64(data.optString("fs")) ?? file.fsize
        return DownloadLink(
            fid: file.fid,
            filename: data.optString("fn").isEmpty ? file.fname : data.optString("fn"),
            downloadUrl: fileUrl,
            size: size,
            guestCookie: cdnCookie ?? ""
        )
    }

    /// 下载请求所需的额外头。
    ///
    /// 直链 CDN 是防盗链的：Referer 必须是 `https://115.com/`，UA 要用客户端 UA，
    /// 并且要带上「账号 Cookie + 取链响应下发的 900 秒 CDN Cookie」的合并串（文档 §4.3）。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        let accountCookie = currentCookie()
        var headers: [String: String] = [
            "User-Agent": currentClientUA(),
            "Referer": Constants.downloadReferer
        ]
        let merged = Self.mergeCookies(accountCookie, link.guestCookie)
        if !merged.isEmpty { headers["Cookie"] = merged }
        return headers
    }

    // MARK: - 分享解析

    /// `share/snap` 的结果（对应上游 `Pan115SharePage`）
    private struct SharePage {
        var files: [ShareFile]
        var total: Int
        /// 分享者 UID：取直链必需
        var userId: String
        var title: String
        var shareState: Int
    }

    private func fetchSharePage(
        shareCode: String,
        receiveCode: String,
        cid: String,
        offset: Int,
        limit: Int
    ) async throws -> SharePage {
        var url = Constants.shareSnapURL
        url += "?share_code=\(Self.encode(shareCode))"
        url += "&receive_code=\(Self.encode(receiveCode))"
        url += "&offset=\(offset)"
        url += "&limit=\(limit)"
        url += "&asc=0&cid=\(Self.encode(cid.isEmpty ? Constants.rootCid : cid))"
        url += "&format=json"

        let json = try await getJson(
            url,
            cookie: currentCookie(),
            referer: Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode)
        )
        try checkState(json, fallback: "获取分享列表失败")

        guard let data = json.optObject("data") else {
            return SharePage(files: [], total: 0, userId: "", title: "", shareState: 0)
        }
        let shareInfo = data.optObject("shareinfo")
        return SharePage(
            files: Self.parseShareFiles(data),
            total: data.optInt("count"),
            userId: data.optObject("userinfo")?.optString("user_id") ?? "",
            title: shareInfo?.optString("share_title") ?? "",
            shareState: data.optInt("share_state") != 0
                ? data.optInt("share_state")
                : (shareInfo?.optInt("share_state") ?? 0)
        )
    }

    /// 分享列表解析：`fc == 0` 为目录，目录 ID 取 `cid`、文件 ID 取 `fid`。
    ///
    /// 上游 Kotlin 写法 `item.optInt("fc", if (fid.isBlank()) 0 else 1) == 0` 的语义是
    /// 「缺 fc 时按 fid 是否为空推断」；Swift 没有 optInt(default:)，这里显式还原。
    private static func parseShareFiles(_ data: [String: Any]) -> [ShareFile] {
        data.optArray("list").compactMap { item -> ShareFile? in
            let fidRaw = item.optString("fid")
            let rawCount = item["fc"]
            let fc: Int
            if rawCount is NSNull || rawCount == nil {
                fc = fidRaw.isEmpty ? 0 : 1
            } else {
                fc = item.optInt("fc")
            }
            let isDir = (fc == 0)
            let id = isDir ? item.optString("cid") : fidRaw
            if id.isEmpty { return nil }
            return ShareFile(
                fid: id,
                fname: item.optString("n"),
                fsize: isDir ? 0 : item.optInt64("s"),
                isdir: isDir,
                pdirFid: isDir ? item.optString("pid") : item.optString("cid"),
                // 分享列表不返回 pickcode（pc）：分享直链只用 file_id
                fidToken: "",
                modifyTime: item.optString("t")
            )
        }
    }

    // MARK: - stoken 编解码（对齐 encodeShareToken / decodeShareToken）

    /// `<receive_code>|<分享者 user_id>`
    private static func encodeShareToken(receiveCode: String, userId: String) -> String {
        "\(receiveCode)|\(userId)"
    }

    /// 反解；格式异常时把整串当提取码、UID 视为空（与上游一致）。
    private static func decodeShareToken(_ token: String) -> (receiveCode: String, userId: String) {
        guard let index = token.firstIndex(of: "|") else {
            return (token, "")
        }
        let code = String(token[token.startIndex..<index])
        let uid = String(token[token.index(after: index)...])
        return (code, uid)
    }

    // MARK: - 客户端版本（取直链必需）

    /// 刷新客户端版本号（进程内只拉一次）。
    ///
    /// 115 会校验客户端版本：UA 里版本过低时连取直链都会被拒（`50029 当前版本过低`）。
    /// 上游按 alist `drivers/115/appver.go` 的做法，从 `appversion.115.com` 取
    /// `data.win.version_code` 刷新 UA；拉取失败保留兜底值，不影响后续请求。
    private func refreshClientVersion() async {
        lock.lock()
        let fetched = clientVersionFetched
        lock.unlock()
        if fetched { return }

        lock.lock(); clientVersionFetched = true; lock.unlock()

        guard let json = try? await getJson(
            Constants.appVersionURL,
            cookie: "",
            referer: Constants.referer
        ) else { return }

        let version = json.optObject("data")?.optObject("win")?.optString("version_code") ?? ""
        applyClientVersion(version)
    }

    /// 用最新版本号刷新缓存（对齐 `Pan115Constants.applyClientVersion`：非法值忽略）。
    private func applyClientVersion(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 形如 36.0.1 / 36.0.10，过滤掉接口异常时的空值或垃圾串
        guard !value.isEmpty, value.count <= 16 else { return }
        guard let first = value.first, first.isNumber else { return }
        guard value.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        lock.lock()
        if clientVersion == value {
            lock.unlock()
            return
        }
        clientVersion = value
        lock.unlock()
    }

    private func currentClientUA() -> String {
        lock.lock(); defer { lock.unlock() }
        return Constants.clientUa(version: clientVersion)
    }

    private func currentCookie() -> String {
        lock.lock(); defer { lock.unlock() }
        return cookie
    }

    // MARK: - 请求

    private func baseHeaders(cookie: String, referer: String, userAgent: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": Constants.xRequestedWith,
            "Referer": referer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    private func getJson(_ url: String, cookie: String, referer: String) async throws -> [String: Any] {
        let (json, _) = try await executeJson(
            url: url,
            cookie: cookie,
            referer: referer,
            userAgent: Constants.webUA
        )
        return json
    }

    /// 执行请求：返回响应 JSON 与响应头里下发的「下载专用 Cookie」（文档 §4.2）。
    private func executeJson(
        url: String,
        cookie: String,
        referer: String,
        userAgent: String
    ) async throws -> ([String: Any], String?) {
        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            headers: baseHeaders(cookie: cookie, referer: referer, userAgent: userAgent)
        ))

        // 上游先取 Set-Cookie 再解析 body：直链 Cookie 与本次响应绑定，不能事后补
        let downloadCookie = Self.downloadCookie(from: http.value(forHTTPHeaderField: "Set-Cookie"))

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if data.isEmpty {
                throw ResolveError.network("请求失败：响应为空（HTTP \(http.statusCode)）")
            }
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）")
        }
        return (json, downloadCookie)
    }

    /// 从 Set-Cookie 里取第一个 `name=value`（文档 §4.2：32 位 hex 名值、path 绑定 object）。
    ///
    /// 直链 CDN 只认 path 绑定的那条（`path=/<对象路径>/`），其余（如 WAF 的 `acw_tc`）不是它。
    private static func downloadCookie(from setCookie: String?) -> String? {
        guard let setCookie, !setCookie.isEmpty else { return nil }
        // URLSession 会把多条 Set-Cookie 用 ", " 合并；按 ", " 切分再各自取第一个 ';' 前的内容。
        // 这里不用裸 "," 切，是为了避免 Cookie 值里含逗号时被切坏（与上游 OkHttp headers() 对齐）
        let rawHeaders = setCookie.components(separatedBy: ", ")
        var fallback: String?
        for raw in rawHeaders {
            let pair = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? raw
            let trimmedPair = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmedPair.firstIndex(of: "=") else { continue }
            let name = String(trimmedPair[trimmedPair.startIndex..<eq])
            if name.isEmpty { continue }
            // 属性行（expires/path/domain）不是 Cookie 本身
            let lowered = name.lowercased()
            if lowered == "expires" || lowered == "path" || lowered == "domain" { continue }
            if fallback == nil { fallback = trimmedPair }

            // 匹配 Set-Cookie 里的 path 属性：[;\s]path=([^;]+)
            if let pathRange = raw.range(of: "path=") {
                let before = raw[raw.startIndex..<pathRange.lowerBound]
                let precededOK = before.isEmpty || before.hasSuffix(";") || before.hasSuffix(" ")
                if precededOK {
                    let rest = raw[pathRange.upperBound...]
                    let pathValue = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
                    if !pathValue.isEmpty, pathValue != "/" {
                        return trimmedPair
                    }
                }
            }
        }
        return fallback
    }

    // MARK: - 错误映射

    /// 成功判定：`state == true`；失败按抓包错误码给出可读提示（文档 §7）。
    private func checkState(_ json: [String: Any], fallback: String) throws {
        if json.optBool("state") { return }

        // errno 兼容 errNo 两种拼写（上游 errnoOf）
        var errno = json.optInt("errno")
        if errno == 0 { errno = json.optInt("errNo") }

        var raw = json.optString("error")
        if raw.isEmpty { raw = json.optString("msg") }

        let message: String
        switch errno {
        case Constants.errnoLoginTimeout:
            message = "登录已过期，请重新登录115网盘"
        case Constants.errnoNeedCode:
            // 分享确实要提取码：抛语义化错误，让 UI 能弹输入框而不是只显示文案
            throw ResolveError.needPassword
        case Constants.errnoWrongCode:
            throw ResolveError.wrongPassword
        case Constants.errnoShareGone:
            message = "分享链接不存在或已被删除"
        case Constants.errnoWebSizeLimit:
            message = "115 拒绝向网页端下发该文件的直链（文件过大），请改用115电脑端/手机客户端下载"
        case Constants.errnoClientTooOld:
            message = "115 判定当前标识版本过低、拒绝下发直链，请改用115电脑端/手机客户端下载"
        default:
            message = raw.isEmpty ? fallback : raw
        }

        // 上游：errno 非 0 且文案里没带这个数字时补一个后缀，便于对日志
        let suffix = (errno != 0 && !message.contains(String(errno))) ? "（errno=\(errno)）" : ""
        throw ResolveError.api(message + suffix)
    }

    // MARK: - 工具

    private static func encode(_ value: String) -> String {
        // Kotlin 的 URLEncoder.encode(v, "UTF-8")；项目内统一封装在 URLCodec
        URLCodec.formEncode(value)
    }

    /// 合并多段 Cookie（登录 Cookie + 直链响应下发的 CDN Cookie，文档 §4.3）
    private static func mergeCookies(_ parts: String...) -> String {
        parts
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "; ")
    }

    /// 取 Cookie 中某字段的值（Cookie 形如 `UID=103616022_A1_169; CID=xxx`）
    private static func cookieValue(_ cookie: String, name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix("\(name)=") else { continue }
            let value = String(pair.dropFirst(name.count + 1))
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }
}

// MARK: - 115「电脑端」下载协议（移植自 Pan115Crypto.kt）
//
// 为什么这个类型在本文件里却**主链路没用它**：`ShareResolving.downloadLink` 只能返回
// 一个 URL，而电脑端接口 `proapi.115.com/app/chrome/downurl` 的返回是
// 「RSA/XOR 包装的 JSON」，应答里同时带 file_name / file_size / url，且**必须**配同一
// 响应下发的 CDN Cookie 才能 206。上游把它用在两处：(1) 个人盘大文件；
// (2) 分享直链被 50028/50029 拒时的「转存 → 电脑端取链」兜底 —— 后者要往用户网盘里
// 真写数据，属于 iOS 首版明确不做的写操作（见 PORTING.md §3）。
//
// 所以：**协议完整搬过来**（字段、密钥表、RSA 分块、PKCS#1 v1.5 填充逐字节一致），
// 供以后接「个人盘直链 / CSE 通道」时直接调用；主链路走网页分享接口。
// 谁要启用它，请连上游的 accept_cookie / 转存清理一起搬，别只搬一半。
//
// 协议结构：
// - 请求：`data = base64( RSA( 我们的16字节key || 密文 ) )`，RSA 1024 位、指数 65537、128 字节分块；
// - 响应：`base64( RSA密文 )` → 去掉前 16 字节（服务端 salt）后按 12/4 两段 XOR 解出明文 JSON。
// 这套「RSA」在客户端侧只是 modPow(e)（服务端拿私钥「加密」，本质是签名），
// 所以公钥就能解回来 —— 两处都用同一个公钥模数。
enum Pan115LinkCrypto {

    /// XOR 密钥表（144 字节，与参考实现的 `xorKeySeed` / `KEY_TABLE` 逐字节一致，改动前先核对）
    private static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]

    /// 12 字节长密钥（参考实现的 xorClientKey / LONG_KEY）
    private static let longKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46
    ]

    /// 1024 位 RSA 公钥模数（115 电脑端内置公钥，两份参考实现一致）
    private static let modulus: [UInt8] = hexToBytes(
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    )

    /// 公钥指数
    private static let exponent = 0x10001

    /// RSA 分块：加密 117 字节（128 - 11），解密 128 字节
    private static let rsaEncodeBlock = 117
    private static let rsaBlock = 128

    /// 生成一次请求用的 16 字节 key（响应用同一个 key 解）
    static func newKey() -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        for index in key.indices {
            key[index] = UInt8.random(in: 0...255)
        }
        return key
    }

    /// 明文 payload → 请求体 `data` 参数值（base64）
    static func encode(payload: String, key: [UInt8]) -> String? {
        guard key.count == 16 else { return nil }
        var body = Array(payload.utf8)
        symmetricEncode(&body, key: key)
        var plain = key
        plain.append(contentsOf: body)
        return rsaEncrypt(plain).base64EncodedString()
    }

    /// 响应 `data` 字段（base64）→ 明文 JSON
    static func decode(data: String, key: [UInt8]) -> String? {
        guard key.count == 16 else { return nil }
        guard let cipherBytes = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            return nil
        }
        guard let decrypted = rsaDecrypt([UInt8](cipherBytes)), decrypted.count > 16 else {
            return nil
        }
        let salt = Array(decrypted[0..<16])
        var body = Array(decrypted[16..<decrypted.count])
        symmetricDecode(&body, key: key, salt: salt)
        return String(bytes: body, encoding: .utf8)
    }

    // MARK: - 内部

    /// XOR → 反转 → 用长密钥再 XOR（对上参考实现的 symmetricEncode）
    private static func symmetricEncode(_ data: inout [UInt8], key: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
        data.reverse()
        xorTransform(&data, key: longKey)
    }

    /// 用服务端 salt 反 XOR → 反转 → 用我们的 key 再 XOR（对上 symmetricDecode）
    private static func symmetricDecode(_ data: inout [UInt8], key: [UInt8], salt: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: salt, size: 12))
        data.reverse()
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
    }

    /// 参考实现的 deriveKey：key[i] = ((seed[i] + KEY_TABLE[size*i]) & 0xff) ^ KEY_TABLE[size*(size-1-i)]
    private static func deriveKey(seed: [UInt8], size: Int) -> [UInt8] {
        guard !seed.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: size)
        for index in 0..<size {
            let left = UInt16(keyTable[size * index])
            let right = UInt16(keyTable[size * (size - 1 - index)])
            let mixed = (UInt16(seed[index % seed.count]) &+ left) & 0xff
            out[index] = UInt8(mixed ^ right)
        }
        return out
    }

    /// 参考实现的 xorTransform：先处理 len%4 的前缀，其余整体平移
    private static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        guard !key.isEmpty else { return }
        let offset = data.count % 4
        if offset > 0 {
            for index in 0..<offset {
                data[index] = data[index] ^ key[index % key.count]
            }
        }
        if offset < data.count {
            for index in offset..<data.count {
                data[index] = data[index] ^ key[(index - offset) % key.count]
            }
        }
    }

    /// RSA 分块「加密」：PKCS#1 v1.5 填充后按公钥指数做 modPow（参考实现的 rsaEncrypt）
    private static func rsaEncrypt(_ input: [UInt8]) -> Data {
        var out = Data()
        var offset = 0
        while offset < input.count {
            let size = min(rsaEncodeBlock, input.count - offset)
            var block = [UInt8](repeating: 0xff, count: rsaBlock)
            block[0] = 0
            block[1] = 2
            let separator = rsaBlock - size - 1
            block[separator] = 0
            for index in 0..<size {
                block[separator + 1 + index] = input[offset + index]
            }
            out.append(contentsOf: toFixedLength(modPow(base: block, exponent: exponent, modulus: modulus)))
            offset += size
        }
        return out
    }

    /// RSA 分块「解密」：服务端用私钥加密，这里用公钥指数还原（参考实现的 rsaDecrypt）
    private static func rsaDecrypt(_ input: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let size = min(rsaBlock, input.count - offset)
            let block = Array(input[offset..<(offset + size)])
            let plain = toFixedLength(modPow(base: block, exponent: exponent, modulus: modulus))
            // PKCS#1 v1.5：0x00 0x02 <填充> 0x00 <数据>，从第 2 字节起找第一个 0x00
            var start = -1
            var index = 2
            while index < plain.count {
                if plain[index] == 0 {
                    start = index + 1
                    break
                }
                index += 1
            }
            guard start > 0, start < plain.count else { return nil }
            out.append(contentsOf: plain[start..<plain.count])
            offset += size
        }
        return out
    }

    // ---------- 大整数（只实现 modPow 用得到的那几件事） ----------
    //
    // 注意：Swift 里没有 `BigInteger`，Security 也没有「只给模数与指数」的接口
    // （SecKeyCreateWithData 要完整 RSA 公钥 DER）。而 115 这套协议只需要
    // `base^65537 mod N`，所以这里用 32 位 limb 手写：limbs 等长（= 模数 limb 数 + 1），
    // 每个运算都返回同样的长度，省掉反复扩容，也让不变量简单到能一眼看穿。

    /// limb 个数：128 字节模数 = 32 个 limb，再多 1 个 limb 给乘法中间结果留余量
    private static let limbCount = (rsaBlock / 4) + 1

    /// 大端字节串 → 定长 limb 数组（小端 limb）
    private static func fromBytes(_ bytes: [UInt8]) -> [UInt32] {
        var limbs = [UInt32](repeating: 0, count: limbCount)
        for (position, byte) in bytes.reversed().enumerated() {
            let limbIndex = position / 4
            if limbIndex >= limbCount { break }
            limbs[limbIndex] |= UInt32(byte) << (UInt32((position % 4) * 8))
        }
        return limbs
    }

    /// limb 数组 → 定长大端字节（左补零，超出则丢高位 —— 调用方保证不会溢出）
    private static func toFixedBytes(_ value: [UInt32], length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        for limbIndex in 0..<value.count {
            let limb = value[limbIndex]
            for byteIndex in 0..<4 {
                let position = limbIndex * 4 + byteIndex
                if position >= length { break }
                bytes[length - 1 - position] = UInt8((limb >> (UInt32(byteIndex * 8))) & 0xff)
            }
        }
        return bytes
    }

    /// 比较两个等长 limb 数组；左小返回 true
    private static func isLess(_ left: [UInt32], than right: [UInt32]) -> Bool {
        var index = min(left.count, right.count) - 1
        while index >= 0 {
            if left[index] != right[index] { return left[index] < right[index] }
            if index == 0 { break }
            index -= 1
        }
        return false
    }

    /// left -= right（要求 left >= right，等长）
    private static func subtractInPlace(_ left: inout [UInt32], _ right: [UInt32]) {
        var borrow: UInt64 = 0
        for index in 0..<left.count {
            let subtrahend = UInt64(index < right.count ? right[index] : 0)
            let current = UInt64(left[index])
            let minuend = current &+ 0x1_0000_0000
            let value = minuend &- subtrahend &- borrow
            left[index] = UInt32(truncatingIfNeeded: value)
            // 借位：减完仍 >= 2^32，说明刚才真的借过一次
            borrow = (value >> 32) == 0 ? 1 : 0
        }
    }

    /// 左移 1 位（等长，最高位丢弃 —— 模数最高位是 1，余数不会溢出）
    private static func shiftLeftOne(_ value: inout [UInt32]) {
        var carry: UInt32 = 0
        for index in 0..<value.count {
            let nextCarry = value[index] >> 31
            value[index] = (value[index] << 1) | carry
            carry = nextCarry
        }
    }

    /// 取第 bit 位（bit 从 0 起，自最低位）
    private static func bit(at index: Int, of value: [UInt32]) -> UInt32 {
        let limbIndex = index / 32
        if limbIndex >= value.count { return 0 }
        return (value[limbIndex] >> UInt32(index % 32)) & 1
    }

    /// 位长度
    private static func bitLength(_ value: [UInt32]) -> Int {
        var index = value.count - 1
        while index >= 0 {
            if value[index] != 0 {
                return index * 32 + (32 - value[index].leadingZeroBitCount)
            }
            if index == 0 { break }
            index -= 1
        }
        return 0
    }

    /// 无符号乘。
    ///
    /// 输出长度是 limbCount 的两倍：32 limb × 32 limb 的积最多 64 limb，
    /// 只留 limbCount 会把高位丢掉，reduce 出来就不是余数了（这个坑已实测踩过）。
    /// 32 limb 的输入本身已小于模数，所以两倍长度足够，不会溢出。
    private static func multiply(_ left: [UInt32], _ right: [UInt32]) -> [UInt32] {
        let size = limbCount * 2
        var out = [UInt32](repeating: 0, count: size)
        for i in 0..<left.count {
            let a = UInt64(left[i])
            if a == 0 { continue }
            var carry: UInt64 = 0
            var j = 0
            while j < right.count && (i + j) < size {
                let current = UInt64(out[i + j])
                let product = a &* UInt64(right[j])
                let sum = product &+ current &+ carry
                out[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                j += 1
            }
            var position = i + j
            while carry != 0 && position < size {
                let sum = UInt64(out[position]) &+ carry
                out[position] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                position += 1
            }
        }
        return out
    }

    /// value mod mod（逐位长除；两个数组等长，语义上 mod 的最高位是模数第 127 位）
    private static func reduce(_ value: [UInt32], mod: [UInt32]) -> [UInt32] {
        var remainder = [UInt32](repeating: 0, count: mod.count)
        let totalBits = bitLength(value)
        if totalBits == 0 { return remainder }

        var index = totalBits - 1
        while index >= 0 {
            shiftLeftOne(&remainder)
            remainder[0] |= bit(at: index, of: value)
            if !isLess(remainder, than: mod) {
                subtractInPlace(&remainder, mod)
            }
            if index == 0 { break }
            index -= 1
        }
        return remainder
    }

    /// base^exponent mod modulus —— 平方乘
    private static func modPow(base: [UInt8], exponent: Int, modulus: [UInt8]) -> [UInt32] {
        let mod = fromBytes(modulus)
        var result = fromBytes([1])
        var accumulator = reduce(fromBytes(base), mod: mod)
        var remaining = exponent
        while remaining > 0 {
            if remaining & 1 == 1 {
                result = reduce(multiply(result, accumulator), mod: mod)
            }
            accumulator = reduce(multiply(accumulator, accumulator), mod: mod)
            remaining >>= 1
        }
        return result
    }

    /// BigInteger → 固定 rsaBlock 字节大端表示（左补 0）
    private static func toFixedLength(_ value: [UInt32]) -> [UInt8] {
        toFixedBytes(value, length: rsaBlock)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}
