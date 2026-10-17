//
//  DownloadsScreen.swift
//  云析 YunX iOS —— 「下载」页：任务列表、进度、暂停/继续/删除
//
//  并发模型说明：
//  - `DownloadManager` 是 `@MainActor` 的单例；`DownloadTask` 是 `ObservableObject`。
//  - 列表行必须逐个用 `@ObservedObject` 观察对应任务，否则进度/speed 不会实时刷新
//    （只观察 Manager 的话，只有 `tasks` 数组本身变化时才重绘）。
//  - View 的 body 在 MainActor 上执行，直接访问 `DownloadManager.shared` 合法；
//    但非 MainActor 闭包（例如 SwipeAction 的按钮回调——SwiftUI 不保证其隔离）
//    里调用 Manager 的方法时，统一用 `Task { @MainActor in … }` 包一层。
//
//  删除确认用 `.confirmationDialog`：它是系统弹层，不受行内 `onDelete` 事务限制，
//  点「删除」后行不会因为确认框弹出而先被移除。
//

import SwiftUI
import Foundation

struct DownloadsScreen: View {

    /// 观察管理器本身（任务增删、全局暂停/继续）。
    /// 在属性初始化处访问 `DownloadManager.shared` 是安全的：View 的初始化
    /// 与 body 都在 MainActor 上；这里只取一次引用，后续由 @StateObject 持有观察。
    @StateObject private var manager = DownloadManager.shared

    /// 待确认删除的任务
    @State private var pendingDeletion: DownloadTask?
    /// 删除确认框是否显示
    @State private var showDeleteDialog = false
    /// 删除任务时是否同时删除已下载的文件
    @State private var deleteFileToo = true
    /// 轻提示
    @State private var toastMessage: String?

    /// 失败任务的错误信息展开状态
    @State private var expandedErrorIds: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if manager.tasks.isEmpty {
                    EmptyStateView(
                        systemImage: "arrow.down.circle",
                        title: "还没有下载任务",
                        message: "去「解析」页粘贴分享链接，选中文件后即可开始下载。"
                    )
                } else {
                    taskList
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pauseAll()
                        } label: {
                            Label("全部暂停", systemImage: "pause.circle")
                        }
                        .disabled(!hasRunningOrQueued)

                        Button {
                            resumeAll()
                        } label: {
                            Label("全部继续", systemImage: "play.circle")
                        }
                        .disabled(!hasPaused)

                        Divider()

                        Button {
                            openDeleteDialog(deleteFile: false)
                        } label: {
                            Label("清除全部任务（保留文件）", systemImage: "trash")
                        }
                        .disabled(manager.tasks.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        // 轻提示（全部暂停/继续、删除结果）
        .toast(message: $toastMessage)
        .confirmationDialog(
            deleteFileToo ? "删除任务并删除已下载的文件？" : "删除任务？（保留已下载的文件）",
            isPresented: $showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button(deleteFileToo ? "删除任务和文件" : "删除任务", role: .destructive) {
                performDeletion()
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(cancelHint + (deleteFileToo
                 ? "已下载到本机的文件会一并删除，无法恢复。"
                 : "已下载到本机的文件会保留，只从列表里移除。"))
        }
    }

    /// 针对单条 / 全部的确认文案前缀。
    private var cancelHint: String {
        guard let task = pendingDeletion else { return "将删除全部任务。" }
        return "任务：\(task.fileName)\n"
    }

    // MARK: - 子视图

    private var taskList: some View {
        List {
            Section {
                ForEach(manager.tasks) { task in
                    // 关键：每个任务单独观察，进度条才会随下载实时前进
                    DownloadTaskRow(
                        task: task,
                        isErrorExpanded: expandedErrorIds.contains(task.id),
                        onToggleError: { toggleError(task) },
                        onTogglePause: { togglePause(task) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            openDeleteDialog(for: task, deleteFile: true)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        if task.state == .running || task.state == .queued {
                            Button {
                                pause(task)
                            } label: {
                                Label("暂停", systemImage: "pause.fill")
                            }
                            .tint(.orange)
                        } else if task.state == .paused || task.state == .failed {
                            Button {
                                resume(task)
                            } label: {
                                Label("继续", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                    }
                    .contextMenu {
                        if task.state == .running || task.state == .queued {
                            Button {
                                pause(task)
                            } label: {
                                Label("暂停", systemImage: "pause")
                            }
                        } else if task.state == .paused || task.state == .failed {
                            Button {
                                resume(task)
                            } label: {
                                Label("继续", systemImage: "play")
                            }
                        }
                        Button(role: .destructive) {
                            openDeleteDialog(for: task, deleteFile: true)
                        } label: {
                            Label("删除任务和文件", systemImage: "trash")
                        }
                        Button {
                            openDeleteDialog(for: task, deleteFile: false)
                        } label: {
                            Label("移除任务（保留文件）", systemImage: "minus.circle")
                        }
                    }
                }
            } footer: {
                Text("左滑可暂停 / 继续 / 删除，长按可查看更多操作。")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 状态判断

    private var hasRunningOrQueued: Bool {
        manager.tasks.contains { $0.state == .running || $0.state == .queued }
    }

    private var hasPaused: Bool {
        manager.tasks.contains { $0.state == .paused }
    }

    // MARK: - 操作

    private func toggleError(_ task: DownloadTask) {
        if expandedErrorIds.contains(task.id) {
            expandedErrorIds.remove(task.id)
        } else {
            expandedErrorIds.insert(task.id)
        }
    }

    private func togglePause(_ task: DownloadTask) {
        switch task.state {
        case .running, .queued:
            pause(task)
        case .paused, .failed:
            resume(task)
        case .completed:
            break
        }
    }

    private func pause(_ task: DownloadTask) {
        Task { @MainActor in
            DownloadManager.shared.pause(task)
        }
    }

    private func resume(_ task: DownloadTask) {
        Task { @MainActor in
            DownloadManager.shared.resume(task)
        }
    }

    private func pauseAll() {
        Task { @MainActor in
            DownloadManager.shared.pauseAll()
            toastMessage = "已暂停全部任务"
        }
    }

    private func resumeAll() {
        Task { @MainActor in
            DownloadManager.shared.resumeAll()
            toastMessage = "已继续全部任务"
        }
    }

    private func openDeleteDialog(for task: DownloadTask, deleteFile: Bool) {
        pendingDeletion = task
        deleteFileToo = deleteFile
        showDeleteDialog = true
    }

    private func openDeleteDialog(deleteFile: Bool) {
        pendingDeletion = nil
        deleteFileToo = deleteFile
        showDeleteDialog = true
    }

    /// 统一处理确认后的删除：单条或全部。
    private func performDeletion() {
        let targets: [DownloadTask]
        if let task = pendingDeletion {
            targets = [task]
        } else {
            targets = manager.tasks
        }
        let canDeleteFile = deleteFileToo
        let count = targets.count
        pendingDeletion = nil

        Task { @MainActor in
            // 先取一份快照再逐个移除：remove 会改动 manager.tasks 数组，
            // 边遍历边删会跳过元素
            for task in targets {
                DownloadManager.shared.remove(task, deleteFile: canDeleteFile)
            }
            toastMessage = canDeleteFile
                ? "已删除 \(count) 个任务及其文件"
                : "已移除 \(count) 个任务（文件保留）"
        }
    }
}

// MARK: - 任务行

/// 单个下载任务行。
///
/// 用 `@ObservedObject` 直接盯住 `DownloadTask`，这样 `downloadedBytes` /
/// `speedBytesPerSec` / `state` 的变化会立刻驱动这一行的重绘。
private struct DownloadTaskRow: View {
    @ObservedObject var task: DownloadTask
    let isErrorExpanded: Bool
    let onToggleError: () -> Void
    let onTogglePause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.fileName)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(byteText(task.downloadedBytes))
                        Text("/")
                        Text(task.totalBytes > 0 ? byteText(task.totalBytes) : "未知大小")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Spacer(minLength: 6)

                StateBadge(state: task.state)
            }

            // 进度条
            ProgressView(value: task.progress)
                .progressViewStyle(.linear)
                .tint(progressTint)

            HStack(spacing: 8) {
                Text("\(Int((task.progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if task.state == .running {
                    Text(task.speedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if task.state == .failed, let message = task.errorMessage, !message.isEmpty {
                    Button {
                        onToggleError()
                    } label: {
                        Label("失败原因", systemImage: isErrorExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                // 已完成时不再显示暂停/继续按钮，改用一个静态对勾
                if task.state != .completed {
                    Button {
                        onTogglePause()
                    } label: {
                        Image(systemName: pauseSymbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(task.state == .running || task.state == .queued ? "暂停" : "继续")
                } else {
                    ProgressBadge(progress: 1, size: 22, showsPercent: false)
                        .accessibilityHidden(true)
                }
            }

            if task.state == .failed, isErrorExpanded, let message = task.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var pauseSymbol: String {
        switch task.state {
        case .running, .queued: return "pause.circle.fill"
        case .paused, .failed: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var progressTint: Color {
        switch task.state {
        case .failed: return .red
        case .paused: return .orange
        case .completed: return .green
        case .queued, .running: return .accentColor
        }
    }

    /// 用 `ByteCountFormatter` 而不是自己算，和 `ShareFile.sizeText` 保持一致的观感。
    private func byteText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 字节" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
