import SwiftUI

/// 示例体验视图（完全离线、不写入真实数据）。
/// 用一组虚构基金与近 90 天示例收益，让用户在“组合 / 收益曲线 / 盈亏日历”三种视角下
/// 预览 App 的真实呈现效果，避免一开始就录入真实持仓。
struct SampleExperienceView: View {
    let experience: SampleExperience
    let onClose: () -> Void

    @State private var section: SampleExperienceSection = .portfolio
    @State private var selectedPointID: Date?
    @State private var visibleMonth: Date

    init(
        experience: SampleExperience = SampleExperienceFactory.make(),
        onClose: @escaping () -> Void = {}
    ) {
        self.experience = experience
        self.onClose = onClose
        let calendar = Self.chinaCalendar
        let lastDate = experience.dailyPerformance.last?.date ?? experience.generatedAt
        _visibleMonth = State(initialValue: calendar.date(from: calendar.dateComponents([.year, .month], from: lastDate)) ?? lastDate)
        _selectedPointID = State(initialValue: experience.dailyPerformance.last?.date)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "sparkles.rectangle.stack.fill",
                title: "组合体验",
                subtitle: "虚构数据 · 可自由查看",
                accessoryText: "示例数据",
                accessoryColor: .orange,
                onClose: onClose
            )

            VStack(spacing: 10) {
                sampleNotice
                PanelSegmentedPicker(
                    values: SampleExperienceSection.allCases,
                    selection: $section,
                    title: \SampleExperienceSection.title,
                    tint: .orange
                )

                Group {
                    switch section {
                    case .portfolio:
                        portfolioContent
                    case .curve:
                        curveContent
                    case .calendar:
                        calendarContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(PanelDesign.panelBackground)
    }

    /// 顶部提示条：声明以下为虚构、离线、不会写入 portfolio.json 或真实收益历史。
    private var sampleNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle.fill")
            Text("以下内容仅用于体验，不联网，也不会写入 portfolio.json 或真实收益历史。")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.7)
        )
    }

    /// “组合”视角：总资产 / 累计收益 / 今日收益 三张指标卡 + 示例基金列表。
    private var portfolioContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    sampleMetric(
                        title: "总资产",
                        value: MoneyFormatter.money(experience.portfolio.totalAmount, signed: false),
                        tone: .primary
                    )
                    sampleMetric(
                        title: "累计收益",
                        value: MoneyFormatter.money(experience.portfolio.holdingIncome, signed: true),
                        tone: toneColor(experience.portfolio.holdingIncome)
                    )
                    sampleMetric(
                        title: "今日收益",
                        value: MoneyFormatter.money(experience.portfolio.todayIncome, signed: true),
                        tone: toneColor(experience.portfolio.todayIncome)
                    )
                }

                PanelSection(title: "示例组合") {
                    VStack(spacing: 0) {
                        ForEach(Array(experience.portfolio.funds.enumerated()), id: \.element.id) { index, fund in
                            sampleFundRow(fund)
                            if index < experience.portfolio.funds.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// “收益曲线”视角：展示近 90 天累计收益，可拖动曲线查看每日明细。
    private var curveContent: some View {
        let selected = selectedPoint
        return ScrollView {
            VStack(spacing: 10) {
                PanelSection(title: "近 90 天累计收益") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selected.map { MoneyFormatter.money($0.cumulativeIncome, signed: true) } ?? "--")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(toneColor(selected?.cumulativeIncome ?? 0))
                                Text(selected.map { Self.fullDateFormatter.string(from: $0.date) } ?? "拖动曲线查看每日数据")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let selected {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("当日 \(MoneyFormatter.money(selected.dailyIncome, signed: true))")
                                        .foregroundStyle(toneColor(selected.dailyIncome))
                                    Text(MoneyFormatter.percent(selected.dailyIncomeRate, signed: true))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                            }
                        }

                        SampleIncomeChart(
                            points: experience.dailyPerformance,
                            selectedID: $selectedPointID
                        )
                        .frame(height: 230)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// “盈亏日历”视角：按月展示每日盈亏，可左右翻月、点选某天查看明细。
    private var calendarContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                PanelSection(title: "每日盈亏日历") {
                    VStack(spacing: 9) {
                        HStack {
                            calendarNavigationButton(systemImage: "chevron.left", monthOffset: -1)
                            Spacer()
                            Text(Self.monthFormatter.string(from: visibleMonth))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            calendarNavigationButton(systemImage: "chevron.right", monthOffset: 1)
                        }

                        LazyVGrid(columns: calendarColumns, spacing: 5) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                                Text(weekday)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }

                            ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                                calendarCell(date)
                            }
                        }
                    }
                }

                if let selected = selectedPoint {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.fullDateFormatter.string(from: selected.date))
                                .font(.system(size: 11, weight: .semibold))
                            Text("累计 \(MoneyFormatter.money(selected.cumulativeIncome, signed: true))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MoneyFormatter.money(selected.dailyIncome, signed: true))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(toneColor(selected.dailyIncome))
                            Text(MoneyFormatter.percent(selected.dailyIncomeRate, signed: true))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(PanelDesign.border(cornerRadius: 10))
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// 当前选中的某日收益点：优先取 selectedPointID，否则取最后一天。
    private var selectedPoint: SampleDailyPerformance? {
        guard let selectedPointID else { return experience.dailyPerformance.last }
        return experience.dailyPerformance.first { Self.chinaCalendar.isDate($0.date, inSameDayAs: selectedPointID) }
            ?? experience.dailyPerformance.last
    }

    /// 指标卡（标题 + 数值，按盈亏着色）。
    private func sampleMetric(title: String, value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 9))
    }

    /// 示例基金列表行（名称/代码 + 金额/今日收益）。
    private func sampleFundRow(_ fund: FundPosition) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fund.name)
                    .font(.system(size: 11, weight: .semibold))
                Text(fund.code)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormatter.money(fund.currentAmount ?? 0, signed: false))
                    .font(.system(size: 11, weight: .semibold))
                Text(MoneyFormatter.money(fund.todayIncome, signed: true))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(toneColor(fund.todayIncome))
            }
            .monospacedDigit()
        }
        .padding(.vertical, 8)
    }

    /// 日历翻月按钮：切换到上/下一个月（超出示例数据范围时禁用）。
    private func calendarNavigationButton(systemImage: String, monthOffset: Int) -> some View {
        let target = Self.chinaCalendar.date(byAdding: .month, value: monthOffset, to: visibleMonth)
        let isEnabled = target.map(monthIsWithinSample) ?? false
        return Button {
            if let target {
                visibleMonth = target
                selectLastPoint(in: target)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }

    /// 单个日历格：有收益数据的日期显示当日盈亏并着色，可点选；无数据的日期留空。
    @ViewBuilder
    private func calendarCell(_ date: Date?) -> some View {
        if let date {
            let point = performanceByDay[Self.chinaCalendar.startOfDay(for: date)]
            let isSelected = selectedPointID.map { Self.chinaCalendar.isDate($0, inSameDayAs: date) } ?? false
            Button {
                if point != nil {
                    selectedPointID = date
                }
            } label: {
                VStack(spacing: 2) {
                    Text("\(Self.chinaCalendar.component(.day, from: date))")
                        .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                    Text(point.map { compactIncome($0.dailyIncome) } ?? "")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(point.map { toneColor($0.dailyIncome) } ?? .secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    (point.map { toneColor($0.dailyIncome).opacity(0.09) } ?? Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color.orange.opacity(0.75) : Color.secondary.opacity(point == nil ? 0.08 : 0.14), lineWidth: isSelected ? 1.2 : 0.6)
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(point == nil)
        } else {
            Color.clear.frame(height: 38)
        }
    }

    /// 把每日收益按“当天 0 点”映射到字典，供日历快速查表。
    private var performanceByDay: [Date: SampleDailyPerformance] {
        Dictionary(
            uniqueKeysWithValues: experience.dailyPerformance.map {
                (Self.chinaCalendar.startOfDay(for: $0.date), $0)
            }
        )
    }

    /// 计算当前月份需要渲染的日期数组（含前置空白占位，按周一为一周起点对齐到 7 的倍数）。
    private var calendarDays: [Date?] {
        let calendar = Self.chinaCalendar
        guard let dayRange = calendar.range(of: .day, in: .month, for: visibleMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) else {
            return []
        }
        let mondayBasedLeading = (calendar.component(.weekday, from: firstDay) + 5) % 7
        var days = Array<Date?>(repeating: nil, count: mondayBasedLeading)
        days.append(contentsOf: dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        })
        while !days.count.isMultiple(of: 7) {
            days.append(nil)
        }
        return days
    }

    /// 日历网格：7 列等宽。
    private var calendarColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    }

    /// 判断某个月是否落在示例数据范围内（用于翻月按钮可用性）。
    private func monthIsWithinSample(_ month: Date) -> Bool {
        guard let first = experience.dailyPerformance.first?.date,
              let last = experience.dailyPerformance.last?.date else { return false }
        let calendar = Self.chinaCalendar
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let start = calendar.date(from: components),
              let next = calendar.date(byAdding: .month, value: 1, to: start) else { return false }
        return next > first && start <= last
    }

    /// 翻到某月后，自动选中该月最后一条有数据的收益点。
    private func selectLastPoint(in month: Date) {
        let calendar = Self.chinaCalendar
        let matches = experience.dailyPerformance.filter {
            calendar.isDate($0.date, equalTo: month, toGranularity: .month)
        }
        selectedPointID = matches.last?.date
    }

    /// 日历格用的紧凑收益文本（如 +12 / -3，四舍五入取整）。
    private func compactIncome(_ value: Double) -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(Int(value.rounded()))"
    }

    /// 收益着色：涨为红、跌为绿、接近 0 为次要色（与中国习惯一致）。
    private func toneColor(_ value: Double) -> Color {
        if value > 0.005 { return .red }
        if value < -0.005 { return .green }
        return .secondary
    }

    /// 以中国时区/中文区域、周一为一周起点构造的日历，全文件共用。
    private static var chinaCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// “M月d日 星期X”格式（中文）日期格式化器。
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    /// “yyyy年 M月”格式（中文）月份格式化器。
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年 M月"
        return formatter
    }()
}

/// 示例体验的三个子视图分段：组合 / 收益曲线 / 盈亏日历。
private enum SampleExperienceSection: String, CaseIterable, Identifiable {
    case portfolio
    case curve
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: "组合"
        case .curve: "收益曲线"
        case .calendar: "盈亏日历"
        }
    }
}

/// 纯 SwiftUI 自绘的累计收益曲线图。
/// 用 Path 按每日累计收益绘制折线，零轴用虚线标出，支持拖拽选取某一天（DragGesture），
/// 并按涨跌为相邻线段分别着色。坐标映射依赖 PortfolioPerformanceChartScale。
private struct SampleIncomeChart: View {
    let points: [SampleDailyPerformance]
    @Binding var selectedID: Date?

    var body: some View {
        GeometryReader { proxy in
            let scale = PortfolioPerformanceChartScale(values: points.map(\.cumulativeIncome))
            let zeroY = chartY(for: 0, size: proxy.size, scale: scale)
            ZStack(alignment: .topLeading) {
                chartGrid(size: proxy.size)
                    .stroke(Color.secondary.opacity(0.13), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))

                Path { path in
                    path.move(to: CGPoint(x: 8, y: zeroY))
                    path.addLine(to: CGPoint(x: proxy.size.width - 8, y: zeroY))
                }
                .stroke(
                    Color.secondary.opacity(0.48),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )

                if points.count == 1 {
                    let location = pointLocation(index: 0, size: proxy.size, scale: scale)
                    Circle()
                        .fill(color(for: PortfolioPerformanceChartTone(value: points[0].cumulativeIncome)))
                        .frame(width: 6, height: 6)
                        .position(location)
                } else if points.count > 1 {
                    ForEach(1..<points.count, id: \.self) { index in
                        let startValue = points[index - 1].cumulativeIncome
                        let endValue = points[index].cumulativeIncome
                        let start = pointLocation(index: index - 1, size: proxy.size, scale: scale)
                        let end = pointLocation(index: index, size: proxy.size, scale: scale)
                        let portions = PortfolioPerformanceChartColor.segmentPortions(
                            from: startValue,
                            to: endValue
                        )
                        ForEach(Array(portions.enumerated()), id: \.offset) { _, portion in
                            Path { path in
                                path.move(to: interpolatedPoint(
                                    from: start,
                                    to: end,
                                    fraction: portion.startFraction
                                ))
                                path.addLine(to: interpolatedPoint(
                                    from: start,
                                    to: end,
                                    fraction: portion.endFraction
                                ))
                            }
                            .stroke(
                                color(for: portion.tone),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                }

                Text("¥0")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(PanelDesign.cardBackground.opacity(0.92), in: Capsule())
                    .position(x: 22, y: min(max(zeroY - 8, 8), proxy.size.height - 8))

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let location = pointLocation(index: selectedIndex, size: proxy.size, scale: scale)
                    Path { path in
                        path.move(to: CGPoint(x: location.x, y: 4))
                        path.addLine(to: CGPoint(x: location.x, y: proxy.size.height - 18))
                    }
                    .stroke(Color.secondary.opacity(0.34), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))

                    Circle()
                        .fill(color(for: PortfolioPerformanceChartTone(
                            value: points[selectedIndex].cumulativeIncome
                        )))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .position(location)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !points.isEmpty else { return }
                        let width = max(proxy.size.width - 16, 1)
                        let progress = min(max((value.location.x - 8) / width, 0), 1)
                        let index = Int((progress * Double(max(points.count - 1, 0))).rounded())
                        selectedID = points[index].date
                    }
            )
            .accessibilityLabel("示例累计收益曲线")
            .accessibilityValue(selectedIndex.map { MoneyFormatter.money(points[$0].cumulativeIncome, signed: true) } ?? "")
        }
    }

    /// 当前选中点在 points 中的下标：优先按 selectedID 匹配，否则取最后一天。
    private var selectedIndex: Int? {
        guard let selectedID else { return points.indices.last }
        return points.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: selectedID) }
    }

    /// 绘制 4 条水平网格参考线。
    private func chartGrid(size: CGSize) -> Path {
        Path { path in
            for row in 0 ... 3 {
                let y = 8 + (size.height - 28) * CGFloat(row) / 3
                path.move(to: CGPoint(x: 8, y: y))
                path.addLine(to: CGPoint(x: size.width - 8, y: y))
            }
        }
    }

    /// 把第 index 个数据点的累计收益映射到图内坐标点（x 均匀分布，y 由 chartY 计算）。
    private func pointLocation(
        index: Int,
        size: CGSize,
        scale: PortfolioPerformanceChartScale
    ) -> CGPoint {
        let plotWidth = max(size.width - 16, 1)
        let x = 8 + plotWidth * CGFloat(index) / CGFloat(max(points.count - 1, 1))
        return CGPoint(
            x: x,
            y: chartY(for: points[index].cumulativeIncome, size: size, scale: scale)
        )
    }

    /// 把收益值映射为图内 y 坐标（借助 scale.normalizedY，顶部留白 8、底部留白 20）。
    private func chartY(
        for value: Double,
        size: CGSize,
        scale: PortfolioPerformanceChartScale
    ) -> CGFloat {
        let plotHeight = max(size.height - 28, 1)
        return 8 + plotHeight * CGFloat(scale.normalizedY(for: value))
    }

    /// 在 start→end 线段上按比例 fraction 线性插值，得到中间坐标点。
    private func interpolatedPoint(
        from start: CGPoint,
        to end: CGPoint,
        fraction: Double
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(fraction),
            y: start.y + (end.y - start.y) * CGFloat(fraction)
        )
    }

    /// 把图表色调（正/负/中性）映射为颜色：正红、负绿、中性次要色。
    private func color(for tone: PortfolioPerformanceChartTone) -> Color {
        switch tone {
        case .positive:
            .red
        case .negative:
            .redFundGreen
        case .neutral:
            .secondary
        }
    }
}
