import XCTest
@testable import RedFund

/// 验证新浪分时曲线的解析与口径转换。
///
/// 解析走 `parseIntradayPoints(from:code:)`，与网络解耦，可直接喂真实报文结构，
/// 覆盖单位换算、日期格式、15:00 截断与排序这些**真正会出错**的环节——
/// 仅用"无数据的基金代码"做测试是覆盖不到它们的。
final class SinaQuoteServiceTests: XCTestCase {

    private func china(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    private func show(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000))
    }

    // MARK: - 解析

    func testParseConvertsGrowthRateToPercentAndBuildsTimestamp() {
        // 真实报文结构：growthrate 是小数，pre_date 是带横杠的 yyyy-MM-dd。
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"09:30:00","growthrate":-0.011509,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"10:15:00","growthrate":0.0242,"pre_date":"2026-08-31"}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        XCTAssertEqual(points.count, 2)
        // 小数 → 百分数（项目内统一口径）
        XCTAssertEqual(points[0].rate, -1.1509, accuracy: 1e-9)
        XCTAssertEqual(points[1].rate, 2.42, accuracy: 1e-9)
        // 上海时区下的时刻（02:30 UTC + 8 = 09:30）
        XCTAssertEqual(show(points[0].timestamp), "08-31 09:30")
        XCTAssertEqual(show(points[1].timestamp), "08-31 10:15")
    }

    /// 新浪曲线会延伸到 16:04，而东财 15:00 后停更 → 必须截断对齐，否则横轴多出一段。
    func testParseTruncatesPointsAfterMarketClose() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"14:59:00","growthrate":-0.02,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"15:00:00","growthrate":-0.021,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"15:30:00","growthrate":-0.022,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"16:04:00","growthrate":-0.023,"pre_date":"2026-08-31"}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        XCTAssertEqual(points.count, 2, "15:00 之后（含 15:30 / 16:04）应被截断")
        XCTAssertEqual(show(points.last!.timestamp), "08-31 15:00")
    }

    /// 乱序输入也要输出升序——曲线渲染依赖这一不变量。
    func testParseSortsPointsAscending() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"11:00:00","growthrate":0.01,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"09:30:00","growthrate":0.02,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"10:00:00","growthrate":0.03,"pre_date":"2026-08-31"}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        XCTAssertEqual(points.map { show($0.timestamp) }, ["08-31 09:30", "08-31 10:00", "08-31 11:00"])
    }

    /// 覆盖率不足的基金：networth 为空 → 返回空，调用方据此只展示数据源 1。
    func testParseReturnsEmptyWhenNoNetworth() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[]}}}
        """
        XCTAssertTrue(SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "008999").isEmpty)
    }

    /// 字段缺失/为 null 的点应被跳过，而不是崩溃或产生脏点。
    func testParseSkipsIncompleteRows() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"09:30:00","growthrate":null,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"09:31:00","growthrate":0.01,"pre_date":"2026-08-31"},
          {"symbol":"015053","min_time":"09:32:00","growthrate":0.02,"pre_date":"2026-08-31"}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        // 同日期下只丢弃 growthrate 为 null 的那条，排序结果完全确定。
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map { show($0.timestamp) }, ["08-31 09:31", "08-31 09:32"])
    }

    /// 缺 `pre_date` 的点回退到「今天」。
    /// 必须用**测试的当天日期**断言：写死日期会在跨天后失效（回退值与写死值不再同一天）。
    func testParseFallsBackToTodayWhenPreDateMissing() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"09:31:00","growthrate":0.01}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        XCTAssertEqual(points.count, 1)
        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        dayOnly.dateFormat = "MM-dd"
        XCTAssertEqual(show(points[0].timestamp), "\(dayOnly.string(from: Date())) 09:31")
    }

    /// 兼容紧凑日期格式（顶层 worth_date 用的就是 yyyyMMdd）。
    func testParseAcceptsCompactDateFormat() {
        let json = """
        {"result":{"status":{"code":0},"data":{"networth":[
          {"symbol":"015053","min_time":"09:30:00","growthrate":-0.01,"pre_date":"20260831"}
        ]}}}
        """

        let points = SinaQuoteService.parseIntradayPoints(from: Data(json.utf8), code: "015053")

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(show(points[0].timestamp), "08-31 09:30")
    }

    // MARK: - 网络入口的兜底

    func testFetchReturnsEmptyForBlankCode() async {
        let points = await SinaQuoteService.fetchIntradayRatePoints(code: "   ")
        XCTAssertTrue(points.isEmpty)
    }

    func testFetchReturnsEmptyForUnsupportedCode() async {
        // 接口对未知代码返回空 networth；网络不可用时同样返回空。
        // 两种情况下调用方行为一致（只展示数据源 1），故该断言稳定。
        let points = await SinaQuoteService.fetchIntradayRatePoints(code: "999999")
        XCTAssertTrue(points.isEmpty)
    }

    // MARK: - 落盘失效（第二个交易日清除）

    /// 曲线所属交易日的数据：当天与紧接的下一个交易日仍有效，第二个交易日开始清除。
    func testCacheStaleOnlyAfterSecondTradingDay() {
        // 取一个真实交易日为基准（2026-08-31 是周一，交易日）。
        let recorded = SinaQuoteService.nextTradingDay(after: Date(timeIntervalSince1970: 0))!
        // 当天：未过期
        XCTAssertFalse(SinaQuoteService.isCacheStale(recordedTradingDay: recorded, now: recorded))
        // 第一个交易日（T1）：仍保留
        let t1 = SinaQuoteService.nextTradingDay(after: recorded)!
        XCTAssertFalse(SinaQuoteService.isCacheStale(recordedTradingDay: recorded, now: t1))
        // 第二个交易日（T2）：应清除，避免无限增长
        let t2 = SinaQuoteService.nextTradingDay(after: t1)!
        XCTAssertTrue(SinaQuoteService.isCacheStale(recordedTradingDay: recorded, now: t2))
    }

    // MARK: - 盘中不能复用上一交易日的定格曲线

    /// 回归：昨天收盘后落盘的定格曲线，**今天盘中绝不能复用**。
    /// 新浪盘中只返回「到当前时刻为止」的点（09:38 实测仅 6 点），数据是持续增长的；
    /// 若按「第二个交易日才过期」放行昨日数据，今天一整天都会展示昨天的走势。
    func testPreviousTradingDayDataIsNotCurrentTradingDay() {
        let now = china("2026-09-01 10:00:00")   // 周二盘中
        let yesterday = china("2026-08-31 09:30:00") // 周一（上一交易日）

        // 当前有效交易日应为今天
        XCTAssertEqual(
            showDay(SinaQuoteService.currentEffectiveTradingDay(now: now)),
            "2026-09-01"
        )
        // 昨天的数据不再属于当前应展示的交易日
        XCTAssertFalse(SinaQuoteService.isCurrentTradingDay(yesterday, now: now))
        // 今天的数据才属于
        XCTAssertTrue(SinaQuoteService.isCurrentTradingDay(now, now: now))
    }

    /// 盘前（9:15 集合竞价前）应回溯到上一交易日，此时昨日定格曲线仍可复用。
    func testEffectiveTradingDayFallsBackToPreviousDayBeforeCallAuction() {
        let now = china("2026-09-01 08:30:00")   // 周二盘前
        let yesterday = china("2026-08-31 09:30:00")

        XCTAssertEqual(
            showDay(SinaQuoteService.currentEffectiveTradingDay(now: now)),
            "2026-08-31"
        )
        XCTAssertTrue(SinaQuoteService.isCurrentTradingDay(yesterday, now: now))
    }

    /// 周末查看时应回溯到周五，周五的定格曲线仍可复用。
    func testEffectiveTradingDayFallsBackToFridayOnWeekend() {
        let saturday = china("2026-09-05 10:00:00")
        let friday = china("2026-09-04 09:30:00")

        XCTAssertEqual(
            showDay(SinaQuoteService.currentEffectiveTradingDay(now: saturday)),
            "2026-09-04"
        )
        XCTAssertTrue(SinaQuoteService.isCurrentTradingDay(friday, now: saturday))
    }

    private func showDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 跨周末：周五的数据应保留到周一（下一个交易日），周二（第二个交易日）清除。
    func testCacheStaleSpansWeekend() {
        // 找一个周五交易日：从 2026-08-31(周一) 往前推到最近一个周五交易日。
        var friday = Date(timeIntervalSince1970: 0)
        for _ in 0..<400 {
            let candidate = SinaQuoteService.nextTradingDay(after: friday)!
            let weekday = Calendar(identifier: .gregorian)
                .dateComponents([.weekday], from: candidate).weekday!
            if weekday == 6 { friday = candidate; break }
            friday = candidate
        }
        // 周六/周日（非交易日）仍应保留
        let saturday = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: friday)!
        let sunday = Calendar(identifier: .gregorian).date(byAdding: .day, value: 2, to: friday)!
        XCTAssertFalse(SinaQuoteService.isCacheStale(recordedTradingDay: friday, now: saturday))
        XCTAssertFalse(SinaQuoteService.isCacheStale(recordedTradingDay: friday, now: sunday))
        // 周一（下一个交易日）保留
        let monday = SinaQuoteService.nextTradingDay(after: friday)!
        XCTAssertFalse(SinaQuoteService.isCacheStale(recordedTradingDay: friday, now: monday))
        // 周二（第二个交易日）清除
        let tuesday = SinaQuoteService.nextTradingDay(after: monday)!
        XCTAssertTrue(SinaQuoteService.isCacheStale(recordedTradingDay: friday, now: tuesday))
    }
}
