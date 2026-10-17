//
//  YunXApp.swift
//  云析 YunX iOS —— 应用入口
//
//  对应上游 MainActivity.kt + YunXApp.kt。上游是单 Activity + Compose，
//  iOS 是 App + SwiftUI 窗口；初始化顺序与上游保持一致：
//  设置 → 下载管理器（读回未完成任务）→ 界面。
//
//  与桌面移植版的对应关系（tidain/YunX-Desktop 的 Main.kt）：
//  桌面版在 main() 里做的系统集成（托盘、通知中心进度、阻止休眠）在 iOS 上
//  都有对应物，但首版只做最必要的部分，避免一上来就引入大量平台代码。
//

import SwiftUI

@main
struct YunXApp: App {

    @StateObject private var settings = SettingsStore.shared
    @StateObject private var downloads = DownloadManager.shared

    init() {
        // 初始化顺序有依赖，不能调换：
        // 1. 先让 DownloadManager 单例就绪（它的 init 会读回未完成任务）
        // 2. 再让 SettingsStore 就绪 —— 它的 didSet 会引用 DownloadManager.shared，
        //    若顺序反了会在单例构造期间触发递归初始化。
        let downloads = DownloadManager.shared
        let store = SettingsStore.shared
        // 把设置单向推送进下载管理器（唯一真相在 SettingsStore）
        downloads.maxConnections = store.maxConnections
        downloads.globalSpeedLimitKBps = store.speedLimitKBps
        // 恢复上次未完成的任务。
        // 从 DownloadManager.init() 挪到这里：init 必须是 nonisolated 的
        // （@StateObject = .shared 的要求），而恢复任务要碰 @MainActor 的 DownloadTask。
        downloads.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            // 用 PlatformDispatchingResolver 而不是写死某一家：
            // 用户粘夸克链接就走夸克实现，粘迅雷链接就走迅雷实现。
            RootView(resolver: PlatformDispatchingResolver())
                .environmentObject(settings)
                .environmentObject(downloads)
                .preferredColorScheme(settings.preferredColorScheme)
        }
    }
}
