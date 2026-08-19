import SwiftUI

struct PortfolioPerformanceView: View {
    let portfolioStore: PortfolioStore
    let store: PortfolioPerformanceStore
    let betaFeaturesEnabled: Bool
    let onOpenJDFinanceSync: () -> Void
    let onNavigationChange: (
        HoldingPerformancePage,
        IncomeRankingMetric,
        PortfolioPerformanceRange,
        Date
    ) -> Void
    let onBack: () -> Void

    @AppStorage(AppPreferenceKey.hideHeaderAmounts) private var hidesAmounts = false
    @State private var page: HoldingPerformancePage
    @State private var rankingMetric: IncomeRankingMetric
    @State private var range: PortfolioPerformanceRange
    @State private var displayedMonth: Date

    /// 初始化收益视图：设定初始页 / 排行指标 / 时间范围 / 展示月份（缺失时回退到最近记录日或今天）。
    init(
        portfolioStore: PortfolioStore,
        store: PortfolioPerformanceStore,
        initialPage: HoldingPerformancePage = .ranking,
        initialRankingMetric: IncomeRankingMetric = .amount,
        initialRange: PortfolioPerformanceRange = .threeMonths,
        initialDisplayedMonth: Date? = nil,
        betaFeaturesEnabled: Bool,
        onOpenJDFinanceSync: @escaping () -> Void,
        onNavigationChange: @escaping (
            HoldingPerformancePage,
            IncomeRankingMetric,
            PortfolioPerformanceRange,
            Date
        ) -> Void = { _, _, _, _ in },
        onBack: @escaping () -> Void
    ) {
        self.portfolioStore = portfolioStore
        self.store = store
        self.betaFeaturesEnabled = betaFeaturesEnabled
        self.onOpenJDFinanceSync = onOpenJDFinanceSync
        self.onNavigationChange = onNavigationChange
        self.onBack = onBack
        _page = State(initialValue: initialPage)
        _rankingMetric = State(initialValue: initialRankingMetric)
        _range = State(initialValue: initialRange)
        _displayedMonth = State(
            initialValue: initialDisplayedMonth
                ?? store.snapshot.days.last
                .flatMap { DateOnlyFormatter.parse($0.date) }
                ?? .now
        )
    }

    /// 渲染持仓收益主界面：标题栏（含“京东补全”入口）+ 模块切换 + 当前页内容，并把页面/指标/范围/月份变化上报给导航回调。
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "chart.line.uptrend.xyaxis",
                title: "持仓收益",
                subtitle: headerSubtitle,
                accessoryText: nil,
                actionSystemImage: showsJDFinanceCompletionAction ? "arrow.down.circle" : nil,
                actionTitle: showsJDFinanceCompletionAction ? "京东补全" : nil,
                actionTint: .blue,
                actionHelp: showsJDFinanceCompletionAction ? "从京东金融补全历史收益" : nil,
                onAction: showsJDFinanceCompletionAction ? onOpenJDFinanceSync : nil,
                onClose: onBack
            )

            Divider()

            VStack(spacing: 10) {
                PanelSegmentedPicker(
                    values: HoldingPerformancePage.allCases,
                    selection: $page,
                    title: { $0.title },
                    accessibilityLabelText: "持仓收益模块"
                )
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PanelDesign.panelBackground)
        .onChange(of: page) { _, newValue in
            onNavigationChange(newValue, rankingMetric, range, displayedMonth)
        }
        .onChange(of: rankingMetric) { _, newValue in
            onNavigationChange(page, newValue, range, displayedMonth)
        }
        .onChange(of: range) { _, newValue in
            onNavigationChange(page, rankingMetric, newValue, displayedMonth)
        }
        .onChange(of: displayedMonth) { _, newValue in
            onNavigationChange(page, rankingMetric, range, newValue)
        }
    }

    /// 是否显示“京东补全”入口：Beta 开启且当前不在排行页时为真。
    private var showsJDFinanceCompletionAction: Bool {
        HoldingPerformancePresentation.showsJDFinanceCompletionAction(
            page: page,
            betaFeaturesEnabled: betaFeaturesEnabled
        )
    }

    /// 生成标题栏副标题：排行页显示持仓数量与收益，曲线/日历页显示追踪起点与记录天数。
    private var headerSubtitle: String {
        if page == .ranking {
            let holdingCount = portfolioStore.snapshot.funds.count {
                $0.status == .holding && ($0.isIncomeActive ?? true)
            }
            return HoldingPerformancePresentation.rankingSubtitle(
                holdingCount: holdingCount,
                holdingIncome: portfolioStore.snapshot.holdingIncome,
                holdingIncomeRate: portfolioStore.snapshot.holdingIncomeRate,
                metric: rankingMetric,
                hidesAmounts: hidesAmounts
            )
        }
        guard let start = store.snapshot.trackingStartDate else { return "按日记录组合净收益" }
        return "自 \(start) 起 · \(tradingDayCount) 个记录日"
    }

    /// 按当前页切换内容：排行页显示今日收益排行面板，曲线/日历页显示收益图区块。
    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .ranking:
            TodayIncomeRankingPanelView(
                store: portfolioStore,
                kind: .holding,
                metric: rankingMetric,
                onClose: {},
                isEmbedded: true,
                metricSelection: $rankingMetric
            )
        case .curve, .calendar:
            performancePageContent
        }
    }

    /// 收益页主体：无记录时显示空态（含京东补全引导）或错误横幅，否则显示汇总、来源说明与曲线/日历。
    @ViewBuilder
    private var performancePageContent: some View {
        if store.snapshot.days.isEmpty {
            VStack(spacing: 12) {
                if let lastError = store.lastError {
                    performanceErrorBanner(lastError)
                }
                ContentUnavailableView {
                    Label("暂无收益记录", systemImage: "calendar.badge.clock")
                } description: {
                    Text("点击右上角“京东补全”读取过去收益；之后也会从首次有效刷新开始按日记录。")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    if let lastError = store.lastError {
                        performanceErrorBanner(lastError)
                    }
                    summaryRow
                    sourceSummary
                    if page == .curve {
                        curveContent
                    } else {
                        calendarContent
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    /// 全部累计收益曲线点（按日期累加每日收益）。
    private var allPoints: [PortfolioPerformancePoint] {
        PortfolioPerformanceSeries.cumulativePoints(in: store.snapshot)
    }

    /// 当前时间范围内的可见收益曲线点（截至最近记录日）。
    private var visiblePoints: [PortfolioPerformancePoint] {
        PortfolioPerformanceSeries.points(
            in: store.snapshot,
            range: range,
            through: store.snapshot.days.last.flatMap { DateOnlyFormatter.parse($0.date) } ?? .now
        )
    }

    /// 最后一个交易日记录（非交易日被视为缓存，不计入统计与展示）。
    private var lastTradingDay: PortfolioPerformanceDay? {
        store.snapshot.days.last { day in
            DateOnlyFormatter.parse(day.date).map(TradingCalendar.isFundTradingDay) ?? false
        }
    }

    /// 交易日记录总数（京东补全与本地记录中非交易日均不计入）。
    private var tradingDayCount: Int {
        store.snapshot.days.count { day in
            DateOnlyFormatter.parse(day.date).map(TradingCalendar.isFundTradingDay) ?? false
        }
    }

    /// 顶部汇总行：记录期累计收益、最近记录日盈亏、记录天数三项指标。
    private var summaryRow: some View {
        HStack(spacing: 8) {
            PerformanceMetric(
                title: "记录期累计收益",
                value: amountText(allPoints.last?.cumulativeProfit ?? 0),
                color: PortfolioPerformanceSemanticColor.color(for: allPoints.last?.cumulativeProfit ?? 0)
            )
            PerformanceMetric(
                title: "最近记录日",
                value: amountText(lastTradingDay?.profit ?? 0),
                color: PortfolioPerformanceSemanticColor.color(for: lastTradingDay?.profit ?? 0),
                detail: lastTradingDay?.returnRate.map {
                    MoneyFormatter.percent($0, signed: true)
                }
            )
            PerformanceMetric(
                title: "记录天数",
                value: "\(tradingDayCount)",
                color: .primary
            )
        }
    }

    /// 收益来源说明条：京东补全天数、本地记录天数（若有）与覆盖到的日期。
    @ViewBuilder
    private var sourceSummary: some View {
        let jdCount = store.snapshot.days.count { $0.source == .jdFinance }
        let localTradingDays = store.snapshot.days.count { $0.source == .localQuote && DateOnlyFormatter.parse($0.date).map(TradingCalendar.isFundTradingDay) ?? false }
        if jdCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.icloud")
                Text("京东补全 \(jdCount) 天")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if localTradingDays > 0 {
                    Text("· 本地记录 \(localTradingDays) 天")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 0)
                if let lastDate = lastTradingDay?.date {
                    Text("截至 \(lastDate)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(PanelDesign.inputBackground.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(PanelDesign.border(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }

    /// 累计收益曲线区块：时间范围选择器 + 曲线图 + 起止日期与图例。
    private var curveContent: some View {
        PanelSection(title: "累计收益曲线") {
            VStack(spacing: 10) {
                PanelSegmentedPicker(
                    values: PortfolioPerformanceRange.allCases,
                    selection: $range,
                    title: { $0.title },
                    accessibilityLabelText: "收益曲线时间范围"
                )

                if visiblePoints.isEmpty {
                    ContentUnavailableView("该区间暂无记录", systemImage: "chart.xyaxis.line")
                        .frame(height: 210)
                } else {
                    PortfolioCumulativeProfitChart(points: visiblePoints, hidesAmounts: hidesAmounts)
                        .frame(height: 220)

                    HStack {
                        Text(visiblePoints.first?.day.date ?? "--")
                        Spacer()
                        Text(visiblePoints.last?.day.date ?? "--")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 每日盈亏日历区块：翻月按钮、月汇总、星期表头与日期网格，无记录时显示提示。
    private var calendarContent: some View {
        let grid = PortfolioPerformanceCalendar.grid(monthContaining: displayedMonth)
        let summary = PortfolioPerformanceCalendar.summary(in: store.snapshot, monthContaining: displayedMonth)
        let records = Dictionary(uniqueKeysWithValues: summary.days.map { ($0.date, $0) })

        return PanelSection(title: "每日盈亏日历") {
            VStack(spacing: 10) {
                HStack {
                    monthButton(systemImage: "chevron.left", offset: -1)
                    Spacer()
                    Text(PortfolioPerformanceCalendar.monthTitle(for: displayedMonth))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    monthButton(systemImage: "chevron.right", offset: 1)
                }

                HStack(spacing: 8) {
                    Label(amountText(summary.totalProfit), systemImage: "sum")
                        .foregroundStyle(PortfolioPerformanceSemanticColor.color(for: summary.totalProfit))
                    Spacer()
                    Text("涨 \(summary.riseDays) 天")
                        .foregroundStyle(PortfolioPerformanceSemanticColor.positive)
                    Text("跌 \(summary.fallDays) 天")
                        .foregroundStyle(PortfolioPerformanceSemanticColor.negative)
                    if summary.localQuoteDays > 0 {
                        Text("本地记录 \(summary.localQuoteDays) 天")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 2)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { title in
                        Text(title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(Array(grid.cells.enumerated()), id: \.offset) { _, date in
                        // 周末与节假日不展示任何收益（沿用上一交易日的数据视为缓存，强制占位为“-”）。
                        let recordForCell: PortfolioPerformanceDay? = date.flatMap { dateText in
                            guard let day = DateOnlyFormatter.parse(dateText),
                                  TradingCalendar.isFundTradingDay(day)
                            else { return nil }
                            return records[dateText]
                        }
                        PerformanceCalendarCell(date: date, record: recordForCell, hidesAmounts: hidesAmounts)
                    }
                }

                if summary.days.isEmpty {
                    Text("本月暂无收益记录")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    /// 生成翻月按钮（上/下月），目标月份越界时禁用。
    private func monthButton(systemImage: String, offset: Int) -> some View {
        Button {
            displayedMonth = PortfolioPerformanceCalendar.shiftedMonth(from: displayedMonth, by: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(PanelDesign.buttonBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(PanelDesign.border(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!canShiftMonth(by: offset))
        .accessibilityLabel(offset < 0 ? "上个月" : "下个月")
        .help(offset < 0 ? "上个月" : "下个月")
    }

    /// 判断偏移后的月份是否仍在记录范围内（不早于首记录月，也不晚于最近记录月或当前月）。
    private func canShiftMonth(by offset: Int) -> Bool {
        let target = PortfolioPerformanceCalendar.shiftedMonth(from: displayedMonth, by: offset)
        guard let targetStart = PortfolioPerformanceCalendar.monthStart(containing: target) else { return false }

        let firstMonth = store.snapshot.days.first
            .flatMap { DateOnlyFormatter.parse($0.date) }
            .flatMap { PortfolioPerformanceCalendar.monthStart(containing: $0) }
        let latestRecordMonth = store.snapshot.days.last
            .flatMap { DateOnlyFormatter.parse($0.date) }
            .flatMap { PortfolioPerformanceCalendar.monthStart(containing: $0) }
        let currentMonth = PortfolioPerformanceCalendar.monthStart(containing: .now)

        if let firstMonth, targetStart < firstMonth { return false }
        let upperBound = [latestRecordMonth, currentMonth].compactMap { $0 }.max()
        if let upperBound, targetStart > upperBound { return false }
        return true
    }

    /// 渲染收益加载/同步的错误提示横幅（警告色背景）。
    private func performanceErrorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PanelDesign.warningAccent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelDesign.warningBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(PanelDesign.warningBorder, lineWidth: 0.7)
            )
    }

    /// 金额文本：隐藏金额时返回掩码，否则格式化为带符号金额。
    private func amountText(_ value: Double) -> String {
        hidesAmounts ? "••••" : MoneyFormatter.money(value, signed: true)
    }
}

enum HoldingPerformancePresentation {
    /// 是否显示“京东补全”入口：Beta 开启且非排行页时为真。
    static func showsJDFinanceCompletionAction(
        page: HoldingPerformancePage,
        betaFeaturesEnabled: Bool
    ) -> Bool {
        betaFeaturesEnabled && page != .ranking
    }

    /// 生成排行页副标题文本：持仓数量 +（金额或收益率）的形式。
    static func rankingSubtitle(
        holdingCount: Int,
        holdingIncome: Double,
        holdingIncomeRate: Double,
        metric: IncomeRankingMetric,
        hidesAmounts: Bool
    ) -> String {
        let value: String
        switch metric {
        case .amount:
            value = hidesAmounts ? "••••" : MoneyFormatter.money(holdingIncome, signed: true)
        case .rate:
            value = MoneyFormatter.percent(holdingIncomeRate, signed: true)
        }
        return "\(holdingCount) 只持仓 · \(value)"
    }
}

private enum PortfolioPerformanceSemanticColor {
    static let positive = Color.red
    static let negative = Color.redFundGreen

    /// 按数值正负/中性返回语义色。
    static func color(for value: Double) -> Color {
        color(for: PortfolioPerformanceChartTone(value: value))
    }

    /// 按收益色调返回语义色（正=红、负=绿、中性=灰）。
    static func color(for tone: PortfolioPerformanceChartTone) -> Color {
        switch tone {
        case .positive:
            positive
        case .negative:
            negative
        case .neutral:
            .secondary
        }
    }
}

enum HoldingPerformancePage: String, CaseIterable, Identifiable {
    case ranking
    case curve
    case calendar

    /// 标识符：等于枚举原始值。
    var id: String { rawValue }
    /// 各页面标题：持仓收益排行 / 收益曲线 / 收益日历。
    var title: String {
        switch self {
        case .ranking:
            "持仓收益排行"
        case .curve:
            "收益曲线"
        case .calendar:
            "收益日历"
        }
    }
}

private struct PerformanceMetric: View {
    let title: String
    let value: String
    let color: Color
    var detail: String? = nil

    /// 单个指标卡片：标题 + 主值 + 可选明细，带卡片背景与边框。
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color.opacity(0.84))
                    .monospacedDigit()
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 9))
    }
}

private struct PortfolioCumulativeProfitChart: View {
    let points: [PortfolioPerformancePoint]
    let hidesAmounts: Bool

    @State private var hoverLocation: CGPoint?
    @State private var hoverIndex: Int?

    /// 用 Canvas 绘制累计收益曲线：网格线、零线、按盈亏色调分段着色，叠加悬停提示。
    var body: some View {
        let values = points.map(\.cumulativeProfit)
        let scale = PortfolioPerformanceChartScale(values: values)
        let cumulativeRates = cumulativeReturnRates

        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawGrid(context: context, size: size)
                drawZeroLine(context: context, size: size, scale: scale)
                drawCurve(context: context, size: size, scale: scale)
                drawHoverIndicator(context: context, size: size, scale: scale)
            }
            .padding(.vertical, 15)
            .overlay(mouseTrackingOverlay)

            GeometryReader { geometry in
                let plotHeight = max(geometry.size.height - 30, 1)

                if let hoverIndex, hoverIndex >= 0, hoverIndex < points.count {
                    hoverTooltip(
                        at: hoverIndex,
                        size: geometry.size,
                        plotHeight: plotHeight,
                        scale: scale,
                        cumulativeRates: cumulativeRates
                    )
                }
            }
            .allowsHitTesting(false)

            // 区间总收益 = 区间内每日盈亏之和（而非全量累计曲线末端值），
            // 这样切换 1月/3月/6月/1年 时该数值会随区间变化。
            let intervalProfit = points.reduce(0) { $0 + $1.day.profit }
            let latestRate = cumulativeRates.last ?? nil

            VStack(alignment: .leading, spacing: 2) {
                if points.count > 0 {
                    axisLabel(value: intervalProfit, rate: latestRate, color: PortfolioPerformanceSemanticColor.color(for: intervalProfit))
                }
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("累计收益曲线")
        .accessibilityValue(chartAccessibilityValue)
    }

    /// 坐标轴标签：金额 + 对应累计收益率。
    private func axisLabel(value: Double, rate: Double?, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(axisText(value))
                .foregroundStyle(color ?? .secondary)
            if let rate {
                Text(MoneyFormatter.percent(rate, signed: true))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle((color ?? .secondary).opacity(0.8))
            }
        }
    }

    /// 鼠标跟踪覆盖层，用于捕获悬停位置。
    private var mouseTrackingOverlay: some View {
        GeometryReader { geometry in
            MouseTrackingOverlay(location: $hoverLocation)
                .onChange(of: hoverLocation) { _, newValue in
                    updateHoverIndex(location: newValue, size: geometry.size)
                }
        }
    }

    /// 更新当前悬停数据索引。
    private func updateHoverIndex(location: CGPoint?, size: CGSize) {
        guard let location, size.width > 0, points.count > 0 else {
            hoverIndex = nil
            return
        }
        guard location.y >= 0, location.y <= size.height else {
            hoverIndex = nil
            return
        }
        if points.count == 1 {
            hoverIndex = 0
        } else {
            let index = Int(round(location.x / size.width * CGFloat(points.count - 1)))
            hoverIndex = min(max(index, 0), points.count - 1)
        }
    }

    /// 悬停提示视图。
    private func hoverTooltip(
        at index: Int,
        size: CGSize,
        plotHeight: CGFloat,
        scale: PortfolioPerformanceChartScale,
        cumulativeRates: [Double?]
    ) -> some View {
        let point = points[index]
        let x = points.count == 1 ? size.width / 2 : size.width * CGFloat(index) / CGFloat(points.count - 1)
        let y = 15 + plotHeight * CGFloat(scale.normalizedY(for: point.cumulativeProfit))

        let tooltip = VStack(alignment: .leading, spacing: 3) {
            Text(point.day.date)
                .font(.system(size: 10, weight: .semibold))
            if !hidesAmounts {
                Text(MoneyFormatter.money(point.day.profit, signed: true))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(PortfolioPerformanceSemanticColor.color(for: point.day.profit))
            }
            if let dailyRate = point.day.returnRate {
                HStack(spacing: 3) {
                    Text("当日")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(MoneyFormatter.percent(dailyRate, signed: true))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(PortfolioPerformanceSemanticColor.color(for: dailyRate))
                }
            }
            if let cumulativeRate = cumulativeRates[index] {
                HStack(spacing: 3) {
                    Text("累计")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(MoneyFormatter.percent(cumulativeRate, signed: true))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(PortfolioPerformanceSemanticColor.color(for: cumulativeRate))
                }
            }
        }
        .padding(8)
        .background(
            PanelDesign.cardBackground.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)

        // 默认显示在数据点右上方；接近右边缘时移到左侧，接近上边缘时翻到下方。
        let tooltipWidth: CGFloat = 118
        let tooltipHeight: CGFloat = hidesAmounts && point.day.returnRate == nil && cumulativeRates[index] == nil ? 34 : 86
        let fitsOnRight = x + tooltipWidth + 16 <= size.width
        let xPos = fitsOnRight ? x + 10 + tooltipWidth / 2 : x - 10 - tooltipWidth / 2
        let yPos = y - tooltipHeight / 2 - 10 < 0 ? y + tooltipHeight / 2 + 10 : y - tooltipHeight / 2 - 10

        return tooltip
            .frame(width: tooltipWidth, alignment: .leading)
            .position(x: min(max(xPos, tooltipWidth / 2 + 4), size.width - tooltipWidth / 2 - 4), y: yPos)
    }

    // MARK: - Drawing helpers

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for fraction in [0.0, 0.5, 1.0] {
            let y = size.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.13)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        }
    }

    private func drawZeroLine(context: GraphicsContext, size: CGSize, scale: PortfolioPerformanceChartScale) {
        let zeroY = size.height * CGFloat(scale.normalizedY(for: 0))
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(
            zeroLine,
            with: .color(.secondary.opacity(0.48)),
            style: StrokeStyle(lineWidth: 1, dash: [5, 3])
        )
    }

    private func drawCurve(context: GraphicsContext, size: CGSize, scale: PortfolioPerformanceChartScale) {
        let location: (Int, Double) -> CGPoint = { index, value in
            let x = points.count == 1 ? size.width / 2 : size.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = size.height * CGFloat(scale.normalizedY(for: value))
            return CGPoint(x: x, y: y)
        }

        if points.count == 1 {
            let center = location(0, points[0].cumulativeProfit)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                with: .color(PortfolioPerformanceSemanticColor.color(for: points[0].cumulativeProfit))
            )
        } else {
            for index in 1..<points.count {
                let startValue = points[index - 1].cumulativeProfit
                let endValue = points[index].cumulativeProfit
                let startPoint = location(index - 1, startValue)
                let endPoint = location(index, endValue)
                for portion in PortfolioPerformanceChartColor.segmentPortions(
                    from: startValue,
                    to: endValue
                ) {
                    var segment = Path()
                    segment.move(to: interpolatedPoint(
                        from: startPoint,
                        to: endPoint,
                        fraction: portion.startFraction
                    ))
                    segment.addLine(to: interpolatedPoint(
                        from: startPoint,
                        to: endPoint,
                        fraction: portion.endFraction
                    ))
                    context.stroke(
                        segment,
                        with: .color(color(for: portion.tone)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    private func drawHoverIndicator(context: GraphicsContext, size: CGSize, scale: PortfolioPerformanceChartScale) {
        guard let hoverIndex, hoverIndex >= 0, hoverIndex < points.count else { return }
        let point = points[hoverIndex]
        let x = points.count == 1 ? size.width / 2 : size.width * CGFloat(hoverIndex) / CGFloat(points.count - 1)
        let y = size.height * CGFloat(scale.normalizedY(for: point.cumulativeProfit))

        var verticalLine = Path()
        verticalLine.move(to: CGPoint(x: x, y: 0))
        verticalLine.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            verticalLine,
            with: .color(.secondary.opacity(0.25)),
            style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])
        )

        context.fill(
            Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
            with: .color(PortfolioPerformanceSemanticColor.color(for: point.cumulativeProfit))
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
            with: .color(PanelDesign.panelBackground),
            style: StrokeStyle(lineWidth: 2)
        )
    }

    /// 坐标轴文本：隐藏金额时返回掩码，否则格式化为带符号金额。
    private func axisText(_ value: Double) -> String {
        hidesAmounts ? "••••" : MoneyFormatter.money(value, signed: true)
    }

    /// 按给定比例在起止两点之间插值出坐标点，用于曲线分段绘制。
    private func interpolatedPoint(
        from start: CGPoint,
        to end: CGPoint,
        fraction: Double
    ) -> CGPoint {
        let fraction = CGFloat(fraction)
        return CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }

    /// 按收益色调取语义色。
    private func color(for tone: PortfolioPerformanceChartTone) -> Color {
        PortfolioPerformanceSemanticColor.color(for: tone)
    }

    /// 曲线无障碍描述：起止日期 + 最近一日当日收益（隐藏时说明金额已隐藏）。
    private var chartAccessibilityValue: String {
        guard let first = points.first, let last = points.last else { return "暂无数据" }
        let amount = hidesAmounts ? "金额已隐藏" : MoneyFormatter.money(last.day.profit, signed: true)
        return "从 \(first.day.date) 到 \(last.day.date)，最近记录日收益 \(amount)"
    }

    // MARK: - Return rate helpers

    /// 累计收益率序列（由每日收益率连乘得到）。
    private var cumulativeReturnRates: [Double?] {
        var result: [Double?] = []
        var cumulative: Double = 0
        for point in points {
            if let rate = point.day.returnRate {
                let decimalRate = rate / 100
                cumulative = (1 + cumulative) * (1 + decimalRate) - 1
                result.append(cumulative * 100)
            } else {
                result.append(nil)
            }
        }
        return result
    }
}

#if canImport(AppKit)
/// 透明覆盖层，用于跟踪鼠标在视图中的位置。
struct MouseTrackingOverlay: NSViewRepresentable {
    @Binding var location: CGPoint?

    func makeNSView(context: Context) -> NSView {
        let view = MouseTrackingView()
        view.onMouseMoved = { location in
            self.location = location
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MouseTrackingView: NSView {
        var onMouseMoved: ((CGPoint?) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
        }

        override func mouseMoved(with event: NSEvent) {
            onMouseMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onMouseMoved?(nil)
        }
    }
}
#endif

private struct PerformanceCalendarCell: View {
    let date: String?
    let record: PortfolioPerformanceDay?
    let hidesAmounts: Bool

    /// 单日日历格：显示日期与盈亏金额（带估值点），无记录或空白格以占位呈现。
    var body: some View {
        Group {
            if let date {
                VStack(spacing: 3) {
                    HStack(spacing: 2) {
                        Text(String(Int(date.suffix(2)) ?? 0))
                        if record?.status == .estimated {
                            Circle().fill(.orange).frame(width: 4, height: 4)
                        }
                    }
                    .font(.system(size: 9, weight: .semibold))

                    Text(record.map { compactAmount($0.profit) } ?? "—")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .foregroundStyle(record.map { PortfolioPerformanceSemanticColor.color(for: $0.profit) } ?? .secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(cellColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(PanelDesign.border(cornerRadius: 7))
                .accessibilityLabel(accessibilityText(date))
            } else {
                Color.clear.frame(height: 42)
            }
        }
    }

    /// 单元格背景色：按盈亏语义色淡化，无记录时回退到次背景色。
    private var cellColor: Color {
        guard let record else { return PanelDesign.inputBackground.opacity(0.42) }
        return PortfolioPerformanceSemanticColor.color(for: record.profit).opacity(0.09)
    }

    /// 紧凑金额文本：隐藏时返回掩码，否则带正负号与紧凑数字格式。
    private func compactAmount(_ value: Double) -> String {
        guard !hidesAmounts else { return "••" }
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        return sign + abs(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// 单元格无障碍描述：日期 + 金额 + 状态 + 来源。
    private func accessibilityText(_ date: String) -> String {
        guard let record else { return "\(date)，无记录" }
        let amount = hidesAmounts ? "金额已隐藏" : MoneyFormatter.money(record.profit, signed: true)
        return "\(date)，\(amount)，\(record.status.title)，\(record.source.title)"
    }
}
