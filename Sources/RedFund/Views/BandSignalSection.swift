import SwiftUI

// MARK: - Range 选择

/// 波段信号·评分走势的展示区间（与基估宝参考站一致）。
enum BandSignalRange: String, CaseIterable, Identifiable {
    case sixMonths
    case oneYear
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sixMonths: "近半年"
        case .oneYear: "近1年"
        case .all: "全部"
        }
    }

    /// 默认区间长度（用于裁剪历史信号；`all` 不裁剪）。
    var dayLimit: Int? {
        switch self {
        case .sixMonths: 126   // 约半年（半年 ≈ 126 个交易日）
        case .oneYear: 252     // 约一年
        case .all: nil
        }
    }
}

// MARK: - 主 Section

/// 波段信号子栏目：决策板 + 评分走势 + 策略回测。
/// 与 fund-daily `FundDetailDrawer` 中同名区块对齐（评分 0~1、五指标归一、7 档建议）。
///
/// 卡片外框由外层 `trendSection` 统一提供，这里只出内容（不再自带背景/描边）。
///
/// **性能**：`computeBandSignal` 是 O(n × 252) 的逐日计算（每个点都要扫 252 窗口），
/// 若写成 computed property，则**每次 body 求值**都会重跑——切换区间、动画每一帧
/// 都算一遍，直接卡死 UI。这里改为按「数据指纹」缓存进 @State：
/// 只有净值序列真的变化时才重算，切换区间零重算。
struct BandSignalSection: View, Equatable {
    /// 复权净值序列（升序，旧→新）。建议为等价复权口径以规避分红断层。
    let adjustedSeries: [BandSeriesPoint]
    /// 是否已拼接当日盘中估值（用于显示「含盘中估值」徽标）。
    let withEstimate: Bool
    /// 历史净值是否仍在加载（用于显示加载占位）。
    let isHistoryLoading: Bool

    @State private var bandRange: BandSignalRange = .oneYear
    /// 算法结果缓存：指纹不变（如仅切换区间）时直接复用。
    @State private var computation: BandSignalComputation?

    nonisolated static func == (lhs: BandSignalSection, rhs: BandSignalSection) -> Bool {
        // 只比较外部数据输入；内部 @State 变化由 SwiftUI 自动驱动重算。
        lhs.adjustedSeries == rhs.adjustedSeries
            && lhs.withEstimate == rhs.withEstimate
            && lhs.isHistoryLoading == rhs.isHistoryLoading
    }

    /// 数据指纹：仅在净值序列内容真正变化时改变（点数 + 首末日期 + 末值）。
    private var fingerprint: String {
        guard let first = adjustedSeries.first, let last = adjustedSeries.last else {
            return "empty"
        }
        return "\(adjustedSeries.count)|\(first.date)|\(last.date)|\(last.value)"
    }

    /// 取计算结果：命中缓存直接返回；未命中（首帧 / 数据变化 / 切换区间）同步算一次。
    ///
    /// 回测按**所选区间**统计买卖信号次数（与图表展示窗口、fund.cc.cd 行为一致）：
    /// 默认近 1 年约给出 13 次卖出信号，而非全量历史累计的几十次。
    private func resolvedComputation() -> BandSignalComputation {
        // 指纹纳入区间：切换 近半年 / 近1年 / 全部 时需重算回测。
        let fp = "\(fingerprint)|\(bandRange.rawValue)"
        if let cached = computation, cached.fingerprint == fp {
            return cached
        }
        let signals = computeBandSignal(adjustedSeries)
        let windowed = windowedSignals(from: signals)
        let windowedNav = windowedNavSeries(for: windowed)
        let backtest = windowed.isEmpty
            ? nil
            : backtestBandSignal(signals: windowed, navSeries: windowedNav)
        return BandSignalComputation(
            fingerprint: fp,
            signals: signals,
            backtest: backtest
        )
    }

    /// 按所选区间裁剪信号序列（与图表 `displayedSignals` 同一窗口）。
    private func windowedSignals(from signals: [BandSignalPoint]) -> [BandSignalPoint] {
        guard let limit = bandRange.dayLimit else { return signals }
        return Array(signals.suffix(limit))
    }

    /// 取与裁剪后信号同窗口的净值序列（按日期对齐），供回测按区间统计。
    private func windowedNavSeries(for windowed: [BandSignalPoint]) -> [BandSeriesPoint] {
        guard let cutoff = windowed.first?.date else { return adjustedSeries }
        return adjustedSeries.filter { $0.date >= cutoff }
    }

    var body: some View {
        let result = resolvedComputation()
        return VStack(alignment: .leading, spacing: 10) {
            header
            content(result)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("波段信号")
        .task(id: fingerprint) {
            // 把首帧 / 数据变化时算出的结果写回缓存；此后 body 求值（含切换区间）
            // 直接命中，不再重跑 O(n×252) 的逐日计算。
            if computation?.fingerprint != fingerprint {
                computation = resolvedComputation()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(BandSignalPalette.up, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("波段信号")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if withEstimate {
                Text("含盘中估值")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(BandSignalPalette.up)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BandSignalPalette.up.opacity(0.12), in: Capsule())
                .overlay(
                    Capsule().stroke(BandSignalPalette.up.opacity(0.22), lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ result: BandSignalComputation) -> some View {
        if isHistoryLoading && result.signals.isEmpty {
            placeholder(text: "净值加载中…", minHeight: 90)
        } else if result.signals.isEmpty {
            placeholder(
                text: "数据不足，暂无法计算波段信号（需至少 20 个交易日净值）",
                minHeight: 90
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                BandSignalDecisionPanel(signal: result.signals[result.signals.count - 1])
                BandSignalChart(
                    signals: result.signals,
                    range: bandRange,
                    onRangeChange: { bandRange = $0 }
                )
                if let backtest = result.backtest {
                    BandSignalBacktestSummary(backtest: backtest)
                }
            }
        }
    }

    private func placeholder(text: String, minHeight: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .background(
                PanelDesign.selectorBackground.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// 算法结果缓存载体（含数据指纹，用于判断是否需要重算）。
private struct BandSignalComputation {
    let fingerprint: String
    let signals: [BandSignalPoint]
    let backtest: BandBacktest?
}

// MARK: - 配色（与站内涨色系统对齐：红涨绿跌）

enum BandSignalPalette {
    /// 买侧（up / 评分低位 / 红色 = 涨色）。
    static let up = Color(red: 239 / 255, green: 77 / 255, blue: 98 / 255)
    /// 卖侧（down / 评分高位 / 绿色 = 跌色）。
    static let down = Color.redFundGreen
    /// 中性区。
    static let neutral = Color.secondary

    /// 按 action 返回主色与底色（7 档配色）。
    static func colors(for action: BandAction) -> (fg: Color, bg: Color) {
        switch action {
        case .strongBuy, .buy:
            return (up, up.opacity(0.13))
        case .sell, .strongSell:
            return (down, down.opacity(0.13))
        case .wait, .hold:
            return (neutral, neutral.opacity(0.13))
        }
    }
}

// MARK: - 决策板（7 档徽标 + 综合评分条 + 5 分项）

private struct BandSignalDecisionPanel: View {
    let signal: BandSignalPoint

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let recommendation = bandRecommendation(for: signal.score)
        let palette = BandSignalPalette.colors(for: recommendation.action)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.fg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(recommendation.desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("综合评分")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", signal.score))
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.fg)
                }
            }

            scoreBar(score: signal.score)

            HStack {
                Text("0.0 买入区 <0.3")
                Spacer()
                Text("0.5 中性")
                Spacer()
                Text("1.0 卖出区 >0.7")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                BandSignalIndicatorCell(label: "分位", value: percentText(signal.indicators.percentile))
                BandSignalIndicatorCell(label: "Z 值", value: zScoreText(signal.indicators.zScore))
                BandSignalIndicatorCell(label: "%B", value: String(format: "%.2f", signal.indicators.bollingerB))
                BandSignalIndicatorCell(label: "乖离", value: biasText(signal.indicators.bias))
                BandSignalIndicatorCell(label: "RSI", value: "\(Int((signal.indicators.rsi * 100).rounded()))")
            }
        }
        .padding(10)
        .background(
            PanelDesign.selectorBackground.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func scoreBar(score: Double) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h: CGFloat = 6
            let yOffset = (proxy.size.height - h) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h / 2, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: h)
                    .offset(y: yOffset)
                // 三段背景色
                HStack(spacing: 0) {
                    Rectangle().fill(BandSignalPalette.up.opacity(0.28))
                        .frame(width: w * 0.30, height: h)
                    Rectangle().fill(Color.secondary.opacity(0.18))
                        .frame(width: w * 0.40, height: h)
                    Rectangle().fill(BandSignalPalette.down.opacity(0.28))
                        .frame(width: w * 0.30, height: h)
                }
                .frame(height: h)
                .clipShape(RoundedRectangle(cornerRadius: h / 2, style: .continuous))
                .offset(y: yOffset)
                // 当前评分指针
                Circle()
                    .fill(palette(for: score))
                    .frame(width: 11, height: 11)
                    .overlay(
                        Circle().stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.85)
                                : Color.white,
                            lineWidth: 2
                        )
                    )
                    .position(
                        x: min(max(CGFloat(score) * w, 5), w - 5),
                        y: proxy.size.height / 2
                    )
            }
        }
        .frame(height: 12)
    }

    private func palette(for score: Double) -> Color {
        if score > 0.7 { return BandSignalPalette.down }
        if score < 0.3 { return BandSignalPalette.up }
        return BandSignalPalette.neutral
    }

    /// 分位：原始 0~1 → 百分比 0~100。
    private func percentText(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
    /// Z 值：原始 0~1（±3σ 满量程）→ 反推 ±3。
    private func zScoreText(_ v: Double) -> String {
        String(format: "%.2f", v * 6 - 3)
    }
    /// 乖离：原始 0~1（±12% 满量程）→ 反推百分比。
    private func biasText(_ v: Double) -> String {
        String(format: "%.1f%%", v * 24 - 12)
    }
}

private struct BandSignalIndicatorCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 评分走势图

private struct BandSignalChart: View {
    let signals: [BandSignalPoint]
    let range: BandSignalRange
    let onRangeChange: (BandSignalRange) -> Void

    @State private var hoveredIndex: Int?
    @Environment(\.colorScheme) private var colorScheme

    /// 重采样到固定长度，便于区间切换走「上下形变」动画。
    private static let resampleLength = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartHeader

            infoRow

            chartBody

            dateLabels
        }
        .padding(10)
        .background(
            PanelDesign.selectorBackground.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var displayedSignals: [BandSignalPoint] {
        guard let limit = range.dayLimit else { return signals }
        return Array(signals.suffix(limit))
    }

    private var chartHeader: some View {
        HStack(spacing: 8) {
            Text("评分走势")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            rangePicker
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach(BandSignalRange.allCases) { r in
                Button {
                    // 刻意不包 withAnimation：Canvas 的绘制内容不参与 SwiftUI 几何动画，
                    // 包了只会让动画期间反复求值 body（重采样 + 重绘），反而更卡。
                    // 曲线结果已按数据指纹缓存，直接切换即是最省的路径。
                    onRangeChange(r)
                } label: {
                    Text(r.title)
                        .font(.system(size: 9.5, weight: range == r ? .semibold : .medium))
                        .foregroundStyle(range == r ? BandSignalPalette.up : Color.secondary.opacity(0.85))
                        .frame(minWidth: 30)
                        .frame(height: 20)
                        .padding(.horizontal, 6)
                        .background {
                            if range == r {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(BandSignalPalette.up.opacity(colorScheme == .dark ? 0.20 : 0.12))
                            }
                        }
                        .overlay {
                            if range == r {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(BandSignalPalette.up.opacity(0.30), lineWidth: 0.6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    /// 上方常驻信息行：日期 + 分区 | 评分 + 分位 + RSI。
    private var infoRow: some View {
        let active = currentActive
        let signal = displayedSignals[active]
        let zoneLabel: String
        let zoneColor: Color
        switch signal.zone {
        case .high:
            zoneLabel = "高位区"
            zoneColor = BandSignalPalette.down
        case .low:
            zoneLabel = "低位区"
            zoneColor = BandSignalPalette.up
        case .neutral:
            zoneLabel = "中性区"
            zoneColor = BandSignalPalette.neutral
        }
        let dateText = shortDateText(for: signal.date)
        let scoreText = String(format: "%.2f", signal.score)
        let percentileText = "\(Int((signal.indicators.percentile * 100).rounded()))%"
        let rsiText = "\(Int((signal.indicators.rsi * 100).rounded())) RSI"

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 4) {
                Text(dateText)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(zoneLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(zoneColor)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Text("评分 \(scoreText)")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                Text("分位 \(percentileText)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(rsiText)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var chartBody: some View {
        let data = displayedSignals
        return Group {
            if data.count < 2 {
                Text("数据不足")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                let resampled = resample(data, to: Self.resampleLength)
                ChartCanvas(
                    points: resampled,
                    hoveredIndex: hoveredIndex,
                    onHover: { idx in hoveredIndex = idx },
                    totalCount: data.count
                )
                .frame(height: 120)
            }
        }
    }

    private var dateLabels: some View {
        let data = displayedSignals
        if data.count < 2 {
            return AnyView(HStack { Spacer() }.frame(height: 10))
        }
        let firstDate = shortDateText(for: data.first!.date)
        let midDate = shortDateText(for: data[(data.count - 1) / 2].date)
        let lastDate = shortDateText(for: data.last!.date)
        return AnyView(
            HStack {
                Text(firstDate)
                Spacer()
                Text(midDate)
                Spacer()
                Text(lastDate)
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        )
    }

    private var currentActive: Int {
        guard !displayedSignals.isEmpty else { return 0 }
        if let h = hoveredIndex, h < displayedSignals.count {
            return h
        }
        return displayedSignals.count - 1
    }

    /// 等分重采样到 `len` 个点（与 fund-daily `shape()` 对齐）。
    private func resample(_ source: [BandSignalPoint], to len: Int) -> [BandSignalPoint] {
        guard len > 0, source.count > 0 else { return [] }
        if source.count == len { return source }
        var out: [BandSignalPoint] = []
        out.reserveCapacity(len)
        let lenMinusOne = Double(len - 1)
        let sourceMinusOne = Double(source.count - 1)
        for i in 0..<len {
            let frac = Double(i) / lenMinusOne
            let rawIdx = Int((frac * sourceMinusOne).rounded())
            let clamped = min(max(rawIdx, 0), source.count - 1)
            out.append(source[clamped])
        }
        return out
    }

    private func shortDateText(for yyyyMMdd: String) -> String {
        guard yyyyMMdd.count >= 10 else { return yyyyMMdd }
        let start = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 5)
        let end = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 10)
        return String(yyyyMMdd[start..<end])
    }
}

/// 评分走势图绘图层：底色 + 阈值虚线 + 平滑曲线 + 渐变描边 + 十字线高亮。
/// Canvas 内一次绘制所有静态层，渐变以绘图区为锚定精准落在 0.3 / 0.7 阈值上。
private struct ChartCanvas: View {
    let points: [BandSignalPoint]
    let hoveredIndex: Int?
    let onHover: (Int?) -> Void
    let totalCount: Int

    @Environment(\.colorScheme) private var colorScheme

    private static let padX: CGFloat = 4
    private static let padY: CGFloat = 10
    private static let chartHeight: CGFloat = 120

    var body: some View {
        let data = points
        return GeometryReader { proxy in
            let layout = ChartLayout(
                size: proxy.size,
                padX: Self.padX,
                padY: Self.padY,
                chartHeight: Self.chartHeight
            )
            let xs = Self.computeXs(count: data.count, innerW: layout.innerW, padX: Self.padX)
            let ys = Self.computeYs(points: data, innerH: layout.innerH, padY: Self.padY)

            Canvas { context, _ in
                drawBackground(
                    context: context,
                    innerH: layout.innerH,
                    innerW: layout.innerW
                )
                drawThresholdLines(
                    context: context,
                    innerH: layout.innerH,
                    innerW: layout.innerW
                )
                drawCurve(context: context, xs: xs, ys: ys, innerH: layout.innerH)
                drawYAxisLabels(context: context, innerH: layout.innerH)
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .overlay(alignment: .topLeading) {
                hoverOverlay(data: data, xs: xs, ys: ys, layout: layout)
            }
            .overlay(alignment: .topLeading) {
                hoverInteraction(data: data, layout: layout)
            }
        }
        .frame(height: Self.chartHeight)
    }

    /// 拆解尺寸计算以避免 body 内表达式类型推断爆炸。
    private struct ChartLayout {
        let size: CGSize
        let innerW: CGFloat
        let innerH: CGFloat

        init(size: CGSize, padX: CGFloat, padY: CGFloat, chartHeight: CGFloat) {
            self.size = CGSize(width: size.width, height: chartHeight)
            self.innerW = size.width - padX * 2
            self.innerH = chartHeight - padY * 2
        }
    }

    private static func computeXs(count: Int, innerW: CGFloat, padX: CGFloat) -> [CGFloat] {
        let span = CGFloat(max(count - 1, 1))
        return (0..<count).map { i in
            padX + CGFloat(i) / span * innerW
        }
    }

    private static func computeYs(
        points: [BandSignalPoint],
        innerH: CGFloat,
        padY: CGFloat
    ) -> [CGFloat] {
        return points.map { p in
            padY + innerH - CGFloat(p.score) * innerH
        }
    }

    @ViewBuilder
    private func hoverOverlay(
        data: [BandSignalPoint],
        xs: [CGFloat],
        ys: [CGFloat],
        layout: ChartLayout
    ) -> some View {
        if let h = hoveredIndex, data.indices.contains(h) {
            let x = xs[h]
            let y = ys[h]
            let color = hoverZoneColor(for: data[h].zone)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: x, y: Self.padY))
                    path.addLine(to: CGPoint(x: x, y: Self.padY + layout.innerH))
                }
                .stroke(
                    Color.secondary.opacity(0.55),
                    style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                )
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.92)
                                : Color.white,
                            lineWidth: 1.4
                        )
                    )
                    .position(x: x, y: y)
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func hoverInteraction(
        data: [BandSignalPoint],
        layout: ChartLayout
    ) -> some View {
        Color.clear
            .frame(width: layout.size.width, height: layout.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let span = Double(max(data.count - 1, 1))
                    let frac = (Double(location.x) - Double(Self.padX))
                        / Double(max(layout.innerW, 1))
                    let clamped = min(max(frac, 0), 1)
                    let idx = Int((clamped * span).rounded())
                    onHover(min(max(idx, 0), data.count - 1))
                case .ended:
                    onHover(nil)
                }
            }
    }

    private func drawBackground(
        context: GraphicsContext,
        innerH: CGFloat,
        innerW: CGFloat
    ) {
        let lowZone = CGRect(
            x: Self.padX,
            y: Self.padY + innerH * 0.7,
            width: innerW,
            height: innerH * 0.3
        )
        context.fill(
            Path(lowZone),
            with: .color(BandSignalPalette.up.opacity(0.10))
        )
        let highZone = CGRect(
            x: Self.padX,
            y: Self.padY,
            width: innerW,
            height: innerH * 0.3
        )
        context.fill(
            Path(highZone),
            with: .color(BandSignalPalette.down.opacity(0.10))
        )
    }

    private func drawThresholdLines(
        context: GraphicsContext,
        innerH: CGFloat,
        innerW: CGFloat
    ) {
        let lineColor = GraphicsContext.Shading.color(
            Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.30)
        )
        let dashStyle = StrokeStyle(lineWidth: 0.7, dash: [3, 4])
        let lowY = Self.padY + innerH * 0.7
        let highY = Self.padY + innerH * 0.3
        var lowLine = Path()
        lowLine.move(to: CGPoint(x: Self.padX, y: lowY))
        lowLine.addLine(to: CGPoint(x: Self.padX + innerW, y: lowY))
        context.stroke(lowLine, with: lineColor, style: dashStyle)

        var highLine = Path()
        highLine.move(to: CGPoint(x: Self.padX, y: highY))
        highLine.addLine(to: CGPoint(x: Self.padX + innerW, y: highY))
        context.stroke(highLine, with: lineColor, style: dashStyle)
    }

    private func drawCurve(
        context: GraphicsContext,
        xs: [CGFloat],
        ys: [CGFloat],
        innerH: CGFloat
    ) {
        guard xs.count == ys.count, xs.count > 1 else { return }
        let path = makeSmoothPath(xs: xs, ys: ys)
        let shading = curveShading(innerH: innerH)
        context.stroke(
            path,
            with: shading,
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawYAxisLabels(
        context: GraphicsContext,
        innerH: CGFloat
    ) {
        let labels: [(String, CGFloat)] = [
            ("1.0", Self.padY),
            ("0.5", Self.padY + innerH * 0.5),
            ("0.0", Self.padY + innerH),
        ]
        for (text, y) in labels {
            context.draw(
                Text(text)
                    .font(.system(size: 8.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary),
                at: CGPoint(x: Self.padX + 6, y: y)
            )
        }
    }

    /// 渐变描边：以绘图区为锚定的纵向渐变，0.3 / 0.7 处硬分界（与基估宝一致）。
    private func curveShading(innerH: CGFloat) -> GraphicsContext.Shading {
        let neutralMid = BandSignalPalette.neutral.opacity(0.65)
        let gradient = Gradient(stops: [
            .init(color: BandSignalPalette.down, location: 0.0),
            .init(color: BandSignalPalette.down, location: 0.3),
            .init(color: neutralMid, location: 0.3),
            .init(color: neutralMid, location: 0.7),
            .init(color: BandSignalPalette.up, location: 0.7),
            .init(color: BandSignalPalette.up, location: 1.0),
        ])
        return .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: Self.padY),
            endPoint: CGPoint(x: 0, y: Self.padY + innerH)
        )
    }

    private func hoverZoneColor(for zone: BandZone) -> Color {
        switch zone {
        case .high: return BandSignalPalette.down
        case .low: return BandSignalPalette.up
        case .neutral: return BandSignalPalette.neutral
        }
    }

    /// Catmull-Rom → 三次贝塞尔平滑曲线。端点复用自身避免过冲。
    private func makeSmoothPath(xs: [CGFloat], ys: [CGFloat]) -> Path {
        var path = Path()
        guard xs.count == ys.count, xs.count > 1 else { return path }
        path.move(to: CGPoint(x: xs[0], y: ys[0]))
        for i in 1..<xs.count {
            let p0 = CGPoint(x: xs[max(i - 2, 0)], y: ys[max(i - 2, 0)])
            let p1 = CGPoint(x: xs[i - 1], y: ys[i - 1])
            let p2 = CGPoint(x: xs[i], y: ys[i])
            let p3 = CGPoint(x: xs[min(i + 1, xs.count - 1)], y: ys[min(i + 1, ys.count - 1)])
            // Catmull-Rom → 三次贝塞尔（与 chartMorph.smoothPathD 同型）
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - 策略回测小结

private struct BandSignalBacktestSummary: View {
    let backtest: BandBacktest

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("策略回测（全部数据）")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(backtest.isHolding ? "回测结束时持有中" : "回测结束时空仓")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                StatCell(label: "买入信号", value: "\(backtest.buyCount) 次")
                StatCell(
                    label: "卖出信号",
                    value: "\(backtest.sellCount) 次"
                )
                StatCell(
                    label: "历史胜率",
                    value: "\(Int(backtest.winRate.rounded()))%",
                    valueColor: tone(backtest.winRate - 50)
                )
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                StatCell(
                    label: "策略收益",
                    value: signedPercent(backtest.strategyReturn),
                    valueColor: tone(backtest.strategyReturn)
                )
                StatCell(
                    label: "自然收益",
                    value: signedPercent(backtest.buyHoldReturn),
                    valueColor: tone(backtest.buyHoldReturn)
                )
                StatCell(
                    label: "Alpha 超额",
                    value: signedPercent(backtest.excessReturn),
                    valueColor: tone(backtest.excessReturn)
                )
            }

            Text("规则：评分跌破 0.3 全仓买入、突破 0.7 全仓卖出；按累计净值结算、未计申赎手续费。仅供参考，不构成投资建议。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            PanelDesign.selectorBackground.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func signedPercent(_ v: Double) -> String {
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }

    /// 红涨绿跌：正值用 up（红），负值用 down（绿）。
    private func tone(_ v: Double) -> Color {
        if v > 0 { return BandSignalPalette.up }
        if v < 0 { return BandSignalPalette.down }
        return .primary
    }
}

private struct StatCell: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}