//
//  GuangYaResolver.swift
//  云析 YunX iOS —— 光鸭云盘分享解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/network/GuangYaApi.kt + GuangYaConstants.kt。
//  只移植「分享 → 列目录 → 取直链」三段（文档 §4）：登录/注册/短信、个人盘 CRUD、
//  创建分享、转存轮询都没进来（iOS 首版不做写操作，见 PORTING.md §3）。
//
//  ## 本平台的关键坑
//
//  1. **业务 API 必带 `did` 设备头**（文档 §1.3）：分享接口即便匿名也要带，否则服务端
//     直接拒。上游的做法是「登录设备优先 → 上层注入 → 匿名兜底设备」，iOS 版生成一个
//     进程级随机 32 位 hex 设备 id 兜底（`GuangYaConstants.newDeviceId`）。
//  2. **`traceparent` 每次请求都要重新生成**（W3C 格式 `00-<32hex>-<16hex>-01`），
//     复用同一个值会被判异常。上游注释明确写了「每次请求重新生成」。
//  3. **业务成功判定不是 HTTP 码**：`isSuccess` = `success != false` 且 `error` 为空
//     且 `code` 为空或 "0"。业务码 207 是「分享限制下载」的专用信号（分享者没开免登录下载），
//     必须在通用错误映射之前单独拦下来，否则会被误报成普通失败。
//  4. **列表字段名飘忽**：`list` / `items` / `files` / `records` / `content` 五种都出现过，
//     条目里的 id 也有 `fileId`/`file_id`/`id`/`resId`/`resourceId` 五种 —— 照抄上游的
//     兼容顺序，不要自己挑一个。
//  5. **目录判定看 `resType`**：`"2"`=目录、`"1"`=文件；缺字段时才回退到一堆布尔/字符串判断。
//     判断顺序错了会把空文件夹当成 0 字节文件。
//  6. **两套头别混用**：分享三段（§4）走的是**业务头**（`did` / `dt` / `traceparent`），
//     账号接口（§2）才用那一整套 `X-Client-*` / `X-Device-*` 公共头。上游把两者
//     分别封在 `businessRequest` 与 `accountRequest` 里；iOS 首版只实现前者，
//     后者的字段清单与两个易错点（`X-Device-Id`/`X-Device-Sign` 要 URL 编码、
//     deviceModel 已是编码形态）写在文件末的注释里，接账号能力时照抄。
//  7. **直链字段名至少有六个别名**：`signedURL` / `signedUrl` / `downloadUrl` /
//     `download_url` / `url` / `cdnUrl`，取第一个非空的。
//
//  ## 三段的调用顺序（照上游 `ShareResolveRepository`）
//  `get_share_summary`（取标题，失败不致命）→ `get_share_access_token`（换 stoken）
//  → `get_share_page_files_list`（列目录，`parentId` 空串 = 分享根）→
//  `get_share_download_url`（取直链，body 带 stoken）。
//

import Foundation

final class GuangYaResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    // MARK: - 常量（逐字对齐 GuangYaConstants.kt）

    enum Constants {
        static let clientId = "aMe-8VSlkrbQXpUR"

        static let apiBase = "https://api.guangyapan.com"
        static let accountBase = "https://account.guangyapan.com"
        static let webSite = "https://www.guangyapan.com"

        /// 下载直链必须携带的 Referer（文档 §5.6/§7.1）
        static let downloadReferer = "\(webSite)/"

        static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        // ---------- 账号 API 公共头（文档 §1.3） ----------
        static let clientVersion = "0.0.1"
        static let sdkVersion = "9.1.3"
        static let protocolVersion = "301"
        /// 注意：这个值在上游源码里本身就是 URL 编码后的形态（`chrome%2F131.0.0.0`），
        /// 直接当 header 值发出去，不要再二次编码。
        static let deviceModel = "chrome%2F131.0.0.0"
        static let deviceName = "PC-Chrome"
        static let osVersion = "Win32"
        static let platformVersion = "1"

        // ---------- 端点（文档 §3 业务接口总表） ----------
        static let authToken = "\(accountBase)/v1/auth/token"
        static let userMe = "\(accountBase)/v1/user/me"
        static let signin = "\(accountBase)/v1/auth/signin"

        static let getAssets = "\(apiBase)/assets/v1/get_assets"
        static let shareSummary = "\(apiBase)/userres/v1/get_share_summary"
        static let shareAccessToken = "\(apiBase)/userres/v1/get_share_access_token"
        static let shareFiles = "\(apiBase)/userres/v1/get_share_page_files_list"
        static let shareDownload = "\(apiBase)/userres/v1/get_share_download_url"
        static let restoreShare = "\(apiBase)/userres/v1/restore_share"

        /// 分享根目录 id（空串 —— 不是 "0"，这点与蓝奏/115 都不同）
        static let rootParentId = ""

        /// 分享页大小（文档 §4.3/§5.1）
        static let pageSize = 100

        /// 生成 32 位十六进制设备 id
        static func newDeviceId() -> String {
            let alphabet = Array("0123456789abcdef")
            var out = ""
            out.reserveCapacity(32)
            for _ in 0..<32 {
                out.append(alphabet[Int.random(in: 0..<16)])
            }
            return out
        }

        /// 生成 traceparent（文档 §1.3：每次请求重新生成）—— `00-<32hex>-<16hex>-01`
        static func newTraceparent() -> String {
            let alphabet = Array("0123456789abcdef")
            func hex(_ count: Int) -> String {
                var out = ""
                out.reserveCapacity(count)
                for _ in 0..<count {
                    out.append(alphabet[Int.random(in: 0..<16)])
                }
                return out
            }
            return "00-\(hex(32))-\(hex(16))-01"
        }

        /// `X-Device-Id`：取 deviceSign 中第一个 "." 之后的 32 个字符；不足回退 deviceId（文档 §1.4）
        static func deviceIdFromSign(_ deviceSign: String, fallback: String) -> String {
            guard let index = deviceSign.firstIndex(of: ".") else { return fallback }
            let rest = String(deviceSign[deviceSign.index(after: index)...])
            if rest.count >= 32 {
                return String(rest.prefix(32))
            }
            return fallback
        }

        /// 形如 `wdi10.<32位十六进制><32位十六进制>` 的设备签名
        static func newDeviceSign(deviceId: String) -> String {
            let alphabet = Array("0123456789abcdef")
            var tail = ""
            tail.reserveCapacity(32)
            for _ in 0..<32 {
                tail.append(alphabet[Int.random(in: 0..<16)])
            }
            return "wdi10.\(deviceId)\(tail)"
        }
    }

    // MARK: - 状态

    private let client = HTTPClient.shared

    /// 账号 access token（可选；分享三段的 stoken 与它无关，只有 §4.5 转存才需要）。
    /// iOS 版不内嵌登录，由用户在设置页粘贴导入。
    private var accessToken: String = ""

    /// 业务 API 的 `did` 设备头（未登录时的匿名兜底设备，文档 §1.3）
    private let publicDeviceId = Constants.newDeviceId()

    private let lock = NSLock()

    /// 光鸭用的是账号 access token（不是 Cookie），`accessToken:` 是主入口，
    /// 与 `ResolverFactory` 的调用形态一致。
    init(accessToken: String = "") {
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 与其它平台构造器形态对齐的别名（内部仍按 token 处理）。
    init(cookie: String) {
        self.init(accessToken: cookie)
    }

    /// 注入/更新账号 access token。
    func updateCookie(_ newToken: String) {
        lock.lock(); defer { lock.unlock() }
        accessToken = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同 `updateCookie`，语义更清楚的名字（设置页用这个）。
    func updateToken(_ newToken: String) {
        updateCookie(newToken)
    }

    /// 是否已导入账号令牌。
    ///
    /// 注意：**没有它也能解析公开分享** —— 光鸭的分享三段（summary / access_token /
    /// page_files / download_url）全部走匿名通道，token 只影响「受限分享需登录转存」那类场景。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return !accessToken.isEmpty
    }

    // MARK: - ShareResolving

    /// 换访问凭证。
    ///
    /// 上游没有「解析前先取 token」这一步：`get_share_access_token` 同时承担了
    /// 「校验提取码」与「换 stoken」两个职责（code 209 = 提取码错误/缺失）。
    /// 所以这里按上游顺序：先取摘要标题（失败不致命），再换令牌。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let title = await fetchShareSummary(shareId: share.shareId) ?? ""
        let stoken = try await fetchAccessToken(shareId: share.shareId, code: share.pwd ?? "")
        return ShareToken(
            stoken: stoken,
            title: title,
            // 上游不返回 first_fid，列目录时才拿得到；这里留空（UI 只用于跳转）
            firstFid: ""
        )
    }

    /// 列目录。`pdirFid` 为空串或 "0" 都视为分享根。
    ///
    /// 上游是游标分页（`cursor` + `hasMore`），`ShareResolving` 给的是页码，这里做换算：
    /// 每页 100 条，page=1 不带 cursor，page>1 时按「前 (page-1) 页的游标链」顺序取。
    /// 之所以不能简单地把 page 当 cursor 用：cursor 是服务端给的不透明串。
    /// 若调用方只需要首屏，page=1 就已足够（这也是上游 UI 的实际用法）。
    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        let parentId = (pdirFid.isEmpty || pdirFid == "0") ? Constants.rootParentId : pdirFid

        let target = max(1, page)
        // 逐页跟游标：page=1 时就是一次请求，与上游 UI 的实际用法一致
        var cursor: String? = nil
        var current = 1
        while current < target {
            let result = try await fetchShareFiles(
                accessToken: stoken,
                parentId: parentId,
                cursor: cursor
            )
            guard let next = result.nextCursor else {
                // 提前结束：越界翻页返回空列表（与「该目录没有更多条目」语义一致）
                return []
            }
            cursor = next
            current += 1
        }
        let last = try await fetchShareFiles(
            accessToken: stoken,
            parentId: parentId,
            cursor: cursor
        )
        return last.files
    }

    /// 取下载直链（文档 §4.4）。
    ///
    /// body 里 `accessToken` 是**分享访问令牌**（stoken），不是账号 token —— 上游注释特意点了这句。
    /// 业务码 207 表示「分享者未开启免登录下载」，需要登录后转存，iOS 版按
    /// `ResolveError.api` 透出可读文案（不做转存写操作）。
    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        let json = try await businessJSON(
            url: Constants.shareDownload,
            body: [
                "fileId": file.fid,
                "accessToken": stoken
            ]
        )

        // 207 必须在通用错误映射之前拦：它是「受限」而不是「失败」
        if json.optString("code") == "207" {
            throw ResolveError.api("该光鸭分享需登录并转存后下载，请先登录光鸭云盘")
        }

        try checkBusiness(json, fallback: "获取下载地址失败")

        guard let data = dataOf(json) else {
            throw ResolveError.api("光鸭未返回下载数据")
        }
        let url = firstNonBlank(
            data.optString("signedURL"),
            data.optString("signedUrl"),
            data.optString("downloadUrl"),
            data.optString("download_url"),
            data.optString("url"),
            data.optString("cdnUrl")
        )
        if url.isEmpty {
            throw ResolveError.api("光鸭未返回有效下载地址，请确认下载权限")
        }
        let size = Int64(data.optString("size")) ?? file.fsize
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: url,
            size: size,
            // 光鸭直链是签名 URL，不需要游客 Cookie（只要 Referer/UA）
            guestCookie: ""
        )
    }

    /// 下载请求所需的额外头：光鸭 CDN 校验 Referer 与 Origin（文档 §7.1）。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Constants.webUA,
            "Referer": Constants.downloadReferer
        ]
        if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
        }
        return headers
    }

    // MARK: - 分享三段

    /// 分享摘要标题（文档 §4.1）。失败返回 nil —— 上游包在 runCatching 里，标题不是必需项。
    private func fetchShareSummary(shareId: String) async -> String? {
        guard let json = try? await businessJSON(
            url: Constants.shareSummary,
            body: ["shareId": shareId]
        ) else { return nil }
        // 摘要失败不该阻止后续换令牌：这里只吞掉错误
        guard (try? checkBusiness(json, fallback: "获取分享信息失败")) != nil else { return nil }
        let data = dataOf(json) ?? json
        let title = firstNonBlank(data.optString("title"), data.optString("shareName"))
        return title.isEmpty ? nil : title
    }

    /// 用提取码换分享访问令牌（文档 §4.2）。code 209 = 提取码错误。
    private func fetchAccessToken(shareId: String, code: String) async throws -> String {
        let json = try await businessJSON(
            url: Constants.shareAccessToken,
            body: [
                "shareId": shareId,
                // 上游：`code.ifBlank { "" }` —— 不需要提取码时传空串，不能省字段
                "code": code
            ]
        )
        try checkBusiness(json, fallback: "获取分享访问令牌失败")

        guard let data = dataOf(json) else {
            throw ResolveError.api("光鸭分享链接无效")
        }
        let token = firstNonBlank(data.optString("accessToken"), data.optString("access_token"))
        if token.isEmpty {
            throw ResolveError.api("光鸭分享链接无效")
        }
        return token
    }

    private struct ShareFilesPage {
        var files: [ShareFile]
        var nextCursor: String?
    }

    /// 分享列目录（文档 §4.3）。
    private func fetchShareFiles(accessToken: String, parentId: String, cursor: String?) async throws -> ShareFilesPage {
        var body: [String: Any] = [
            "parentId": parentId,
            "pageSize": Constants.pageSize,
            "orderBy": 0,
            "sortType": 0,
            "accessToken": accessToken
        ]
        if let cursor, !cursor.isEmpty {
            body["cursor"] = cursor
        }

        let json = try await businessJSON(url: Constants.shareFiles, body: body)
        try checkBusiness(json, fallback: "获取分享文件列表失败")

        guard let data = dataOf(json) else {
            return ShareFilesPage(files: [], nextCursor: nil)
        }
        let files = parseFileList(listArray(data))
        let hasMore = data.optBool("hasMore")
        let next = data.optString("cursor")
        // 上游：hasMore 且 cursor 非空才有下一页；hasMore=false 一律视为结束
        let effectiveNext: String? = hasMore ? (next.isEmpty ? nil : next) : nil
        return ShareFilesPage(files: files, nextCursor: effectiveNext)
    }

    // MARK: - 请求

    /// 业务 API 请求（文档 §1.3：`did` / `dt` / `traceparent`，分享接口不带 Authorization）。
    private func businessJSON(url: String, body: [String: Any]?, token: String? = nil) async throws -> [String: Any] {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "User-Agent": Constants.webUA,
            "Origin": Constants.webSite,
            "Referer": Constants.downloadReferer,
            "dt": "4",
            "traceparent": Constants.newTraceparent()
        ]
        // did 为业务 API 必需设备头：登录设备优先，其次匿名兜底设备
        if !publicDeviceId.isEmpty { headers["did"] = publicDeviceId }
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: body ?? [:])
        ))
        if data.isEmpty {
            throw ResolveError.network("请求失败：响应为空（HTTP \(http.statusCode)）")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）")
        }
        return json
    }

    // 关于账号 API 的公共头（文档 §1.3）：
    //
    // 上游 `accountRequest` 会带一整套 `X-Client-Id` / `X-Client-Version` /
    // `X-Device-Id` / `X-Device-Model` / `X-Device-Name` / `X-Device-Sign` /
    // `X-Os-Version` / `X-Platform-Version` / `X-Protocol-Version` / `X-Sdk-Version`，
    // 其中两个易错点记在这里（接账号能力时务必照抄）：
    // 1. `X-Device-Id` 与 `X-Device-Sign` 必须 **URL 编码** 后再放进 header
    //    （参考实现 wenxi guangya_login.dart）；`Constants.deviceModel` 本身已经是
    //    URL 编码形态（`chrome%2F131.0.0.0`），不要再编码第二次。
    // 2. `X-Device-Id` 取 `deviceSign` 里第一个 "." 之后的 32 个字符
    //    （`Constants.deviceIdFromSign`），不是整串 sign。
    //
    // 本文件的分享三段（§4）走的是**业务**头（did / dt / traceparent），不带这套账号头 ——
    // 见 `businessJSON`。账号头只在登录/取 token/取用户信息时出现，iOS 首版不实现。

    // MARK: - 响应解析

    /// 列出阵列字段：光鸭不同接口/版本用 list / items / files / records / content 等多种命名。
    ///
    /// 上游用 `?:` 链「取第一个存在的数组」；`HTTPClient.optArray` 对不存在的 key 也返回 []，
    /// 所以这里显式判断「key 存在且是数组」，语义与上游一致（存在但为空 = 空列表，不再往后找）。
    private func listArray(_ data: [String: Any]) -> [[String: Any]] {
        for key in ["list", "items", "files", "records", "content"] {
            if data[key] is [Any] {
                return data.optArray(key)
            }
        }
        return []
    }

    private func parseFileList(_ items: [[String: Any]]) -> [ShareFile] {
        items.compactMap { parseFile($0) }
    }

    /// 条目 → 统一 ShareFile（逐字段对齐上游 `parseFile`）。
    private func parseFile(_ item: [String: Any]) -> ShareFile {
        let fid = firstNonBlank(
            item.optString("fileId"),
            item.optString("file_id"),
            item.optString("id"),
            item.optString("resId"),
            item.optString("resourceId")
        )
        let name = firstNonBlank(
            item.optString("fileName"),
            item.optString("name"),
            item.optString("filename"),
            item.optString("dirName"),
            item.optString("title")
        )
        let size = Int64(firstNonBlank(
            item.optString("fileSize"),
            item.optString("size"),
            item.optString("file_size")
        )) ?? 0

        let resType = item.optString("resType")
        let dirType = item.optString("dirType")
        let isDir: Bool
        switch resType {
        case "2":
            isDir = true
        case "1":
            isDir = false
        default:
            let typeText = item.optString("type").lowercased()
            let fileTypeText = item.optString("fileType").lowercased()
            let folderTypes: Set<String> = ["folder", "dir", "directory", "0"]
            isDir = item.optBool("isDir")
                || item.optBool("isdir")
                || item.optBool("dir")
                || item.optBool("isFolder")
                || item.optBool("folder")
                || !item.optString("dirName").isEmpty
                || folderTypes.contains(typeText)
                || folderTypes.contains(fileTypeText)
                || (!name.contains(".") && dirType == "1")
        }

        let parent = firstNonBlank(
            item.optString("parentId"),
            item.optString("parentFileId"),
            item.optString("parent_id")
        )
        let time = firstNonBlank(
            item.optString("updatedAt"),
            item.optString("updateAt"),
            item.optString("updated_at"),
            item.optString("updateTime"),
            item.optString("mtime"),
            item.optString("utime"),
            item.optString("createdAt"),
            item.optString("createTime"),
            item.optString("ctime")
        )

        return ShareFile(
            fid: fid,
            fname: name,
            fsize: isDir ? 0 : size,
            isdir: isDir,
            pdirFid: parent,
            // 光鸭取直链只用 fileId + 分享 stoken，没有单独的文件令牌
            fidToken: "",
            modifyTime: time
        )
    }

    /// 业务成功判定：`success != false` 且 `error` 为空 且 `code` 为空或 "0"。
    private func isSuccess(_ json: [String: Any]) -> Bool {
        if json["success"] != nil && !json.optBool("success") { return false }
        if !json.optString("error").isEmpty { return false }
        let code = json.optString("code")
        return code.isEmpty || code == "0"
    }

    /// 业务错误码 → 用户可读文案（文档 §10）。
    ///
    /// 注意 209 既可能是「提取码错误」也可能是「提取码缺失」—— 上游合并成一句。
    /// 这里进一步细分：分享本身声明需要提取码而我们没带，抛 `needPassword`；
    /// 带了还是 209，才是 `wrongPassword`。这个细分是 iOS 侧为「可交互的提取码输入」
    /// 做的增强 —— 上游 Android 是一次性把用户输入的码带上去，界面层没有这个分支需求。
    private func checkBusiness(_ json: [String: Any], fallback: String) throws {
        if isSuccess(json) { return }

        let code = json.optString("code")
        let serverMsg = firstNonBlank(
            json.optString("msg"),
            json.optString("message"),
            json.optString("error_description")
        )

        switch code {
        case "209":
            throw ResolveError.wrongPassword
        case "200", "201", "202":
            throw ResolveError.api("光鸭分享已取消、过期或不可访问")
        case "205", "206", "207", "504":
            throw ResolveError.api("光鸭分享下载受限，请在官网确认该分享的下载权限")
        case "157":
            throw ResolveError.api("光鸭网盘空间不足")
        default:
            throw ResolveError.api(serverMsg.isEmpty ? "\(fallback)（code=\(code)）" : serverMsg)
        }
    }

    /// 业务数据的 data 节点（文档各成功响应两种形态都出现过：包在 data 下，或直接位于顶层）
    private func dataOf(_ json: [String: Any]) -> [String: Any]? {
        json.optObject("data")
    }

    /// 取第一个非空值并去空白（对齐上游 `firstNonBlank`）
    private func firstNonBlank(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
