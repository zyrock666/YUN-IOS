//
//  ResolveScreen.swift
//  云析 YunX iOS —— 「解析」页：粘贴分享文案 → 解析 → 浏览目录 → 取直链入队下载
//
//  本页只做界面与交互编排，真正的网络访问通过初始化器注入的
//  `ShareResolving` 完成（默认由 App 入口传入具体实现），
//  因此本文件不依赖任何具体的平台解析器（如 QuarkResolver）。
//
//  iOS 16 兼容要点：
//  1. `NavigationStack(path:)` + `navigationDestination(for:)` 维护目录栈，
//     path 元素直接用 `[ShareFile]`（`ShareFile` 是 Hashable 的），
//     根目录不入栈，返回手势天然可用；
//  2. 请求都在 `.task {}` / `Task {}` 里 `await`，不阻塞主线程；
//     Task 继承 View 的 MainActor 隔离，所以可以直接改 `@State`。
//

import SwiftUI
import Foundation
// 仅用于 UIPasteboard（SwiftUI 无等价的剪贴板 API），没有使用任何 UIKit 控件。
// iOS 之外的平台（预览/测试）由 `#if canImport(UIKit)` 兜住。
#if canImport(UIKit)
import UIKit
#endif

struct ResolveScreen: View {

    // MARK: - 注入依赖

    /// 分享解析器。由 App 入口注入，本页不知道具体是哪个平台实现。
    ///
    /// 注：`ShareResolving` 已声明为 `Sendable`，因此这里的不可变存储属性
    /// 交给 List/ForEach 闭包使用是合法的；`struct View` 的不可变存储属性
    /// 会被当作 `@MainActor`，调用其 `async` 方法会切换到全局执行器执行
    /// （协议要求 Sendable，跨线程安全）。
    private let resolver: ShareResolving

    init(resolver: ShareResolving) {
        self.resolver = resolver
    }

    // MARK: - 本地状态

    /// 用户粘贴的原始文本（可能是整段分享文案）
    @State private var inputText: String = ""
    /// 输入框是否获得焦点
    @FocusState private var isInputFocused: Bool

    /// 最近一次解析出的分享
    @State private var share: ParsedShare?
    /// 访问凭证
    @State private var token: ShareToken?

    /// 根目录文件
    @State private var rootFiles: [ShareFile] = []
    /// 根目录加载中
    @State private var isLoadingRoot = false
    /// 根目录错误
    @State private var rootErrorText: String?

    /// 目录栈：根目录之下的每一层都压在这里，最后一个是当前目录
    @State private var path: [ShareFile] = []

    /// 全局忙碌标记（解析分享 / 取直链）
    @State private var isBusy = false
    @State private var busyText = ""

    /// 错误弹窗
    @State private var alertMessage: String?
    /// 提示弹窗（成功/失败均走 Toast）
    @State private var toastMessage: String?

    /// 已点过「下载」的文件 fid，防止连点重复入队
    @State private var pendingDownloadFids: Set<String> = []

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let share, token != nil {
                    shareBrowser(share: share)
                } else {
                    pasteEntry
                }
            }
            .navigationTitle("解析")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if share != nil {
                        Button {
                            resetShare()
                        } label: {
                            Label("重新解析", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(isBusy)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { isInputFocused = false }
                }
            }
            .navigationDestination(for: ShareFile.self) { directory in
                DirectoryScreen(
                    directory: directory,
                    resolver: resolver,
                    share: share,
                    stoken: token?.stoken ?? "",
                    onEnqueued: { message in
                        toastMessage = message
                    },
                    onError: { message in
                        alertMessage = message
                    }
                )
            }
        }
        .toast(message: $toastMessage)
        .alert("出错了", isPresented: alertBinding) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "未知错误")
        }
    }

    // MARK: - 粘贴入口（未解析分享时）

    private var pasteEntry: some View {
        // 用 List + `.insetGrouped` 而不是 Form：
        // ① 外观与 shareBrowser 的 List 一致，切换时不闪；
        // ② Form 在 iOS 16 内部就是 ScrollView 包一层；当 NavigationStack 推入
        //    子页面时，嵌套滚动容器容易抢手势。顶层 List 更稳。
        List {
            Section {
                // TextField(axis: .vertical) 需要 iOS 16+，正好符合最低版本要求
                TextField(
                    "粘贴分享链接或整段分享文案",
                    text: $inputText,
                    axis: .vertical
                )
                .lineLimit(4...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($isInputFocused)
                .submitLabel(.done)
            } header: {
                Text("分享链接")
            } footer: {
                Text("支持夸克 / UC / 迅雷的分享链接。直接粘贴「【标题】 https://… 提取码：abcd」这样的整段文案也可以，提取码会自动识别。")
            }

            Section {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }

                Button {
                    resolveShare()
                } label: {
                    HStack {
                        Label("解析", systemImage: "wand.and.stars")
                        Spacer()
                        if isBusy {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBusy || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                if !busyText.isEmpty {
                    Text(busyText)
                }
            }

            Section("支持的平台") {
                HStack(spacing: 12) {
                    ForEach(SharePlatform.allCases, id: \.self) { platform in
                        Text(platform.displayName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.12))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 分享浏览（解析成功后）

    private func shareBrowser(share: ParsedShare) -> some View {
        List {
            if let token {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(token.title)
                            .font(.headline)
                            .lineLimit(3)
                        HStack(spacing: 8) {
                            Text(share.platform.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                            Text(share.shareId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            if let pwd = share.pwd, !pwd.isEmpty {
                                Text("提取码 \(pwd)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if isLoadingRoot {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取文件列表…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let rootErrorText {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(rootErrorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") { reloadRoot() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else if rootFiles.isEmpty {
                    Text("这个分享里没有文件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rootFiles) { file in
                        FileRow(
                            file: file,
                            isDownloading: pendingDownloadFids.contains(file.fid) || isBusy,
                            onTap: { enter(file) },
                            onDownload: { download(file, share: share) }
                        )
                    }
                }
            } header: {
                Text("文件")
            } footer: {
                if path.isEmpty && !rootFiles.isEmpty {
                    Text("点击文件夹可进入，右侧按钮下载文件。共 \(rootFiles.count) 项。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadRoot(share: share, token: token, force: true)
        }
    }

    // MARK: - 交互：输入与解析

    private func pasteFromClipboard() {
        // UIPasteboard 是「尽量不用 UIKit」唯一无法回避的例外：
        // SwiftUI 在 iOS 16 没有等价的读取剪贴板 API（iOS 17 才没有对应替代）。
        // 因此本文件在 iOS 下引入 UIKit —— 仅为这一个调用点，没有使用任何 UI 控件。
        // 读写剪贴板不需要额外权限；系统会在跨 App 粘贴时自行弹出「允许粘贴」确认。
        #if canImport(UIKit)
        if let clip = UIPasteboard.general.string, !clip.isEmpty {
            inputText = clip
            isInputFocused = false
            // 粘贴后直接尝试解析，省用户一次点击；失败也只是弹提示
            resolveShare()
        } else {
            alertMessage = "剪贴板里没有文本"
        }
        #else
        alertMessage = "当前平台不支持读取剪贴板"
        #endif
    }

    private func resolveShare() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isInputFocused = false

        guard let parsed = parseInput(text) else { return }

        isBusy = true
        busyText = "正在解析分享…"

        Task {
            defer {
                isBusy = false
                busyText = ""
            }
            do {
                let resolved = try await resolver.resolveToken(parsed)
                // 先落状态，再拉根目录（rootFiles 会触发下面 shareBrowser 的渲染）
                share = parsed
                token = resolved
                path.removeAll()
                await loadRoot(share: parsed, token: resolved, force: true)
            } catch {
                alertMessage = Self.describe(error)
            }
        }
    }

    /// 解析文本；返回 nil 时已经设置好弹窗文案。
    private func parseInput(_ text: String) -> ParsedShare? {
        do {
            guard let parsed = try ShareLinkParser.parse(text) else {
                alertMessage = "没有识别到可用的分享链接。\n请确认链接来自夸克、UC 或迅雷的分享页。"
                return nil
            }
            return parsed
        } catch {
            alertMessage = Self.describe(error)
            return nil
        }
    }

    // MARK: - 网络：根目录

    private func reloadRoot() {
        guard let share, let token else { return }
        Task { await loadRoot(share: share, token: token, force: true) }
    }

    /// 读取分享根目录（pdirFid 为 "0"）。
    private func loadRoot(share: ParsedShare, token: ShareToken?, force: Bool) async {
        guard let token else { return }
        if isLoadingRoot { return }
        if !force && !rootFiles.isEmpty { return }

        isLoadingRoot = true
        rootErrorText = nil
        defer { isLoadingRoot = false }

        do {
            let files = try await resolver.listFiles(
                playload: share,
                stoken: token.stoken,
                pdirFid: "0",
                page: 1
            )
            // 目录优先、按名称排序（模型层已提供排序工具）
            rootFiles = ShareFile.sortedForDisplay(files)
        } catch {
            rootFiles = []
            rootErrorText = Self.describe(error)
        }
    }

    // MARK: - 交互：目录与下载

    private func enter(_ file: ShareFile) {
        guard file.isdir else {
            // 点文件行 = 直接下载，和右侧按钮行为一致
            if let share { download(file, share: share) }
            return
        }
        path.append(file)
    }

    private func download(_ file: ShareFile, share: ParsedShare) {
        guard let token else { return }
        guard !file.isdir else { return }
        guard !pendingDownloadFids.contains(file.fid) else { return }

        pendingDownloadFids.insert(file.fid)

        Task {
            defer { pendingDownloadFids.remove(file.fid) }
            do {
                let link = try await resolver.downloadLink(
                    for: file,
                    share: share,
                    stoken: token.stoken
                )
                let headers = Self.downloadHeaders(
                    for: link,
                    platform: share.platform,
                    resolver: resolver
                )
                let task = DownloadManager.shared.enqueue(link, headers: headers)
                toastMessage = "已加入下载队列：\(task.fileName)"
            } catch {
                alertMessage = "取直链失败：\(Self.describe(error))"
            }
        }
    }

    /// 直链请求需要带上的头。
    ///
    /// 游客态取链会拿到 `guestCookie`（夸克缺了会 412、UC 会 403），
    /// 这里把它转成 `Cookie` 头；登录态为空串则不传。
    /// 构造下载请求头。
    ///
    /// **Referer 是必需的，不是可选项**：夸克与 UC 的 CDN 直链都有防盗链校验，
    /// 缺 Referer 会直接 403。登录态还要带账号 Cookie，游客态带 `__pugs`。
    /// 这些规则属于各平台协议细节，所以交给解析器自己给（`DownloadHeadersProviding`），
    /// 界面层不重复实现一遍 —— 否则平台一改就要改两处。
    /// 改成 `static` 是为了能被 `DirectoryScreen` 复用 ——
    /// 后者是独立的结构体，拿不到 `ResolveScreen` 的实例方法。
    /// 注意是 `static` + **非 private**：`DirectoryScreen` 是同文件里的独立结构体，
    /// private 会报「'downloadHeaders' is inaccessible due to 'private' protection level」。
    static func downloadHeaders(
        for link: DownloadLink,
        platform: SharePlatform,
        resolver: ShareResolving
    ) -> [String: String] {
        if let dispatcher = resolver as? PlatformDispatchingResolver {
            return dispatcher.downloadHeaders(for: link, platform: platform)
        }
        // 非分派器（例如测试注入的单个解析器）：退回到最小可用头
        var headers: [String: String] = ["Referer": "https://pan.quark.cn/"]
        if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
        }
        return headers
    }

    // MARK: - 状态重置

    private func resetShare() {
        path.removeAll()
        rootFiles = []
        rootErrorText = nil
        token = nil
        share = nil
    }

    // MARK: - 工具

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    /// 把任意错误转成中文可读文案，`ResolveError` 优先走自身的 `errorDescription`。
    static func describe(_ error: Error) -> String {
        if let resolveError = error as? ResolveError {
            return resolveError.errorDescription ?? "解析失败"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络请求失败：\(nsError.localizedDescription)"
        }
        return error.localizedDescription
    }
}

// MARK: - 文件行

/// 分享内的文件 / 文件夹行。
private struct FileRow: View {
    let file: ShareFile
    let isDownloading: Bool
    let onTap: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isdir ? "folder.fill" : iconName(for: file.fname))
                .font(.system(size: 20))
                .foregroundStyle(file.isdir ? Color.orange : Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.fname)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(file.sizeText)
                    if !file.modifyTime.isEmpty {
                        Text("·")
                        Text(file.modifyTime)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if file.isdir {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    onDownload()
                } label: {
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("下载", systemImage: "arrow.down.circle")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDownloading)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityHint(file.isdir ? "进入文件夹" : "下载该文件")
    }

    /// 按扩展名挑一个图标。只做展示用，认不出来就用通用文档图标。
    private func iconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "avi", "mov", "webm", "flv", "rmvb", "ts":
            return "film"
        case "mp3", "flac", "wav", "aac", "m4a", "ogg":
            return "music.note"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return "photo"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return "archivebox"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx", "rtf", "pages":
            return "doc.text"
        case "xls", "xlsx", "csv", "numbers":
            return "tablecells"
        case "ppt", "pptx", "key":
            return "rectangle.on.rectangle"
        case "txt", "md", "json", "xml", "log":
            return "doc.plaintext"
        case "apk", "ipa", "dmg", "exe":
            return "shippingbox"
        default:
            return "doc"
        }
    }
}

// MARK: - 子目录页

/// 进入某一层目录后的列表页。
///
/// 做成独立 View 的原因是每个目录都有自己的加载状态，
/// 塞在 ResolveScreen 里会互相踩状态；目录栈本身仍由 ResolveScreen 的 `path` 管理。
private struct DirectoryScreen: View {
    let directory: ShareFile
    /// 分享解析器。
    ///
    /// ⚠️ Swift 5.9 的 View 结构性规则：View 的值类型存储属性支持
    /// `let` / `@State` / `@StateObject` / `@ObservedObject` 等，
    /// 但「协议存在类型且协议非 Sendable」时会被视为不可变，随后在 body 里
    /// 调用它的方法可能报 “cannot use mutating member on immutable value”。
    /// `ShareResolving` 本身声明为 `Sendable`，理论上是安全的；若你的
    /// Xcode 版本仍在这里报错，把本行改成
    /// `let resolver: any ShareResolving & Sendable` 即可（语义完全相同）。
    let resolver: ShareResolving
    let share: ParsedShare?
    let stoken: String
    let onEnqueued: (String) -> Void
    let onError: (String) -> Void

    @State private var files: [ShareFile] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var pendingDownloadFids: Set<String> = []

    var body: some View {
        List {
            if let errorText {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") {
                            Task { await load(force: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if isLoading && files.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取…").foregroundStyle(.secondary)
                }
            } else if files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这个文件夹是空的")
                        .foregroundStyle(.secondary)
                    if directory.pdirFid != "0" {
                        Text("提示：返回上一级可以继续浏览其它目录。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Section {
                    ForEach(files) { file in
                        if file.isdir {
                            // 目录：push 到子目录页
                            NavigationLink(value: file) {
                                FileRowSummary(
                                    file: file,
                                    isDownloading: false,
                                    onDownload: { downloadFile(file) }
                                )
                            }
                        } else {
                            // 文件行不需要导航，所以不用 NavigationLink，
                            // 避免出现点了没反应的箭头/变灰效果
                            FileRowSummary(
                                file: file,
                                isDownloading: pendingDownloadFids.contains(file.fid),
                                onDownload: { downloadFile(file) }
                            )
                        }
                    }
                } footer: {
                    Text("共 \(files.count) 项")
                }
            }
        }
        .navigationTitle(directory.fname)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load(force: false)
        }
        .refreshable {
            await load(force: true)
        }
    }

    private func load(force: Bool) async {
        guard let share else {
            errorText = "分享信息已失效，请返回重新解析"
            return
        }
        if isLoading { return }
        if !force && !files.isEmpty { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let listed = try await resolver.listFiles(
                playload: share,
                stoken: stoken,
                pdirFid: directory.fid,
                page: 1
            )
            files = ShareFile.sortedForDisplay(listed)
        } catch {
            errorText = ResolveScreen.describe(error)
        }
    }

    private func downloadFile(_ file: ShareFile) {
        guard let share else {
            onError("分享信息已失效，请返回重新解析")
            return
        }
        guard !file.isdir, !pendingDownloadFids.contains(file.fid) else { return }
        pendingDownloadFids.insert(file.fid)

        Task {
            defer { pendingDownloadFids.remove(file.fid) }
            do {
                let link = try await resolver.downloadLink(
                    for: file,
                    share: share,
                    stoken: stoken
                )
                // 注意用 `ResolveScreen.` 而不是 `Self.`：这里在 DirectoryScreen 内部
                let headers = ResolveScreen.downloadHeaders(
                    for: link,
                    platform: share.platform,
                    resolver: resolver
                )
                let task = DownloadManager.shared.enqueue(link, headers: headers)
                onEnqueued("已加入下载队列：\(task.fileName)")
            } catch {
                onError("取直链失败：\(ResolveScreen.describe(error))")
            }
        }
    }
}

/// 子目录行内容：与 `FileRow` 同样的信息，但点击行为交给 NavigationLink。
private struct FileRowSummary: View {
    let file: ShareFile
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if file.isdir {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.orange)
                    .frame(width: 26)
            } else {
                // 文件行的图标只用于区分类型；行尾按钮才是下载入口
                Image(systemName: "doc.text")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.fname)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(file.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !file.isdir {
                Button {
                    onDownload()
                } label: {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isDownloading)
                .accessibilityLabel("下载 \(file.fname)")
            }
        }
    }
}
