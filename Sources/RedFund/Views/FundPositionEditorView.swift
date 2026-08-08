import SwiftUI

struct FundPositionEditorView: View {
    let store: PortfolioStore
    let fund: FundPosition?
    let onSaved: (() async -> Void)?
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var name: String
    @State private var positionMode: PositionMode
    @State private var positionAmount: String
    @State private var positionProfit: String
    @State private var shares: String
    @State private var cost: String
    @State private var isSameDayNewFund: Bool
    @State private var positionDate: Date
    @State private var positionTimeType: PositionTimeType
    @State private var memo: String
    @State private var lookupTask: Task<Void, Never>?
    @State private var autoResolvedName: String?
    @State private var latestQuote: FundQuote?
    @State private var isLookingUpMetadata = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// 初始化编辑表单：修改时带入已有持仓数据（金额/份额/成本/日期等），新增时初始化空白表单与默认值。
    init(
        store: PortfolioStore,
        fund: FundPosition? = nil,
        onSaved: (() async -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.fund = fund
        self.onSaved = onSaved
        self.onClose = onClose

        // 持仓编辑默认按"份额"录入（与加仓/减仓/转换保持一致），而非按"金额"。
        // 金额基金的金额数据仍由 positionAmount 草稿保留，切回"金额"即可恢复，不会丢失。
        let mode: PositionMode = .share
        let date = fund?.positionDate.flatMap(DateOnlyFormatter.parse) ?? .now
        let netValue: Double? = {
            guard let principal = fund?.migratedPrincipal,
                  let shares = fund?.migratedShares,
                  shares > 0
            else { return nil }
            return principal / shares
        }()
        let amount: Double? = {
            if let pendingAmount = fund?.pendingAmount {
                return pendingAmount
            }
            if let currentAmount = fund?.currentAmount {
                return currentAmount
            }
            if let principal = fund?.migratedPrincipal {
                return principal + (fund?.holdingIncome ?? 0)
            }
            guard let netValue, let shares = fund?.migratedShares else { return nil }
            return shares * netValue
        }()
        let profit: Double? = {
            if let pendingProfit = fund?.pendingProfit {
                return pendingProfit
            }
            if let holdingIncome = fund?.holdingIncome {
                return holdingIncome
            }
            guard let netValue,
                  let shares = fund?.migratedShares,
                  let cost = fund?.migratedCost
            else { return nil }
            return (netValue - cost) * shares
        }()

        _code = State(initialValue: fund?.code ?? "")
        _name = State(initialValue: fund?.name ?? "")
        _positionMode = State(initialValue: mode)
        _positionAmount = State(initialValue: amount.map { Self.fixedText($0, places: PortfolioPrecision.moneyPlaces) } ?? "")
        _positionProfit = State(initialValue: profit.map { Self.fixedText($0, places: PortfolioPrecision.moneyPlaces) } ?? "")
        _shares = State(initialValue: fund?.migratedShares.map { Self.text($0, places: 2) } ?? "")
        _cost = State(initialValue: fund?.migratedCost.map { Self.text($0, places: 4) } ?? "")
        _isSameDayNewFund = State(initialValue: false)
        _positionDate = State(initialValue: date)
        _positionTimeType = State(initialValue: fund?.positionTimeType ?? TradingCalendar.defaultPositionTimeType())
        _memo = State(initialValue: fund?.memo ?? "")
    }

    /// 渲染持仓编辑界面：顶部标题、滚动表单（基金识别 + 持仓录入）、底部操作栏，并绑定代码变更自动读取净值逻辑。
    var body: some View {
        VStack(spacing: 0) {
            header
                .layoutPriority(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PanelSection(title: "基金识别") {
                        field("基金代码") {
                            PanelTextInput("例如 588760", text: $code, isDisabled: fund != nil)
                        }
                        field("基金名称") {
                            PanelTextInput("可选，留空则自动读取", text: $name)
                            if isLookingUpMetadata && fund == nil {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("正在读取基金名称")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        latestNetValueRow
                    }

                    PanelSection(title: "持仓录入") {
                        PanelSegmentedPicker(
                            values: Array(PositionMode.allCases),
                            selection: $positionMode,
                            title: { $0.title }
                        )

                        if positionMode == .amount {
                            field("持仓金额") {
                                PanelTextInput("请输入持仓金额", text: $positionAmount, suffix: "元")
                            }
                            field("持仓收益") {
                                PanelTextInput("可为负，默认为 0", text: $positionProfit, suffix: "元")
                            }
                        } else {
                            field("持仓份额") {
                                PanelTextInput("可精确 2 位小数", text: $shares, suffix: "份")
                            }
                            field("持仓成本价") {
                                PanelTextInput("可精确 4 位小数", text: $cost)
                            }
                        }

                        if fund == nil {
                            sameDayNewFundRow
                            if shouldShowTradeTimeControls {
                                field("交易时点") {
                                    PanelSegmentedPicker(
                                        values: Array(PositionTimeType.allCases),
                                        selection: $positionTimeType,
                                        title: { $0.title }
                                    )
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: shouldShowTradeTimeControls)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            footer
                .layoutPriority(1)
        }
        .frame(width: PopoverLayout.editorWidth, height: PopoverLayout.editorHeight)
        .background(PanelDesign.panelBackground)
        .onChange(of: code) { _, newValue in
            scheduleFundMetadataLookup(for: newValue)
        }
        .onChange(of: isSameDayNewFund) { _, newValue in
            guard newValue else { return }
            positionDate = .now
            positionTimeType = TradingCalendar.defaultPositionTimeType()
        }
        .onAppear {
            if isSameDayNewFund {
                positionDate = .now
                positionTimeType = TradingCalendar.defaultPositionTimeType()
            }
            scheduleFundMetadataLookup(for: code)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    /// 顶部标题栏：新增/修改标题切换，并提供关闭按钮。
    private var header: some View {
        PanelHeader(
            systemImage: fund == nil ? "plus" : "pencil",
            title: fund == nil ? "添加基金" : "修改基金",
            subtitle: fund == nil ? "记录一只新的基金持仓" : "调整基金持仓与提醒",
            onClose: close
        )
    }

    /// 底部操作栏：取消与保存按钮（保存文案随新增/修改、处理中状态变化）。
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                close()
            } label: {
                PanelButtonLabel(title: "取消")
                    .frame(width: 82)
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button {
                save()
            } label: {
                PanelButtonLabel(
                    title: isSaving ? "处理中" : (fund == nil ? "确认添加" : "保存修改"),
                    style: .primary,
                    isEnabled: canSubmit && !isSaving
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || !canSubmit)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    /// 显示输入基金代码后读取到的最新净值与净值日期；读取中显示进度，无数据显示“暂无”。
    private var latestNetValueRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("最新净值")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(latestQuote?.netValueDate.isEmpty == false ? "净值日期 \(latestQuote?.netValueDate ?? "")" : "输入基金代码后自动读取")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLookingUpMetadata {
                ProgressView()
                    .controlSize(.small)
            } else if let latestQuote {
                Text(Self.text(latestQuote.netValue, places: 4))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelDesign.accent)
                    .monospacedDigit()
            } else {
                Text("暂无")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 提示“确认净值日”：根据持仓日期与时段算出按哪天净值确认份额与成本。
    private var confirmNetValueTip: some View {
        let dateText = DateOnlyFormatter.string(from: positionDate)
        let acceptedDate = TradingCalendar.acceptedTradeDate(positionDate: dateText, timeType: positionTimeType)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("确认净值日")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("按该日净值确认份额和成本")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(acceptedDate)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(9)
        .background(PanelDesign.selectorBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.10), lineWidth: 0.6)
        )
    }

    /// “当日新增”开关与说明：开启表示今天刚买入并进入待确认，关闭则按历史持仓补录。
    private var sameDayNewFundRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelDesign.warningAccent)
                Text("是否当日新增")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelDesign.warningAccent)
                Spacer()
                Toggle("", isOn: $isSameDayNewFund)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Text(isSameDayNewFund ? "开启后表示今天刚买入，需选择 15:00 前后；净值未确认前进入待确认。" : "关闭时按已有历史持仓补录，使用最新确认净值进入持仓，不进入待确认。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(PanelDesign.warningBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PanelDesign.warningBorder, lineWidth: 1)
        )
    }

    /// 是否为当日新买入的基金（新增且开启“当日新增”）。
    private var isTodayNewFund: Bool {
        fund == nil && isSameDayNewFund
    }

    /// 仅当日新基金才显示交易时点（15:00 前后）选择控件。
    private var shouldShowTradeTimeControls: Bool {
        isTodayNewFund
    }

    /// 校验表单是否可提交：基金代码非空，且金额模式金额 > 0 或份额模式份额与成本均有效。
    private var canSubmit: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (
            positionMode == .amount
                ? (Self.number(positionAmount) ?? 0) > 0
                : (Self.number(shares) ?? 0) > 0 && (Self.number(cost) ?? 0) > 0
        )
    }

    /// 表单字段的通用封装：上方标题 + 下方内容视图的纵向布局。
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// 组装持仓草稿并通过 store 保存；成功后在主线程回调并关闭，失败则显示错误文案。
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let resolvedPositionDate = DateOnlyFormatter.string(from: isTodayNewFund ? .now : positionDate)
        let resolvedPositionTimeType = isTodayNewFund
            ? positionTimeType
            : .before15

        let draft = FundPositionDraft(
            code: code,
            name: name,
            positionMode: positionMode,
            positionAmount: Self.number(positionAmount),
            positionProfit: Self.number(positionProfit) ?? 0,
            shares: Self.number(shares),
            cost: Self.number(cost),
            positionDate: resolvedPositionDate,
            positionTimeType: resolvedPositionTimeType,
            memo: memo,
            requiresTradeConfirmation: isTodayNewFund
        )

        Task {
            do {
                try await store.upsertFund(draft, replacing: fund?.code)
                if let onSaved {
                    await onSaved()
                }
                await MainActor.run {
                    close()
                }
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    /// 关闭编辑器：优先调用外部 onClose 回调，否则使用 SwiftUI 的 dismiss。
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// 代码变更后防抖地异步拉取最新净值与基金名称：校验 6 位代码后延时查询，回填净值并显示，必要时自动补全名称。
    private func scheduleFundMetadataLookup(for rawCode: String) {
        lookupTask?.cancel()
        let trimmedCode = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode.count == 6, trimmedCode.allSatisfy(\.isNumber) else {
            isLookingUpMetadata = false
            latestQuote = nil
            return
        }

        isLookingUpMetadata = true
        lookupTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let fetchedQuote = await store.fetchLatestQuote(code: trimmedCode)
            let fetchedName: String?
            if let fetchedQuote, fetchedQuote.name != trimmedCode {
                fetchedName = fetchedQuote.name
            } else {
                fetchedName = await store.lookupFundName(code: trimmedCode)
            }
            await MainActor.run {
                guard !Task.isCancelled,
                      code.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCode
                else {
                    return
                }

                latestQuote = fetchedQuote
                if fund == nil,
                   let fetchedName,
                   name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == autoResolvedName {
                    name = fetchedName
                    autoResolvedName = fetchedName
                }
                isLookingUpMetadata = false
            }
        }
    }

    /// 把输入文本解析为 Double：处理全/半角负号、全角逗号与英文千分位。
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    /// 按指定小数位（默认 2）把数值格式化为字符串。
    private static func text(_ value: Double, places: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)))
    }

    /// 按固定小数位格式化数值（用于金额录入回填，保留指定位数）。
    private static func fixedText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}
