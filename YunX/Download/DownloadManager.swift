//
//  DownloadManager.swift
//  云析 YunX iOS —— 下载任务编排
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/download/DownloadManager.kt 的调度层。
//
//  ## 上游这个文件有 119KB 的原因
//  它把「任务队列 + 分片规划 + 断点续传 + 合并 + 限速 + 通知 + 磁盘空间检查 +
//  重复任务去重 + Gopeed 引擎切换」全塞在一个类里，导致 issue #8「下载一个文件
//  出现两三个」这类问题极难排查。iOS 版**刻意拆开**：
//  - 分片与写盘 → `ChunkDownloader`
//  - 任务与状态 → 本文件
//  - 持久化 → `TaskStore`
//
//  ## 上游 issue #8 的教训（本文件已规避）
//  同一个直链重复入队会生成多个任务并行写同一目标文件，互相覆盖导致文件损坏、
//  列表里出现多份。这里用 `activeKeys` 按「直链 + 目标路径」去重：
//  已在队列里的任务直接返回原任务，不再新建。
//

import Foundation
import Combine

/// 任务状态。
enum DownloadState: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

/// 单个下载任务。
///
/// 标 `@MainActor` 是因为所有字段都被 SwiftUI 直接绑定显示；
/// 后台的引擎只通过 `onProgress` 回调把数据推回主线程。
@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id: UUID
    @Published var fileName: String
    /// 直链（会被持久化，用于断点续传时重新取链 —— 注意直链通常几小时就过期）
    @Published var url: String
    @Published var totalBytes: Int64
    @Published var downloadedBytes: Int64
    @Published var state: DownloadState
    @Published var speedBytesPerSec: Double
    @Published var errorMessage: String?

    /// 目标文件完整路径
    let destinationPath: String
    /// 下载请求额外头（夸克的 Referer / Cookie 等），不持久化
    let requestHeaders: [String: String]
    /// 创建时间，用于列表稳定排序
    let createdAt: Date

    /// 引擎句柄，非持久化
    var engine: ChunkDownloader?
    /// 驱动引擎的 Task，便于取消
    var runTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        fileName: String,
        url: String,
        totalBytes: Int64,
        destinationPath: String,
        requestHeaders: [String: String] = [:],
        state: DownloadState = .queued,
        downloadedBytes: Int64 = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.url = url
        self.totalBytes = totalBytes
        self.destinationPath = destinationPath
        self.requestHeaders = requestHeaders
        self.state = state
        self.downloadedBytes = downloadedBytes
        self.speedBytesPerSec = 0
        self.createdAt = createdAt
    }

    /// 0...1 的进度。总大小未知时返回 0。
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    /// 速度文本，例如「3.4 MB/s」。
    var speedText: String {
        guard speedBytesPerSec > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file) + "/s"
    }

    /// 「1.2 MB / 300 MB」
    var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        guard totalBytes > 0 else { return done }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(done) / \(total)"
    }
}

/// 下载任务管理器（单例）。
@MainActor
final class DownloadManager: ObservableObject {

    /// 单例。
    ///
    /// 为什么 `shared` 和 `init()` 都要 `nonisolated`：
    /// SwiftUI 的 `@StateObject private var x = DownloadManager.shared` 在**属性初始化器**
    /// 里求值，那不是 main actor 上下文。若 `shared` 是 `@MainActor` 的 static，
    /// 会报「main actor-isolated static property 'shared' can not be referenced from a non-isolated context」；
    /// 而只给 `shared` 加 `nonisolated(unsafe)` 又会让它去调 `@MainActor` 的 `init()`，
    /// 报「call to main actor-isolated initializer 'init()' in a synchronous nonisolated(unsafe) context」。
    /// 所以两者必须同时 `nonisolated`。
    ///
    /// 安全性：`init()` 里只做纯数据加载（读 JSON 到属性），不碰 UI、不跨线程共享；
    /// 实例创建完成后，所有可变状态的读写仍由类上的 @MainActor 隔离保护。
    nonisolated(unsafe) static let shared = DownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []

    /// 分片并发数。
    ///
    /// **不在这里读写 UserDefaults** —— 配置的唯一真相是 `SettingsStore`。
    /// 早期版本两边各存一份，会出现「设置页显示 8、实际跑 4」这种双源不一致，
    /// 现在由 `SettingsStore` 的 `didSet` 单向推过来。
    /// 已在跑的任务不重建引擎，只对后续新建的任务生效（与上游一致）。
    var maxConnections: Int = 8

    /// 全局限速（KB/s），0 = 不限。同样由 `SettingsStore` 单向推送。
    /// 与并发数不同，限速可以**热更新**到正在跑的任务上（令牌桶每片都读最新值）。
    var globalSpeedLimitKBps: Int = 0 {
        didSet {
            let limitBytes = Int64(globalSpeedLimitKBps) * 1024
            for task in tasks {
                task.engine?.updateSpeedLimit(limitBytes)
            }
        }
    }

    private let store = TaskStore()
    private let client = HTTPClient.shared
    /// 去重：key = "url|destination"
    private var activeKeys: Set<String> = []
    /// 同时进行（running）的任务上限。iOS 后台时间有限，串行队列更稳。
    private let maxConcurrentTasks = 2

    /// `nonisolated` 的理由见 `shared` 的注释：它要被 nonisolated 的 static 属性调用。
    ///
    /// 这里**不做任何有隔离要求的工作**（不读文件、不建对象），只让属性默认值生效；
    /// 真正的任务恢复由 `bootstrap()` 在 App 启动时于主 actor 上执行。
    nonisolated private init() {}

    // MARK: - 启动

    /// 启动时恢复未完成任务。
    ///
    /// 单独抽成方法而不是放在 `init()` 里，是因为 `init` 必须是 `nonisolated`
    /// （SwiftUI 的 `@StateObject = .shared` 要求），而 `loadPersistedTasks()`
    /// 要碰 `@MainActor` 的 `DownloadTask`。由 `YunXApp.init` 在主 actor 上调用即可。
    /// 幂等：重复调用只会重读一次本地 JSON。
    func bootstrap() {
        loadPersistedTasks()
    }

    // MARK: - 入队

    /// 新建下载任务。
    ///
    /// - Parameters:
    ///   - link: 解析得到的下载直链
    ///   - headers: 下载请求要带的额外头（夸克/UC 的 Referer 与 Cookie）
    /// - Returns: 任务对象。若同一「直链 + 目标」已在队列中，返回已有任务而不是新建
    ///   （规避上游 issue #8 的重复下载问题）。
    @discardableResult
    func enqueue(_ link: DownloadLink, headers: [String: String]) -> DownloadTask {
        let safeName = Self.sanitizeFileName(link.filename.isEmpty ? link.fid : link.filename)
        let destination = Self.downloadDirectory().appendingPathComponent(safeName)
        let key = "\(link.downloadUrl)|\(destination.path)"

        if let existing = tasks.first(where: { "\($0.url)|\($0.destinationPath)" == key }),
           existing.state != .completed {
            return existing
        }

        let task = DownloadTask(
            fileName: safeName,
            url: link.downloadUrl,
            totalBytes: link.size,
            destinationPath: destination.path,
            requestHeaders: headers
        )
        tasks.insert(task, at: 0)
        activeKeys.insert(key)
        persist()
        scheduleNext()
        return task
    }

    // MARK: - 控制

    func pause(_ task: DownloadTask) {
        switch task.state {
        case .running:
            task.engine?.pause()
            task.engine?.saveCheckpoint()
            task.runTask?.cancel()
            task.runTask = nil
            task.engine = nil
            task.state = .paused
            task.speedBytesPerSec = 0
        case .queued:
            task.state = .paused
        default:
            break
        }
        persist()
        scheduleNext()
    }

    func resume(_ task: DownloadTask) {
        guard task.state == .paused || task.state == .failed else { return }
        task.state = .queued
        task.errorMessage = nil
        persist()
        scheduleNext()
    }

    func pauseAll() {
        for task in tasks where task.state == .running || task.state == .queued {
            pause(task)
        }
    }

    func resumeAll() {
        for task in tasks where task.state == .paused || task.state == .failed {
            resume(task)
        }
    }

    func remove(_ task: DownloadTask, deleteFile: Bool) {
        task.engine?.cancel()
        task.runTask?.cancel()
        task.runTask = nil
        task.engine = nil

        if deleteFile {
            try? FileManager.default.removeItem(atPath: task.destinationPath)
            // 清掉侧车元数据，避免下次续传读到旧进度
            let metaPath = task.destinationPath + ".yunx.meta"
            try? FileManager.default.removeItem(atPath: metaPath)
        }
        activeKeys.remove("\(task.url)|\(task.destinationPath)")
        tasks.removeAll { $0.id == task.id }
        persist()
        scheduleNext()
    }

    // MARK: - 调度

    /// 按并发上限拉起排队中的任务。
    private func scheduleNext() {
        let running = tasks.filter { $0.state == .running }.count
        guard running < maxConcurrentTasks else { return }

        for task in tasks where task.state == .queued {
            if tasks.filter({ $0.state == .running }).count >= maxConcurrentTasks { break }
            start(task)
        }
    }

    private func start(_ task: DownloadTask) {
        task.state = .running
        task.errorMessage = nil

        let destination = URL(fileURLWithPath: task.destinationPath)
        let speedLimit = Int64(globalSpeedLimitKBps) * 1024

        let engine = ChunkDownloader(
            url: task.url,
            headers: task.requestHeaders,
            destination: destination,
            chunkCount: maxConnections,
            speedLimit: speedLimit,
            client: client
        ) { [weak task] downloaded, total, speed in
            // 回调来自后台线程，切回主线程更新 @Published。
            //
            // 注意这里**不**在闭包里写 `guard let task else { return }`：
            // Swift 5.10 会认为 `[weak task]` 捕获的是 var，`guard let` 在
            // 并发执行的代码里重新绑定它会报
            // 「reference to captured var 'task' in concurrently-executing code」。
            // 改为先取出强引用常量再进 Task。
            let strongTask = task
            guard let strongTask else { return }
            Task { @MainActor in
                strongTask.downloadedBytes = downloaded
                if total > 0 { strongTask.totalBytes = total }
                strongTask.speedBytesPerSec = speed
            }
        }
        task.engine = engine

        // 引擎在后台跑，完成后回到主 actor 收尾。
        //
        // 注意：这里用 `Task { @MainActor in ... }` 而不是 `await MainActor.run { ... }`。
        // 后者在 Swift 6 的严格并发下，闭包是非隔离上下文，直接调用 @MainActor
        // 方法（persist/scheduleNext）会报「main actor-isolated method in a
        // nonisolated context」。`@MainActor` 标注的 Task 闭包天然在主 actor 上跑。
        task.runTask = Task { [weak self, weak task] in
            // 同上的并发捕获限制：先固定强引用，避免在 Task 闭包里重绑定 weak var
            guard let task = task else { return }
            var failure: String?
            var wasCancelled = false
            do {
                try await engine.start()
            } catch {
                if case ResolveError.cancelled = error {
                    wasCancelled = true
                } else {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }

            await MainActor.run {
                guard let self else { return }
                defer {
                    self.persist()
                    self.scheduleNext()
                }
                // 用户主动暂停/删除触发的取消不算失败
                if wasCancelled || task.state == .paused { return }

                if let failure {
                    task.state = .failed
                    task.errorMessage = failure
                    task.speedBytesPerSec = 0
                } else if task.state == .running {
                    // start() 正常返回 = 全部分片完成
                    task.state = .completed
                    task.downloadedBytes = task.totalBytes
                    task.speedBytesPerSec = 0
                }
            }
        }
    }

    // MARK: - 持久化

    private func persist() {
        // 同 loadPersistedTasks 的理由：Record.init(from:) 读的是 @MainActor 的
        // DownloadTask，因此它自身也是 @MainActor；`map` 闭包不是主 actor 上下文，
        // 必须改成显式循环（本方法已在 @MainActor 上）。
        var records: [TaskStore.Record] = []
        records.reserveCapacity(tasks.count)
        for task in tasks {
            records.append(TaskStore.Record(from: task))
        }
        store.save(records)
    }

    private func loadPersistedTasks() {
        let records = store.load()
        // 不能用 `records.map { $0.toTask() }`：`map` 的闭包不是 @MainActor 上下文，
        // 而 toTask() 是 @MainActor 方法（它要构造 @MainActor 的 DownloadTask），
        // 会报「call to main actor-isolated instance method in a synchronous nonisolated context」。
        // 改成显式循环，本方法本身已在 @MainActor 上，循环体内的调用是合法的。
        var loaded: [DownloadTask] = []
        loaded.reserveCapacity(records.count)
        for record in records {
            loaded.append(record.toTask())
        }
        tasks = loaded
        // 上次退出时正在下载的任务：置为已暂停，让用户手动继续（自动续传会耗流量）
        for task in tasks where task.state == .running {
            task.state = .paused
        }
        for task in tasks {
            activeKeys.insert("\(task.url)|\(task.destinationPath)")
        }
    }

    // MARK: - 路径

    /// 下载保存目录：App 沙盒 Documents/Downloads。
    /// Info.plist 里开了 UIFileSharingEnabled，用户能在「文件」App 里看到。
    static func downloadDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 去掉文件名里的路径分隔符与控制字符。
    ///
    /// 上游有 `DownloadPathPolicy` 专门做这件事（也是它单测覆盖的点之一）：
    /// 网盘返回的文件名可能含 `/`、`..`、控制字符，直接拼路径会写到沙盒外。
    static func sanitizeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
            .union(.controlCharacters)
        var cleaned = name.components(separatedBy: forbidden).joined(separator: "_")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "未命名文件"
        }
        // 限制长度，避免超过文件系统上限
        if cleaned.count > 180 {
            cleaned = String(cleaned.prefix(180))
        }
        return cleaned
    }
}
