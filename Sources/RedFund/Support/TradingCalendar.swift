import Foundation

/// 市场时段状态。
enum MarketSessionState: Equatable {
    /// 开市（交易时段内）。
    case open
    /// 午间休市。
    case middayBreak
    /// 休市（非交易日或交易时段外）。
    case closed

    /// 状态中文标题。
    var title: String {
        switch self {
        case .open:
            "开市"
        case .middayBreak:
            "午休"
        case .closed:
            "休市"
        }
    }
}

/// 中国基金交易日与交易时段的工具集（基于上海时区）。
enum TradingCalendar {
    /// 操作提醒排程的最大天数。
    static let operationReminderScheduleLimit = 30

    /// 预设的法定休市日期区间（用于判定非交易日）。
    private static let marketClosedRanges = [
        ("2026-01-01", "2026-01-03"),
        ("2026-02-15", "2026-02-23"),
        ("2026-04-04", "2026-04-06"),
        ("2026-05-01", "2026-05-05"),
        ("2026-06-19", "2026-06-21"),
        ("2026-09-25", "2026-09-27"),
        ("2026-10-01", "2026-10-07")
    ]

    /// 上海时区、中文 locale 的中国日历。
    private static var chinaCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    /// 根据当前小时返回默认持仓时段（15 点后视为 after15）。
    static func defaultPositionTimeType(now: Date = .now) -> PositionTimeType {
        chinaCalendar.component(.hour, from: now) >= 15 ? .after15 : .before15
    }

    /// 将持仓日期按时段规整为可接受的交易日字符串。
    static func acceptedTradeDate(positionDate: String, timeType: PositionTimeType) -> String {
        guard let date = DateOnlyFormatter.parse(positionDate) else {
            return positionDate
        }
        return DateOnlyFormatter.string(from: acceptedTradeDate(from: date, timeType: timeType))
    }

    /// 返回给定日期文本之后的下一个交易日字符串。
    static func nextFundTradingDate(after dateText: String) -> String? {
        guard let date = DateOnlyFormatter.parse(dateText) else {
            return nil
        }
        return DateOnlyFormatter.string(from: nextFundTradingDay(after: date))
    }

    /// 判断某日期是否为基金交易日（排除周末与休市区间）。
    static func isFundTradingDay(_ date: Date) -> Bool {
        let calendar = chinaCalendar
        let weekday = calendar.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        guard !isWeekend else { return false }

        let value = DateOnlyFormatter.string(from: date)
        return !marketClosedRanges.contains { start, end in
            value >= start && value <= end
        }
    }

    /// 返回给定日期之前最近的一个基金交易日（含跨周末/休市回退）。
    /// 用于识别「净值日期落后超过一个交易日」的滞后基金（如 QDII T+1/T+2 披露）。
    static func previousTradingDay(from date: Date = .now) -> Date {
        let calendar = chinaCalendar
        var cursor = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        for _ in 0..<14 {
            if isFundTradingDay(cursor) { return cursor }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return cursor
    }

    /// 返回当前市场时段状态（非交易日直接为休市）。
    static func marketSessionState(now: Date = .now) -> MarketSessionState {
        let calendar = chinaCalendar
        guard isFundTradingDay(now) else { return .closed }

        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let minutes = hour * 60 + minute
        return marketSessionState(minutes: minutes, isTradingDay: true)
    }

    /// 当前是否处于开市时段。
    static func isMarketOpen(now: Date = .now) -> Bool {
        marketSessionState(now: now) == .open
    }

    /// 集合竞价开始时刻（9:15，上海时区）。在此之前当日估值尚未产生。
    static let callAuctionStartMinutes = 9 * 60 + 15

    /// 当前是否处于「当日 9:15 集合竞价之前」。
    /// 仅对交易日有意义；非交易日直接返回 false。
    static func isBeforeDailyCallAuction(now: Date = .now) -> Bool {
        guard isFundTradingDay(now) else { return false }
        let minutes = chinaCalendar.component(.hour, from: now) * 60
            + chinaCalendar.component(.minute, from: now)
        return minutes < callAuctionStartMinutes
    }

    /// 是否处于「集合竞价时段」（交易日 9:15-9:30）。
    ///
    /// 此阶段尚未正式开盘（`marketSessionState` 仍为 `.closed`），但盘中估值
    /// **已经从 9:15 开始产生**。若按休市间隔处理，这 15 分钟内行情在变而状态栏不更新，
    /// 故刷新排期需把它与开盘时段同等对待。
    static func isCallAuctionPeriod(now: Date = .now) -> Bool {
        guard isFundTradingDay(now) else { return false }
        let minutes = minutesOfDay(now)
        return minutes >= callAuctionStartMinutes && minutes < 9 * 60 + 30
    }

    /// 盘中数据的「有效交易日」：
    /// - 交易日 9:15（集合竞价）之后 → 当天；
    /// - 交易日 9:15 之前、周末与节假日 → 回溯至上一交易日。
    /// 用于盘中预估历史等「当日预测信息」的生命周期判定，使 9:15 前仍视为上一交易日。
    static func effectiveIntradayTradingDay(now: Date = .now) -> Date {
        if isFundTradingDay(now), !isBeforeDailyCallAuction(now: now) {
            return now
        }
        let calendar = chinaCalendar
        var day = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        var attempts = 0
        while !isFundTradingDay(day), attempts < 366 {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            attempts += 1
        }
        return day
    }

    // MARK: - 数据静止时段的定点唤醒

    /// 午休时段的定点唤醒时刻（12:00）。
    ///
    /// 午休（11:30-13:00）期间估值冻结，按固定间隔反复拉取只会拿到完全相同的数据，
    /// 且每次都触发一次全量落盘。改为中午只刷新一次，随后直接排期到 13:00 下午开盘。
    static let middayBreakWakeMinutes = 12 * 60

    /// 夜间静止时段的起点（次日 0:30）。
    ///
    /// 起点**必须晚于当日净值公布时段的末尾**。基金净值通常在 20:00-23:00 陆续公布，
    /// 但部分基金（尤其 QDII、指数型）可能延迟到 23:00 之后甚至跨零点才出。
    /// 而「估值准确率」的配对依赖当晚刷到 `quote.netValueDate == intradayRateDate`
    /// 这一瞬间（见 `EstimationDeviationRecorder.applyingConfirmedDeviation`），
    /// 一旦把起点提前到 23:30，这些晚公布基金的准确率数据将永远采集不到。
    /// 取次日 0:30 以覆盖跨零点的情况。
    static let quietPeriodStartMinutes = 30

    /// 清晨静止时段的定点唤醒时刻（8:00、9:00、9:15）。
    ///
    /// 8:00 对应 QDII 补充数据的刷新槽（见 `PortfolioStore.supplementRefreshSlot`），
    /// 9:00 用于开盘前预热，9:15 则直接对接集合竞价（当日的盘中估值从此刻开始产生）。
    static let quietPeriodWakeMinutes = [8 * 60, 9 * 60, callAuctionStartMinutes]

    /// 当日分钟数（0..<1440，上海时区）。
    private static func minutesOfDay(_ date: Date) -> Int {
        chinaCalendar.component(.hour, from: date) * 60
            + chinaCalendar.component(.minute, from: date)
    }

    /// 构造当日某一分钟对应的时刻（上海时区）。
    private static func timeOnDay(_ day: Date, minutes: Int) -> Date? {
        chinaCalendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day
        )
    }

    /// 午休时段的下一个唤醒时刻；当前不在午休则 nil。
    ///
    /// - 11:30-12:00 → 12:00（中午刷新一次）
    /// - 12:00-13:00 → 13:00（直接排到下午开盘，不再中途空刷）
    static func nextMiddayBreakWakeTime(after now: Date = .now) -> Date? {
        guard marketSessionState(now: now) == .middayBreak else { return nil }
        let minutes = minutesOfDay(now)
        let target = minutes < middayBreakWakeMinutes ? middayBreakWakeMinutes : 13 * 60
        guard let wake = timeOnDay(now, minutes: target), wake > now else { return nil }
        return wake
    }

    /// 夜间/清晨静止时段（次日 0:30 → 当日 9:15）的下一个唤醒时刻；不在该时段则 nil。
    ///
    /// 该窗口内数据已完全静止，按固定间隔刷新毫无收益，改为在 8:00、9:00 各刷新一次，
    /// 9:00 之后直接排到 9:15 集合竞价——否则普通间隔会在 9:10 插入一次多余刷新。
    ///
    /// 起点刻意取在次日 0:30 而非前一天的 23:30：净值公布可持续到 23:00 之后甚至
    /// 跨零点，而「估值准确率」的配对必须在当晚刷到净值公布的那一刻
    /// （见 `EstimationDeviationRecorder.applyingConfirmedDeviation`），
    /// 提前进入静止窗口会让晚公布基金永久采不到数据。
    static func nextQuietPeriodWakeTime(after now: Date = .now) -> Date? {
        let minutes = minutesOfDay(now)
        let calendar = chinaCalendar

        // 0:00 - 0:30 仍属「前一晚的净值公布尾巴」：净值可能跨零点才公布，此时必须
        // 继续按普通间隔刷新，因此**不能**返回定点唤醒时刻，直接返回 nil 交由调用方
        // 回退到普通间隔。
        //
        // 修复前这里会把唤醒日设为「次日」，导致 0:00-0:30 触发刷新时直接排到次日 8:00，
        // 中间空窗 31 小时以上，整个交易日的盘中估值与当晚净值配对全部丢失。
        guard minutes >= quietPeriodStartMinutes else { return nil }

        // 0:30 - 9:15 → 数据已静止，按定点唤醒（8:00 / 9:00 / 9:15），唤醒时刻就在当天。
        guard minutes < callAuctionStartMinutes else { return nil }

        let day = calendar.startOfDay(for: now)

        for target in quietPeriodWakeMinutes {
            guard let wake = timeOnDay(day, minutes: target), wake > now else { continue }
            return wake
        }
        return nil
    }

    /// 下一个「定点唤醒」时刻：用于数据静止时段替代固定刷新间隔。
    /// 不在任何静止时段则返回 nil，调用方回退到普通间隔逻辑。
    static func nextQuietWakeTime(after now: Date = .now) -> Date? {
        nextMiddayBreakWakeTime(after: now) ?? nextQuietPeriodWakeTime(after: now)
    }

    /// 从当前时间起，返回下一个交易时段边界（开盘/午休开始/下午开盘/收盘）。
    static func nextMarketSessionBoundary(after now: Date = .now) -> Date? {
        let calendar = chinaCalendar
        var day = calendar.startOfDay(for: now)

        for _ in 0..<366 {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }

            guard isFundTradingDay(day) else { continue }

            // 包含 9:15 集合竞价边界：使盘前排期能精确卡到集合竞价开启时刻，
            // 自动刷新以切换到新交易日的当日估值（无需手动点击状态栏）。
            for minutes in [callAuctionStartMinutes, 9 * 60 + 30, 11 * 60 + 30, 13 * 60, 15 * 60] {
                guard let boundary = calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: day
                ),
                    boundary > now
                else {
                    continue
                }

                return boundary
            }
        }

        return nil
    }

    /// 给定分钟数是否处于开市提醒时刻。
    static func isMarketOpenReminderTime(minutes: Int) -> Bool {
        marketSessionState(minutes: minutes, isTradingDay: true) == .open
    }

    /// 生成后续若干交易日的开市提醒时间（用于本地通知排程）。
    static func nextMarketOpenReminderDates(
        minutes: Int,
        from now: Date = .now,
        limit: Int = operationReminderScheduleLimit
    ) -> [Date] {
        guard limit > 0,
              isMarketOpenReminderTime(minutes: minutes)
        else {
            return []
        }

        let calendar = chinaCalendar
        var dates: [Date] = []
        var day = calendar.startOfDay(for: now)
        let hour = minutes / 60
        let minute = minutes % 60

        while dates.count < limit {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }

            guard isFundTradingDay(day),
                  let reminderDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  reminderDate > now
            else {
                continue
            }

            dates.append(reminderDate)
        }

        return dates
    }

    /// 将日期转为带上海时区的通知组件。
    static func notificationDateComponents(from date: Date) -> DateComponents {
        let calendar = chinaCalendar
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }

    /// 按分钟数判定时段状态（核心判定逻辑）。
    private static func marketSessionState(minutes: Int, isTradingDay: Bool) -> MarketSessionState {
        guard isTradingDay else { return .closed }

        let morningOpen = 9 * 60 + 30
        let morningClose = 11 * 60 + 30
        let afternoonOpen = 13 * 60
        let afternoonClose = 15 * 60

        if (morningOpen..<morningClose).contains(minutes) || (afternoonOpen..<afternoonClose).contains(minutes) {
            return .open
        }
        if (morningClose..<afternoonOpen).contains(minutes) {
            return .middayBreak
        }
        return .closed
    }

    /// 返回给定日期之后的下一个交易日。
    private static func nextFundTradingDay(after date: Date) -> Date {
        var currentDate = date
        repeat {
            currentDate = chinaCalendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        } while !isFundTradingDay(currentDate)
        return currentDate
    }

    /// 将持仓日期规整为可接受的交易日（15 点前且为交易日则当日，否则顺延）。
    private static func acceptedTradeDate(from date: Date, timeType: PositionTimeType) -> Date {
        if timeType == .before15, isFundTradingDay(date) {
            return date
        }
        return nextFundTradingDay(after: date)
    }
}
