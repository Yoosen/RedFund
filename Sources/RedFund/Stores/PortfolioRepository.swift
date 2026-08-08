import Foundation

/// 持仓快照的持久化仓储协议：定义数据目录、文件路径及加载/保存能力。
protocol PortfolioRepository {
    var dataDirectory: URL { get }
    var dataFileURL: URL { get }

    func load() throws -> PortfolioSnapshot?
    func save(_ snapshot: PortfolioSnapshot) throws
}

/// 基于 JSON 文件的持仓快照仓储（实际落盘实现）。
struct JSONPortfolioRepository: PortfolioRepository {
    let dataDirectory: URL

    /// 持仓数据文件路径（portfolio.json）。
    var dataFileURL: URL {
        dataDirectory.appending(path: "portfolio.json")
    }

    /// 从磁盘加载持仓快照；文件不存在时返回 nil。
    func load() throws -> PortfolioSnapshot? {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: dataFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PortfolioSnapshot.self, from: data)
    }

    /// 将持仓快照编码为格式化 JSON 并原子写入磁盘。
    func save(_ snapshot: PortfolioSnapshot) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: dataFileURL, options: .atomic)
    }
}

/// 内存暂存型持仓快照仓储（用于预览/暂存，不落盘）。
final class StagedPortfolioRepository: PortfolioRepository {
    let dataDirectory: URL
    /// 持仓数据文件路径（与 JSON 实现一致）。
    var dataFileURL: URL {
        dataDirectory.appending(path: "portfolio.json")
    }
    private var snapshot: PortfolioSnapshot?

    /// 用指定目录与初始快照初始化暂存仓储。
    init(dataDirectory: URL, snapshot: PortfolioSnapshot) {
        self.dataDirectory = dataDirectory
        self.snapshot = snapshot
    }

    /// 直接返回暂存的内存快照。
    func load() throws -> PortfolioSnapshot? {
        snapshot
    }

    /// 将快照保存在内存中（不落盘）。
    func save(_ snapshot: PortfolioSnapshot) throws {
        self.snapshot = snapshot
    }
}
