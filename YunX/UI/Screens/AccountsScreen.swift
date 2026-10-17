//
//  AccountsScreen.swift
//  云析 YunX iOS —— 账号凭据导入
//
//  为什么需要这个页面：iOS 版没有内嵌浏览器登录（见 PORTING.md 第 3 节），
//  各平台凭据由用户自行导出后粘贴导入。上游 Android 版是在 WebView 里登录
//  后自动提取 Cookie，桌面版用 JCEF 内嵌 Chromium —— 两者在 iOS 上都不可行
//  （WKWebView 的 Cookie 与 HTTPCookieStorage 存在域隔离，且各网盘对非官方
//  UA 有风控策略）。
//
//  所以这里把「每个平台需要导入什么」讲清楚，比只给一个输入框有用得多。
//

import SwiftUI
// UIPasteboard 来自 UIKit —— SwiftUI 没有等价的剪贴板 API。
// 这是本文件唯一用到 UIKit 的地方（「从剪贴板粘贴」按钮）。
import UIKit

struct AccountsScreen: View {

    @ObservedObject private var settings = SettingsStore.shared

    /// 正在编辑的平台（nil 表示没弹编辑框）
    @State private var editingPlatform: SharePlatform?
    @State private var inputText: String = ""
    /// 各平台是否已配置。读 Keychain，进入页面时刷新一次，保存后也刷新。
    @State private var configured: [SharePlatform: Bool] = [:]
    @State private var toastMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(SharePlatform.allCases, id: \.self) { platform in
                    Button {
                        editingPlatform = platform
                        inputText = ResolverFactory.savedCredential(for: platform)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: platform))
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.displayName)
                                    .foregroundStyle(.primary)
                                Text(platform.credentialHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if platform.requiresLogin && !(configured[platform] ?? false) {
                                // 该平台必须登录才能下载，未配置时给红色提醒
                                Text("必需")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                            if configured[platform] ?? false {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("账号")
            } footer: {
                Text("标「必需」的平台没有免登录取链通道，不配置就下载不了。其余平台可以游客态解析，但单文件大小和并发数会受限。")
            }

            Section {
                Button(role: .destructive) {
                    KeychainStore.shared.removeAll()
                    refreshConfigured()
                    toastMessage = "已清除全部凭据"
                } label: {
                    Text("清除全部凭据")
                }
            } footer: {
                Text("凭据保存在系统 Keychain，仅本机可读、不随备份迁移。")
            }

            Section {
                ForEach(howToRows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0)
                            .font(.subheadline.weight(.medium))
                        Text(row.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("怎么拿到凭据")
            } footer: {
                Text("导出 Cookie 需要用第三方抓包工具或浏览器扩展。本应用不提供、也不引导任何绕过平台登录的自动化流程。")
            }
        }
        .navigationTitle("账号")
        .toast(message: $toastMessage)
        .onAppear(perform: refreshConfigured)
        .sheet(item: $editingPlatform) { platform in
            editor(for: platform)
        }
    }

    // MARK: - 编辑弹窗

    private func editor(for platform: SharePlatform) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $inputText)
                        .frame(minHeight: 120)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("\(platform.displayName) 的\(platform.credentialHint)")
                } footer: {
                    Text(hint(for: platform))
                }

                Section {
                    Button {
                        if let clip = UIPasteboard.general.string {
                            inputText = clip
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    Button(role: .destructive) {
                        inputText = ""
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(platform.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingPlatform = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        ResolverFactory.saveCredential(inputText, for: platform)
                        refreshConfigured()
                        editingPlatform = nil
                        toastMessage = inputText.isEmpty ? "已清除 \(platform.displayName) 凭据"
                                                          : "已保存 \(platform.displayName) 凭据"
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - 数据

    private func refreshConfigured() {
        var map: [SharePlatform: Bool] = [:]
        for platform in SharePlatform.allCases {
            map[platform] = !ResolverFactory.savedCredential(for: platform).isEmpty
        }
        configured = map
    }

    private func icon(for platform: SharePlatform) -> String {
        switch platform {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .lanzou, .ilanzou: return "doc.zipper"
        default: return "externaldrive.connected.to.line.below"
        }
    }

    private func hint(for platform: SharePlatform) -> String {
        switch platform {
        case .xunlei:
            return "迅雷要的是 access_token（不是 Cookie）。登录迅雷网盘后从抓包工具里取 Authorization 头里 Bearer 后面那一段。不填也能用，但只能匿名解析、无法转存大文件。"
        case .github:
            return "可选。填了 Personal Access Token 会把 API 限额从每小时 60 次提到 5000 次。只需要读取公开仓库时留空即可。"
        case .baidu:
            return "百度必须登录：本应用按官方链路先转存到你的网盘再取直链，没有免登录通道。至少需要 BDUSS 字段。注意：频繁下载可能触发风控。"
        case .pan115:
            return "115 下载需要登录态 Cookie。可从浏览器开发者工具里复制完整 Cookie 字符串粘贴进来。"
        default:
            return "从浏览器登录对应网盘后，打开开发者工具，复制完整的 Cookie 请求头粘贴进来。需要保留全部字段，不要只复制某几项。"
        }
    }

    /// 「怎么拿到凭据」的通用说明。按平台特征分组，避免 11 条重复文案。
    private var howToRows: [(String, String)] {
        [
            ("浏览器开发者工具", "登录网盘网页版 → F12 → Network → 任选一个请求 → 复制 Request Headers 里的 Cookie 整行。"),
            ("曲奇类扩展", "也可以装一个 Cookie 导出扩展，一键复制当前域名下的全部 Cookie。"),
            ("迅雷 token", "迅雷网盘用的是 Authorization: Bearer <token> 里的 token，不是 Cookie。"),
            ("有效期", "多数网盘的会话 Cookie 几天到几个月不等。如果突然报「登录态已失效」，重新导一次即可。")
        ]
    }
}

// 让 SharePlatform 能直接给 .sheet(item:) 用
extension SharePlatform: Identifiable {
    public var id: String { rawValue }
}
