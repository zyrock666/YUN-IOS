//
//  PlatformDispatchingResolver.swift
//  云析 YunX iOS —— 按平台分派的解析器
//
//  UI 层（RootView）只接受一个固定的 `ShareResolving`，但实际使用中用户可能
//  先粘夸克、再粘迅雷。这个类型把「按 `ParsedShare.platform` 挑实现」的逻辑
//  集中到一处，避免在视图里写 switch。
//
//  为什么要新建实例而不是复用：各解析器持有会话状态（夸克/UC 的 `__puus`
//  会话 Cookie、`__pugs` 游客令牌，迅雷的 captcha 令牌缓存），复用同一个实例
//  会串味。这里每次调用按平台新建，状态天然隔离。
//

import Foundation

/// 按分享平台把调用转发给对应的解析器实现。
struct PlatformDispatchingResolver: ShareResolving {

    /// 每次解析都从 `ResolverFactory` 取一个干净的实现。
    private func resolver(for share: ParsedShare) -> ShareResolving {
        ResolverFactory.make(for: share.platform)
    }

    func resolveToken(_ share: ParsedShare) async throws -> ShareToken {
        try await resolver(for: share).resolveToken(share)
    }

    func listFiles(
        playload share: ParsedShare,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [ShareFile] {
        try await resolver(for: share).listFiles(
            playload: share,
            stoken: stoken,
            pdirFid: pdirFid,
            page: page
        )
    }

    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink {
        try await resolver(for: share).downloadLink(for: file, share: share, stoken: stoken)
    }
}

/// 带下载请求头能力的解析器。
///
/// 夸克/UC 的直链是防盗链的：下载时必须带 Referer，登录态还要带账号 Cookie。
/// UI 层在 `enqueue` 时需要拿到这些头，但 `ShareResolving` 协议本身不暴露它们
/// （协议只描述「解析」，不描述「怎么下」）。所以这里用可选协议扩展：
/// 实现了就取头，没实现就用空头。
protocol DownloadHeadersProviding {
    func downloadHeaders(for link: DownloadLink) -> [String: String]
}

extension PlatformDispatchingResolver {

    /// 取某个下载链接所需请求头。解析器不支持时返回空字典（DownloadManager 会照常下）。
    func downloadHeaders(for link: DownloadLink, platform: SharePlatform) -> [String: String] {
        let impl = ResolverFactory.make(for: platform)
        if let provider = impl as? DownloadHeadersProviding {
            return provider.downloadHeaders(for: link)
        }
        return [:]
    }
}
