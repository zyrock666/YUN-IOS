//
//  ShareResolving.swift
//  云析 YunX iOS —— 网盘解析统一接口
//
//  对应上游 data/repository/ShareResolveRepository.kt 的公共接口。
//  上游用「{平台}{Resolve}Repository 成对存在」的组织方式；iOS 版把它收敛成
//  一个协议 + 各平台实现，UI 只依赖协议，方便以后换实现或加 Mock。
//

import Foundation

/// 网盘分享解析能力。
///
/// 三次调用构成完整链路：
/// 1. `resolveToken` —— 用分享短码 + 提取码换访问凭证
/// 2. `listFiles` —— 用凭证逐层列目录
/// 3. `downloadLink` —— 用文件 fid + 文件令牌换直链
///
/// 实现方需要自己处理 Cookie / token 的持有与刷新，接口层不关心。
protocol ShareResolving: Sendable {
    /// 换访问凭证。需要提取码却没给时应抛 `ResolveError.needPassword`。
    func resolveToken(_ share: ParsedShare) async throws -> ShareToken

    /// 列目录。`pdirFid` 传 "0" 表示分享根目录。`page` 从 1 开始。
    func listFiles(playload share: ParsedShare, stoken: String, pdirFid: String, page: Int) async throws -> [ShareFile]

    /// 取下载直链。
    func downloadLink(for file: ShareFile, share: ParsedShare, stoken: String) async throws -> DownloadLink
}

/// 根据平台挑解析器。
///
/// 上游在 ViewModel 里按平台分支 `when (platform) { QUARK -> ... }`；这里集中到
/// 一个工厂，避免同样的分支散落在多个界面。
///
/// 凭据来源：iOS 版没有内嵌浏览器登录，各平台凭据由用户在设置页粘贴导入，
/// 统一存 Keychain，key 形如 `cookie.quark` / `token.xunlei` / `token.github`。
enum ResolverFactory {

    /// Keychain 里存凭据用的键。与设置页的导入逻辑共用，改这里就够了。
    enum CredentialKey {
        static func forPlatform(_ platform: SharePlatform) -> String {
            switch platform {
            case .xunlei: return "token.xunlei"
            case .github: return "token.github"
            default: return "cookie.\(platform.rawValue)"
            }
        }
    }

    /// 读某个平台已保存的凭据（没有则空串）。
    static func savedCredential(for platform: SharePlatform) -> String {
        KeychainStore.shared.string(forKey: CredentialKey.forPlatform(platform)) ?? ""
    }

    /// 保存凭据到 Keychain。空串表示清除。
    @discardableResult
    static func saveCredential(_ value: String, for platform: SharePlatform) -> Bool {
        let key = CredentialKey.forPlatform(platform)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainStore.shared.remove(key: key)
        }
        return KeychainStore.shared.set(trimmed, forKey: key)
    }

    /// 按平台创建解析器实例。
    ///
    /// 每次新建而不是缓存：各解析器持有会话状态（`__puus` 会话 Cookie、
    /// `__pugs` 游客令牌、迅雷 captcha 令牌），复用会串味。
    static func make(for platform: SharePlatform) -> ShareResolving {
        switch platform {
        case .quark:
            return QuarkResolver(cookie: savedCredential(for: .quark))
        case .uc:
            return UCResolver(cookie: savedCredential(for: .uc))
        case .xunlei:
            return XunleiResolver(accessToken: savedCredential(for: .xunlei))
        case .baidu:
            return BaiduResolver(cookie: savedCredential(for: .baidu))
        case .c139:
            return C139Resolver(cookie: savedCredential(for: .c139))
        case .pan123:
            return Pan123Resolver(token: savedCredential(for: .pan123))
        case .pan115:
            return Pan115Resolver(cookie: savedCredential(for: .pan115))
        case .guangya:
            return GuangYaResolver(accessToken: savedCredential(for: .guangya))
        case .ilanzou:
            return ILanzouResolver(cookie: savedCredential(for: .ilanzou))
        case .lanzou:
            return LanzouResolver(cookie: savedCredential(for: .lanzou))
        case .github:
            return GitHubResolver(token: savedCredential(for: .github))
        }
    }
}
