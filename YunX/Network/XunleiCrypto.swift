//
//  XunleiCrypto.swift
//  云析 YunX iOS —— 迅雷设备指纹与请求签名
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）：
//  - data/network/XunleiDeviceFingerprint.kt（设备指纹生成与持久化）
//  - data/network/XunleiApi.kt 中的 buildCaptchaSign / md5Hex
//  - data/network/XunleiConstants.kt 中的盐表与常量
//
//  两套签名：
//  1. devicesign  = "div101." + deviceId + md5(sha1(deviceId + package + appid + appKey))
//     —— 登录请求体里带，标识「一台设备」。
//  2. captcha_sign = "1." + 10 层 md5 迭代
//     raw = clientId + clientVersion + packageName + deviceId + timestampMs
//     每轮 h = md5(h + salt)，10 个 salt 来自 alist 源码，已实测可通过活体验证。
//
//  上游源码注释里写清了为什么要动态生成指纹：开源分发后所有用户共享同一个
//  官方抓包指纹，会被迅雷风控识别并连带封禁。iOS 版沿用同样策略，
//  指纹存在 Keychain 里（比 Android SharedPreferences 更难被备份带走）。
//  常量中的官方值仅作为 Keychain 读写异常时的兜底。
//

import Foundation
import CryptoKit
import Security

enum XunleiCrypto {

    // MARK: - 常量（与上游 XunleiConstants 逐字一致，禁止随意改动）

    static let clientId = "Xp6pAdwyJv9sQuoN"
    static let clientSecret = "standard_a@api#"
    static let appClientId = "Xp6vsxz_7IYVw2BB"
    static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    static let appClientVersion = "8.31.0.9726"
    static let appPackageName = "com.xunlei.downloadprovider"

    /// devicesign 计算常量（文档 §8 / alist 一致）
    private static let appId = "40"
    private static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"

    /// Android 端 captcha 盐（10 个，alist 源码确认）
    static let captchaSalts = [
        "9uJNVj/wLmdwKrJaVj/omlQ",
        "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
        "Eb+L7Ce+Ej48u",
        "jKY0",
        "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
        "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
        "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
        "5IiCoM9B1/788ntB",
        "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
        "+oK0AN"
    ]

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    /// 兜底指纹（上游抓包值）
    private static let fallbackDeviceId = "78a70629a2b17d0b4302317ffa94807a"
    private static let fallbackPeerId = "92df4c42e0926ff55f1c605ebe4c3754"
    private static let fallbackDeviceSign = "div101.78a70629a2b17d0b4302317ffa94807a31491e163e795b39e798ed33ae58858b"

    // MARK: - 摘要

    static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ input: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// devicesign：`div101.{deviceId}{md5(sha1(deviceId + package + appid + appKey))}`
    static func buildDeviceSign(deviceId: String) -> String {
        let base = deviceId + appPackageName + appId + appKey
        let hashed = md5Hex(sha1Hex(base))
        return "div101.\(deviceId)\(hashed)"
    }

    /// captcha_sign：`1.` + 10 层 md5(raw + salt)
    static func buildCaptchaSign(deviceId: String, timestampMs: String) -> String {
        var h = appClientId + appClientVersion + appPackageName + deviceId + timestampMs
        for salt in captchaSalts {
            h = md5Hex(h + salt)
        }
        return "1.\(h)"
    }

    // MARK: - 设备指纹（持久化）

    /// 一台设备的身份三元组。
    struct Identity: Sendable {
        var deviceId: String
        var peerId: String
        var deviceSign: String
    }

    private static let lock = NSLock()
    private static var cached: Identity?

    /// 取本机设备指纹；首次调用时生成并写入 Keychain。
    ///
    /// - Note: 幂等，进程内只算一次。Keychain 读写失败时回退到官方抓包值，
    ///   保证请求不会因为缺字段而崩（与上游 `runCatching` 的兜底语义一致）。
    static func identity() -> Identity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let store = KeychainStore.shared
        if let savedId = store.string(forKey: "xunlei.deviceId"),
           let savedPeer = store.string(forKey: "xunlei.peerId"),
           let savedSign = store.string(forKey: "xunlei.deviceSign") {
            let identity = Identity(deviceId: savedId, peerId: savedPeer, deviceSign: savedSign)
            cached = identity
            return identity
        }

        // 首次启动：生成 32 位随机 hex（与上游 randomHex(32) 一致）
        let newId = randomHex(32)
        let newPeer = randomHex(32)
        let newSign = buildDeviceSign(deviceId: newId)

        // 写失败不阻断流程：本次会话用内存值，下次启动再试
        store.set(newId, forKey: "xunlei.deviceId")
        store.set(newPeer, forKey: "xunlei.peerId")
        store.set(newSign, forKey: "xunlei.deviceSign")

        let identity = Identity(deviceId: newId, peerId: newPeer, deviceSign: newSign)
        cached = identity
        return identity
    }

    static func fallbackIdentity() -> Identity {
        Identity(deviceId: fallbackDeviceId, peerId: fallbackPeerId, deviceSign: fallbackDeviceSign)
    }

    private static func randomHex(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        // SecRandomCopyBytes 由 Security 框架提供，在 KeychainStore 里已 import
        for i in 0..<length {
            bytes[i] = UInt8(SecureRandom.byte())
        }
        return bytes.map { String(format: "%x", $0) }.joined()
    }
}

/// 系统安全随机数的最小封装，避免在多处重复 `SecRandomCopyBytes` 的返回值判断。
enum SecureRandom {
    static func byte() -> UInt8 {
        var value: UInt8 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, 1, &value)
        if status != errSecSuccess {
            return UInt8.random(in: 0...255)
        }
        return value
    }
}
