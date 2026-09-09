import XCTest
@testable import RedFund

/// 验证开盘时段的自动刷新间隔计算：应等于用户设置的开盘间隔（1m），而非休市间隔。
final class TradingCalendarIntervalTests: XCTestCase {

    /// 构造上海时区下某交易日的指定时分（周一）。
    private func tradingDayAt(hour: Int, minute: Int) -> Date {
        // 2026-08-31 是给定的"当前"日期（周一），落在交易日区间即可。
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31 // 周一
        components.hour = hour
        components.minute = minute
        components.second = 0
        // 使用东八区构造，确保与 TradingCalendar 内部 chinaCalendar 时区一致。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar.date(from: components)!
    }

    func testMarketSessionStateDuringOpen() {
        let morning = tradingDayAt(hour: 10, minute: 15)
        XCTAssertEqual(TradingCalendar.marketSessionState(now: morning), .open, "10:15 应为开盘")

        let afternoon = tradingDayAt(hour: 14, minute: 15)
        XCTAssertEqual(TradingCalendar.marketSessionState(now: afternoon), .open, "14:15 应为开盘")
    }

    /// 开盘时段 nextQuietWakeTime 必须返回 nil，否则会被它覆盖成很长的静默唤醒间隔。
    func testNextQuietWakeTimeIsNilDuringOpen() {
        let morning = tradingDayAt(hour: 10, minute: 15)
        XCTAssertNil(TradingCalendar.nextQuietWakeTime(after: morning), "开盘 10:15 不应有静默定点唤醒")

        let lateMorning = tradingDayAt(hour: 11, minute: 15)
        XCTAssertNil(TradingCalendar.nextQuietWakeTime(after: lateMorning), "开盘 11:15 不应有静默定点唤醒")

        let afternoon = tradingDayAt(hour: 14, minute: 15)
        XCTAssertNil(TradingCalendar.nextQuietWakeTime(after: afternoon), "开盘 14:15 不应有静默定点唤醒")
    }

    /// 开盘时 nextMarketSessionBoundary 应返回下一个边界（11:30 / 13:00 / 15:00），且远大于 1m。
    func testNextMarketSessionBoundaryDuringOpen() {
        let morning = tradingDayAt(hour: 10, minute: 15)
        let boundary = TradingCalendar.nextMarketSessionBoundary(after: morning)
        XCTAssertNotNil(boundary)
        if let boundary {
            let interval = boundary.timeIntervalSince(morning)
            // 到 11:30 约 75 分钟，远大于 60s。
            XCTAssertGreaterThan(interval, 60, "开盘到边界的间隔应大于 1m")
        }
    }

    // MARK: - 静止时段的定点唤醒（跨夜边界）

    /// 构造上海时区下的任意时刻。
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    /// 回归锁定：0:00–0:30 属「前一晚净值公布尾巴」，必须返回 nil 走普通间隔，
    /// 不能排到次日 8:00——否则会跳过整个交易日的盘中估值与当晚净值配对。
    func testQuietPeriodWakeTimeIsNilDuringLateNightTail() {
        XCTAssertNil(
            TradingCalendar.nextQuietPeriodWakeTime(after: date("2026-08-31 00:05:00")),
            "0:05 应回退到普通间隔，不能排定点唤醒"
        )
        XCTAssertNil(
            TradingCalendar.nextQuietPeriodWakeTime(after: date("2026-08-31 00:25:00")),
            "0:25 应回退到普通间隔，不能排到次日 8:00"
        )
        XCTAssertNil(
            TradingCalendar.nextQuietPeriodWakeTime(after: date("2026-08-31 00:29:59")),
            "0:29:59 仍属净值公布尾巴"
        )
    }

    /// 0:30 起进入静止时段，定点唤醒应落在**当天**的 8:00 / 9:00 / 9:15。
    func testQuietPeriodWakeTimeStaysOnSameDayFromEarlyMorning() {
        let wake = TradingCalendar.nextQuietPeriodWakeTime(after: date("2026-08-31 00:31:00"))
        XCTAssertNotNil(wake)
        if let wake {
            XCTAssertEqual(wake, date("2026-08-31 08:00:00"), "0:31 应排到当天 8:00")
        }

        let lateWake = TradingCalendar.nextQuietPeriodWakeTime(after: date("2026-08-31 09:10:00"))
        XCTAssertEqual(lateWake, date("2026-08-31 09:15:00"), "9:10 应排到当天 9:15 集合竞价")
    }

    /// 核心回归：任何时刻的定点唤醒间隔都不得跨越 24 小时（历史上曾出现 31.6 小时空窗）。
    func testQuietWakeNeverSpansMoreThanADay() {
        // 覆盖 0:00-0:30 的每一分钟，以及 0:30-9:15 的若干采样点。
        let candidates = (0..<30).map { date(String(format: "2026-08-31 00:%02d:00", $0)) }
            + [date("2026-08-31 03:00:00"), date("2026-08-31 07:59:00"), date("2026-08-31 09:14:00")]

        for moment in candidates {
            if let wake = TradingCalendar.nextQuietWakeTime(after: moment) {
                let interval = wake.timeIntervalSince(moment)
                XCTAssertLessThanOrEqual(
                    interval, 24 * 3600,
                    "\(moment) 的唤醒间隔 \(interval)s 超过 24 小时（会跳过整个交易日）"
                )
                XCTAssertGreaterThan(interval, 0, "\(moment) 的唤醒时刻必须在未来")
            }
        }
    }

    // MARK: - 集合竞价时段（9:15-9:30）

    /// 集合竞价期间盘中估值已开始产生，必须被识别为"需要按开盘频率刷新"的时段，
    /// 否则会被 marketSessionState 判为 .closed 而退化成休市间隔（用户常设 30m）。
    func testIsCallAuctionPeriodCovers915To930() {
        XCTAssertTrue(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 9, minute: 15)),
            "9:15 集合竞价开始即应算作竞价时段"
        )
        XCTAssertTrue(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 9, minute: 20)),
            "9:20 应算作竞价时段"
        )
        XCTAssertTrue(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 9, minute: 29)),
            "9:29 应算作竞价时段"
        )

        XCTAssertFalse(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 9, minute: 14)),
            "9:14 尚未开始集合竞价"
        )
        XCTAssertFalse(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 9, minute: 30)),
            "9:30 已正式开盘，属于 .open 而非竞价时段"
        )
        XCTAssertFalse(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 10, minute: 0)),
            "10:00 已开盘"
        )
        XCTAssertFalse(
            TradingCalendar.isCallAuctionPeriod(now: tradingDayAt(hour: 12, minute: 0)),
            "午休不属于竞价时段"
        )
    }

    /// 竞价时段若命中"静默定点唤醒"，就会用很长的唤醒间隔覆盖用户设置的开盘频率。
    /// 必须返回 nil，排期才能落到"按开盘间隔刷新"的分支。
    func testNextQuietWakeTimeIsNilDuringCallAuction() {
        for minute in [15, 20, 25, 29] {
            let moment = tradingDayAt(hour: 9, minute: minute)
            XCTAssertNil(
                TradingCalendar.nextQuietWakeTime(after: moment),
                "9:\(minute) 集合竞价期间不应命中静默定点唤醒"
            )
        }
    }

    /// 竞价时段应能取到下一个交易时段边界 9:30，从而"开盘即刷新"。
    func testNextMarketSessionBoundaryDuringCallAuctionIs930() {
        let moment = tradingDayAt(hour: 9, minute: 20)
        let boundary = TradingCalendar.nextMarketSessionBoundary(after: moment)
        XCTAssertEqual(
            boundary,
            tradingDayAt(hour: 9, minute: 30),
            "竞价时段应排到 9:30 正式开盘这一边界"
        )
    }
}
