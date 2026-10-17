//
//  RootView.swift
//  云析 YunX iOS —— 根视图：解析 / 下载 / 设置 三个标签页 + 全局外观设置
//
//  依赖注入：
//  「解析」页需要一个 `ShareResolving` 实现。本文件不写死任何具体解析器
//  （平台实现由 Network 层 / `ResolverFactory` 提供），由 App 入口通过
//  `init(resolver:)` 注入。
//
//  外观：`SettingsStore.darkMode`（0 跟随系统 / 1 浅色 / 2 深色）在这里统一
//  转成 `.preferredColorScheme`，各页面只管自己的内容。
//  `SettingsStore` 自带 `preferredColorScheme` 计算属性，直接复用，
//  避免「设置页里改完外观、根视图不刷新」这类不一致。
//

import SwiftUI
import Foundation

struct RootView: View {

    /// 当前选中的标签
    @State private var selection: Tab = .resolve

    /// 设置页的观察对象（RootView 用它读取外观偏好）
    @StateObject private var settings = SettingsStore.shared

    /// 分享解析器，由 App 入口注入。
    ///
    /// 按平台切换解析器可以用 `ResolverFactory.make(for:)`：
    /// ```swift
    /// RootView(resolver: ResolverFactory.make(for: .quark))
    /// ```
    /// 若希望「粘什么链接就用什么解析器」，把 `ResolverFactory.make(for:)`
    /// 包一层按 `ParsedShare.platform` 分派的实现即可 —— 那属于业务层，本文件不掺和。
    private let resolver: ShareResolving

    /// 标签定义
    enum Tab: Hashable {
        case resolve, downloads, settings
    }

    init(resolver: ShareResolving) {
        self.resolver = resolver
    }

    var body: some View {
        TabView(selection: $selection) {
            ResolveScreen(resolver: resolver)
                .tabItem {
                    Label("解析", systemImage: "link.badge.plus")
                }
                .tag(Tab.resolve)

            DownloadsScreen()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tag(Tab.downloads)

            SettingsScreen()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        // SettingsStore 已经提供 preferredColorScheme（0/nil、1/.light、2/.dark）
        .preferredColorScheme(settings.preferredColorScheme)
    }
}
