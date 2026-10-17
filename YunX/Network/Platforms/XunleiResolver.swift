//
//  XunleiResolver.swift
//  云析 YunX iOS —— 迅雷网盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/XunleiApi.kt + XunleiConstants.kt。
//
//  ## 迅雷与其他网盘的关键差异
//  1. **直链必须先转存**：迅雷没有「免转存取分享直链」的接口，流程是
//     share → restore（转存到个人网盘的临时目录）→ getFileDetail（拿 links 直链）。
//     上游在个人网盘里建「YunX临时转存」目录，下载完再删。
//  2. **captcha 令牌**：pan 接口部分 action 需要 `X-Captcha-Token`，不带会拿到
//     降级 token 或被拒。上游做法是先用 `/v1/shield/captcha/init` 换令牌，
//     请求体里带 captcha_sign（10 层 md5）。
//  3. **游客态不能写 Authorization**：带一个失效的 `Bearer ` 反而会被判成
//     unauthenticated（上游 Agent.md §3.19 记录）。所以 accessToken 为空时
//     干脆不加这个头。
//  4. **提取码状态是 HTTP 200 + files 空数组**：必须读 share_status
//     （PASS_CODE_EMPTY / ERROR / NEED），否则会误判成「此目录为空」。
//
//  ## iOS 首版的收敛
//  上游迅雷模块有 47KB，包含账号密码登录、短信验证码、活体验证、token 刷新。
//  iOS 版不内嵌登录流程：`accessToken` 由用户在设置页粘贴导入（抓包得到），
//  失效时提示重新导入。这样砍掉了整个登录态维护链路，但保留了完整的
//  解析 / 转存 / 取直链能力。
//

import Foundation

final class XunleiResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    private enum Constants {
        static let authBase = "https://xluser-ssl.xunlei.com"
        static let panBase = "https://api-pan.xunlei.com"

        static let captchaInitURL = "\(authBase)/v1/shield/captcha/init"
        static let filesURL = "\(panBase)/drive/v1/files"
        static let shareURL = "\(panBase)/drive/v1/share"
        static let shareDetailURL = "\(panBase)/drive/v1/share/detail"
        static let restoreURL = "\(panBase)/drive/v1/share/restore"
        static let tasksURL = "\(panBase)/drive/v1/tasks"

        /// 临时转存目录名（与上游一致，便于识别与清理）
        static let tempDirName = "YunX临时转存"
    }

    private let client = HTTPClient.shared
    private var accessToken: String
    /// captcha 令牌按 action 缓存：不同 action 的签名不同，不能混用
    private var captchaTokens: [String: String] = [:]
    private let lock = NSLock()

    init(accessToken: String = "") {
        self.accessToken = accessToken
    }

    func updateAccessToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        captchaTokens.removeAll()
    }

    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return !accessToken.isEmpty
    }

    // MARK: - ShareResolving

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        // 迅雷的「分享解析」本身就是列根目录，顺带拿到标题和 pass_code_token
        let result = try await getShare(
            shareId: share.shareId,
            passCode: share.pwd ?? ""
        )
        return ShareToken(
            stoken: result.passCodeToken,
            title: result.title,
            firstFid: result.files.first?.fid ?? ""
        )
    }

    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        // 迅雷用 page_token 分页而不是 page 序号；这里 page>1 时暂不支持
        // （上游同样只处理首屏 100 条 + next_page_token，iOS 首版沿用）
        guard page == 1 else { return [] }

        if pdirFid == "0" || stoken.isEmpty {
            // 根目录：share 接口自带 files
            let result = try await getShare(shareId: share.shareId, passCode: share.pwd ?? "")
            return result.files
        }
        // 子目录：share/detail
        return try await getShareDetail(
            shareId: share.shareId,
            parentId: pdirFid,
            passCodeToken: stoken
        )
    }

    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        // 第 1 步：转存到个人网盘的临时目录，拿到新文件 id
        let tempDirId = try await ensureTempDir()
        let newFileId = try await restore(
            shareId: share.shareId,
            passCodeToken: stoken,
            parentFolderId: tempDirId,
            fileIds: [file.fid]
        )

        // 第 2 步：查文件详情拿直链（links.application/octet-stream.url）
        let link = try await getFileDetail(fileId: newFileId, fallbackName: file.fname)
        return link
    }

    /// 下载时不需要额外头（迅雷 CDN 直链自带签名），但保留接口以便将来加 Referer。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        ["User-Agent": XunleiCrypto.webUA]
    }

    // MARK: - 分享解析

    private struct ShareResult {
        var title: String
        var files: [ShareFile]
        var passCodeToken: String
        var nextPageToken: String
    }

    private func getShare(shareId: String, passCode: String) async throws -> ShareResult {
        var components = URLComponents(string: Constants.shareURL)!
        components.queryItems = [
            URLQueryItem(name: "share_id", value: shareId),
            URLQueryItem(name: "pass_code", value: passCode),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "page_token", value: ""),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_SMALL")
        ]

        let data = try await panCall(
            url: components.url!.absoluteString,
            action: "GET:/drive/v1/share"
        )

        // 提取码状态检查：这三种情况 files 为空数组且 HTTP 200
        switch data.optString("share_status") {
        case "PASS_CODE_EMPTY": throw ResolveError.needPassword
        case "PASS_CODE_ERROR": throw ResolveError.wrongPassword
        case "PASS_CODE_NEED": throw ResolveError.needPassword
        default: break
        }

        return ShareResult(
            title: data.optString("title"),
            files: parseFiles(data.optArray("files"), parentDir: "0"),
            passCodeToken: data.optString("pass_code_token"),
            nextPageToken: data.optString("next_page_token")
        )
    }

    private func getShareDetail(
        shareId: String,
        parentId: String,
        passCodeToken: String
    ) async throws -> [ShareFile] {
        var components = URLComponents(string: Constants.shareDetailURL)!
        components.queryItems = [
            URLQueryItem(name: "share_id", value: shareId),
            URLQueryItem(name: "parent_id", value: parentId),
            URLQueryItem(name: "pass_code_token", value: passCodeToken),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "page_token", value: ""),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_SMALL")
        ]
        let data = try await panCall(
            url: components.url!.absoluteString,
            action: "GET:/drive/v1/share/detail"
        )
        return parseFiles(data.optArray("files"), parentDir: parentId)
    }

    /// 迅雷文件项 → 统一 ShareFile。
    private func parseFiles(_ items: [[String: Any]], parentDir: String) -> [ShareFile] {
        items.compactMap { item in
            let id = item.optString("id")
            guard !id.isEmpty else { return nil }
            return ShareFile(
                fid: id,
                fname: item.optString("name"),
                fsize: item.optInt64("size"),
                isdir: item.optString("kind").contains("folder"),
                pdirFid: parentDir,
                // 迅雷没有 share_fid_token，直链靠转存后的新 id 拿
                fidToken: "",
                modifyTime: item.optString("modified_time")
            )
        }
    }

    // MARK: - 转存与直链

    /// 确保个人网盘里存在临时转存目录，返回其 id。存在则复用。
    private func ensureTempDir() async throws -> String {
        // 先查根目录下有没有同名目录
        var components = URLComponents(string: Constants.filesURL)!
        components.queryItems = [
            URLQueryItem(name: "parent_id", value: ""),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "filters", value: #"{"trashed":{"eq":false}}"#),
            URLQueryItem(name: "with_audit", value: "true")
        ]
        let listing = try await panCall(
            url: components.url!.absoluteString,
            action: "GET:/drive/v1/files"
        )
        for item in listing.optArray("files") where item.optString("name") == Constants.tempDirName {
            return item.optString("id")
        }

        // 不存在则创建（上游注释：space 必须是字符串，数字会 400）
        let body: [String: Any] = [
            "kind": "drive#folder",
            "name": Constants.tempDirName,
            "parent_id": "",
            "space": ""
        ]
        let created = try await panCall(
            url: Constants.filesURL,
            action: "POST:/drive/v1/files",
            method: "POST",
            body: body
        )
        let id = created.optString("id")
        guard !id.isEmpty else {
            throw ResolveError.api("创建迅雷临时转存目录失败")
        }
        return id
    }

    /// 转存分享文件到指定目录，返回转存后的新文件 id。
    private func restore(
        shareId: String,
        passCodeToken: String,
        parentFolderId: String,
        fileIds: [String]
    ) async throws -> String {
        let body: [String: Any] = [
            "share_id": shareId,
            "pass_code_token": passCodeToken,
            "parent_id": parentFolderId,
            "file_ids": fileIds
        ]
        let data = try await panCall(
            url: Constants.restoreURL,
            action: "POST:/drive/v1/share/restore",
            method: "POST",
            body: body
        )

        // 官方同步返回 trace_file_ids 映射（原 id → 新 id）
        let trace = data.optObject("trace_file_ids")
        if let trace, let newId = trace[fileIds[0]] as? String, !newId.isEmpty {
            return newId
        }

        // 异步路径：有 task_id 就轮询任务
        let taskId = data.optString("task_id")
        if !taskId.isEmpty {
            return try await pollTask(taskId: taskId, originalId: fileIds[0])
        }
        throw ResolveError.api("转存失败：未返回新的文件 id")
    }

    private func pollTask(taskId: String, originalId: String) async throws -> String {
        let url = "\(Constants.tasksURL)/\(taskId)?type=share"
        // 最多等 60 秒（转存通常 1~3 秒完成，慢的时候取决于文件大小）
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let data = try await panCall(url: url, action: "GET:/drive/v1/tasks")
            if let trace = data.optObject("trace_file_ids"),
               let newId = trace[originalId] as? String, !newId.isEmpty {
                return newId
            }
            let state = data.optString("state")
            if state == "PHASE_TYPE_FAILURE" || state == "PHASE_TYPE_ERROR" {
                throw ResolveError.api(data.optString("message").isEmpty ? "迅雷转存任务失败" : data.optString("message"))
            }
        }
        throw ResolveError.api("迅雷转存超时，请稍后在网盘里查看")
    }

    private func getFileDetail(fileId: String, fallbackName: String) async throws -> DownloadLink {
        var components = URLComponents(string: "\(Constants.filesURL)/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "_magic", value: "2021"),
            URLQueryItem(name: "usage", value: "PLAY"),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"),
            URLQueryItem(name: "with", value: "hdr10"),
            URLQueryItem(name: "with", value: "subtitle_files"),
            URLQueryItem(name: "with", value: "task"),
            URLQueryItem(name: "with", value: "public_share_tag")
        ]
        let data = try await panCall(
            url: components.url!.absoluteString,
            action: "GET:/drive/v1/files/\(fileId)"
        )

        let links = data.optObject("links")
        let url = links?.optObject("application/octet-stream")?.optString("url") ?? ""
        let fallback = data.optString("web_content_link")
        guard !url.isEmpty || !fallback.isEmpty else {
            throw ResolveError.api("迅雷未返回下载直链")
        }
        return DownloadLink(
            fid: data.optString("id").isEmpty ? fileId : data.optString("id"),
            filename: data.optString("name").isEmpty ? fallbackName : data.optString("name"),
            downloadUrl: url.isEmpty ? fallback : url,
            size: data.optInt64("size"),
            guestCookie: ""
        )
    }

    // MARK: - pan 请求与 captcha

    /// 发一次 pan 请求，自动带上设备标识与 captcha 令牌。
    ///
    /// 与上游 `panCall` 对齐：首次不带 captcha 令牌，若服务端要求（或返回 412/403 一类
    /// 验证码错误）则初始化 captcha 后重试一次。
    private func panCall(
        url: String,
        action: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let identity = XunleiCrypto.identity()

        lock.lock()
        let token = accessToken
        let cachedCaptcha = captchaTokens[action] ?? ""
        lock.unlock()

        func makeRequest(captcha: String) throws -> HTTPClient.Request {
            var headers: [String: String] = [
                "User-Agent": XunleiCrypto.webUA,
                "X-Device-Id": identity.deviceId,
                "X-Client-Version": XunleiCrypto.appClientVersion,
                "Content-Type": "application/json",
                "Origin": "https://pan.xunlei.com",
                "Referer": "https://pan.xunlei.com/"
            ]
            // 游客模式（空 token）不写 Authorization —— 见文件头注释第 3 条
            if !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
            if !captcha.isEmpty {
                headers["X-Captcha-Token"] = captcha
            }
            return HTTPClient.Request(
                url: url,
                method: method,
                headers: headers,
                body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            )
        }

        do {
            return try await client.sendJSON(try makeRequest(captcha: cachedCaptcha))
        } catch let error as ResolveError {
            // captcha 失效（上游实测拿到的令牌是 723 长度，失效后服务端拒绝）
            guard case .api(let message) = error,
                  message.contains("captcha") || message.contains("验证") else {
                throw error
            }
            let fresh = try await initCaptcha(action: action, identity: identity)
            return try await client.sendJSON(try makeRequest(captcha: fresh))
        }
    }

    /// 初始化 captcha，返回令牌。算法见 XunleiCrypto.buildCaptchaSign。
    private func initCaptcha(action: String, identity: XunleiCrypto.Identity) async throws -> String {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let sign = XunleiCrypto.buildCaptchaSign(deviceId: identity.deviceId, timestampMs: ts)

        let body: [String: Any] = [
            "client_id": XunleiCrypto.appClientId,
            "action": action,
            "captcha_token": "",
            "device_id": identity.deviceId,
            "meta": [
                "package_name": XunleiCrypto.appPackageName,
                "client_version": XunleiCrypto.appClientVersion,
                "captcha_sign": sign,
                "timestamp": ts,
                "user_id": "0"
            ]
        ]

        let json = try await client.sendJSON(HTTPClient.Request(
            url: Constants.captchaInitURL,
            method: "POST",
            headers: [
                "User-Agent": XunleiCrypto.webUA,
                "Content-Type": "application/json",
                "X-Client-Id": XunleiCrypto.appClientId,
                "X-Client-Version": XunleiCrypto.appClientVersion
            ],
            body: try? JSONSerialization.data(withJSONObject: body)
        ))

        let captchaToken = json.optString("captcha_token")
        guard !captchaToken.isEmpty else {
            throw ResolveError.api("迅雷验证码初始化失败")
        }
        lock.lock(); captchaTokens[action] = captchaToken; lock.unlock()
        return captchaToken
    }
}
