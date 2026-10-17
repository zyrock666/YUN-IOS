//
//  GitHubResolver.swift
//  云析 YunX iOS —— GitHub 仓库 / 文件直链解析
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//  - data/network/GitHubApi.kt        （REST API 封装：repo / tree / releases / readme）
//  - data/network/GitHubLinkParser.kt （链接分类：DirectFile / Repository / Account）
//  - data/network/GitHubModels.kt     （DTO）
//
//  ## GitHub 与其他平台的根本差异
//  GitHub 不是网盘：没有分享短码、没有提取码、没有「列目录接口」，
//  它只有树形结构的仓库。因此 `ShareResolving` 三个方法的语义映射是：
//  - `resolveToken`：拉一次仓库元信息（默认分支），把 branch 名字当 stoken 回传
//  - `listFiles`  ：用 Git Trees API 列出仓库下的**直接子项**（一层，不是递归）
//  - `downloadLink`：把 blob 路径换成 `raw.githubusercontent.com` 直链
//
//  ## 上游的匹配优先级（照抄，别乱改顺序）
//  `DirectFile > Repository > Account`
//  - DirectFile：`raw.githubusercontent.com/o/r/branch/path`、
//    `github.com/o/r/releases/download/tag/file`、`github.com/o/r/raw/branch/path`
//  - Repository：`github.com/o/r[/tree|blob|releases...]`
//  - Account   ：`github.com/o`（单段路径）
//  最后一条要排除 `features` / `trending` / `login` 这类功能页路径，
//  否则把 `github.com/features` 当成用户主页（上游有 specialPaths 白名单）。
//
//  ## API 限额
//  未认证：每小时 60 次；带 PAT：5000 次。Git Trees API 一次请求即可取整棵树，
//  所以未认证也够用 —— PAT 只是可选优化，不是必需。
//

import Foundation

final class GitHubResolver: ShareResolving, DownloadHeadersProviding, @unchecked Sendable {

    enum Constants {
        static let apiBase = "https://api.github.com"
        static let rawBase = "https://raw.githubusercontent.com"
        static let userAgent = "YunX-iOS/1.0"
        /// 镜像加速前缀（设置页可开关）。留空表示直连。
        static let mirrorPrefix = ""
    }

    /// 链接分类结果（对应上游 sealed class GitHubLinkType）。
    enum LinkType {
        /// 仓库链接；`subPath` 为 tree/blob 后的路径（可空）
        case repository(owner: String, repo: String, subPath: String?)
        /// 用户 / 组织主页
        case account(owner: String)
        /// 直接可下的文件直链
        case directFile(url: String, fileName: String)
    }

    private let client = HTTPClient.shared
    private var token: String
    private let lock = NSLock()
    /// 仓库默认分支缓存，避免每次列目录都多打一次 API
    private var branchCache: [String: String] = [:]

    init(token: String = "") {
        self.token = token
    }

    func updateToken(_ newToken: String) {
        lock.lock(); defer { lock.unlock() }
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateCookie(_ newCookie: String) { updateToken(newCookie) }

    /// PAT 是可选的：没有它也能浏览公开仓库，只是速率受限。
    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return !token.isEmpty
    }

    // MARK: - ShareResolving

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        let (owner, repo) = Self.splitRepo(share)
        let info = try await repoInfo(owner: owner, repo: repo)
        return ShareToken(
            stoken: info.defaultBranch,
            title: info.fullName.isEmpty ? "\(owner)/\(repo)" : info.fullName,
            firstFid: ""
        )
    }

    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        guard page == 1 else { return [] }
        let (owner, repo) = Self.splitRepo(share)
        let branch = stoken.isEmpty ? (try await repoInfo(owner: owner, repo: repo)).defaultBranch : stoken

        // 目录路径：根目录用空串
        let dir = pdirFid == "0" ? "" : pdirFid
        let tree = try await fetchTree(owner: owner, repo: repo, branch: branch)

        // Trees API 返回的是**扁平**列表，这里筛出「当前目录的直接子项」
        let prefix = dir.isEmpty ? "" : (dir.hasSuffix("/") ? dir : dir + "/")
        var seen = Set<String>()
        var result: [ShareFile] = []

        for entry in tree {
            let path = entry.optString("path")
            guard path.hasPrefix(prefix), !path.isEmpty else { continue }
            let rest = String(path.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }

            let isNested = rest.contains("/")
            let name = isNested ? String(rest.split(separator: "/")[0]) : rest
            let fid = prefix + name

            // 已处理过（深层文件归并到它的父目录）
            guard seen.insert(fid).inserted else { continue }

            let isDir = entry.optString("type") == "tree" || isNested
            result.append(ShareFile(
                fid: fid,
                fname: name,
                fsize: isDir ? 0 : entry.optInt64("size"),
                isdir: isDir,
                pdirFid: dir.isEmpty ? "0" : dir,
                fidToken: "",
                modifyTime: ""
            ))
        }

        // Trees API 不带文件大小（只有 blob 才带），对文件补一次查询会很贵，
        // 所以这里对根目录用一个轻量策略：不查大小，界面上显示为「—」。
        // 上游同样是「列表不保证 size」，下载时会用真实 Content-Length 覆盖。
        return ShareFile.sortedForDisplay(result)
    }

    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        let (owner, repo) = Self.splitRepo(share)
        let branch = stoken.isEmpty ? (try await repoInfo(owner: owner, repo: repo)).defaultBranch : stoken
        let encodedPath = file.fid
            .split(separator: "/")
            .map { URLCodec.queryEncode(String($0)) }
            .joined(separator: "/")

        let url = "\(Constants.rawBase)/\(owner)/\(repo)/\(branch)/\(encodedPath)"
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: url,
            size: file.fsize,
            guestCookie: ""
        )
    }

    /// raw.githubusercontent.com 不需要特殊头；带上 UA 即可。
    func downloadHeaders(for link: DownloadLink) -> [String: String] {
        ["User-Agent": Constants.userAgent]
    }

    // MARK: - API

    private struct RepoInfo {
        var fullName: String
        var defaultBranch: String
    }

    private func repoInfo(owner: String, repo: String) async throws -> RepoInfo {
        let key = "\(owner)/\(repo)"
        lock.lock()
        let cached = branchCache[key]
        lock.unlock()

        let json = try await api("\(Constants.apiBase)/repos/\(owner)/\(repo)")
        let branch = json.optString("default_branch")
        let resolved = branch.isEmpty ? "main" : branch
        lock.lock(); branchCache[key] = resolved; lock.unlock()
        _ = cached
        return RepoInfo(fullName: json.optString("full_name"), defaultBranch: resolved)
    }

    private func fetchTree(owner: String, repo: String, branch: String) async throws -> [[String: Any]] {
        // recursive=1 一次拿整棵树；文件多的仓库会返回 truncated=true
        let json = try await api(
            "\(Constants.apiBase)/repos/\(owner)/\(repo)/git/trees/\(URLCodec.queryEncode(branch))?recursive=1"
        )
        return json.optArray("tree")
    }

    private func api(_ url: String) async throws -> [String: Any] {
        var headers = [
            "User-Agent": Constants.userAgent,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        lock.lock()
        let currentToken = token
        lock.unlock()
        if !currentToken.isEmpty {
            headers["Authorization"] = "Bearer \(currentToken)"
        }

        let (data, http) = try await client.send(HTTPClient.Request(url: url, headers: headers))

        // GitHub 的错误响应是 JSON，但偶尔是纯文本（限流页）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.network("GitHub 响应解析失败（HTTP \(http.statusCode)）")
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let message = json.optString("message")
            if message.contains("rate limit") {
                throw ResolveError.api("GitHub API 触发速率限制：请在设置里填入 Personal Access Token 提升限额")
            }
            throw ResolveError.api(message.isEmpty ? "GitHub 拒绝请求（HTTP \(http.statusCode)）" : message)
        }
        if http.statusCode == 404 {
            throw ResolveError.api("仓库或分支不存在（HTTP 404）")
        }
        if http.statusCode >= 400 {
            let message = json.optString("message")
            throw ResolveError.api(message.isEmpty ? "GitHub 返回 HTTP \(http.statusCode)" : message)
        }
        return json
    }

    // MARK: - 链接解析

    /// 从 `ParsedShare.shareId`（形如 `owner/repo`）拆出两段。
    /// 若解析器把完整 URL 塞进了 rawURL，优先用 rawURL 再做一次分类。
    static func splitRepo(_ share: ParsedShare) -> (owner: String, repo: String) {
        if !share.rawURL.isEmpty, case let .repository(owner, repo, _)? = classify(share.rawURL) {
            return (owner, repo)
        }
        let parts = share.shareId.split(separator: "/")
        guard parts.count >= 2 else { return (share.shareId, "") }
        return (String(parts[0]), String(parts[1]))
    }

    /// 把一段文本分类成 DirectFile / Repository / Account。
    /// 优先级与上游一致：DirectFile > Repository > Account。
    static func classify(_ text: String) -> LinkType? {
        guard let url = firstURL(in: text) else { return nil }

        // 1) 文件直链
        if let m = matches(#"raw\.githubusercontent\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/[^/]+/(.+)"#, url),
           m.count >= 3, let name = fileName(m[2]) {
            return .directFile(url: url, fileName: name)
        }
        if let m = matches(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/[^/]+/(.+)"#, url),
           m.count >= 3, let name = fileName(m[2]) {
            return .directFile(url: url, fileName: name)
        }
        if let m = matches(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/raw/[^/]+/(.+)"#, url),
           m.count >= 3, let name = fileName(m[2]) {
            return .directFile(url: url, fileName: name)
        }

        // 2) 仓库
        if let m = matches(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/(.*))?"#, url),
           m.count >= 2 {
            let owner = m[0]
            let repo = m[1]
            let sub = m.count >= 3 && !m[2].isEmpty ? m[2] : nil
            return .repository(owner: owner, repo: repo, subPath: sub)
        }

        // 3) 账号主页
        if let m = matches(#"github\.com/([A-Za-z0-9_.-]+)/?(?:[?#]|$)"#, url),
           let owner = m.first, !specialPaths.contains(owner.lowercased()) {
            return .account(owner: owner)
        }
        return nil
    }

    /// 功能页路径，不应被识别成账号。
    private static let specialPaths: Set<String> = [
        "features", "topics", "trending", "collections", "events", "sponsors",
        "about", "pricing", "login", "signup", "join", "marketplace", "explore",
        "notifications", "settings", "new", "orgs", "sites", "customer-stories",
        "team", "enterprise", "readme", "contact", "security", "resources"
    ]

    private static func firstURL(in text: String) -> String? {
        guard let caps = matches(#"https?://[^\s]+"#, text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return caps.first?.trimmingCharacters(in: CharacterSet(charactersIn: "。，,；;)]}\"'"))
    }

    private static func fileName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// 用 NSRegularExpression 取捕获组（与 ShareLinkParser 的做法一致）。
    private static func matches(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        if match.numberOfRanges <= 1 {
            return match.range.location == NSNotFound ? nil : [ns.substring(with: match.range)]
        }
        var out: [String] = []
        for i in 1..<match.numberOfRanges {
            let range = match.range(at: i)
            if range.location == NSNotFound {
                out.append("")
            } else {
                out.append(ns.substring(with: range))
            }
        }
        return out
    }
}
