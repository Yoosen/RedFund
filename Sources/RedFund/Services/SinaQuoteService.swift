import Foundation

/// 新浪基金分时估值服务（数据源 2）。
///
/// 与东财（数据源 1）的区别：
/// - **盘中返回的是「到当前时刻为止」的增量点**，随交易推进逐分钟增长；只有收盘后才是一整天的完整曲线。
///   （实测：09:38 请求 002833 仅返回 6 个点 09:27–09:37；而收盘后可得 156+ 点。
///    「一次拿到全天曲线」只在收盘后成立，盘中切勿按全天数据假设。）
/// - 曲线延伸到 16:04，需截断到 15:00 对齐东财；
/// - 不支持批量，单只请求；
/// - 覆盖率约 81%，部分基金无数据（调用方据此只展示数据源 1）。
///
/// 取数策略：仅在详情页把数据源切到「数据源2」时按需加载，不参与批量刷新。
/// - **盘中**：数据未定格，按 `refetchInterval` 节流持续刷新，随交易推进增长；
/// - **收盘后**：曲线已定格，此时才落盘，重复进入详情页直接读磁盘，不再请求；
/// - 落盘按「曲线所属交易日」保留到**第二个交易日**（跨周末/节假日顺延）后清除，避免无限增长。
struct SinaQuoteService {

    // MARK: - 进程内缓存（含交易日，用于跨天失效）

    private struct CacheEntry {
        let points: [FundIntradayRatePoint]
        let fetchedAt: Date
        /// 曲线所属交易日（上海时区当天 0 点），用于跨「第二个交易日」失效。
        let tradingDay: Date
    }

    private static let cache = IntradayCache()
    /// 盘中节流间隔：数据未定格，需持续刷新才能看到曲线增长。
    /// 单只基金详情页按需请求，1 分钟一次的压力可忽略；收盘后由「定格 + 落盘」接管，不再请求。
    private static let refetchInterval: TimeInterval = 60
    private static let marketCloseMinutes = 15 * 60             // 15:00 截断对齐东财

    private static let diskSubdirectory = "sina-intraday"

    private static let chinaCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private final class IntradayCache: @unchecked Sendable {
        private var store: [String: CacheEntry] = [:]
        private let lock = NSLock()

        func value(for code: String, now: Date) -> [FundIntradayRatePoint]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = store[code] else { return nil }
            let marketClosed = TradingCalendar.marketSessionState(now: now) == .closed
            let fresh = now.timeIntervalSince(entry.fetchedAt) < SinaQuoteService.refetchInterval
            guard fresh || marketClosed else { return nil }
            // 必须仍是「当前应展示的交易日」：隔夜后 App 未退出时，
            // 昨天的定格曲线不能顶替今天盘中的数据（收盘后 marketClosed 会无条件复用）。
            guard SinaQuoteService.isCurrentTradingDay(entry.tradingDay, now: now) else { return nil }
            // 跨「第二个交易日」则视为失效，迫使重新取数。
            guard !SinaQuoteService.isCacheStale(recordedTradingDay: entry.tradingDay, now: now) else { return nil }
            return entry.points
        }

        func store(_ points: [FundIntradayRatePoint], for code: String, tradingDay: Date, now: Date) {
            lock.lock(); defer { lock.unlock() }
            store[code] = CacheEntry(points: points, fetchedAt: now, tradingDay: tradingDay)
        }
    }

    // MARK: - 对外入口

    /// 取某只基金当日新浪分时曲线。优先级：进程缓存 → 落盘 → 网络（仅交易日）。
    /// 非交易日且无落盘时不发起无意义请求。
    static func fetchIntradayRatePoints(code: String) async -> [FundIntradayRatePoint] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 清理过期落盘（跨会话；同一会话内过期进程缓存也会在下方磁盘层一并失效）
        Self.pruneStaleDiskCache(now: Date())

        if let cached = cache.value(for: trimmed, now: Date()) {
            return cached
        }

        // 落盘命中：重复进入详情页优先读磁盘，避免重复请求
        if let disk = loadFromDisk(code: trimmed, now: Date()) {
            cache.store(disk.points, for: trimmed, tradingDay: disk.tradingDay, now: Date())
            return disk.points
        }

        // 非交易日且无落盘：不发起无意义请求
        guard TradingCalendar.isFundTradingDay(Date()) else { return [] }

        guard let url = URL(string:
            "https://stock.finance.sina.com.cn/fundInfo/api/openapi.php/FdFundService.getEstimateNetworthPic?symbol=\(trimmed)"
        ) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = Self.parseIntradayPointsWithDay(from: data, code: trimmed)
            if !parsed.points.isEmpty {
                cache.store(parsed.points, for: trimmed, tradingDay: parsed.tradingDay, now: Date())
                // 只在**收盘后**落盘：此时曲线已定格为完整一天，重复进入详情页可直接读磁盘。
                // 盘中数据是持续增长的增量快照，落盘没有意义，反而会被后续读取当成定格数据。
                if TradingCalendar.marketSessionState(now: Date()) == .closed {
                    saveToDisk(code: trimmed, points: parsed.points, tradingDay: parsed.tradingDay)
                }
            }
            return parsed.points
        } catch {
            return []
        }
    }

    // MARK: - 解析（与网络解耦，便于测试）

    /// 解析报文，返回「曲线点 + 曲线所属交易日」。
    static func parseIntradayPointsWithDay(from data: Data, code: String) -> (points: [FundIntradayRatePoint], tradingDay: Date) {
        guard let payload = try? JSONDecoder().decode(SinaEstimateResponse.self, from: data),
              payload.result.status.code == 0,
              let rows = payload.result.data?.networth else {
            return ([], startOfTodayInShanghai())
        }
        let points = normalizedPoints(rows: rows, code: code)
        let tradingDay = startOfDayInShanghai(dayComponents(from: rows.first?.preDate))
        return (points, tradingDay)
    }

    /// 仅返回曲线点（解析口径测试用）。
    static func parseIntradayPoints(from data: Data, code: String) -> [FundIntradayRatePoint] {
        parseIntradayPointsWithDay(from: data, code: code).points
    }

    private static func startOfTodayInShanghai() -> Date {
        startOfDayInShanghai(dayComponents(from: nil))
    }

    private static func startOfDayInShanghai(_ day: (year: Int, month: Int, day: Int)) -> Date {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 0
        components.minute = 0
        components.second = 0
        return chinaCalendar.date(from: components) ?? Date()
    }

    private static func normalizedPoints(rows: [SinaEstimateRow], code: String) -> [FundIntradayRatePoint] {
        return rows.compactMap { row in
            guard let rate = row.growthrate,
                  let minute = parseMinutes(row.minTime),
                  minute <= marketCloseMinutes else { return nil }
            let dc = dayComponents(from: row.preDate)
            let ts = timestamp(year: dc.year, month: dc.month, day: dc.day, minute: minute)
            let formatted = Self.chinaFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
            return FundIntradayRatePoint(timestamp: ts, rate: rate * 100, estimateTime: formatted)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - 落盘

    private struct DiskRecord: Codable {
        let tradingDay: Date
        let points: [FundIntradayRatePoint]
    }

    private static func diskDirectory() -> URL {
        let dir = AppDataPaths.sharedDataDirectory
            .appending(path: diskSubdirectory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskFileURL(for code: String) -> URL {
        diskDirectory().appending(path: "\(code).json")
    }

    private static func saveToDisk(code: String, points: [FundIntradayRatePoint], tradingDay: Date) {
        let record = DiskRecord(tradingDay: tradingDay, points: points)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: diskFileURL(for: code), options: .atomic)
    }

    private static func loadFromDisk(code: String, now: Date) -> (points: [FundIntradayRatePoint], tradingDay: Date)? {
        let url = diskFileURL(for: code)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DiskRecord.self, from: data) else { return nil }
        guard !isCacheStale(recordedTradingDay: record.tradingDay, now: now) else {
            // 已过期：删除落盘文件，避免无限增长
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // 落盘是「收盘后定格」的曲线，只在它仍属于当前应展示的交易日时复用。
        // 否则（例如昨天落盘、今天已开盘）必须重新取当日的盘中数据——
        // 用昨天的定格曲线顶替今天，会让走势图一整天停在过去。
        guard isCurrentTradingDay(record.tradingDay, now: now) else { return nil }
        return (record.points, record.tradingDay)
    }

    /// 清除所有已超过「第二个交易日」的落盘文件。
    private static func pruneStaleDiskCache(now: Date) {
        let dir = diskDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DiskRecord.self, from: data) else { continue }
            if isCacheStale(recordedTradingDay: record.tradingDay, now: now) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - 交易日失效计算

    /// 当前应展示的盘中曲线所属交易日（上海时区 0 点）：盘前回溯到上一交易日。
    static func currentEffectiveTradingDay(now: Date) -> Date {
        chinaCalendar.startOfDay(for: TradingCalendar.effectiveIntradayTradingDay(now: now))
    }

    /// `day` 是否正是当前应展示的交易日。
    /// 昨日/更早的数据一律不复用——盘中数据会持续增长，必须用当日的数据。
    static func isCurrentTradingDay(_ day: Date, now: Date) -> Bool {
        chinaCalendar.startOfDay(for: day) == currentEffectiveTradingDay(now: now)
    }

    /// 曲线所属交易日 `recordedTradingDay` 的数据：保留到当天及紧接的下一个交易日，
    /// 在「第二个交易日」（跨周末/节假日顺延）开始时清除。
    static func isCacheStale(recordedTradingDay: Date, now: Date) -> Bool {
        let today = chinaCalendar.startOfDay(for: now)
        let recorded = chinaCalendar.startOfDay(for: recordedTradingDay)
        guard let t1 = nextTradingDay(after: recorded),
              let t2 = nextTradingDay(after: t1) else { return true }
        return today >= t2
    }

    static func nextTradingDay(after date: Date) -> Date? {
        var cursor = chinaCalendar.date(byAdding: .day, value: 1, to: chinaCalendar.startOfDay(for: date))
        for _ in 0..<14 {
            if let c = cursor, TradingCalendar.isFundTradingDay(c) { return c }
            guard let c = cursor else { return nil }
            cursor = chinaCalendar.date(byAdding: .day, value: 1, to: c)
        }
        return nil
    }

    // MARK: - 报文模型

    private static let chinaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func timestamp(year: Int, month: Int, day: Int, minute: Int) -> Int64 {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = minute / 60
        c.minute = minute % 60
        c.second = 0
        guard let date = chinaCalendar.date(from: c) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// 解析 `pre_date`（兼容 `2026-08-31` 与 `20260831` 两种格式）。缺省回退到今天。
    private static func dayComponents(from date: String?) -> (year: Int, month: Int, day: Int) {
        guard let raw = date, !raw.isEmpty else {
            let now = chinaCalendar.dateComponents([.year, .month, .day], from: Date())
            return (now.year ?? 1970, now.month ?? 1, now.day ?? 1)
        }
        let digits = raw.filter { $0.isNumber }
        let year = Int(String(digits.prefix(4))) ?? 1970
        let month = Int(String(digits.dropFirst(4).prefix(2))) ?? 1
        let day = Int(String(digits.dropFirst(6).prefix(2))) ?? 1
        return (year, month, day)
    }

    private static func parseMinutes(_ time: String?) -> Int? {
        guard let time, !time.isEmpty else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

private struct SinaEstimateResponse: Decodable {
    let result: SinaResultContainer
}

private struct SinaResultContainer: Decodable {
    let status: SinaStatus
    let data: SinaEstimateData?
}

private struct SinaStatus: Decodable {
    let code: Int
}

private struct SinaEstimateData: Decodable {
    let networth: [SinaEstimateRow]?
}

private struct SinaEstimateRow: Decodable {
    let symbol: String?
    let minTime: String?
    let growthrate: Double?
    let preDate: String?

    enum CodingKeys: String, CodingKey {
        case symbol
        case minTime = "min_time"
        case growthrate
        case preDate = "pre_date"
    }
}
