//
//  ShareModels.swift
//  云析 YunX iOS —— 分享解析领域模型
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）的
//  app/src/main/kotlin/com/yunx/app/data/network/model/ShareModels.kt
//  以及 ShareLinkParser.kt 中的 SharePlatform 枚举。
//
//  本文件只放纯数据结构，不含任何网络调用，便于单元测试与跨层复用。
//

import Foundation

/// 网盘平台。
///
/// 与上游 `SharePlatform` 的 11 个取值一一对应（quark / uc / xunlei / baidu /
/// c139 / pan123 / pan115 / guangya / ilanzou / lanzou / github）。
/// 顺序也与上游保持一致，便于对照排查。
enum SharePlatform: String, Codable, CaseIterable, Sendable {
    case quark
    case uc
    case xunlei
    case baidu
    case c139
    case pan123
    case pan115
    case guangya
    case ilanzou
    case lanzou
    case github

    /// 平台显示名（界面与错误提示共用）。
    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou: return "蓝奏云"
        case .github: return "GitHub"
        }
    }

    /// 该平台下载是否强制要求登录凭据。
    ///
    /// 百度没有免转存直链接口，必须先转存到个人网盘，所以必须有 BDUSS；
    /// 其余平台可以游客态取链（夸克有单文件约 50MB 限制）。
    /// 界面据此在解析前提示用户。
    var requiresLogin: Bool {
        switch self {
        // 百度/115：没有免登录取链通道
        // 123：列目录和取分享信息可以匿名，但 download/info 必须带 authorToken
        case .baidu, .pan115, .pan123: return true
        default: return false
        }
    }

    /// 凭据类型说明，用于设置页的导入提示。
    var credentialHint: String {
        switch self {
        case .pan123:
            return "authorToken"
        case .quark, .uc, .baidu, .c139, .pan115, .guangya, .ilanzou, .lanzou:
            return "Cookie"
        case .xunlei:
            return "access_token"
        case .github:
            return "Personal Access Token（可选，仅提升 API 限额）"
        }
    }
}

/// 分享链接解析结果：分享短码 + 提取码 + 平台。
struct ParsedShare: Codable, Sendable, Equatable {
    /// 分享短码。注意百度是去掉开头 "1" 的 surl，夸克/UC/迅雷是路径末段，
    /// 115 是 sw 开头的 11 位码，蓝奏云是路径末段（i 文件 / b 文件夹）。
    var shareId: String
    /// 提取码，可能为空（不需要提取码的分享）。
    var pwd: String?
    var platform: SharePlatform
    /// 原始链接。GitHub 等平台需要完整 URL 而不只是短码。
    var rawURL: String = ""

    /// 用于展示的一行摘要，例如「夸克网盘 · 3f2a9c」。
    var summary: String {
        "\(platform.displayName) · \(shareId)"
    }
}

/// 分享访问凭证（对应上游 `ShareToken`）。
struct ShareToken: Sendable, Equatable {
    /// 分享访问令牌，后续列目录/取直链都要带。
    /// 夸克叫 stoken，迅雷是 passCodeToken，百度是 sekey(randsk)，115 是 share_code 本身。
    var stoken: String
    /// 分享标题（通常是「xxx 分享的文件」）。
    var title: String
    /// 分享根目录下第一个文件的 fid（上游只用于跳转，iOS 版保留以对齐协议）。
    var firstFid: String
}

/// 分享内的文件/目录项。
///
/// 字段与上游 `ShareFile` 一一对应：
/// - `fid` 夸克是数字串，迅雷是文件 id，百度文件用 fs_id / 目录用 path
/// - `fidToken` 夸克为 `share_fid_token`，其余平台一般留空
struct ShareFile: Identifiable, Codable, Sendable, Hashable {
    var fid: String
    var fname: String
    /// 字节数。目录为 0 或未知。
    var fsize: Int64
    var isdir: Bool
    /// 父目录 fid，"0" 表示分享根目录。
    var pdirFid: String
    /// 夸克取直链时必须带上的分享文件令牌。
    var fidToken: String
    /// 修改时间，原样透传服务端字符串（各平台格式不一致，不做解析）。
    var modifyTime: String

    var id: String { fid }

    /// 人类可读大小，例如「1.2 MB」。目录不显示大小。
    var sizeText: String {
        guard !isdir else { return "文件夹" }
        return ByteCountFormatter.string(fromByteCount: fsize, countStyle: .file)
    }

    /// 排序用：目录优先，再按文件名。
    static func sortedForDisplay(_ files: [ShareFile]) -> [ShareFile] {
        files.sorted { lhs, rhs in
            if lhs.isdir != rhs.isdir { return lhs.isdir }
            return lhs.fname.localizedStandardCompare(rhs.fname) == .orderedAscending
        }
    }
}

/// 下载直链。
///
/// `guestCookie` 是上游踩过的坑：游客态取链时夸克/UC 会在 Set-Cookie 里下发
/// `__pugs`，直链的 CDN 校验绑定这份令牌 —— 缺了夸克返回 412、UC 返回 403。
/// 登录态取链时该字段为空串，此时下载要用账号 Cookie。
struct DownloadLink: Sendable, Equatable {
    var fid: String
    var filename: String
    var downloadUrl: String
    var size: Int64
    var guestCookie: String
}

/// 解析过程中的错误。
///
/// 上游用的是 `QuarkApiException(code: String)` 加一串 `when` 分支映射文案；
/// iOS 版改成带语义的枚举，让 UI 能区分「需要输入提取码」这类可交互的错误。
enum ResolveError: LocalizedError, Equatable {
    /// 底层网络失败（超时、DNS、TLS 等）。
    case network(String)
    /// 服务端返回了业务错误码。
    case api(String)
    /// 该分享需要提取码但没提供。
    case needPassword
    /// 提取码错误。
    case wrongPassword
    /// 平台未实现或链接不支持。
    case notSupported(String)
    /// 用户取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return detail.isEmpty ? "网络请求失败，请检查网络后重试" : "网络请求失败：\(detail)"
        case .api(let message):
            return message.isEmpty ? "服务端返回了未知错误" : message
        case .needPassword:
            return "该分享需要提取码，请补上后重试"
        case .wrongPassword:
            return "提取码错误"
        case .notSupported(let what):
            return what
        case .cancelled:
            return "已取消"
        }
    }
}
