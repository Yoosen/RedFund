import Foundation

/// 记录并管理基金盘中估值（涨跌幅）历史的工具。
enum FundIntradayRateHistoryRecorder {
    /// 京东数据使用的中国时区。
    private static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    /// 交易日（yyyy-MM-dd）格式化器。
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 解析京东估值时间字段的多种时间格式。
    private static let estimateTimeParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "MM-dd HH:mm:ss",
            "MM-dd HH:mm"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = chinaTimeZone
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// 估值时间文本 → 毫秒时间戳的解析缓存。
    ///
    /// `DateFormatter` 解析代价高，而盘中每 5 秒刷新会对每只基金的**每个**历史点
    /// 反复解析同一个 `estimateTime`（去重、排序比较、`shouldRecord` 各跑一遍，
    /// 排序比较闭包内更是 O(n log n) 次调用）。缓存后同一文本只解析一次。
    /// 缓存键为原始文本（不足 10 位的无效/空串结果为 nil，也一并缓存）。
    private static let estimateTimestampCache = EstimateTimestampCache()

    /// 线程安全的解析缓存容器（盘中刷新在后台线程写盘时会并发读取）。
    /// 内部已用 NSLock 保护全部读写，故声明 `@unchecked Sendable`。
    private final class EstimateTimestampCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int64?] = [:]
        /// 上限保护：文本种类实际有界（分钟级 × 交易日），留足冗余避免异常输入撑爆内存。
        private let capacity = 4096

        /// 查询缓存，未命中则计算并写入。
        func value(for text: String, compute: (String) -> Int64?) -> Int64? {
            lock.lock()
            if let cached = storage[text] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let computed = compute(text)

            lock.lock()
            if storage.count >= capacity {
                storage.removeAll(keepingCapacity: true)
            }
            storage[text] = computed
            lock.unlock()

            return computed
        }
    }

    /// 将最新估值涨跌幅写入持仓的盘中历史（仅交易时段、当日未记录时）。
    static func applyingQuotes(
        to snapshot: PortfolioSnapshot,
        quotes: [String: FundQuote],
        now: Date = .now
    ) -> PortfolioSnapshot {
        var next = snapshot
        let tradingDay = tradingDayString(from: now)
        let requestTimestamp = Int64((now.timeIntervalSince1970 * 1000).rounded())

        next.funds = snapshot.funds.map { fund in
            var updatedFund = resetIfNeeded(fund, tradingDay: tradingDay)
            // updatedFund = normalizeHistoryIfNeeded(updatedFund)
            updatedFund = normalizeHistoryIfNeeded(updatedFund, tradingDay: tradingDay)

            guard TradingCalendar.marketSessionState(now: now) == .open else {
                return updatedFund
            }

            guard let quote = quotes[fund.code],
                  quote.growthRate.isFinite,
                  quoteHasCurrentIntradayEstimate(quote, tradingDay: tradingDay),
                  let pointTimestamp = quoteEstimateTimestamp(quote),
                  pointTimestamp <= requestTimestamp,
                  shouldRecord(quote: quote, pointTimestamp: pointTimestamp, for: updatedFund)
            else {
                return updatedFund
            }

            var points = normalizedPoints(updatedFund.intradayRateHistory ?? [], tradingDay: tradingDay)
            let point = FundIntradayRatePoint(
                timestamp: pointTimestamp,
                rate: quote.growthRate,
                estimateTime: quote.estimateTime
            )
            points.removeAll { $0.estimateTime == point.estimateTime }
            points.append(point)
            updatedFund.intradayRateDate = tradingDay
            updatedFund.intradayRateHistory = normalizedPoints(points, tradingDay: tradingDay)
            return updatedFund
        }

        return next
    }

    /// 返回该基金当日有效的盘中估值点（按时间升序）。
    static func activePoints(for fund: FundPosition, now: Date = .now) -> [FundIntradayRatePoint] {
        let tradingDay = tradingDayString(from: now)
        return (fund.intradayRateHistory ?? [])
            .filter { point in
                guard !point.estimateTime.isEmpty else { return true }
                guard point.estimateTime.count >= 10 else { return false }
                return String(point.estimateTime.prefix(10)) == tradingDay
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 将日期映射为盘中历史的「有效交易日」字符串。
    /// 9:15 集合竞价前及非交易日回溯至上一交易日，使昨日盘中预估曲线在次日 9:15 前完整保留展示。
    static func tradingDayString(from date: Date) -> String {
        dayFormatter.string(from: TradingCalendar.effectiveIntradayTradingDay(now: date))
    }

    /// 若交易日变更，清空旧的盘中历史。
    private static func resetIfNeeded(_ fund: FundPosition, tradingDay: String) -> FundPosition {
        guard fund.intradayRateDate != tradingDay else { return fund }

        var next = fund
        next.intradayRateDate = tradingDay
        next.intradayRateHistory = nil
        return next
    }

    /// 对已有盘中历史执行去重与排序归一化（按当前交易日过滤，避免误删历史点）。
    private static func normalizeHistoryIfNeeded(_ fund: FundPosition, tradingDay: String) -> FundPosition {
        guard let points = fund.intradayRateHistory else { return fund }

        var next = fund
        next.intradayRateHistory = normalizedPoints(points, tradingDay: tradingDay)
        return next
    }

    /// 按估值时间/时间戳去重并排序盘中点，剔除非当日数据。
    private static func normalizedPoints(
        _ points: [FundIntradayRatePoint],
        tradingDay: String? = nil
    ) -> [FundIntradayRatePoint] {
        let day = tradingDay ?? tradingDayString(from: .now)
        var latestByKey: [String: FundIntradayRatePoint] = [:]
        var keys: [String] = []

        for point in points {
            if !point.estimateTime.isEmpty {
                guard point.estimateTime.count >= 10 else { continue }
                guard String(point.estimateTime.prefix(10)) == day else { continue }
            }
            let key = point.estimateTime.isEmpty ? "timestamp:\(point.timestamp)" : "estimate:\(point.estimateTime)"
            if latestByKey[key] == nil {
                keys.append(key)
            }
            latestByKey[key] = point
        }

        return keys
            .compactMap { latestByKey[$0] }
            .sorted { lhs, rhs in
                let lhsTimestamp = recordedEstimateTimestamp(lhs) ?? lhs.timestamp
                let rhsTimestamp = recordedEstimateTimestamp(rhs) ?? rhs.timestamp
                if lhsTimestamp == rhsTimestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhsTimestamp < rhsTimestamp
            }
    }

    /// 判断估值时间是否属于当前交易日。
    private static func quoteHasCurrentIntradayEstimate(_ quote: FundQuote, tradingDay: String) -> Bool {
        quote.estimateTime.count >= 10 && String(quote.estimateTime.prefix(10)) == tradingDay
    }

    /// 将估值时间文本转换为毫秒时间戳。
    private static func quoteEstimateTimestamp(_ quote: FundQuote) -> Int64? {
        estimateTimestampCache.value(for: quote.estimateTime, compute: parseEstimateTimestamp)
    }

    /// 按多种格式尝试解析估值时间文本（结果走缓存，同一文本只解析一次）。
    private static func parseEstimateTime(_ value: String) -> Date? {
        guard let timestamp = estimateTimestampCache.value(for: value, compute: parseEstimateTimestamp) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }

    /// 实际执行解析：按多种格式尝试，返回毫秒时间戳。
    private static func parseEstimateTimestamp(_ value: String) -> Int64? {
        for formatter in estimateTimeParsers {
            if let date = formatter.date(from: value) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded())
            }
        }
        return nil
    }

    /// 判断是否应将当前估值写入历史（同日已存在则覆盖，否则仅在晚于最新时追加）。
    private static func shouldRecord(
        quote: FundQuote,
        pointTimestamp: Int64,
        for fund: FundPosition
    ) -> Bool {
        let points = fund.intradayRateHistory ?? []
        if points.contains(where: { $0.estimateTime == quote.estimateTime }) {
            return true
        }

        guard let latestRecordedEstimateTimestamp = points.compactMap(recordedEstimateTimestamp).max() else {
            return true
        }
        return pointTimestamp > latestRecordedEstimateTimestamp
    }

    /// 取盘中点对应的时间戳（优先由估值时间解析，否则用记录时间戳）。
    private static func recordedEstimateTimestamp(_ point: FundIntradayRatePoint) -> Int64? {
        estimateTimestampCache.value(for: point.estimateTime, compute: parseEstimateTimestamp)
    }
}
