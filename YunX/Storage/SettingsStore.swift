//
//  SettingsStore.swift
//  云析 YunX iOS —— 应用设置
//
//  对应上游 data/prefs/*.kt。上游用 SharedPreferences，iOS 用 UserDefaults。
//  凭据类（Cookie / 迅雷 accessToken）**不进这里**，走 KeychainStore。
//
//  ## 为什么这个类**不**标 @MainActor
//
//  最初写成 `@MainActor final class SettingsStore`，结果陷入死结：
//  - SwiftUI 的 `@StateObject private var s = SettingsStore.shared` 在**属性初始化器**
//    里求值，那不是 main actor 上下文 → `shared` 必须 `nonisolated(unsafe)`；
//  - 而 `nonisolated(unsafe) static let shared = SettingsStore()` 又要调 `init()`，
//    → `init()` 也得 `nonisolated`；
//  - 但 `nonisolated init()` 里给 `@Published` 属性赋值是**非法**的
//    （「main actor-isolated property can not be mutated from a non-isolated context」）。
//
//  三者无法同时成立。而 `SettingsStore` 只被界面读写（天然在主线程），
//  没有任何跨线程访问，**根本不需要 actor 隔离**。去掉 `@MainActor` 后
//  单例、init、@Published 全部回到普通 ObservableObject 语义，问题消失。
//
//  唯一的跨 actor 调用是 `didSet` 里把配置推给 `@MainActor` 的 DownloadManager，
//  那里显式跳一次 main actor（见下）。
//

import Foundation
import Combine
import SwiftUI

final class SettingsStore: ObservableObject {

    /// 单例。不需要 `nonisolated(unsafe)` —— 本类没有 actor 隔离。
    static let shared = SettingsStore()

    private enum Key {
        static let maxConnections = "settings.maxConnections"
        static let speedLimitKBps = "settings.speedLimitKBps"
        static let darkMode = "settings.darkMode"
        static let useMirror = "settings.useMirror"
        static let lastShareText = "settings.lastShareText"
    }

    /// 分片并发数。上限 32 与上游「实验性功能硬上限」一致。
    ///
    /// `didSet` 里把值推给 `DownloadManager`（`@MainActor` 类），
    /// 必须 `Task { @MainActor in ... }` 跳一次线程。
    @Published var maxConnections: Int {
        didSet {
            defaults.set(maxConnections, forKey: Key.maxConnections)
            let value = maxConnections
            Task { @MainActor in
                DownloadManager.shared.maxConnections = value
            }
        }
    }

    /// 全局限速，0 = 不限
    @Published var speedLimitKBps: Int {
        didSet {
            defaults.set(speedLimitKBps, forKey: Key.speedLimitKBps)
            let value = speedLimitKBps
            Task { @MainActor in
                DownloadManager.shared.globalSpeedLimitKBps = value
            }
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
