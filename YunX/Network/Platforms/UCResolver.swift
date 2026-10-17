//
//  UCResolver.swift
//  云析 YunX iOS —— UC 网盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/UCApi.kt + UCConstants.kt。
//
//  UC 与夸克是同一套云盘后端（都属于阿里云盘系），接口路径与字段几乎一致，
//  差异在域名、UA 与部分鉴权细节。上游把两者写成两个独立文件而不是抽公共基类，
//  是因为 UA / 域名 / 错误码经常各自变动；iOS 版沿用这个思路保持独立，
//  只在真正重复的解析逻辑上复用了 `ShareFile` 的构造方式。
//
//  已知差异（对照上游 UCConstants）：
//  - 域名 drive.uc.cn，API 基址 pc-api.uc.cn
//  - 游客态取链缺 `__pugs` 时返回 403（夸克是 412）
//

import Foundation

final class UCResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    private enum Constants {
        static let apiUserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "UCBrowser/7.2.0.300 Chrome/130.0.0.0 Electron/30.0.8 Safari/537.36 Channel/ucpc_other_ch"

        static let apiBase = "https://pc-api.uc.cn"
        static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
        static let shareDetailURL = "\(apiBase)/1/clouddrive/share/sharepage/detail?pr=UCBrowser&fr=pc"
        static let downloadURL = "\(apiBase)/1/clouddrive/file/download?pr=UCBrowser&fr=pc&sys=win32&ve=3.23.2"

        static let downloadReferer = "https://drive.uc.cn/"
    }

    private let client = HTTPClient.shared
    private var cookie: String
    private var guestPugs: String = ""
    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie
    }

    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }

    // MARK: - ShareResolving

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let body: [String: Any] = [
            "pwd_id": share.shareId,
            "passcode": share.pwd ?? "",
            "support_visit_limit_private_share": true
        ]
        let json = try await postJSON(Constants.shareTokenURL, body: body)
        try checkStatus(json)

        guard let data = json.optObject("data") else {
            throw ResolveError.api("响应缺少 data 字段")
        }
        let stoken = data.optString("stoken")
        if stoken.isEmpty {
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

        var headers = baseHeaders()
        headers["Origin"] = "https://drive.uc.cn"
        headers["Referer"] = "https://drive.uc.cn/"

        let json = try await client.sendJSON(HTTPClient.Request(
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
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": share.shareId,
            "stoken": stoken,
            "speedup_session": "",
            "token": ""
        ]

        lock.lock()
        let currentCookie = cookie
        let pugs = guestPugs
        lock.unlock()

        let useCookie = !currentCookie.isEmpty
        var headers = baseHeaders()
        headers["Content-Type"] = "application/json"
        if useCookie {
            headers["Cookie"] = currentCookie
        } else if !pugs.isEmpty {
            headers["Cookie"] = pugs
        }

        let (data, http) = try await client.send(HTTPClient.Request(
            url: Constants.downloadURL,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: body)
        ))

        if let responsePugs = Self.pugs(from: http.value(forHTTPHeaderField: "Set-Cookie")) {
            lock.lock(); guestPugs = responsePugs; lock.unlock()
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）")
        }
        let code = json.optInt("code")
        if json.optInt("status") != 200 && code != 0 {
            throw ResolveError.api(Self.errorMessage(code: code, message: json.optString("message")))
        }

        guard let item = json.optArray("data").first else {
            throw ResolveError.api("未返回下载链接")
        }
        let url = item.optString("download_url")
        guard !url.isEmpty else {
            // UC 游客态缺 __pugs 时是 403，与夸克的 412 不同，提示里要点明
            throw ResolveError.api("下载直链为空（HTTP \(http.statusCode)），可能是游客态令牌失效，请导入 Cookie 后重试")
        }

        lock.lock(); let pugsNow = guestPugs; lock.unlock()

        return DownloadLink(
            fid: item.optString("fid").isEmpty ? file.fid : item.optString("fid"),
            filename: item.optString("file_name").isEmpty ? item.optString("filename") : item.optString("file_name"),
            downloadUrl: url,
            size: item.optInt64("size"),
            guestCookie: useCookie ? "" : pugsNow
        )
    }

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

    private func postJSON(_ url: String, body: [String: Any]) async throws -> [String: Any] {
        var headers = baseHeaders()
        headers["Content-Type"] = "application/json"
        lock.lock()
        let current = cookie
        lock.unlock()
        if !current.isEmpty { headers["Cookie"] = current }

        return try await client.sendJSON(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: body)
        ))
    }

    private func checkStatus(_ json: [String: Any]) throws {
        let code = json.optInt("code")
        if json.optInt("status") != 200 && code != 0 {
            throw ResolveError.api(Self.errorMessage(code: code, message: json.optString("message")))
        }
    }

    private static func pugs(from setCookie: String?) -> String? {
        guard let setCookie, !setCookie.isEmpty else { return nil }
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

    private static func errorMessage(code: Int, message: String) -> String {
        switch code {
        case 31001: return "登录态已失效，请重新导入 Cookie"
        case 41004, 40003: return "提取码错误"
        case 41006: return "分享已被取消或删除"
        case 41010: return "分享已过期"
        case 23018: return "请求过于频繁，可能触发风控，请稍后再试"
        default:
            return message.isEmpty ? "UC 接口返回错误（code \(code)）" : message
        }
    }
}
