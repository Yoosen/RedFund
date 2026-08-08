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

    /// 从当前时间起，返回下一个交易时段边界（开盘/午休开始/下午开盘/收盘）。
    static func nextMarketSessionBoundary(after now: Date = .now) -> Date? {
        let calendar = chinaCalendar
        var day = calendar.startOfDay(for: now)

        for _ in 0..<366 {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }

            guard isFundTradingDay(day) else { continue }

            for minutes in [9 * 60 + 30, 11 * 60 + 30, 13 * 60, 15 * 60] {
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
