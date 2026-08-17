import XCTest
@testable import RedFund

final class PortfolioPerformanceTests: XCTestCase {
    func testRecorderRejectsEmptyPortfolioAndNonFiniteIncome() throws {
        let now = try shanghaiDate("2026-07-15 14:30")

        XCTAssertNil(
            PortfolioPerformanceRecorder.candidate(
                from: .empty,
                now: now,
                allQuotesConfirmed: false
            )
        )

        var invalid = portfolio(todayIncome: .nan, todayIncomeRate: 0.2)
        XCTAssertNil(
            PortfolioPerformanceRecorder.candidate(
                from: invalid,
                now: now,
                allQuotesConfirmed: false
            )
        )

        invalid.todayIncome = 10
        invalid.todayIncomeRate = .infinity
        XCTAssertNil(
            PortfolioPerformanceRecorder.candidate(
                from: invalid,
                now: now,
                allQuotesConfirmed: false
            )
        )
    }

    func testRecorderBuildsShanghaiDatedCandidate() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T16:30:00Z"))

        let candidate = try XCTUnwrap(
            PortfolioPerformanceRecorder.candidate(
                from: portfolio(todayIncome: 12.34, todayIncomeRate: 0.56),
                now: instant,
                allQuotesConfirmed: false
            )
        )

        XCTAssertEqual(candidate.date, "2026-07-15")
        XCTAssertEqual(candidate.profit, 12.34)
        XCTAssertEqual(candidate.returnRate, 0.56)
        XCTAssertEqual(candidate.status, .estimated)
        XCTAssertEqual(candidate.updatedAt, instant)
    }

    func testQuoteConfirmationRequiresCurrentDataForEveryActiveHolding() throws {
        let now = try shanghaiDate("2026-07-15 14:30")
        var snapshot = portfolio(todayIncome: 12, todayIncomeRate: 0.2)
        snapshot.funds[0].isIncomeActive = true
        snapshot.funds.append(
            FundPosition(
                code: "000002",
                name: "第二只基金",
                dateText: "07-15 14:30",
                todayIncome: 2,
                todayRate: 0.1,
                holdingRate: 1,
                status: .holding,
                isUpdated: true,
                isIncomeActive: true
            )
        )
        let official = FundQuote(
            code: "000001",
            name: "测试基金",
            netValue: 1.1,
            estimatedNetValue: 1.1,
            growthRate: 0.2,
            estimateTime: "2026-07-15 14:30",
            netValueDate: "2026-07-15"
        )
        let estimate = FundQuote(
            code: "000002",
            name: "第二只基金",
            netValue: 1,
            estimatedNetValue: 1.01,
            growthRate: 0.1,
            estimateTime: "2026-07-15 14:30",
            netValueDate: "2026-07-14"
        )

        XCTAssertEqual(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": official, "000002": estimate],
                now: now
            ),
            false
        )
        XCTAssertNil(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": official],
                now: now
            )
        )

        var confirmedSecond = estimate
        confirmedSecond.netValueDate = "2026-07-15"
        XCTAssertEqual(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": official, "000002": confirmedSecond],
                now: now
            ),
            true
        )
    }

    func testQuoteConfirmationIgnoresLaggingQDIIQuote() throws {
        let now = try shanghaiDate("2026-07-28 14:30")
        var snapshot = portfolio(todayIncome: 12, todayIncomeRate: 0.2)
        snapshot.funds[0].isIncomeActive = true
        snapshot.funds.append(
            FundPosition(
                code: "012920",
                name: "QDII基金",
                dateText: "07-24 15:00",
                todayIncome: 0,
                todayRate: 0,
                holdingRate: 1,
                status: .holding,
                isUpdated: false,
                isIncomeActive: true
            )
        )
        let domesticEstimate = FundQuote(
            code: "000001",
            name: "测试基金",
            netValue: 1.1,
            estimatedNetValue: 1.1,
            growthRate: 0.2,
            estimateTime: "2026-07-28 14:30",
            netValueDate: "2026-07-27"
        )
        let laggingQDIIQuote = FundQuote(
            code: "012920",
            name: "QDII基金",
            netValue: 3.8989,
            estimatedNetValue: 4.0528,
            growthRate: 0.19,
            estimateTime: "2026-07-25 04:00",
            netValueDate: "2026-07-24"
        )

        // QDII 行情滞后（净值 T+1 披露、估值时间非当日）时不再否决整个组合的记录。
        XCTAssertEqual(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": domesticEstimate, "012920": laggingQDIIQuote],
                now: now
            ),
            false
        )

        // 海外/QDII 基金产生「当日」但北京时间开盘前的估算（如 04:00）时，
        // 不应阻止 A 股基金官方净值确认。
        let domesticConfirmed = FundQuote(
            code: "000001",
            name: "测试基金",
            netValue: 1.1,
            estimatedNetValue: 1.1,
            growthRate: 0.2,
            estimateTime: "2026-07-28 15:00",
            netValueDate: "2026-07-28"
        )
        let qdiiTodayOverseasEstimate = FundQuote(
            code: "012920",
            name: "QDII基金",
            netValue: 3.8989,
            estimatedNetValue: 4.0528,
            growthRate: 0.19,
            estimateTime: "2026-07-28 04:00",
            netValueDate: "2026-07-27"
        )
        XCTAssertEqual(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": domesticConfirmed, "012920": qdiiTodayOverseasEstimate],
                now: now
            ),
            true
        )

        // 滞后净值（净值日期落后超过一个交易日）在刷新当日被揭示时，其涨幅归属当日并记录。
        let staleDomestic = FundQuote(
            code: "000001",
            name: "测试基金",
            netValue: 1.1,
            estimatedNetValue: 1.1,
            growthRate: 0.2,
            estimateTime: "2026-07-27 15:00",
            netValueDate: "2026-07-26"
        )
        XCTAssertEqual(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": staleDomestic, "012920": laggingQDIIQuote],
                now: now
            ),
            true
        )

        // 行情整体缺失时仍不记录。
        XCTAssertNil(
            PortfolioPerformanceRecorder.quoteConfirmationState(
                portfolio: snapshot,
                quotes: ["000001": domesticEstimate],
                now: now
            )
        )
    }

    func testSameDayEstimateUpgradesToConfirmedAndCannotDowngrade() throws {
        let morning = try shanghaiDate("2026-07-15 10:00")
        let evening = try shanghaiDate("2026-07-15 21:00")
        let later = try shanghaiDate("2026-07-15 22:00")
        var snapshot = PortfolioPerformanceSnapshot.empty

        let estimate = try XCTUnwrap(
            PortfolioPerformanceRecorder.candidate(
                from: portfolio(todayIncome: 10, todayIncomeRate: 0.1),
                now: morning,
                allQuotesConfirmed: false
            )
        )
        snapshot = PortfolioPerformanceRecorder.recording(estimate, in: snapshot)

        let confirmed = try XCTUnwrap(
            PortfolioPerformanceRecorder.candidate(
                from: portfolio(todayIncome: 16, todayIncomeRate: 0.16),
                now: evening,
                allQuotesConfirmed: true
            )
        )
        snapshot = PortfolioPerformanceRecorder.recording(confirmed, in: snapshot)

        let lateEstimate = PortfolioPerformanceRecorder.Candidate(
            date: "2026-07-15",
            profit: 99,
            returnRate: 0.99,
            status: .estimated,
            updatedAt: later
        )
        snapshot = PortfolioPerformanceRecorder.recording(lateEstimate, in: snapshot)

        XCTAssertEqual(snapshot.trackingStartDate, "2026-07-15")
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertEqual(snapshot.days[0].profit, 16)
        XCTAssertEqual(snapshot.days[0].returnRate, 0.16)
        XCTAssertEqual(snapshot.days[0].status, .confirmed)
        XCTAssertEqual(snapshot.days[0].updatedAt, evening)
    }

    func testRecordsAreSortedAndStaleSameStatusUpdateIsIgnored() throws {
        let newer = try shanghaiDate("2026-07-16 10:00")
        let older = try shanghaiDate("2026-07-16 09:00")
        let candidates = [
            candidate("2026-07-17", profit: -4, updatedAt: newer),
            candidate("2026-07-15", profit: 2, updatedAt: newer),
            candidate("2026-07-16", profit: 3, updatedAt: newer),
            candidate("2026-07-16", profit: 100, updatedAt: older)
        ]

        let snapshot = candidates.reduce(PortfolioPerformanceSnapshot.empty) {
            PortfolioPerformanceRecorder.recording($1, in: $0)
        }

        XCTAssertEqual(snapshot.trackingStartDate, "2026-07-15")
        XCTAssertEqual(snapshot.days.map(\.date), ["2026-07-15", "2026-07-16", "2026-07-17"])
        XCTAssertEqual(snapshot.days.map(\.profit), [2, 3, -4])
    }

    func testCumulativeSeriesIsDerivedBeforeRangeFiltering() throws {
        let update = try shanghaiDate("2026-07-15 15:00")
        // 这些日期均为交易日（避开周末与法定节假日），用于验证区间过滤前已完成累计推导。
        let snapshot = PortfolioPerformanceSnapshot(
            trackingStartDate: "2026-03-02",
            days: [
                day("2026-03-02", profit: 100, updatedAt: update),
                day("2026-06-15", profit: -20, updatedAt: update),
                day("2026-06-16", profit: 10, updatedAt: update),
                day("2026-07-15", profit: 5, updatedAt: update)
            ]
        )

        let allPoints = PortfolioPerformanceSeries.cumulativePoints(in: snapshot)
        let monthPoints = PortfolioPerformanceSeries.points(
            in: snapshot,
            range: .oneMonth,
            through: try shanghaiDate("2026-07-15 20:00")
        )

        XCTAssertEqual(allPoints.map(\.cumulativeProfit), [100, 80, 90, 95])
        XCTAssertEqual(monthPoints.map(\.day.date), ["2026-06-15", "2026-06-16", "2026-07-15"])
        XCTAssertEqual(monthPoints.map(\.cumulativeProfit), [80, 90, 95])
    }

    func testRangeFilteringSupportsNaturalMonthQuarterYearAndAll() throws {
        let update = try shanghaiDate("2026-07-15 15:00")
        let snapshot = PortfolioPerformanceSnapshot(
            trackingStartDate: "2025-07-14",
            days: [
                day("2025-07-14", profit: 1, updatedAt: update),
                day("2025-07-15", profit: 1, updatedAt: update),
                day("2026-01-15", profit: 1, updatedAt: update),
                day("2026-04-15", profit: 1, updatedAt: update),
                day("2026-06-15", profit: 1, updatedAt: update),
                day("2026-07-15", profit: 1, updatedAt: update)
            ]
        )
        let end = try shanghaiDate("2026-07-15 23:00")

        XCTAssertEqual(PortfolioPerformanceSeries.points(in: snapshot, range: .oneMonth, through: end).count, 2)
        XCTAssertEqual(PortfolioPerformanceSeries.points(in: snapshot, range: .threeMonths, through: end).count, 3)
        XCTAssertEqual(PortfolioPerformanceSeries.points(in: snapshot, range: .sixMonths, through: end).count, 4)
        XCTAssertEqual(PortfolioPerformanceSeries.points(in: snapshot, range: .oneYear, through: end).count, 5)
        XCTAssertEqual(PortfolioPerformanceSeries.points(in: snapshot, range: .all, through: end).count, 6)
    }

    func testMonthGridUsesSundayFirstAndHandlesLeapFebruary() throws {
        let grid = PortfolioPerformanceCalendar.grid(
            monthContaining: try shanghaiDate("2024-02-20 12:00")
        )

        XCTAssertEqual(grid.monthKey, "2024-02")
        XCTAssertEqual(grid.cells.count, 35)
        XCTAssertEqual(Array(grid.cells.prefix(4)), [nil, nil, nil, nil])
        XCTAssertEqual(grid.cells[4], "2024-02-01")
        XCTAssertEqual(grid.cells[32], "2024-02-29")
        XCTAssertEqual(Array(grid.cells.suffix(2)), [nil, nil])
    }

    func testCalendarMonthSummaryDoesNotLeakAdjacentMonthRecords() throws {
        let update = try shanghaiDate("2026-07-15 15:00")
        let snapshot = PortfolioPerformanceSnapshot(
            trackingStartDate: "2026-06-30",
            days: [
                day("2026-06-30", profit: 100, updatedAt: update),
                day("2026-07-01", profit: 10, updatedAt: update),
                day("2026-07-02", profit: -3, updatedAt: update),
                day("2026-08-01", profit: 50, updatedAt: update)
            ]
        )

        let summary = PortfolioPerformanceCalendar.summary(
            in: snapshot,
            monthContaining: try shanghaiDate("2026-07-15 12:00")
        )

        XCTAssertEqual(summary.totalProfit, 7)
        XCTAssertEqual(summary.riseDays, 1)
        XCTAssertEqual(summary.fallDays, 1)
        XCTAssertEqual(summary.estimatedDays, 0)
        XCTAssertEqual(summary.days.map(\.date), ["2026-07-01", "2026-07-02"])
    }

    @MainActor
    func testStoreLoadsMissingEmptyAndLegacyFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PortfolioPerformanceStore(dataDirectory: directory)

        XCTAssertEqual(store.snapshot, .empty)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: store.dataFileURL)
        store.load()
        XCTAssertEqual(store.snapshot, .empty)

        let legacy = """
        {
          "days" : [
            {
              "date" : "2026-07-15",
              "profit" : 8.5,
              "returnRate" : 0.2,
              "status" : "estimated",
              "updatedAt" : "2026-07-15T02:00:00Z"
            }
          ]
        }
        """
        try XCTUnwrap(legacy.data(using: .utf8)).write(to: store.dataFileURL, options: .atomic)
        store.load()

        XCTAssertEqual(store.snapshot.schemaVersion, PortfolioPerformanceSnapshot.currentSchemaVersion)
        XCTAssertEqual(store.snapshot.trackingStartDate, "2026-07-15")
        XCTAssertEqual(store.snapshot.days.count, 1)
    }

    @MainActor
    func testUnreadableHistoryIsNeverOverwrittenByAutomaticRecording() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "portfolio-performance.json")
        let unreadableData = Data("{not-valid-json".utf8)
        try unreadableData.write(to: fileURL, options: .atomic)

        let store = PortfolioPerformanceStore(dataDirectory: directory)
        let originalError = try XCTUnwrap(store.lastError)

        XCTAssertTrue(store.hasUnreadablePersistedData)
        XCTAssertFalse(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: try shanghaiDate("2026-07-15 10:00"),
                allQuotesConfirmed: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), unreadableData)
        XCTAssertEqual(store.lastError, originalError)

        try store.replace(.empty)
        XCTAssertFalse(store.hasUnreadablePersistedData)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testFutureSchemaHistoryIsNeverDowngradedOrExported() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "portfolio-performance.json")
        let futureSnapshot = PortfolioPerformanceSnapshot(
            schemaVersion: PortfolioPerformanceSnapshot.currentSchemaVersion + 1,
            trackingStartDate: "2026-07-15",
            days: [day("2026-07-15", profit: 20, updatedAt: try shanghaiDate("2026-07-15 10:00"))]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let futureData = try encoder.encode(futureSnapshot)
        try futureData.write(to: fileURL, options: .atomic)

        let store = PortfolioPerformanceStore(dataDirectory: directory)

        XCTAssertTrue(store.hasUnreadablePersistedData)
        XCTAssertTrue(store.snapshot.days.isEmpty)
        XCTAssertThrowsError(try store.exportSnapshot())
        XCTAssertFalse(
            store.record(
                portfolio: portfolio(todayIncome: 30, todayIncomeRate: 0.6),
                now: try shanghaiDate("2026-07-15 11:00"),
                allQuotesConfirmed: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), futureData)
    }

    @MainActor
    func testStoreClearPersistsAnEmptySnapshot() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PortfolioPerformanceStore(dataDirectory: directory)
        let now = try shanghaiDate("2026-07-15 10:00")

        XCTAssertTrue(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: now,
                allQuotesConfirmed: false
            )
        )
        XCTAssertTrue(store.clear())

        let reloaded = PortfolioPerformanceStore(dataDirectory: directory)
        XCTAssertEqual(reloaded.snapshot, .empty)
    }

    @MainActor
    func testUnchangedEstimateDoesNotRewriteHistoryOnEveryRefresh() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PortfolioPerformanceStore(dataDirectory: directory)
        let todayString = DateOnlyFormatter.string(from: Date())
        let first = try shanghaiDate("\(todayString) 10:00")
        let later = try shanghaiDate("\(todayString) 10:01")

        XCTAssertTrue(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: first,
                allQuotesConfirmed: false
            )
        )
        XCTAssertFalse(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: later,
                allQuotesConfirmed: false
            )
        )
        XCTAssertEqual(store.snapshot.days.count, 1)
        XCTAssertEqual(store.snapshot.days.first?.updatedAt, first)
    }

    /// 历史交易日一旦被回填为「已确认」，再次写入相同估值不应回退状态。
    @MainActor
    func testPastEstimatedRecordIsBackfilledToConfirmed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PortfolioPerformanceStore(dataDirectory: directory)
        let first = try shanghaiDate("2026-07-15 10:00")
        let later = try shanghaiDate("2026-07-15 10:01")

        XCTAssertTrue(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: first,
                allQuotesConfirmed: false
            )
        )
        XCTAssertEqual(store.snapshot.days.first?.status, .estimated)

        XCTAssertTrue(
            store.record(
                portfolio: portfolio(todayIncome: 20, todayIncomeRate: 0.5),
                now: later,
                allQuotesConfirmed: false
            )
        )
        XCTAssertEqual(store.snapshot.days.count, 1)
        XCTAssertEqual(store.snapshot.days.first?.status, .confirmed)
        XCTAssertEqual(store.snapshot.days.first?.updatedAt, first)
    }

    @MainActor
    func testStoreImportExportRoundTripNormalizesDuplicateDays() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PortfolioPerformanceStore(dataDirectory: directory)
        let older = try shanghaiDate("2026-07-15 10:00")
        let newer = try shanghaiDate("2026-07-15 21:00")
        let imported = PortfolioPerformanceSnapshot(
            trackingStartDate: nil,
            days: [
                day("2026-07-16", profit: 3, updatedAt: newer),
                day("2026-07-15", profit: 1, updatedAt: older),
                day("2026-07-15", profit: 2, status: .confirmed, updatedAt: newer)
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let input = try encoder.encode(imported)

        try store.importSnapshot(from: input)
        let exported = try store.exportSnapshot()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PortfolioPerformanceSnapshot.self, from: exported)
        XCTAssertEqual(decoded.trackingStartDate, "2026-07-15")
        XCTAssertEqual(decoded.days.map(\.date), ["2026-07-15", "2026-07-16"])
        XCTAssertEqual(decoded.days[0].profit, 2)
        XCTAssertEqual(decoded.days[0].status, .confirmed)
    }

    func testCumulativeSeriesHandlesOneThousandPoints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try shanghaiDate("2023-01-01 12:00")
        let update = try shanghaiDate("2026-07-15 15:00")
        let days = (0..<1_000).compactMap { offset -> PortfolioPerformanceDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return day(DateOnlyFormatter.string(from: date), profit: 1, updatedAt: update)
        }
        let snapshot = PortfolioPerformanceSnapshot(
            trackingStartDate: days.first?.date,
            days: Array(days.reversed())
        )

        let points = PortfolioPerformanceSeries.cumulativePoints(in: snapshot)

        // 过滤非交易日后点数应少于原始连续天数，但仍是有效序列；累计末值不变。
        XCTAssertLessThanOrEqual(points.count, 1_000)
        XCTAssertGreaterThan(points.count, 0)
        // 每个交易日 profit 为 1，过滤后累计末值等于交易日数量。
        XCTAssertEqual(points.last?.cumulativeProfit, Double(points.count))
        // 2023-01-01 为周日，序列首条交易日为 2023-01-02。
        XCTAssertEqual(points.first?.day.date, "2023-01-02")
    }

    func testChartScalePlacesPositiveValuesAboveZeroAndNegativeValuesBelowZero() {
        let scale = PortfolioPerformanceChartScale(values: [-20_715.12, 14_738.06])
        let zeroY = scale.normalizedY(for: 0)

        XCTAssertLessThan(scale.normalizedY(for: 10_000), zeroY)
        XCTAssertGreaterThan(scale.normalizedY(for: -10_000), zeroY)
        XCTAssertEqual(scale.normalizedY(for: scale.maximum), 0, accuracy: 0.000_001)
        XCTAssertEqual(scale.normalizedY(for: scale.minimum), 1, accuracy: 0.000_001)
    }

    func testChartAxisLabelsDoNotDuplicateZeroAtAnExtreme() {
        let positiveValues = [10.0, 30.0]
        let positiveScale = PortfolioPerformanceChartScale(values: positiveValues)
        XCTAssertEqual(
            PortfolioPerformanceChartAxisLabels(values: positiveValues, scale: positiveScale),
            .init(maximum: 30, minimum: nil)
        )

        let negativeValues = [-30.0, -10.0]
        let negativeScale = PortfolioPerformanceChartScale(values: negativeValues)
        XCTAssertEqual(
            PortfolioPerformanceChartAxisLabels(values: negativeValues, scale: negativeScale),
            .init(maximum: nil, minimum: -30)
        )
    }

    func testChartAxisLabelsOnlyShowTheIndependentZeroForAnAllZeroSeries() {
        let values = [0.0, 0.0, 0.0]
        let scale = PortfolioPerformanceChartScale(values: values)

        XCTAssertEqual(
            PortfolioPerformanceChartAxisLabels(values: values, scale: scale),
            .init(maximum: nil, minimum: nil)
        )
        XCTAssertEqual(scale.normalizedY(for: 0), 0.5, accuracy: 0.000_001)
    }

    func testChartAxisLabelsKeepBothNonzeroExtremesForMixedSigns() {
        let values = [-20.0, 10.0]
        let scale = PortfolioPerformanceChartScale(values: values)

        XCTAssertEqual(
            PortfolioPerformanceChartAxisLabels(values: values, scale: scale),
            .init(maximum: 10, minimum: -20)
        )
    }

    func testChartToneUsesPositiveNegativeAndNeutralSemantics() {
        XCTAssertEqual(PortfolioPerformanceChartTone(value: 0.01), .positive)
        XCTAssertEqual(PortfolioPerformanceChartTone(value: -0.01), .negative)
        XCTAssertEqual(PortfolioPerformanceChartTone(value: 0), .neutral)
    }

    func testChartSegmentSplitsColorExactlyWhereCumulativeProfitCrossesZero() {
        XCTAssertEqual(
            PortfolioPerformanceChartColor.segmentPortions(from: 10, to: -30),
            [
                .init(startFraction: 0, endFraction: 0.25, tone: .positive),
                .init(startFraction: 0.25, endFraction: 1, tone: .negative)
            ]
        )
        XCTAssertEqual(
            PortfolioPerformanceChartColor.segmentPortions(from: -30, to: 10),
            [
                .init(startFraction: 0, endFraction: 0.75, tone: .negative),
                .init(startFraction: 0.75, endFraction: 1, tone: .positive)
            ]
        )
        XCTAssertEqual(
            PortfolioPerformanceChartColor.segmentPortions(from: 0, to: -10),
            [.init(startFraction: 0, endFraction: 1, tone: .negative)]
        )
    }

    private func candidate(
        _ date: String,
        profit: Double,
        status: PortfolioPerformanceRecordStatus = .estimated,
        updatedAt: Date
    ) -> PortfolioPerformanceRecorder.Candidate {
        PortfolioPerformanceRecorder.Candidate(
            date: date,
            profit: profit,
            returnRate: profit / 100,
            status: status,
            updatedAt: updatedAt
        )
    }

    private func day(
        _ date: String,
        profit: Double,
        status: PortfolioPerformanceRecordStatus = .confirmed,
        updatedAt: Date
    ) -> PortfolioPerformanceDay {
        PortfolioPerformanceDay(
            date: date,
            profit: profit,
            returnRate: profit / 100,
            status: status,
            updatedAt: updatedAt
        )
    }

    private func portfolio(todayIncome: Double, todayIncomeRate: Double) -> PortfolioSnapshot {
        PortfolioSnapshot(
            updateTime: .now,
            totalAmount: 1_000,
            holdingIncome: 100,
            holdingIncomeRate: 10,
            todayIncome: todayIncome,
            todayIncomeRate: todayIncomeRate,
            pendingCount: 0,
            funds: [
                FundPosition(
                    code: "000001",
                    name: "测试基金",
                    dateText: "07-15 14:30",
                    todayIncome: todayIncome,
                    todayRate: todayIncomeRate,
                    holdingRate: 10,
                    status: .holding,
                    isUpdated: true
                )
            ],
            migration: nil
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "red-fund-performance-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func shanghaiDate(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: value))
    }
}
