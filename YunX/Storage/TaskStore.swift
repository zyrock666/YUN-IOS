//
//  TaskStore.swift
//  云析 YunX iOS —— 下载任务持久化
//
//  对应上游 data/db/DownloadTask{Entity,Dao}.kt 的职责。上游用 Room + SQLite；
//  iOS 版任务量小（一般几十条），直接用 JSON 文件存到 Application Support 更简单，
//  也避免引入 CoreData/SwiftData 的迁移负担。
//

import Foundation

/// 下载任务的持久化记录。
struct TaskStore: Sendable {

    /// 落盘用的扁平结构。字段与 `DownloadTask` 对应，但去掉回调与运行时句柄。
    struct Record: Codable, Sendable {
        var id: UUID
        var fileName: String
        var url: String
        var totalBytes: Int64
        var downloadedBytes: Int64
        var state: DownloadState
        var destinationPath: String
        var createdAt: Date
        var errorMessage: String?

        /// `DownloadTask` 是 `@MainActor` 隔离的，读它的属性必须在主 actor 上，
        /// 所以这个转换器也要标 `@MainActor`（否则报
        /// 「main actor-isolated property 'fileName' can not be referenced from a non-isolated context」）。
        @MainActor
        init(from task: DownloadTask) {
            self.id = task.id
            self.fileName = task.fileName
            self.url = task.url
            self.totalBytes = task.totalBytes
            self.downloadedBytes = task.downloadedBytes
            self.state = task.state
            self.destinationPath = task.destinationPath
            self.createdAt = task.createdAt
            self.errorMessage = task.errorMessage
        }

        @MainActor
        func toTask() -> DownloadTask {
            let task = DownloadTask(
                id: id,
                fileName: fileName,
                url: url,
                totalBytes: totalBytes,
                destinationPath: destinationPath,
                requestHeaders: [:],
                state: state,
                downloadedBytes: downloadedBytes,
                createdAt: createdAt
            )
            task.errorMessage = errorMessage
            return task
        }
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YunX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    func save(_ records: [Record]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不该影响正在进行的下载，只记日志
            print("[TaskStore] 保存失败：\(error.localizedDescription)")
        }
    }

    func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }
}
