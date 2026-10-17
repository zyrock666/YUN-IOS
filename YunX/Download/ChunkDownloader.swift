//
//  ChunkDownloader.swift
//  云析 YunX iOS —— Range 分片下载引擎
//
//  移植自上游 CYQawa/YunX（AGPL-3.0）data/download/{DownloadManager,ChunkDownloader,
//  HttpRangePolicy}.kt 的核心设计。
//
//  ## 上游设计里必须保留的三条约束
//  1. **服务端必须支持 Range**：先发一个 `Range: bytes=0-0` 探针，看是否回 206 +
//     `Content-Range`。不支持就退化成单线程整文件下载（否则拼出来的文件是坏的）。
//  2. **HTTP/1.1**：上游实测 OkHttp 的 HTTP/2 每流 16MB 接收窗口，消费端一慢就把
//     堆撑爆。iOS 上用 URLSession 的 `httpMaximumConnectionsPerHost` 控制并发，
//     并强制不走 HTTP/2（见 HTTPClient）。
//  3. **分片写盘用独立的文件句柄 + 预分配**：不要多线程写同一个 FileHandle
//     （会互相覆盖 offset），上游用「每片一个独立区间 + 汇聚成一个文件」的方式。
//     iOS 版用 `FileHandle.seek(toOffset:)` 按区间写，并用串行队列保护 seek+write，
//     避免句柄位置竞争。
//
//  ## 断点续传
//  每个分片的已完成字节数记在内存 + 侧车文件（`.yunx.meta`）里，重启后
//  按记录的位置重新发 `Range: bytes=<done>-<end>`。
//

import Foundation

/// 分片下载引擎。
///
/// 一个 `ChunkDownloader` 对应一个下载任务，持有自己的临时文件与分片进度。
final class ChunkDownloader: @unchecked Sendable {

    private let url: String
    private let headers: [String: String]
    private let destination: URL
    private let chunkCount: Int
    private let client: HTTPClient
    /// 限速（字节/秒），0 = 不限
    private var speedLimit: Int64
    /// 进度回调：已下载总字节、总字节、瞬时速度
    private let onProgress: @Sendable (Int64, Int64, Double) -> Void

    private let writeQueue = DispatchQueue(label: "com.yunx.download.write")
    private var handle: FileHandle?
    private var chunks: [Chunk] = []
    private var totalBytes: Int64 = 0
    private var supportsRange = false
    private var receivedBytes: Int64 = 0
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var currentSpeed: Double = 0

    private let lock = NSLock()
    private var cancelled = false
    private var paused = false

    init(
        url: String,
        headers: [String: String],
        destination: URL,
        chunkCount: Int,
        speedLimit: Int64,
        client: HTTPClient = .shared,
        onProgress: @escaping @Sendable (Int64, Int64, Double) -> Void
    ) {
        self.url = url
        self.headers = headers
        self.destination = destination
        self.chunkCount = max(1, chunkCount)
        self.speedLimit = speedLimit
        self.client = client
        self.onProgress = onProgress
    }

    // MARK: - 公开控制

    /// 暂停：仅置标志，正在跑的请求会在下一个数据块处退出。
    func pause() {
        lock.lock(); paused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); paused = false; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func updateSpeedLimit(_ limit: Int64) {
        lock.lock(); speedLimit = limit; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    // MARK: - 主流程

    /// 开始下载。返回时表示「本次会话结束」（可能因暂停/取消提前结束）。
    /// - Throws: 网络或磁盘错误。
    func start() async throws {
        try await probe()

        if totalBytes <= 0 {
            throw ResolveError.api("服务端未返回文件大小，无法下载")
        }

        try prepareFile()

        if supportsRange && chunkCount > 1 {
            try await downloadInChunks()
        } else {
            try await downloadSingleStream()
        }

        guard !isCancelled else { return }
        guard !isPaused else { return }

        // 所有分片完成 → 关句柄、写入最终大小
        try closeHandle()
        try persistMeta(completed: true)
    }

    // MARK: - 探测

    /// 探测文件大小与是否支持 Range。
    ///
    /// 上游同样先看 `Content-Length` 与 `Accept-Ranges`，再用一次
    /// `Range: bytes=0-0` 实际确认（有些 CDN 声明支持但实际回 200）。
    private func probe() async throws {
        var reqHeaders = headers
        reqHeaders["Range"] = "bytes=0-0"
        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            headers: reqHeaders
        ), useDownloadSession: true)

        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let total = Self.totalFromContentRange(contentRange) {
            supportsRange = true
            totalBytes = total
            return
        }

        // 退回整文件模式：从 Content-Length 拿大小
        supportsRange = false
        if let length = http.value(forHTTPHeaderField: "Content-Length"), let value = Int64(length) {
            totalBytes = value
        } else if http.statusCode >= 400 {
            throw ResolveError.network("下载地址返回 HTTP \(http.statusCode)")
        } else {
            // 没有 Content-Length 也没 Range：大小未知，仍尝试单流下载
            totalBytes = 0
        }
        _ = data // 探测响应体丢弃
    }

    /// 从 `bytes 0-0/12345` 里取总大小。
    private static func totalFromContentRange(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(total)
    }

    // MARK: - 文件准备

    private func prepareFile() throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: destination)

        // 预分配文件大小：避免边下边扩容造成碎片，也让断点续传能直接按偏移写
        if totalBytes > 0 {
            try handle?.truncate(atOffset: UInt64(totalBytes))
        }

        // 构建分片区间
        chunks = Self.planChunks(total: totalBytes, count: chunkCount)

        // 读取侧车元数据恢复进度（仅当与当前总大小匹配时才用）
        if let meta = loadMeta(), meta.total == totalBytes, meta.chunks.count == chunks.count {
            for i in 0..<chunks.count {
                chunks[i].downloaded = min(meta.chunks[i], chunks[i].end - chunks[i].start + 1)
            }
            receivedBytes = chunks.reduce(0) { $0 + $1.downloaded }
        }
    }

    /// 均分区间。最后一片吸收余数，保证不丢字节。
    static func planChunks(total: Int64, count: Int) -> [Chunk] {
        guard total > 0, count > 0 else { return [] }
        let n = Int64(count)
        let base = total / n
        let remainder = total % n
        var result: [Chunk] = []
        var start: Int64 = 0
        for i in 0..<count {
            let size = base + (Int64(i) < remainder ? 1 : 0)
            guard size > 0 else { continue }
            let end = start + size - 1
            result.append(Chunk(start: start, end: end, downloaded: 0))
            start = end + 1
        }
        return result
    }

    // MARK: - 分片下载

    /// 以「滑动窗口」方式并发下载所有分片。
    ///
    /// 实现要点（两个容易写错的点）：
    /// 1. **不能**在 `addTask` 之前 `await gate.wait()` 再在组内 `signal` ——
    ///    那样 addTask 就会在信号量上排队，实际退化成串行。
    ///    正确做法是先按并发上限灌满窗口，然后「完成一个补一个」。
    /// 2. 组内任务的返回值必须显式处理：`withThrowingTaskGroup` 要求 `group.next()`
    ///    的返回值被消费，否则任务抛错时错误会被静默吞掉。
    private func downloadInChunks() async throws {
        let pending = (0..<chunks.count).filter { !chunks[$0].finished }
        guard !pending.isEmpty else { return }

        // 并发上限不超过分片数，也不超过设定的 chunkCount
        let concurrency = max(1, min(chunkCount, pending.count))

        try await withThrowingTaskGroup(of: Int.self) { group in
            var cursor = 0
            // 先灌满窗口
            while cursor < min(concurrency, pending.count) {
                let index = pending[cursor]
                group.addTask { [weak self] in
                    // 先用局部常量固定 strong 引用再调用：
                    // 直接 `guard let self` 在 concurrent 闭包里会被判为
                    // 「reference to captured var 'self'」。
                    let strong = self
                    guard let strong else { return index }
                    try await strong.downloadChunk(at: index)
                    return index
                }
                cursor += 1
            }

            // 完成一个补一个，直到全部下发
            while let finishedIndex = try await group.next() {
                _ = finishedIndex
                if cursor < pending.count {
                    let index = pending[cursor]
                    group.addTask { [weak self] in
                        let strong = self
                        guard let strong else { return index }
                        try await strong.downloadChunk(at: index)
                        return index
                    }
                    cursor += 1
                }
            }
        }
    }

    /// 下载单片。按当前已下载偏移续传，循环直到本片完成。
    private func downloadChunk(at index: Int) async throws {
        var attempts = 0
        while !chunks[index].finished {
            if isCancelled || isPaused { return }
            attempts += 1
            if attempts > 5 {
                throw ResolveError.network("分片 \(index) 重试超过 5 次")
            }

            let chunk = chunks[index]
            var reqHeaders = headers
            reqHeaders["Range"] = "bytes=\(chunk.next)-\(chunk.end)"

            do {
                let (data, http) = try await client.send(HTTPClient.Request(
                    url: url,
                    headers: reqHeaders,
                    timeout: 60
                ), useDownloadSession: true)

                // 206 = 按 Range 返回；200 = 服务端忽略了 Range，会把整个文件发回来
                if http.statusCode == 206 {
                    try write(data, at: chunk.next)
                    chunks[index].downloaded += Int64(data.count)
                    advanceProgress(Int64(data.count))
                } else if http.statusCode == 200 {
                    // 服务端不支持 Range：放弃分片，交给整文件模式（此处直接报错让上层降级）
                    throw ResolveError.api("服务端不支持 Range")
                } else {
                    throw ResolveError.network("分片 \(index) 返回 HTTP \(http.statusCode)")
                }
            } catch let error as ResolveError {
                if case .api(let message) = error, message.contains("不支持 Range") {
                    throw error
                }
                // 网络抖动：退避后重试
                try await Task.sleep(nanoseconds: UInt64(min(attempts, 5)) * 500_000_000)
            }
        }
    }

    /// 整文件单流下载（Range 不可用时的退化路径）。
    private func downloadSingleStream() async throws {
        let (data, http) = try await client.send(HTTPClient.Request(
            url: url,
            headers: headers,
            timeout: 60
        ), useDownloadSession: true)
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw ResolveError.network("下载失败：HTTP \(http.statusCode)")
        }
        if totalBytes == 0 {
            totalBytes = Int64(data.count)
            try? handle?.truncate(atOffset: UInt64(totalBytes))
        }
        try write(data, at: 0)
        receivedBytes = Int64(data.count)
        onProgress(receivedBytes, totalBytes, 0)
    }

    // MARK: - 写盘

    /// 按偏移写。串行队列保证 seek+write 是原子的。
    private func write(_ data: Data, at offset: Int64) throws {
        guard let handle else {
            throw ResolveError.api("文件句柄未就绪")
        }
        var thrown: Error?
        writeQueue.sync {
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    private func closeHandle() throws {
        try handle?.close()
        handle = nil
    }

    // MARK: - 进度与限速

    private func advanceProgress(_ delta: Int64) {
        receivedBytes += delta
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed >= 0.5 {
            let gained = Double(receivedBytes - lastSampleBytes)
            currentSpeed = gained / elapsed
            lastSampleTime = now
            lastSampleBytes = receivedBytes
        }
        onProgress(receivedBytes, totalBytes, currentSpeed)
        // 节流：超速就睡一会儿（简单令牌桶，与上游全局限速思路一致）
        let limit = speedLimitSnapshot()
        if limit > 0, currentSpeed > Double(limit) {
            let over = currentSpeed - Double(limit)
            let sleepMs = min(200, Int(over / Double(limit) * 100))
            if sleepMs > 0 {
                Thread.sleep(forTimeInterval: Double(sleepMs) / 1000.0)
            }
        }
    }

    private func speedLimitSnapshot() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return speedLimit
    }

    // MARK: - 侧车元数据

    /// 侧车文件路径：与目标文件同目录，后缀 `.yunx.meta`。
    private var metaURL: URL {
        destination.appendingPathExtension("yunx.meta")
    }

    private struct Meta: Codable {
        var total: Int64
        var chunks: [Int64]
    }

    private func persistMeta(completed: Bool) throws {
        if completed {
            try? FileManager.default.removeItem(at: metaURL)
            return
        }
        let meta = Meta(total: totalBytes, chunks: chunks.map { $0.downloaded })
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL)
    }

    private func loadMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// 保存断点（暂停时调用）。
    func saveCheckpoint() {
        try? persistMeta(completed: false)
        try? closeHandle()
    }
}

/// 分片状态。
///
/// 提到文件作用域（internal）而不是嵌套在 `ChunkDownloader` 里：`planChunks`
/// 是 static 方法且要返回它，Swift 会要求「返回类型不能比方法本身更私有」，
/// 嵌套 private 会直接编译失败。
struct Chunk: Equatable {
    var start: Int64
    /// 含端点的结束偏移
    var end: Int64
    /// 已写字节数
    var downloaded: Int64

    var finished: Bool { downloaded >= (end - start + 1) }
    /// 下一次续传应从哪个偏移开始
    var next: Int64 { start + downloaded }
    /// 本片总长度
    var length: Int64 { end - start + 1 }
}

