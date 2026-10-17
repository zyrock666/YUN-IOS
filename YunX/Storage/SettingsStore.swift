//
//  SettingsStore.swift
//  云析 YunX iOS —— 应用设置
//
//  对应上游 data/prefs/*.kt。上游用 SharedPreferences，iOS 用 UserDefaults。
//  凭据类（Cookie / 迅雷 accessToken）**不进这里**，走 KeychainStore。
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {

    /// 单例。`nonisolated(unsafe)` 的理由同 DownloadManager.shared：
    /// SwiftUI 的 `@StateObject = .shared` 属性初始化器不在 main actor 上。
    nonisolated(unsafe) static let shared = SettingsStore()

    private enum Key {
        static let maxConnections = "settings.maxConnections"
        static let speedLimitKBps = "settings.speedLimitKBps"
        static let darkMode = "settings.darkMode"
        static let useMirror = "settings.useMirror"
        static let lastShareText = "settings.lastShareText"
    }

    /// 分片并发数。上限 32 与上游「实验性功能硬上限」一致。
    @Published var maxConnections: Int {
        didSet {
            defaults.set(maxConnections, forKey: Key.maxConnections)
            DownloadManager.shared.maxConnections = maxConnections
        }
    }

    /// 全局限速，0 = 不限
    @Published var speedLimitKBps: Int {
        didSet {
            defaults.set(speedLimitKBps, forKey: Key.speedLimitKBps)
            DownloadManager.shared.globalSpeedLimitKBps = speedLimitKBps
        }
    }

    /// 0 跟随系统 / 1 浅色 / 2 深色
    @Published var darkMode: Int {
        didSet { defaults.set(darkMode, forKey: Key.darkMode) }
    }

    /// GitHub 镜像加速（iOS 首版尚未实现 GitHub 平台，保留开关以便后续对齐）
    @Published var useMirror: Bool {
        didSet { defaults.set(useMirror, forKey: Key.useMirror) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let conn = defaults.object(forKey: Key.maxConnections) as? Int
        let limit = defaults.object(forKey: Key.speedLimitKBps) as? Int
        let mode = defaults.object(forKey: Key.darkMode) as? Int

        self.maxConnections = conn ?? 8
        self.speedLimitKBps = limit ?? 0
        self.darkMode = mode ?? 0
        self.useMirror = defaults.bool(forKey: Key.useMirror)
    }

    /// 对应到 SwiftUI 的配色方案。沿用上游「深色模式 + 自定义种子色」的语义，
    /// 但 iOS 27 前 SwiftUI 不支持全局种子色，所以只做明暗切换。
    var preferredColorScheme: ColorScheme? {
        switch darkMode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
