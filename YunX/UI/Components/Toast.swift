//
//  Toast.swift
//  云析 YunX iOS —— 通用界面组件：轻提示（Toast）与状态徽标 / 进度徽标
//
//  设计要点：
//  1. 纯 SwiftUI，iOS 16.0+，无第三方依赖；不使用 UIKit；
//  2. Toast 用「顶部浮层 + 自动消失」实现，不拦截用户操作
//     （`allowsHitTesting(false)`），也不影响导航栏与列表滚动；
//  3. 生命周期收敛在 `ToastHost` 里，业务页面只需准备一个
//     `Binding<String?>`（nil = 不显示），调用 `.toast(message:)` 即可；
//  4. 同一个 `message` 非 nil 期间只计时一次（靠 task id 判重），
//     避免 View 重绘把倒计时不断重置、导致 Toast 永不消失。
//
//  ⚠️ 依赖：本文件底部有一个只用 `#if DEBUG` 包起来的预览占位类型
//  `_ToastPreviewFixtures`。当 DownloadTask / DownloadState 这些业务类型
//  还没有进入编译目标时，它会被一起编译并报错 —— 那时删掉这个 `#if DEBUG`
//  整块即可，正式代码不依赖它。
//

import SwiftUI

// MARK: - Toast

/// 轻提示的视觉与计时参数，集中一处方便统一调整。
enum ToastStyle {
    /// 停留时间（秒）
    static let duration: TimeInterval = 2.0
    /// 浮层到屏幕底部的距离
    static let bottomInset: CGFloat = 40
    /// 圆角
    static let cornerRadius: CGFloat = 14
}

/// Toast 的承载层：放在页面最外层，负责把「顶部浮层 + 自动消失」的
/// 行为套到任意内容上。
///
/// 计时放在 `.task(id:)` 里：id 只在 `message` 的值变化时改变，
/// 因此 View 因其它原因重绘不会重启计时。
struct ToastHost<Content: View>: View {
    @Binding var message: String?
    private let content: Content

    init(message: Binding<String?>, @ViewBuilder content: () -> Content) {
        _message = message
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .bottom) {
                if let text = message, !text.isEmpty {
                    ToastLabel(text: text)
                        .padding(.horizontal, 24)
                        .padding(.bottom, ToastStyle.bottomInset)
                        // 动画收在浮层自身，避免影响宿主内容布局
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                        )
                }
            }
            .task(id: message) {
                guard let text = message, !text.isEmpty else { return }
                // 允许一次性传入「多行提示」，按长度延长停留时间，读得完
                let extra = min(Double(text.count) * 0.04, 1.5)
                do {
                    try await Task.sleep(nanoseconds: UInt64((ToastStyle.duration + extra) * 1_000_000_000))
                } catch {
                    // 视图消失导致 task 被取消：这正是预期行为，不处理
                    return
                }
                withAnimation(.easeInOut(duration: 0.22)) {
                    message = nil
                }
            }
            .animation(.easeInOut(duration: 0.22), value: message)
            // 全屏浮层不许拦截点击/滚动，否则吐司停留期间页面会「卡住」
            .allowsHitTesting(false)
    }
}

/// Toast 本体外观。
struct ToastLabel: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ToastStyle.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        // 用固定上限 + 两侧留白代替 UIScreen.main.bounds：
        // 不依赖 UIKit，也自动适配 iPad 分屏与旋转
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// 给页面挂一个 Toast。
    ///
    /// 用法：
    /// ```swift
    /// @State private var toastMessage: String?
    /// …
    /// someView.toast(message: $toastMessage)
    /// ```
    /// 把 `toastMessage` 设为非 nil 即弹出，到时自动清空。
    func toast(message: Binding<String?>) -> some View {
        ToastHost(message: message) { self }
    }
}

// MARK: - 状态徽标

/// 下载状态徽标：把 `DownloadState` 渲染成带底色的小胶囊。
///
/// 颜色/文案的映射写在内部的 `style` 里，View 本身不接触枚举细节，
/// 因此调用方换状态源时只需要改那一处。
struct StateBadge: View {

    /// 展示用的状态种类。
    enum Kind {
        case queued, running, paused, completed, failed

        var title: String {
            switch self {
            case .queued: return "排队中"
            case .running: return "下载中"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            }
        }

        var tint: Color {
            switch self {
            case .queued: return .secondary
            case .running: return .blue
            case .paused: return .orange
            case .completed: return .green
            case .failed: return .red
            }
        }

        var symbolName: String {
            switch self {
            case .queued: return "clock"
            case .running: return "arrow.down.circle"
            case .paused: return "pause.circle"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// 从 `DownloadState` 构造。单独留一个初始化器，
    /// 让「徽标组件」与「下载领域类型」之间只通过 Kind 连接。
    init(state: DownloadState) {
        switch state {
        case .queued: self.kind = .queued
        case .running: self.kind = .running
        case .paused: self.kind = .paused
        case .completed: self.kind = .completed
        case .failed: self.kind = .failed
        }
    }

    private var title: String { kind.title }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(kind.tint.opacity(0.14))
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态：\(title)")
    }
}

// MARK: - 进度徽标

/// 进度徽标：环形进度 + 百分比数字，用在列表行尾或工具栏。
///
/// 已完成时只显示实心对勾；未完成时画环，尺寸够大才在环内叠百分比数字。
struct ProgressBadge: View {
    /// 0...1，超出范围会被夹紧。
    let progress: Double
    var size: CGFloat = 26
    var lineWidth: CGFloat = 3
    /// 是否显示百分比数字（尺寸很小时可关掉，只留环）
    var showsPercent: Bool = true

    private var clamped: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    private var isComplete: Bool { clamped >= 0.999 }

    private var percentText: String {
        "\(Int((clamped * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.82, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(
                            colors: [Color.accentColor.opacity(0.65), Color.accentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    // 从 12 点方向开始画
                    .rotationEffect(.degrees(-90))

                if showsPercent && size >= 24 {
                    Text(percentText)
                        .font(.system(size: max(7, size * 0.30), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度")
        .accessibilityValue(percentText)
    }
}

// MARK: - 空态占位

/// 统一风格的列表空态，供解析页与下载页复用。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - 预览（可选，缺业务类型时可整块删除）

#if DEBUG
/// 预览不依赖 DownloadManager / SettingsStore，只用本文件内的组件造数据。
///
/// 注意：当 `DownloadState` 等业务类型尚未进入编译目标时，
/// `StateBadge(state:)` 与 `#Preview` 会一起编译失败，删除本 `#if DEBUG` 块即可。
#Preview("Toast / 徽标") {
    PreviewContainer()
}

private struct PreviewContainer: View {
    @State private var message: String? = "已加入下载队列：示例文件.zip"
    @State private var progress: Double = 0.42

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                ProgressBadge(progress: progress)
                ProgressBadge(progress: 1)
                ProgressBadge(progress: 0.05, size: 20, showsPercent: false)
            }
            Slider(value: $progress, in: 0...1)

            Button("弹一个提示") {
                message = "已加入下载队列"
            }
        }
        .padding()
        .toast(message: $message)
    }
}
#endif
