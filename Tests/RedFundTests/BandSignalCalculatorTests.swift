import XCTest
@testable import RedFund

/// 验证波段信号计算与回测的核心规则。
///
/// 与参考站口径一致：5 个分项归一加权、7 档建议、跌破 0.3 全仓买入 / 突破 0.7 全仓卖出。
/// 仅覆盖**真正会算错的环节**：分项归一越界、Z-Score 极端值处理、RSI 边界、建议档位映射、
/// 回测触发条件与胜率计算——纯「不传数据」型测试覆盖不到这些。
final class BandSignalCalculatorTests: XCTestCase {

    // MARK: - computeBandSignal

    func testEmptySeriesReturnsEmptyArray() {
        XCTAssertTrue(computeBandSignal([]).isEmpty)
    }

    func testInsufficientPointsDegradesToEmpty() {
        // 19 个点：MIN_POINTS = 20，应降级为空
        let series = makeSeries(values: Array(repeating: 1.0, count: 19))
        XCTAssertTrue(computeBandSignal(series).isEmpty)
    }

    func testExactlyMinPointsProducesOneSignal() {
        let series = makeSeries(values: (1...20).map { Double($0) })
        let result = computeBandSignal(series)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.date, series[19].date)
    }

    func testScoresAreAlwaysWithinZeroOne() {
        // 构造带跳变 + 极端值的序列，覆盖分位/Z/%B/BIAS/RSI 全部边界
        var values: [Double] = []
        for _ in 0..<260 { values.append(Double.random(in: 0.8...1.2)) }
        // 注入一次极端下跌
        values[200] = 0.01
        let series = makeSeries(values: values)
        for signal in computeBandSignal(series) {
            XCTAssertGreaterThanOrEqual(signal.score, 0)
            XCTAssertLessThanOrEqual(signal.score, 1)
        }
    }

    func testZoneMatchesScoreThresholds() {
        var values: [Double] = []
        for _ in 0..<60 { values.append(Double.random(in: 0.8...1.2)) }
        let series = makeSeries(values: values)
        for signal in computeBandSignal(series) {
            if signal.score > 0.7 {
                XCTAssertEqual(signal.zone, .high)
            } else if signal.score < 0.3 {
                XCTAssertEqual(signal.zone, .low)
            } else {
                XCTAssertEqual(signal.zone, .neutral)
            }
        }
    }

    func testMonotonicUpTrendHasHighScore() {
        // 持续单调上涨：最新值应处于历史高位，评分接近 1
        let values = (1...260).map { Double($0) }
        let signals = computeBandSignal(makeSeries(values: values))
        let last = signals.last!
        XCTAssertGreaterThan(last.score, 0.5, "持续上涨末期评分应偏高，实测 \(last.score)")
    }

    func testMonotonicDownTrendHasLowScore() {
        // 持续单调下跌：最新值应处于历史低位，评分接近 0
        let values = (1...260).map { 260.0 - Double($0) + 1 }
        let signals = computeBandSignal(makeSeries(values: values))
        let last = signals.last!
        XCTAssertLessThan(last.score, 0.5, "持续下跌末期评分应偏低，实测 \(last.score)")
    }

    // MARK: - bandRecommendation

    func testRecommendation7LevelsByThresholds() {
        // 边界值校验：< 0.15 / < 0.30 / < 0.45 / < 0.55 / < 0.70 / < 0.85 / 其他
        XCTAssertEqual(bandRecommendation(for: 0.10).action, .strongBuy)
        XCTAssertEqual(bandRecommendation(for: 0.20).action, .buy)
        XCTAssertEqual(bandRecommendation(for: 0.40).action, .wait)
        XCTAssertEqual(bandRecommendation(for: 0.50).action, .hold)
        XCTAssertEqual(bandRecommendation(for: 0.60).action, .hold)
        XCTAssertEqual(bandRecommendation(for: 0.80).action, .sell)
        XCTAssertEqual(bandRecommendation(for: 0.95).action, .strongSell)
    }

    func testRecommendationLabelsMatchReference() {
        XCTAssertEqual(bandRecommendation(for: 0.10).label, "逢低建仓")
        XCTAssertEqual(bandRecommendation(for: 0.20).label, "买入区间")
        XCTAssertEqual(bandRecommendation(for: 0.40).label, "谨慎观望")
        XCTAssertEqual(bandRecommendation(for: 0.50).label, "中性观望")
        XCTAssertEqual(bandRecommendation(for: 0.60).label, "持仓观望")
        XCTAssertEqual(bandRecommendation(for: 0.80).label, "分批减仓")
        XCTAssertEqual(bandRecommendation(for: 0.95).label, "止盈离场")
    }

    // MARK: - backtestBandSignal

    func testBacktestMonotonicUprendHasNoSells() {
        // 缓慢持续上涨（每日 +0.1%，避免早期窗口不稳）
        var values: [Double] = []
        for i in 0..<300 { values.append(1.0 + Double(i) * 0.001) }
        let series = makeSeries(values: values)
        let signals = computeBandSignal(series)
        let result = backtestBandSignal(signals: signals, navSeries: series)

        // 缓慢上涨时不应触发卖出（信号不应进入 high 持续态）
        XCTAssertEqual(result.sellCount, 0)
        XCTAssertGreaterThanOrEqual(result.buyCount, 0)
    }

    func testBacktestEmptySignalsReturnsEmpty() {
        let result = backtestBandSignal(signals: [], navSeries: [])
        XCTAssertEqual(result.buyCount, 0)
        XCTAssertEqual(result.sellCount, 0)
        XCTAssertEqual(result.strategyReturn, 0)
    }

    func testBacktestHandlesExactTriggers() {
        // 手工构造 5 个点的 zone 序列：neutral → low → neutral → high → neutral
        // 期望触发：buy at index 1, sell at index 3
        let signals: [BandSignalPoint] = [
            makeSignal(date: "2026-01-01", score: 0.5, zone: .neutral),
            makeSignal(date: "2026-01-02", score: 0.2, zone: .low),
            makeSignal(date: "2026-01-03", score: 0.5, zone: .neutral),
            makeSignal(date: "2026-01-04", score: 0.8, zone: .high),
            makeSignal(date: "2026-01-05", score: 0.5, zone: .neutral),
        ]
        let navSeries: [BandSeriesPoint] = [
            .init(date: "2026-01-01", value: 1.0),
            .init(date: "2026-01-02", value: 0.95),
            .init(date: "2026-01-03", value: 1.05),
            .init(date: "2026-01-04", value: 1.15),
            .init(date: "2026-01-05", value: 1.10),
        ]
        let result = backtestBandSignal(signals: signals, navSeries: navSeries)
        XCTAssertEqual(result.buyCount, 1)
        XCTAssertEqual(result.sellCount, 1)
        XCTAssertEqual(result.isHolding, false)
        // 0.95 买入 1.15 卖出，盈利 21%，为胜
        XCTAssertEqual(result.winRate, 100, accuracy: 0.01)
    }

    func testBacktestStrategyReturnCalculation() {
        // 简单情景：首日买入(zone=low)，末日卖出(zone=high)，检查策略收益计算
        let signals: [BandSignalPoint] = [
            makeSignal(date: "2026-01-01", score: 0.2, zone: .low),  // 起始即 low 补一次 buy
            makeSignal(date: "2026-01-02", score: 0.8, zone: .high), // 卖出
        ]
        let navSeries: [BandSeriesPoint] = [
            .init(date: "2026-01-01", value: 1.0),
            .init(date: "2026-01-02", value: 1.10),
        ]
        let result = backtestBandSignal(signals: signals, navSeries: navSeries)
        XCTAssertEqual(result.buyCount, 1)
        XCTAssertEqual(result.sellCount, 1)
        // 1.0 → 1.10：策略收益 = +10%
        XCTAssertEqual(result.strategyReturn, 10, accuracy: 0.01)
        // 自然收益 = (1.10 - 1.0) / 1.0 * 100 = 10%
        XCTAssertEqual(result.buyHoldReturn, 10, accuracy: 0.01)
        XCTAssertEqual(result.excessReturn, 0, accuracy: 0.01)
    }

    func testBacktestHandlesLossAsNonWin() {
        // 亏损交易：买入 1.0、卖出 0.9 → 亏损，胜率不计入
        let signals: [BandSignalPoint] = [
            makeSignal(date: "2026-01-01", score: 0.2, zone: .low),
            makeSignal(date: "2026-01-02", score: 0.8, zone: .high),
        ]
        let navSeries: [BandSeriesPoint] = [
            .init(date: "2026-01-01", value: 1.0),
            .init(date: "2026-01-02", value: 0.9),
        ]
        let result = backtestBandSignal(signals: signals, navSeries: navSeries)
        XCTAssertEqual(result.winRate, 0, accuracy: 0.01)
        XCTAssertLessThan(result.strategyReturn, 0)
    }

    // MARK: - Helpers

    private func makeSeries(values: [Double]) -> [BandSeriesPoint] {
        return values.enumerated().map { i, v in
            BandSeriesPoint(date: String(format: "2024-%02d-%02d", i / 28 + 1, i % 28 + 1), value: v)
        }
    }

    private func makeSignal(date: String, score: Double, zone: BandZone) -> BandSignalPoint {
        BandSignalPoint(
            date: date,
            score: score,
            zone: zone,
            indicators: .init(
                percentile: 0.5,
                zScore: 0.5,
                bollingerB: 0.5,
                bias: 0.5,
                rsi: 0.5
            )
        )
    }
}