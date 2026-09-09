import Foundation

/// 波段信号·分区：综合评分所在的「历史价位」区位。
enum BandZone: String, Equatable {
    /// < 0.3 历史低位（买区）
    case low
    /// 0.3~0.7 中性
    case neutral
    /// > 0.7 历史高位（卖区）
    case high
}

/// 波段信号·操作建议（7 档）。
enum BandAction: String, Equatable {
    case strongBuy   // 逢低建仓
    case buy         // 买入区间
    case wait        // 谨慎观望
    case hold        // 中性/持仓观望
    case sell        // 分批减仓
    case strongSell  // 止盈离场
}

/// 波段信号·单日评分（综合 + 5 分项原始归一值）。
struct BandSignalPoint: Equatable {
    /// yyyy-MM-dd
    let date: String
    /// 综合评分 0~1：低=历史低位（买），高=历史高位（卖）。
    let score: Double
    let zone: BandZone
    let indicators: Indicators

    struct Indicators: Equatable {
        /// 252 日窗口内历史分位（0~1）。
        let percentile: Double
        /// 252 日窗口 Z-Score 映射（0~1，±3σ 满量程）。
        let zScore: Double
        /// 20 日布林带 %B（0~1）。
        let bollingerB: Double
        /// 60 日均线乖离率映射（0~1，±12% 满量程）。
        let bias: Double
        /// RSI(14)/100（0~1）。
        let rsi: Double
    }
}

/// 波段信号·策略回测结果。
struct BandBacktest: Equatable {
    /// 区间内产生的买入信号次数。
    let buyCount: Int
    /// 区间内产生的卖出信号次数。
    let sellCount: Int
    /// 已平仓交易胜率（%）。
    let winRate: Double
    /// 策略收益（%）。信号全仓进出、初始 1 万、按当日净值成交、不计手续费。
    let strategyReturn: Double
    /// 自然收益（%）。买入持有。
    let buyHoldReturn: Double
    /// 超额收益（%）= 策略收益 − 自然收益。
    let excessReturn: Double
    /// 回测结束时是否仍持仓。
    let isHolding: Bool

    static let empty = BandBacktest(
        buyCount: 0,
        sellCount: 0,
        winRate: 0,
        strategyReturn: 0,
        buyHoldReturn: 0,
        excessReturn: 0,
        isHolding: false
    )
}

/// 波段信号·7 档建议：标签 + 一句话说明 + 语义动作。
struct BandRecommendation: Equatable {
    let label: String
    let desc: String
    let action: BandAction
}

/// 波段信号·单点序列输入（升序，旧→新）。
///
/// 值口径：**单位净值（单位净值）**，与 fund.cc.cd 权威实现一致——
/// 其信号函数 `s(e)` 直接读取 `e.value`（原始净值）。`netValueType:"adjusted"`
/// 仅用于填充展示字段，不参与信号计算。盘中估值与单位净值同尺度可直接拼接。
struct BandSeriesPoint: Equatable {
    let date: String
    let value: Double
}

// MARK: - 算法常量（与基估宝参考站保持一致）

private enum Constant {
    static let minPoints = 20
    static let longWindow = 252
    static let bollWindow = 20
    static let maWindow = 60
    static let rsiPeriod = 14

    // 权重
    static let wPercentile = 0.30
    static let wZScore = 0.20
    static let wBollingerB = 0.20
    static let wBias = 0.15
    static let wRSI = 0.15

    // 评分阈值
    static let lowThreshold = 0.3
    static let highThreshold = 0.7
}

// MARK: - 内部工具

private func clamp01(_ v: Double) -> Double {
    v < 0 ? 0 : (v > 1 ? 1 : v)
}

private func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

/// 总体标准差（σ，除以 n；与参考站一致）。
private func populationStddev(_ values: [Double], mean: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return variance.squareRoot()
}

/// RSI(14) 序列，Wilder 平滑，结果归一到 0~1（RSI/100）。
/// 数据不足（有效点 ≤ 14）时全部返回中性 0.5。
private func rsiSeries(_ values: [Double?]) -> [Double] {
    var out = Array(repeating: 0.5, count: values.count)
    var start = 0
    while start < values.count && values[start] == nil { start += 1 }
    guard values.count - start > Constant.rsiPeriod else { return out }

    var gain = 0.0
    var loss = 0.0
    var prev: Double? = values[start]
    var i = start + 1
    var n = 0

    // 前 RSI_PERIOD 个变动：简单平均
    while i < values.count && n < Constant.rsiPeriod {
        guard let cur = values[i], let p = prev else {
            i += 1
            continue
        }
        let diff = cur - p
        if diff > 0 { gain += diff } else { loss += abs(diff) }
        prev = cur
        n += 1
        i += 1
    }
    guard n >= Constant.rsiPeriod else { return out }

    var avgGain = gain / Double(Constant.rsiPeriod)
    var avgLoss = loss / Double(Constant.rsiPeriod)
    let idx = i - 1
    out[idx] = avgLoss == 0
        ? 1.0
        : (100.0 - 100.0 / (1.0 + avgGain / avgLoss)) / 100.0

    // 之后：Wilder 平滑 (13×prev + x) / 14
    while i < values.count {
        guard let cur = values[i], let p = prev else {
            i += 1
            continue
        }
        let diff = cur - p
        let g = diff > 0 ? diff : 0
        let l = diff < 0 ? abs(diff) : 0
        avgGain = (13.0 * avgGain + g) / Double(Constant.rsiPeriod)
        avgLoss = (13.0 * avgLoss + l) / Double(Constant.rsiPeriod)
        out[i] = avgLoss == 0
            ? 1.0
            : (100.0 - 100.0 / (1.0 + avgGain / avgLoss)) / 100.0
        prev = cur
        i += 1
    }
    return out
}

// MARK: - 主计算

/// 逐日输出综合评分。
///
/// 窗口按可用数据自动收缩（早期数据不足时取 `min(已有天数, 窗口)`），
/// 与基估宝参考站语义一致；评分 = 5 项归一值的加权和，结果 clamp 到 [0, 1]。
///
/// - Parameter series: 升序（旧→新）的净值序列；值请用复权口径。
/// - Returns: 至少 20 个有效点才能产出信号，否则返回空数组（UI 降级为「数据不足」）。
func computeBandSignal(_ series: [BandSeriesPoint]) -> [BandSignalPoint] {
    guard series.count >= Constant.minPoints else { return [] }

    let values: [Double?] = series.map { point in
        guard point.value.isFinite, point.value > 0 else { return nil }
        return point.value
    }
    let rsi = rsiSeries(values)
    var result: [BandSignalPoint] = []
    result.reserveCapacity(series.count)

    for t in 0..<values.count {
        guard let cur = values[t] else { continue }
        let pos = t + 1
        guard pos >= Constant.minPoints else { continue }

        let win252 = min(pos, Constant.longWindow)
        let win20 = min(pos, Constant.bollWindow)
        let win60 = min(pos, Constant.maWindow)

        // ① 历史分位（窗口 252）：窗口内小于当前值的比例（当前点不计入分母）
        let windowStart252 = max(0, t - win252 + 1)
        var count = 0
        var below = 0
        for k in windowStart252...t {
            guard let v = values[k] else { continue }
            count += 1
            if v < cur { below += 1 }
        }
        let percentile: Double = count > 1 ? Double(below) / Double(count - 1) : 0.5

        // ② Z-Score（窗口 252）：(x-μ)/σ 映射到 0~1，±3σ 满量程
        var seg252: [Double] = []
        seg252.reserveCapacity(win252)
        for k in windowStart252...t {
            if let v = values[k] { seg252.append(v) }
        }
        let mean252 = average(seg252)
        let std252 = populationStddev(seg252, mean: mean252)
        let zScore: Double = std252 == 0
            ? 0.5
            : clamp01(((cur - mean252) / std252 + 3.0) / 6.0)

        // ③ 布林带 %B（窗口 20，2σ）：(x − 下轨) / (上轨 − 下轨)
        let windowStart20 = max(0, t - win20 + 1)
        var seg20: [Double] = []
        seg20.reserveCapacity(win20)
        for k in windowStart20...t {
            if let v = values[k] { seg20.append(v) }
        }
        let mean20 = average(seg20)
        let std20 = populationStddev(seg20, mean: mean20)
        let upper = mean20 + 2 * std20
        let lower = mean20 - 2 * std20
        let bollingerB: Double = upper - lower == 0
            ? 0.5
            : clamp01((cur - lower) / (upper - lower))

        // ④ 均线乖离率 BIAS（窗口 60）：((x−MA60)/MA60×100 + 12) / 24
        let windowStart60 = max(0, t - win60 + 1)
        var seg60: [Double] = []
        seg60.reserveCapacity(win60)
        for k in windowStart60...t {
            if let v = values[k] { seg60.append(v) }
        }
        let ma60 = average(seg60)
        let bias: Double = ma60 == 0
            ? 0.5
            : clamp01(((cur - ma60) / ma60 * 100 + 12) / 24)

        // ⑤ RSI(14)/100
        let rsiN = rsi[t]

        let score = clamp01(
            Constant.wPercentile * percentile
                + Constant.wZScore * zScore
                + Constant.wBollingerB * bollingerB
                + Constant.wBias * bias
                + Constant.wRSI * rsiN
        )
        let zone: BandZone = score > Constant.highThreshold
            ? .high
            : (score < Constant.lowThreshold ? .low : .neutral)

        result.append(BandSignalPoint(
            date: series[t].date,
            score: score,
            zone: zone,
            indicators: .init(
                percentile: percentile,
                zScore: zScore,
                bollingerB: bollingerB,
                bias: bias,
                rsi: rsiN
            )
        ))
    }
    return result
}

// MARK: - 7 档建议

/// 评分 → 7 档建议。
/// 阈值 0.15 / 0.30 / 0.45 / 0.55 / 0.70 / 0.85（与参考站一致）。
func bandRecommendation(for score: Double) -> BandRecommendation {
    if score < 0.15 {
        return BandRecommendation(
            label: "逢低建仓",
            desc: "处于历史极低位，适合分批建仓",
            action: .strongBuy
        )
    }
    if score < 0.30 {
        return BandRecommendation(
            label: "买入区间",
            desc: "处于历史低位，可考虑买入",
            action: .buy
        )
    }
    if score < 0.45 {
        return BandRecommendation(
            label: "谨慎观望",
            desc: "处于偏低区间，建议耐心等待",
            action: .wait
        )
    }
    if score < 0.55 {
        return BandRecommendation(
            label: "中性观望",
            desc: "处于中位区间，暂无明确方向",
            action: .hold
        )
    }
    if score < 0.70 {
        return BandRecommendation(
            label: "持仓观望",
            desc: "处于偏高区间，持仓者可继续持有",
            action: .hold
        )
    }
    if score < 0.85 {
        return BandRecommendation(
            label: "分批减仓",
            desc: "处于历史高位，建议分批减仓",
            action: .sell
        )
    }
    return BandRecommendation(
        label: "止盈离场",
        desc: "处于历史极高位，建议止盈离场",
        action: .strongSell
    )
}

// MARK: - 策略回测

private enum BandTriggerType {
    case buy, sell
}

private struct BandTrigger {
    let date: String
    let type: BandTriggerType
}

/// 策略回测：zone 进入 low 记一次买入、进入 high 记一次卖出（首点即 low 也补买入），
/// 全仓进出、初始 1 万、按当日净值成交、不计手续费。
/// `navSeries` 与 `signals` 同源（升序），仅取有限数值参与结算。
func backtestBandSignal(
    signals: [BandSignalPoint],
    navSeries: [BandSeriesPoint]
) -> BandBacktest {
    guard !signals.isEmpty, !navSeries.isEmpty else { return .empty }

    var navByDate: [String: Double] = [:]
    navByDate.reserveCapacity(navSeries.count)
    for point in navSeries {
        guard point.value.isFinite, point.value > 0 else { continue }
        navByDate[point.date] = point.value
    }

    var first: Double = .nan
    var last: Double = .nan
    for point in navSeries {
        guard point.value.isFinite, point.value > 0 else { continue }
        first = point.value
        break
    }
    for i in stride(from: navSeries.count - 1, through: 0, by: -1) {
        let v = navSeries[i].value
        guard v.isFinite, v > 0 else { continue }
        last = v
        break
    }
    guard first.isFinite, last.isFinite else { return .empty }

    // 信号生成：非 low → low 记买入；非 high → high 记卖出
    var triggers: [BandTrigger] = []
    triggers.reserveCapacity(signals.count)
    for i in 1..<signals.count {
        let prev = signals[i - 1]
        let cur = signals[i]
        if prev.zone != .low, cur.zone == .low {
            triggers.append(BandTrigger(date: cur.date, type: .buy))
        }
        if prev.zone != .high, cur.zone == .high {
            triggers.append(BandTrigger(date: cur.date, type: .sell))
        }
    }
    if signals.first?.zone == .low {
        triggers.insert(
            BandTrigger(date: signals[0].date, type: .buy),
            at: 0
        )
    }

    let initial = 10_000.0
    var cash = initial
    var shares = 0.0
    var open: (date: String, price: Double, shares: Double)? = nil
    var closed = 0
    var wins = 0

    for trigger in triggers {
        guard let price = navByDate[trigger.date], price > 0 else { continue }
        switch trigger.type {
        case .buy where shares == 0:
            shares = cash / price
            cash = 0
            open = (trigger.date, price, shares)
        case .sell where shares > 0:
            if let openTrade = open {
                let proceeds = shares * price
                let cost = openTrade.price * openTrade.shares
                if (proceeds - cost) / cost > 0 { wins += 1 }
                closed += 1
                cash = proceeds
                shares = 0
                open = nil
            }
        default:
            break
        }
    }

    let finalEquity = shares > 0 ? shares * last : cash
    let strategyReturn = (finalEquity - initial) / initial * 100
    let buyHoldReturn = (last - first) / first * 100

    let buyCount = triggers.reduce(0) { $0 + ($1.type == .buy ? 1 : 0) }
    let sellCount = triggers.reduce(0) { $0 + ($1.type == .sell ? 1 : 0) }
    let winRate = closed > 0 ? Double(wins) / Double(closed) * 100 : 0

    return BandBacktest(
        buyCount: buyCount,
        sellCount: sellCount,
        winRate: winRate,
        strategyReturn: strategyReturn,
        buyHoldReturn: buyHoldReturn,
        excessReturn: strategyReturn - buyHoldReturn,
        isHolding: shares > 0
    )
}