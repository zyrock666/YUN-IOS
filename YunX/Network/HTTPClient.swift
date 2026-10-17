//
//  HTTPClient.swift
//  云析 YunX iOS —— HTTP 基础设施
//
//  对应上游 data/network/HttpClients.kt + 各 Api 文件里的 postJson / parseData 辅助函数。
//  上游用 OkHttp，iOS 用 URLSession。
//
//  关键移植点（来自上游 HttpClients.buildDownload 的实测结论）：
//  - 下载客户端**强制 HTTP/1.1**：OkHttp 的 HTTP/2 客户端对外声明每流 16MB 接收窗口，
//    消费端一慢（写盘慢/限速挂起），几十路分片叠加会把堆撑爆。这一点在 iOS 上同样成立，
//    而且 URLSession 的 httpMaximumConnectionsPerHost 也需要配合分片数调大。
//  - 空闲连接池收紧、连接/读取超时分离：api 用短超时，下载用长读超时。
//

import Foundation

/// 统一封装的轻量 HTTP 客户端。
///
/// 只做三件事：发请求、把网络层错误统一成 `ResolveError.network`、按上游约定解析 JSON。
/// 不做重试与并发控制 —— 那是 `ChunkDownloader` 的职责。
final class HTTPClient: @unchecked Sendable {

    static let shared = HTTPClient()

    /// API 请求用（短超时、连接池偏小）
    private let apiSession: URLSession
    /// 下载分片用（长读超时、连接数按分片数放宽）
    private let downloadSession: URLSession

    private init() {
        let apiConfig = URLSessionConfiguration.ephemeral
        apiConfig.timeoutIntervalForRequest = 15
        apiConfig.timeoutIntervalForResource = 60
        apiConfig.httpMaximumConnectionsPerHost = 8
        apiConfig.httpShouldUsePipelining = false
        // 禁用 URL 缓存：网盘接口全是短时凭证，缓存只会拿到过期数据
        apiConfig.urlCache = nil
        apiConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        apiSession = URLSession(configuration: apiConfig)

        let downloadConfig = URLSessionConfiguration.ephemeral
        downloadConfig.timeoutIntervalForRequest = 60
        // 大文件下载可能持续很久，资源超时给足（分片内部还有自己的续传与重试）
        downloadConfig.timeoutIntervalForResource = 3600
        downloadConfig.httpMaximumConnectionsPerHost = 32
        downloadConfig.httpShouldUsePipelining = false
        downloadConfig.urlCache = nil
        downloadConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        downloadSession = URLSession(configuration: downloadConfig)
    }

    // MARK: - 请求构造

    /// 一次请求的描述。用结构体而不是闭包，方便分片下载复用同一份配置。
    struct Request {
        var url: String
        var method: String = "GET"
        var headers: [String: String] = [:]
        var body: Data?
        var timeout: TimeInterval?
    }

    /// 发送请求，返回原始数据与 HTTP 响应。
    func send(_ request: Request, useDownloadSession: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: request.url) else {
            throw ResolveError.network("链接格式不合法：\(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let session = useDownloadSession ? downloadSession : apiSession
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ResolveError.network("响应不是 HTTP 响应")
            }
            return (data, http)
        } catch let error as URLError {
            // 用户主动取消要原样透传，不能被当成网络故障重试
            if error.code == .cancelled { throw ResolveError.cancelled }
            throw ResolveError.network(error.localizedDescription)
        } catch let error as ResolveError {
            throw error
        } catch {
            throw ResolveError.network(error.localizedDescription)
        }
    }

    /// 发送 JSON 请求并解析响应体。
    func sendJSON(_ request: Request) async throws -> [String: Any] {
        let (data, http) = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 上游同样在这里防的是「风控 HTML 页 / 错误页」：把状态码带出来才分得清 401/403
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? ""
            throw ResolveError.network("响应解析失败（HTTP \(http.statusCode)）\(preview.isEmpty ? "" : "：\(preview)")")
        }
        return json
    }
}

// MARK: - JSON 取值辅助

/// 对应上游 Kotlin 里满屏的 `json.optString / optInt / optJSONObject`。
/// 网盘接口字段类型飘忽（有时是数字有时是字符串），这里统一做容错转换。
extension Dictionary where Key == String, Value == Any {

    func optString(_ key: String) -> String {
        switch self[key] {
        case let str as String: return str
        case let num as NSNumber: return num.stringValue
        case .none: return ""
        default: return ""
        }
    }

    func optInt(_ key: String) -> Int {
        switch self[key] {
        case let num as NSNumber: return num.intValue
        case let str as String: return Int(str) ?? 0
        default: return 0
        }
    }

    /// Kotlin 的 optLong。网盘的文件大小经常以「字符串形式的整数」返回，
    /// 超过 2^53 时用 Double 会丢精度，所以字符串走 Int64(str) 而不是先转 Double。
    func optInt64(_ key: String) -> Int64 {
        switch self[key] {
        case let str as String: return Int64(str) ?? 0
        case let num as NSNumber: return num.int64Value
        default: return 0
        }
    }

    func optBool(_ key: String) -> Bool {
        switch self[key] {
        case let flag as Bool: return flag
        case let num as NSNumber: return num.boolValue
        case let str as String: return str == "true" || str == "1"
        default: return false
        }
    }

    func optObject(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func optArray(_ key: String) -> [[String: Any]] {
        guard let array = self[key] as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}

// MARK: - URL 编码

enum URLCodec {
    /// 对应 Kotlin 的 URLEncoder.encode(s, "UTF-8")。
    /// 注意：Kotlin 的 URLEncoder 把空格编成 `+`，而 `addingPercentEncoding` 编成 `%20`。
    /// 这里保持 `+` 以对齐上游行为 —— 迅雷的 pass_code_token 是 base64 风格，
    /// 里面会出现 `+` `/` `=`，编码方式不一致会直接导致 401。
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    /// 查询参数编码：空格编成 %20（用在 URL 的 query 里，与 formEncode 区分）
    static func queryEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
