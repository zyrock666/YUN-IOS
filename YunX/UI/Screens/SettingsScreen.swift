//
//  SettingsScreen.swift
//  云析 YunX iOS —— 「设置」页：并发/限速/外观/镜像 + 关于与免责声明
//
//  绑定方式：
//  `SettingsStore.shared` 是 `@MainActor` 单例，其属性是 `@Published`。
//  这里用 `@StateObject` 观察 store，并实现一个 `@MainActor` 的 `Binding` 工厂
//  （body 在 MainActor 上执行，构造 Binding 合法；get/set 闭包也都是
//  同步访问 MainActor 状态，因此不需要 `await`）。
//
//  iOS 16 兼容：用 `Picker(.segmented)` 代替 `Picker(.palette)`（后者 iOS 17+）。
//

import SwiftUI
import Foundation

struct SettingsScreen: View {

    @StateObject private var store = SettingsStore.shared

    /// 轻提示
    @State private var toastMessage: String?

    /// 从 Info.plist 读版本号与构建号（SettingsStore 已提供同功能属性，这里复用）
    private var versionText: String {
        store.versionText
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                downloadSection
                networkSection
                appearanceSection
                aboutSection
                disclaimerSection
            }
            .navigationTitle("设置")
        }
        .toast(message: $toastMessage)
    }

    // MARK: - 账号

    /// 账号凭据导入入口。
    ///
    /// iOS 版没有内嵌浏览器登录，各平台凭据必须手动导入（理由见 PORTING.md 第 3 节）。
    /// 这里只放一个入口，具体编辑放在独立的 AccountsScreen 里 ——
    /// 11 个平台如果全铺在设置页会把这一页撑得没法看。
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountsScreen()
            } label: {
                Label("账号与凭据", systemImage: "person.badge.key")
            }
        } footer: {
            Text("导入各网盘 Cookie / Token。百度与 115 必须登录才能下载。")
        }
    }

    // MARK: - 下载

    private var downloadSection: some View {
        Section {
            Stepper(value: intBinding(\.maxConnections), in: 1...32) {
                HStack {
                    Text("分片并发数")
                    Spacer()
                    Text("\(store.maxConnections)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // 注意：无需在这里同步 DownloadManager —— SettingsStore 的
            // maxConnections / speedLimitKBps 的 didSet 已经负责写 UserDefaults
            // 并同步给 DownloadManager，UI 只管绑定。

            Stepper(value: speedLimitBinding, in: 0...1_048_576, step: 256) {
                HStack {
                    Text("下载限速")
                    Spacer()
                    Text(speedLimitText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("下载")
        } footer: {
            Text("并发数越大下载越快，但可能更容易触发网盘风控；建议 4～16。限速 0 表示不限速，按 256 KB/s 步进。")
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        Section {
            Toggle(isOn: boolBinding(\.useMirror)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub 镜像加速")
                    Text("通过镜像站访问资源，网络不通时再打开")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("网络")
        } footer: {
            Text("镜像由第三方提供，可用性与数据安全不由本应用保证，请自行判断是否开启。")
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section {
            Picker(selection: intBinding(\.darkMode)) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            } label: {
                Label("外观", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("外观")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本") {
                Text(versionText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("协议") {
                Text("AGPL-3.0")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("上游项目") {
                Text("CYQawa/YunX")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本应用是开源项目 CYQawa/YunX 的 iOS 移植版，依据 GNU Affero 通用公共许可证第 3 版（AGPL-3.0）发布：你可以自由使用、修改和再分发，但分发时必须同样以 AGPL-3.0 开放源代码，并通过网络提供服务时须向用户提供对应源代码。本应用不含任何广告和付费功能。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 免责声明

    private var disclaimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                disclaimerParagraph("1. 本应用仅供个人学习、研究与技术交流使用，不得用于任何商业用途。")
                disclaimerParagraph("2. 本应用本身不存储、不缓存、不分发任何版权内容，也不提供任何资源。所有文件均来自第三方网盘，由用户自行提供分享链接，文件内容与本应用无关。")
                disclaimerParagraph("3. 请于下载完成后 24 小时内删除相关文件，并遵守所在地区的法律法规以及各网盘平台的服务条款。请勿下载传播盗版、违法或侵权内容。")
                disclaimerParagraph("4. 本应用使用非官方的第三方接口访问网盘。使用此类工具可能违反平台用户协议，导致网盘账号被限速、风控甚至封禁，由此产生的一切后果由用户自行承担。")
                disclaimerParagraph("5. 因使用本应用造成的任何数据丢失、账号异常或法律责任，开发者不承担任何责任。若你不同意以上条款，请立即停止使用并卸载本应用。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } header: {
            Text("免责声明")
        } footer: {
            Text("继续使用即表示你已阅读并同意以上全部条款。")
        }
    }

    private func disclaimerParagraph(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 绑定与换算

    /// Int → 限速文案："不限速" 或 "1.5 MB/s"
    private var speedLimitText: String {
        let kbps = store.speedLimitKBps
        guard kbps > 0 else { return "不限速" }
        if kbps >= 1024 {
            let mb = Double(kbps) / 1024.0
            // 去掉多余的 .0，显示成 "2 MB/s" 而不是 "2.0 MB/s"
            if mb == mb.rounded() {
                return "\(Int(mb)) MB/s"
            }
            return String(format: "%.1f MB/s", mb)
        }
        return "\(kbps) KB/s"
    }

    /// 限速绑定：单位为 KB/s，0 表示不限，步进 256。
    private var speedLimitBinding: Binding<Int> {
        Binding(
            get: { store.speedLimitKBps },
            set: { newValue in
                // 夹紧到合法区间，并吸附到 256 的整数倍
                let clamped = min(max(newValue, 0), 1_048_576)
                store.speedLimitKBps = clamped == 0 ? 0 : (clamped / 256) * 256
            }
        )
    }

    /// 生成一个读写 `@Published` Int 属性的 Binding。
    ///
    /// 用 KeyPath 是为了避免为每个设置手写一份 get/set；
    /// `store` 是 `@StateObject` 持有的 ObservableObject，赋值会触发 `objectWillChange`。
    @MainActor
    private func intBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Int>) -> Binding<Int> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { store[keyPath: keyPath] = $0 }
        )
    }

    /// 生成一个读写 `@Published` Bool 属性的 Binding。
    @MainActor
    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { store[keyPath: keyPath] = $0 }
        )
    }
}
