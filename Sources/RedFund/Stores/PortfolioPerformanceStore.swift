import Foundation
import Observation

/// 收益历史持久化存储可能抛出的错误。
enum PortfolioPerformanceStoreError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case unreadablePersistedData(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "收益历史来自更高版本（v\(version)），为避免丢失数据，当前版本不会覆盖它"
        case .unreadablePersistedData(let reason):
            "收益历史暂时无法读取，为避免丢失数据，当前版本不会覆盖它：\(reason)"
        }
    }
}

/// 收益历史（`PortfolioPerformanceSnapshot`）的持久化存储。
/// 负责加载/保存收益快照、并入京东同步结果，并支持导入导出。
@Observable
@MainActor
final class PortfolioPerformanceStore {
    private(set) var snapshot: PortfolioPerformanceSnapshot = .empty
    private(set) var dataDirectory: URL
    private(set) var lastError: String?
    private(set) var hasUnreadablePersistedData = false

    init(dataDirectory: URL = AppDataPaths.sharedDataDirectory) {
        self.dataDirectory = dataDirectory
        load()
    }

    /// 收益历史数据文件路径（portfolio-performance.json）。
    var dataFileURL: URL {
        dataDirectory.appending(path: "portfolio-performance.json")
    }

    /// 从磁盘加载收益快照：版本过高则保留不覆盖，损坏则标记不可读。
    func load() {
        do {
            guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
                snapshot = .empty
                lastError = nil
                hasUnreadablePersistedData = false
                return
            }

            let data = try Data(contentsOf: dataFileURL)
            guard !data.isEmpty else {
                snapshot = .empty
                lastError = nil
                hasUnreadablePersistedData = false
                return
            }

            let decoded = try Self.decoder.decode(
                PortfolioPerformanceSnapshot.self,
                from: data
            )
            guard decoded.schemaVersion <= PortfolioPerformanceSnapshot.currentSchemaVersion else {
                throw PortfolioPerformanceStoreError.unsupportedSchemaVersion(decoded.schemaVersion)
            }
            snapshot = PortfolioPerformanceRecorder.normalized(decoded)
            lastError = nil
            hasUnreadablePersistedData = false
        } catch {
            snapshot = .empty
            lastError = error.localizedDescription
            hasUnreadablePersistedData = true
        }
    }

    @discardableResult
    /// 由完整持仓快照生成候选收益记录并落盘（无变化则返回 false）。
    func record(
        portfolio: PortfolioSnapshot,
        now: Date = .now,
        allQuotesConfirmed: Bool
    ) -> Bool {
        guard let candidate = PortfolioPerformanceRecorder.candidate(
            from: portfolio,
            now: now,
            allQuotesConfirmed: allQuotesConfirmed
        ) else {
            return false
        }
        return record(candidate)
    }

    /// 写入一条候选收益记录并更新内存快照。
    @discardableResult
    func record(_ candidate: PortfolioPerformanceRecorder.Candidate) -> Bool {
        guard !hasUnreadablePersistedData else { return false }
        let next = PortfolioPerformanceRecorder.recording(candidate, in: snapshot)
        guard next != snapshot else { return false }

        do {
            try persist(next)
            snapshot = next
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 清空全部收益历史。
    @discardableResult
    func clear() -> Bool {
        do {
            try persist(.empty)
            snapshot = .empty
            lastError = nil
            hasUnreadablePersistedData = false
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 整体替换收益快照（校验版本后归一化并落盘）。
    func replace(_ replacement: PortfolioPerformanceSnapshot) throws {
        guard replacement.schemaVersion <= PortfolioPerformanceSnapshot.currentSchemaVersion else {
            throw PortfolioPerformanceStoreError.unsupportedSchemaVersion(replacement.schemaVersion)
        }
        let normalized = PortfolioPerformanceRecorder.normalized(replacement)
        try persist(normalized)
        snapshot = normalized
        lastError = nil
        hasUnreadablePersistedData = false
    }

    /// 将京东历史收益合并计划应用到本地收益快照（可覆盖冲突）。
    @discardableResult
    func applyJDFinancePerformanceMerge(
        _ plan: PortfolioPerformanceMergePlan,
        overwriteConflicts: Bool = false
    ) throws -> Bool {
        try ensurePersistedDataIsReadable()
        let next = try PortfolioPerformanceMergePlanner.applying(
            plan,
            to: snapshot,
            overwriteConflicts: overwriteConflicts
        )
        guard next != snapshot else { return false }
        try persist(next)
        snapshot = next
        lastError = nil
        return true
    }

    /// 从二进制数据导入收益快照（解码后整体替换）。
    func importSnapshot(from data: Data) throws {
        let decoded = try Self.decoder.decode(PortfolioPerformanceSnapshot.self, from: data)
        try replace(decoded)
    }

    /// 从文件 URL 导入收益快照。
    func importSnapshot(from url: URL) throws {
        try importSnapshot(from: Data(contentsOf: url))
    }

    /// 导出当前收益快照为二进制数据。
    func exportSnapshot() throws -> Data {
        try ensurePersistedDataIsReadable()
        return try Self.encoder.encode(snapshot)
    }

    /// 返回可用于导出的内存快照。
    func snapshotForExport() throws -> PortfolioPerformanceSnapshot {
        try ensurePersistedDataIsReadable()
        return snapshot
    }

    /// 将收益快照导出到指定文件。
    func exportSnapshot(to url: URL) throws {
        try exportSnapshot().write(to: url, options: .atomic)
    }

    /// 将收益快照原子写入磁盘。
    private func persist(_ value: PortfolioPerformanceSnapshot) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: dataFileURL, options: .atomic)
    }

    /// 校验当前持久化数据可读，否则抛出不可读错误。
    private func ensurePersistedDataIsReadable() throws {
        guard !hasUnreadablePersistedData else {
            throw PortfolioPerformanceStoreError.unreadablePersistedData(lastError ?? "未知错误")
        }
    }

    /// 带 ISO8601 日期策略的收益快照编码器。
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// 带 ISO8601 日期策略的收益快照解码器。
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
