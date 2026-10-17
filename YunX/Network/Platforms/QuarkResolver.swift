//
//  QuarkResolver.swift
//  云析 YunX iOS —— 夸克网盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/QuarkApi.kt + QuarkConstants.kt。
//  只移植「分享解析 → 取直链」这条主链路；个人网盘管理（上传/转存/建目录/分享创建）
//  不在 iOS 首版范围内。
//
//  ## 上游踩过的坑（照抄进注释，避免以后改错）
//  1. 取 token 的 body 必须带 `support_visit_limit_private_share: true`，
//     否则私有分享拿不到 stoken。
//  2. 列目录必须带 Origin / Referer，否则偶发 400。
//  3. 直链签名绑定**取链时刻的 Cookie**：响应的 Set-Cookie 里会重新下发
//     `__puus`，必须合并回会话，否则下载时 412。`__puus` 有效期约 3 小时。
//  4. 游客态取链不看 Cookie 登录态，但会在 Set-Cookie 下发 `__pugs=xxx`，
//     这个令牌要跟着下载请求走（缺了夸克返回 412）。
//  5. 上游的 `pwd_id` 参数值就是分享短码，不是「密码 ID」，别被名字误导。
//

import Foundation

/// 夸克网盘解析器。
///
/// 会话 Cookie 通过 `updateCookie` 注入（iOS 版没有内嵌浏览器登录，靠用户从
/// Safari / 快捷指令导出 Cookie，或留空走游客态 —— 游客态有约 50MB 单文件限制，
/// 这是上游文档里明确记录的）。
final class QuarkResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量

    private enum Constants {
        static let apiUserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 " +
            "Safari/537.36 Channel/pckk_other_ch"

        static let apiBase = "https://drive-pc.quark.cn"
        static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
        static let shareDetailURL = "\(apiBase)/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
        static let downloadURL = "\(apiBase)/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"

        /// 下载直链防盗链必须带的 Referer
        static let downloadReferer = "https://pan.quark.cn/"
    }

    // MARK: - 状态

    private let client = HTTPClient.shared
    /// 账号 Cookie。为空 = 游客态。
    private var cookie: String = ""
    /// 游客态取链拿到的 `__pugs` 令牌，跨请求复用（同一次分享解析内）
    private var guestPugs: String = ""
    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie
    }

    /// 注入/更新账号 Cookie。
    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否处于登录态（上游判定：关键 Cookie 字段齐全）。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }

    // MARK: - ShareResolving

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        // pwd 为 nil 时传空串，与上游 `pwd ?: ""` 一致
        let body: [String: Any] = [
            "pwd_id": share.shareId,
            "passcode": share.pwd ?? "",
            "support_visit_limit_private_share": true
        ]
        let json = try await postJSON(Constants.shareTokenURL, body: body, useCookie: true)

        // 上游 parseData：先看 status/code，再取 data
        try checkStatus(json)

        guard let data = json.optObject("data") else {
            throw ResolveError.api("响应缺少 data 字段")
        }
        let stoken = data.optString("stoken")
        if stoken.isEmpty {
            // 需要提取码时服务端不返回 stoken，用 code 区分
            let code = json.optInt("code")
            if code == 41004 || code == 40003 { throw ResolveError.needPassword }
            throw ResolveError.api(json.optString("message").isEmpty ? "获取分享凭证失败" : json.optString("message"))
        }
        return ShareToken(
            stoken: stoken,
            title: data.optString("title"),
            firstFid: data.optString("first_fid")
        )
    }

    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        // 参数名必须是 pwd_id（值 = 分享短码），并追加 ver=2 / _page / _size 等固定参数
        var components = URLComponents(string: Constants.shareDetailURL)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "pwd_id", value: share.shareId),
            URLQueryItem(name: "stoken", value: stoken),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "_page", value: String(page)),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_banner", value: "0"),
            URLQueryItem(name: "_fetch_share", value: "0"),
            URLQueryItem(name: "fetch_relate_conversation", value: "0"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
        ]

        // 该接口需携带 Origin / Referer，否则可能返回 400
        var headers = baseHeaders()
        headers["Origin"] = "https://pan.quark.cn"
        headers["Referer"] = "https://pan.quark.cn/"

        let json = try await sendJSON(HTTPClient.Request(
            url: components.url?.absoluteString ?? Constants.shareDetailURL,
            headers: headers
        ))
        try checkStatus(json)

        guard let data = json.optObject("data") else {
            throw ResolveError.api("响应缺少 data 字段")
        }
        return data.optArray("list").map { item in
            ShareFile(
                fid: item.optString("fid"),
                fname: item.optString("file_name"),
                fsize: item.optInt64("size"),
                isdir: item.optBool("dir"),
                pdirFid: item.optString("pdir_fid"),
                fidToken: item.optString("share_fid_token"),
                modifyTime: item.optString("updated_at")
            )
        }
    }

    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        // 登录态与游客态打的是同一个端点，区别只在 Cookie 有无；游客态单文件约 50MB 上限
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": share.shareId,
            "stoken": stoken,
            // 与游客取链同构：两个空占位，官方前端同样传空串
            "speedup_session": "",
            "token": ""
        ]

        lock.lock()
        let currentCookie = cookie
        lock.unlock()

        let useCookie = !currentCookie.isEmpty
        var headers = baseHeaders()
        if useCookie {
            headers["Cookie"] = currentCookie
        } else {
            lock.lock()
            let pugs = guestPugs
            lock.unlock()
            if !pugs.isEmpty { headers["Cookie"] = pugs }
        }

        let (data, http) = try await client.send(HTTPClient.Request(
            url: Constants.downloadURL,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: body)
        ))

        // 先取本次响应的 __pugs —— 与本次直链同响应绑定，不能用别的响应的值
        let responsePugs = Self.pugs(from: http.value(forHTTPHeaderField: "Set-Cookie"))
        if let responsePugs {
            lock.lock(); guestPugs = responsePugs; lock.unlock()
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 非 JSON（风控页 / HTML 错误页）时带上 HTTP 状态码，便于分辨 401/403 与分享失效
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）")
        }

        let code = json.optInt("code")
        if json.optInt("status") != 200 && code != 0 {
            throw ResolveError.api(Self.errorMessage(code: code, message: json.optString("message")))
        }

        let items = json.optArray("data")
        guard let item = items.first else {
            throw ResolveError.api("未返回下载链接")
        }
        let url = item.optString("download_url")
        guard !url.isEmpty else {
            throw ResolveError.api("下载直链为空，可能是分享已失效或账号被风控")
        }

        lock.lock(); let pugsNow = guestPugs; lock.unlock()

        return DownloadLink(
            fid: item.optString("fid").isEmpty ? file.fid : item.optString("fid"),
            filename: item.optString("file_name").isEmpty ? item.optString("filename") : item.optString("file_name"),
            downloadUrl: url,
            size: item.optInt64("size"),
            // 登录态不返回 __pugs，此时下载用账号 Cookie（由调用方注入 headers）
            guestCookie: useCookie ? "" : pugsNow
        )
    }

    /// 下载请求所需的额外头（Callers 在 enqueue 时传入）。
    ///
    /// 夸克直链是防盗链的：不带 Referer 会 403，登录态还要带账号 Cookie；
    /// 游客态则要带 `__pugs`。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var headers = [
            "User-Agent": Constants.apiUserAgent,
            "Referer": Constants.downloadReferer
        ]
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        } else if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
        }
        return headers
    }

    // MARK: - 内部

    private func baseHeaders() -> [String: String] {
        ["User-Agent": Constants.apiUserAgent]
    }

    private func postJSON(
        _ url: String,
        body: [String: Any],
        useCookie: Bool
    ) async throws -> [String: Any] {
        var headers = baseHeaders()
        headers["Content-Type"] = "application/json"
        if useCookie {
            lock.lock()
            let current = cookie
            lock.unlock()
            if !current.isEmpty { headers["Cookie"] = current }
        }
        return try await sendJSON(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: body)
        ))
    }

    private func sendJSON(_ request: HTTPClient.Request) async throws -> [String: Any] {
        let json = try await client.sendJSON(request)
        return json
    }

    /// 上游 parseData 的状态检查：`status != 200 && code != 0` 视为失败。
    private func checkStatus(_ json: [String: Any]) throws {
        let code = json.optInt("code")
        if json.optInt("status") != 200 && code != 0 {
            throw ResolveError.api(Self.errorMessage(code: code, message: json.optString("message")))
        }
    }

    /// 从 Set-Cookie 列表里抠出 `__pugs` 的值。
    private static func pugs(from setCookie: String?) -> String? {
        guard let setCookie, !setCookie.isEmpty else { return nil }
        // URLSession 会把多个 Set-Cookie 用 ", " 合并；按前缀查找而不是按逗号切分，
        // 避免 Cookie 值里含逗号时被切坏
        for raw in setCookie.components(separatedBy: ",") {
            let pair = raw.split(separator: ";").first.map(String.init) ?? raw
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("__pugs=") {
                let value = String(trimmed.dropFirst("__pugs=".count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// 业务错误码 → 用户可读文案（对齐上游 guestErrorMessage / noSaveErrorMessage）。
    private static func errorMessage(code: Int, message: String) -> String {
        switch code {
        case 31001: return "登录态已失效，请重新导入 Cookie"
        case 41004, 40003: return "提取码错误"
        case 41006: return "分享已被取消或删除"
        case 41010: return "分享已过期"
        case 23018: return "请求过于频繁，可能触发风控，请稍后再试"
        default:
            return message.isEmpty ? "夸克接口返回错误（code \(code)）" : message
        }
    }
}
