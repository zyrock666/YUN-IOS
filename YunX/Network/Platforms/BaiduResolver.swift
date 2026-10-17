//
//  BaiduResolver.swift
//  云析 YunX iOS —— 百度网盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/BaiduApi.kt + BaiduConstants.kt。
//
//  ## 本平台是全项目最长的链路（四步）
//  1. `share/verify`     —— 提交提取码，换 randsk（即 sekey）
//  2. `xpan/share?method=list` —— 列分享目录（根 root=1 / 子目录 root=0）
//  3. `share/transfer`   —— 转存到自己的网盘「YunX临时转存」目录
//  4. `pcs/file?method=locatedownload` —— 用转存后的**路径**换高速直链
//
//  百度没有「免转存直链」接口，必须转存。这也是上游 README 里
//  「不建议使用百度网盘，可能导致账号被风控」的原因 —— 每次下载
//  都会在你的网盘里留下临时文件与转存记录。
//
//  ## 照抄上游的五个坑
//  1. **root 参数**：顶层 `root=1`，子目录 `root=0`。root=1 下百度会忽略 dir 参数，
//     导致永远进不去子文件夹。
//  2. **BDCLND**：verify 的响应会在 Set-Cookie 里下发 `BDCLND=<randsk>`，
//     列子目录与转存都必须带上，缺了返回 errno=2。iOS 版手动拼进 Cookie。
//  3. **sekey**：为空（公开分享）时必须**省略整个 `&sekey=` 参数**，不能传空串。
//  4. **errno=-6** 是「未登录/身份验证失败」，游客态常见。此时提示用户找提取码
//     是误导，要单独区分成「需要提取码或需要登录」。
//  5. **直链候选选择**：locatedownload 返回 urls[] 多个候选。
//     rank1 常是 `d2-ant.baidu.com`（encrypt=1，AES-CTR 加密通道，部分网络 TLS 握手失败），
//     必须优先挑 `encrypt=0` 的明文通道（appallNN.baidupcs.com），否则下下来是乱码。
//
//  ## iOS 版的收敛
//  砍掉个人网盘管理（上传/重命名/移动/分享创建）与转存后的清理，
//  保留完整「解析 → 转存 → 取直链」链路。
//

import Foundation

final class BaiduResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    enum Constants {
        /// PC 网页 UA（share/verify、xpan/share、gettemplatevariable 使用）
        static let uaWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        /// 百度客户端 UA（locatedownload 使用）
        static let uaNetdisk = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"

        /// 百度网盘统一 app_id
        static let appId = "250528"

        /// 临时转存目录名（对齐上游抓包）
        static let tempDirName = "YunX临时转存"
    }

    /// 分享列表结果（xpan/share list 响应）。
    /// `shareId` / `uk` 是转存必需的两个参数，来自分享本身而不是链接。
    struct ShareListResult {
        var title: String
        var files: [ShareFile]
    }

    private let client = HTTPClient.shared
    private var cookie: String
    /// bdstoken 缓存在登录态内长期有效
    private var cachedBdstoken: String?
    /// 本次解析的 sekey（randsk），转存与子目录列目录都要用
    private var sekey: String = ""
    /// 分享的 share_id 与 uk（转存参数），由 listShare 填
    private var shareIdForTransfer: String = ""
    private var ukForTransfer: String = ""
    private let lock = NSLock()

    init(cookie: String = "") {
        self.cookie = cookie
    }

    func updateCookie(_ newCookie: String) {
        lock.lock(); defer { lock.unlock() }
        cookie = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedBdstoken = nil
    }

    /// 上游判定：缺 BDUSS 即视为未登录。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookie.contains("BDUSS=")
    }

    // MARK: - ShareResolving

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        // 第 1 步：提交提取码换 randsk。无提取码的公开分享也要走一次（上游同样调用）。
        if let pwd = share.pwd, !pwd.isEmpty {
            sekey = try await verifyShare(surl: share.shareId, pwd: pwd)
        } else {
            sekey = ""
        }

        // 第 2 步：列根目录，顺带拿标题与 share_id / uk
        let listing = try await listShare(surl: share.shareId, sekey: sekey, dir: "/", page: 1)
        return ShareToken(
            stoken: sekey,
            title: listing.title,
            firstFid: listing.files.first?.fid ?? ""
        )
    }

    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        // 百度用「路径」导航而不是 fid：目录项的 fid 就是 path
        let dir = pdirFid.isEmpty ? "/" : pdirFid
        let listing = try await listShare(
            surl: share.shareId,
            sekey: stoken.isEmpty ? sekey : stoken,
            dir: dir,
            page: page
        )
        return listing.files
    }

    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        guard isLoggedIn else {
            throw ResolveError.api("百度网盘下载必须登录：请先在设置里导入百度 Cookie（BDUSS）")
        }

        // 第 3 步：转存到个人网盘
        let tempDir = "/\(Constants.tempDirName)"
        try? await createDir(path: tempDir)

        let transferred = try await transfer(
            sekey: stoken.isEmpty ? sekey : stoken,
            fsId: file.fid,
            toDir: tempDir
        )

        // 第 4 步：用转存后的路径换高速直链
        let url = try await locateDownload(path: transferred.path)

        return DownloadLink(
            fid: transferred.fsId,
            filename: file.fname,
            downloadUrl: url,
            size: file.fsize,
            guestCookie: ""
        )
    }

    /// 百度直链需要登录 Cookie 与手机端 UA，否则 403。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var headers = [
            "User-Agent": Constants.uaNetdisk,
            "Referer": "https://pan.baidu.com/"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: - 分享验证

    /// 验证提取码，返回 randsk（直接作为 sekey 使用）。
    private func verifyShare(surl: String, pwd: String) async throws -> String {
        let body = "pwd=\(URLCodec.formEncode(pwd))&vcode_str=&vcode="
        let json = try await sendForm(
            url: "https://pan.baidu.com/share/verify?surl=\(URLCodec.queryEncode(surl))",
            body: body,
            referer: "https://pan.baidu.com/s/\(surl)",
            withCookie: true
        )
        try checkErrno(json, fallback: "验证提取码失败")
        let randsk = json.optString("randsk")
        guard !randsk.isEmpty else {
            throw ResolveError.api("未返回分享密钥（randsk）")
        }
        return randsk
    }

    // MARK: - 分享列表

    private func listShare(
        surl: String,
        sekey: String,
        dir: String,
        page: Int
    ) async throws -> ShareListResult {
        let isRoot = dir.isEmpty || dir == "/"
        let root = isRoot ? "1" : "0"
        // 公开分享（无 sekey）必须省略整个参数，不能传空串
        let sekeyPart = sekey.isEmpty ? "" : "&sekey=\(URLCodec.queryEncode(sekey))"

        let url = "https://pan.baidu.com/rest/2.0/xpan/share?method=list" +
            "&shorturl=\(URLCodec.queryEncode(surl))&page=\(page)&num=100&root=\(root)" +
            "&dir=\(URLCodec.queryEncode(dir.isEmpty ? "/" : dir))" + sekeyPart

        // 子目录(root=0)必须携带 BDCLND（= verify 的 randsk），否则 errno=2；顶层(root=1)无需
        var authCookie = currentCookie()
        if !sekey.isEmpty && !authCookie.contains("BDCLND=") {
            authCookie += "; BDCLND=\(sekey)"
        }

        let json = try await sendJSON(HTTPClient.Request(
            url: url,
            headers: [
                "Cookie": authCookie,
                "User-Agent": Constants.uaWeb,
                "Referer": "https://pan.baidu.com/s/\(surl)"
            ]
        ))

        let errno = json.optInt("errno")
        if errno != 0 {
            if sekey.isEmpty {
                // errno=-6 是「未登录/身份验证失败」，游客态常见；
                // 这时只提示提取码会让人白找密码，要区分开
                throw ResolveError.api(errno == -6
                    ? "该分享需要提取码，或需要登录百度网盘（errno=\(errno)）"
                    : "该分享需要提取码（errno=\(errno)）")
            }
            try checkErrno(json, fallback: "获取分享文件列表失败")
        }

        // 记下转存需要的两个参数
        lock.lock()
        shareIdForTransfer = json.optString("share_id")
        ukForTransfer = json.optString("uk")
        lock.unlock()

        let files: [ShareFile] = json.optArray("list").compactMap { item in
            let isdir = item.optString("isdir") == "1"
            let path = item.optString("path")
            // 目录用 path 作 fid（导航传参），文件用 fs_id（转存传参）
            let fid = isdir ? path : item.optString("fs_id")
            guard !fid.isEmpty else { return nil }
            return ShareFile(
                fid: fid,
                fname: item.optString("server_filename"),
                fsize: item.optInt64("size"),
                isdir: isdir,
                pdirFid: path,
                fidToken: "",
                modifyTime: item.optString("server_mtime")
            )
        }

        return ShareListResult(title: json.optString("title"), files: files)
    }

    // MARK: - 转存

    /// 转存单个文件到指定目录，返回新 fs_id 与新路径。
    private func transfer(sekey: String, fsId: String, toDir: String) async throws -> (fsId: String, path: String) {
        let bdstoken = try await bdstoken()
        lock.lock()
        let shareId = shareIdForTransfer
        let uk = ukForTransfer
        lock.unlock()

        let url = "https://pan.baidu.com/share/transfer?shareid=\(shareId)&from=\(uk)" +
            "&channel=chunlei&sekey=\(URLCodec.queryEncode(sekey))&ondup=newcopy&web=1" +
            "&app_id=\(Constants.appId)&bdstoken=\(URLCodec.queryEncode(bdstoken))&clienttype=0"
        // fsidlist 是 URL 编码后的 JSON 数组，上游写死成 %5B%22...%22%5D
        let body = "fsidlist=%5B%22\(fsId)%22%5D&path=\(URLCodec.formEncode(toDir))"

        // verify 响应会 Set-Cookie: BDCLND=<randsk>，transfer 必须携带（分享验证标识），
        // 缺失会 errno=2；BDCLND 的值即 sekey
        let authCookie = currentCookie().contains("BDCLND=")
            ? currentCookie()
            : "\(currentCookie()); BDCLND=\(sekey)"

        let headers = [
            "Cookie": authCookie,
            "User-Agent": Constants.uaWeb,
            "Origin": "https://pan.baidu.com",
            "Referer": "https://pan.baidu.com/s/",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
        ]

        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        ))
        _ = http
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.network("转存响应解析失败")
        }
        try checkErrno(json, fallback: "转存失败")

        guard let first = json.optObject("extra")?.optArray("list").first else {
            throw ResolveError.api("转存失败：未返回新文件")
        }
        let newFsId = first.optString("to_fs_id")
        guard !newFsId.isEmpty else {
            throw ResolveError.api("转存失败：未返回新的 fs_id")
        }
        let newPath = first.optString("to").isEmpty ? "\(toDir)/" : first.optString("to")
        return (newFsId, newPath)
    }

    /// 创建个人网盘目录（已存在时百度返回 errno=-8，视为成功）。
    private func createDir(path: String) async throws {
        let bdstoken = try await bdstoken()
        let url = "https://pan.baidu.com/api/create?a=commit&bdstoken=\(URLCodec.queryEncode(bdstoken))" +
            "&clienttype=0&app_id=\(Constants.appId)&web=1"
        let body = "path=\(URLCodec.formEncode(path))&isdir=1&block_list=%5B%5D"
        do {
            let json = try await sendForm(url: url, body: body, referer: "https://pan.baidu.com/disk/home", withCookie: true)
            let errno = json.optInt("errno")
            // -8 = 目录已存在，不是错误
            if errno != 0 && errno != -8 {
                throw ResolveError.api(json.optString("show_msg").isEmpty ? "创建临时目录失败" : json.optString("show_msg"))
            }
        } catch {
            // 建目录失败不阻断主流程：转存到根目录也能拿到直链
            return
        }
    }

    // MARK: - 直链

    /// 用转存后的完整路径换高速直链。
    ///
    /// 响应 `urls[]` 按 rank 返回多个候选：优先挑 `encrypt=0` 的明文 https 直链
    /// （appallNN.baidupcs.com）。rank1 常为 `d2-ant.baidu.com`（encrypt=1，AES-CTR
    /// 加密通道，部分网络 TLS 握手失败），直接排除。
    private func locateDownload(path: String) async throws -> String {
        let time = String(Int64(Date().timeIntervalSince1970))
        let url = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload" +
            "&app_id=\(Constants.appId)&clienttype=17&ver=4.0" +
            "&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1" +
            "&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1" +
            "&err_ver=1.0&network_type=WIFI&channel=0" +
            "&path=\(URLCodec.queryEncode(path))" +
            "&time=\(time)" +
            // 以下四项是上游抓包写死的常量（psign 为固定签名，rand/devuid/cuid/deviceid 可复用）
            "&rand=5ed606e9da222cde0474cdf70eda884b" +
            "&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF" +
            "&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF" +
            "&deviceid=348642637967375013" +
            "&psign=860a071f77c860e8cea06e4e54c518f3" +
            "&version=2.2.111.34&version_app=12.24.6&vip=0"

        let (data, _) = try await client.send(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: [
                "Cookie": currentCookie(),
                "User-Agent": Constants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: "0".data(using: .utf8)
        ))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.network("获取高速下载链接失败：响应解析失败")
        }
        try checkErrno(json, fallback: "获取高速下载链接失败")

        let candidates = json.optArray("urls").filter { !$0.optString("url").isEmpty }

        // 1) 优先明文通道（encrypt=0），且 https 优先
        let plain = candidates
            .filter { $0.optInt("encrypt") == 0 }
            .sorted { lhs, rhs in
                let l = lhs.optString("url").hasPrefix("https")
                let r = rhs.optString("url").hasPrefix("https")
                if l != r { return l }
                return false
            }
            .first
        if let plain, !plain.optString("url").isEmpty {
            return plain.optString("url")
        }

        // 2) 退回任意 https 候选（加密通道，仍有尝试价值）
        if let https = candidates.first(where: { $0.optString("url").hasPrefix("https") }) {
            return https.optString("url")
        }

        // 3) 最后兜底第一个候选
        if let first = candidates.first {
            return first.optString("url")
        }
        throw ResolveError.api("百度未返回下载链接")
    }

    // MARK: - bdstoken

    private func bdstoken() async throws -> String {
        lock.lock()
        if let cached = cachedBdstoken, !cached.isEmpty {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fields = URLCodec.queryEncode("[\"bdstoken\"]")
        let url = "https://pan.baidu.com/api/gettemplatevariable" +
            "?clienttype=0&app_id=\(Constants.appId)&web=1&fields=\(fields)"
        let json = try await sendJSON(HTTPClient.Request(
            url: url,
            headers: ["Cookie": currentCookie(), "User-Agent": Constants.uaWeb]
        ))
        guard json.optInt("errno") == 0 else {
            throw ResolveError.api("获取 bdstoken 失败，请重新导入 Cookie")
        }
        let token = json.optObject("result")?.optString("bdstoken") ?? ""
        guard !token.isEmpty else {
            throw ResolveError.api("获取 bdstoken 失败，请重新导入 Cookie")
        }
        lock.lock(); cachedBdstoken = token; lock.unlock()
        return token
    }

    // MARK: - 工具

    private func currentCookie() -> String {
        lock.lock(); defer { lock.unlock() }
        return cookie
    }

    private func sendJSON(_ request: HTTPClient.Request) async throws -> [String: Any] {
        try await client.sendJSON(request)
    }

    /// 发表单请求（百度多数接口用 x-www-form-urlencoded）。
    private func sendForm(
        url: String,
        body: String,
        referer: String,
        withCookie: Bool
    ) async throws -> [String: Any] {
        var headers = [
            "User-Agent": Constants.uaWeb,
            "Referer": referer,
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        if withCookie { headers["Cookie"] = currentCookie() }
        return try await client.sendJSON(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        ))
    }

    /// errno != 0 即失败。常见：-12 提取码错误 / 403 分享已失效 / 31066 文件不存在。
    private func checkErrno(_ json: [String: Any], fallback: String) throws {
        let errno = json.optInt("errno")
        guard errno != 0 else { return }
        let message = json.optString("err_msg").isEmpty
            ? (json.optString("show_msg").isEmpty ? fallback : json.optString("show_msg"))
            : json.optString("err_msg")
        switch errno {
        case -12: throw ResolveError.wrongPassword
        case 403: throw ResolveError.api("分享已失效（errno=403）")
        case 31066: throw ResolveError.api("文件不存在（errno=31066）")
        default: throw ResolveError.api("\(message)（errno=\(errno)）")
        }
    }
}
