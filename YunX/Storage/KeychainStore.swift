//
//  KeychainStore.swift
//  云析 YunX iOS —— 凭据与设备指纹的安全存储
//
//  对应上游 data/security/{CredentialCipher,DbKeyStore}.kt 的职责。
//
//  上游在桌面版用「AES-GCM + 本地 credential.key 文件」，在 Android 版用 Keystore。
//  iOS 上直接用系统 Keychain 更合适：它是进程外的加密存储，受设备密码保护，
//  且能通过 kSecAttrAccessible 控制「设备解锁后可读」这种粒度 —— 不需要自己
//  再造一套密钥文件方案（那在 iOS 上反而是弱点，因为文件会和备份一起走）。
//

import Foundation
import Security

/// 极简 Keychain 封装（只做字符串读写，够用即可）。
///
/// 使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
/// - 首次解锁后即可读（后台续传下载时也能用）
/// - `ThisDeviceOnly` 保证不会随 iCloud/iTunes 备份迁移到其他设备
final class KeychainStore: @unchecked Sendable {

    static let shared = KeychainStore()

    private let service: String

    init(service: String = "com.yunx.ios.credentials") {
        self.service = service
    }

    // MARK: - 读

    func string(forKey key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 写

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // 先尝试更新，不存在再新增 —— 比「先删后加」少一次写放大
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var insert = query
        for (key, value) in attributes { insert[key] = value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - 删

    @discardableResult
    func remove(key: String) -> Bool {
        SecItemDelete(baseQuery(key: key) as CFDictionary) == errSecSuccess
    }

    /// 清空本 App 的全部凭据（设置页「退出全部账号」用）。
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 内部

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
