import SwiftUI

struct FundTradeEditorView: View {
    let store: PortfolioStore
    let fund: FundPosition
    let action: FundTradeAction
    let editingRecord: FundTradeRecord?
    let onSaved: (() async -> Void)?
    let onClose: (() -> Void)?

    @State private var mode: PositionMode
    @State private var amount: String = ""
    @State private var shares: String = ""
    @State private var buyFeeRate: String = "0"
    @State private var sellFeeMode: TradeFeeMode = .rate
    @State private var sellFeeValue: String = "0"
    @State private var tradeDate: Date = .now
    @State private var tradeTimeType: PositionTimeType = TradingCalendar.defaultPositionTimeType()
    @State private var isSaving = false
    @State private var isConfirming = false
    @State private var referenceNetValue: Double?
    @State private var referenceNetValueDate: String?
    @State private var isLoadingReferenceNetValue = false
    @State private var referenceTask: Task<Void, Never>?
    @State private var errorMessage: String?

    /// 初始化交易编辑器：买入默认金额模式、卖出默认份额模式；编辑时载入已有记录字段，新增基金可改模式。
    init(
        store: PortfolioStore,
        fund: FundPosition,
        action: FundTradeAction,
        editingRecord: FundTradeRecord? = nil,
        onSaved: (() async -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.fund = fund
        self.action = action
        self.editingRecord = editingRecord
        self.onSaved = onSaved
        self.onClose = onClose
        let isEditingInitialFund = editingRecord?.kind == .newFund
        let initialMode: PositionMode = action == .buy && !isEditingInitialFund
            ? .amount
            : (editingRecord?.mode ?? (action == .buy ? .amount : .share))
        _mode = State(initialValue: initialMode)
        _amount = State(initialValue: editingRecord?.amount.map { Self.initialNumberText($0, places: 2) } ?? "")
        _shares = State(initialValue: (editingRecord?.shares ?? editingRecord?.confirmedShares).map { Self.initialNumberText($0, places: 2) } ?? "")
        _buyFeeRate = State(initialValue: editingRecord?.buyFeeRate.map { Self.initialNumberText($0, places: 2) } ?? "0")
        _sellFeeMode = State(initialValue: editingRecord?.sellFeeMode ?? .rate)
        _sellFeeValue = State(initialValue: editingRecord?.sellFeeValue.map { Self.initialNumberText($0, places: 2) } ?? "0")
        _tradeDate = State(initialValue: editingRecord.flatMap { DateOnlyFormatter.parse($0.tradeDate) } ?? .now)
        _tradeTimeType = State(initialValue: editingRecord?.tradeTimeType ?? TradingCalendar.defaultPositionTimeType())
    }

    /// 渲染交易编辑界面：标题栏 + 滚动内容（表单或确认页）+ 底部按钮；进入或切换日期/时段时刷新参考净值。
    var body: some View {
        VStack(spacing: 0) {
            header
                .layoutPriority(1)
            content
            Spacer(minLength: 0)
            footer
                .layoutPriority(1)
        }
        .frame(width: PopoverLayout.editorWidth, height: PopoverLayout.standardChildPanelHeight)
        .background(PanelDesign.panelBackground)
        .onAppear {
            scheduleReferenceNetValueLookup()
        }
        .onChange(of: tradeDate) { _, _ in
            isConfirming = false
            scheduleReferenceNetValueLookup()
        }
        .onChange(of: tradeTimeType) { _, _ in
            isConfirming = false
            scheduleReferenceNetValueLookup()
        }
        .onDisappear {
            referenceTask?.cancel()
        }
    }

    /// 顶部标题栏：动作图标 + 标题/副标题 + 关闭按钮。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerSystemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(actionColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("取消")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /// 滚动内容区：确认态显示确认页，否则显示录入表单。
    private var content: some View {
        ScrollView {
            Group {
                if isConfirming {
                    confirmationContent
                } else {
                    formContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// 表单页：基金摘要 + 交易录入 + 交易确认区，以及错误提示。
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            fundSummary
            tradeInputSection
            tradeConfirmSection

            if let errorMessage {
                errorText(errorMessage)
            }
        }
    }

    /// 确认页：确认摘要 + 持仓变化预览，以及错误提示。
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            confirmationSummary
            positionPreview

            if let errorMessage {
                errorText(errorMessage)
            }
        }
    }

    /// 基金信息摘要卡：名称、代码、当前份额与成本价。
    private var fundSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fund.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(FundCodeFormatter.display(fund.code))
                        .fontWeight(.semibold)
                    Text("当前份额 \(numberText(fund.migratedShares ?? 0, places: 2))")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("成本价")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(fund.migratedCost.map { numberText($0, places: 4) } ?? "暂无")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(cardBorder(cornerRadius: 10))
    }

    /// 交易录入区：可选模式切换 + 金额/份额/费率输入（买入或卖出）。
    private var tradeInputSection: some View {
        section("交易录入") {
            if canChooseTradeMode {
                modeSelector
            }
            if effectiveMode == .amount {
                field(action == .buy ? "加仓金额" : "卖出金额") {
                    plainTextField(
                        action == .buy ? "请输入加仓金额" : "请输入卖出金额",
                        text: $amount,
                        suffix: "元"
                    )
                }
                if action == .buy {
                    field("买入费率") {
                        plainTextField("例如 0.12", text: $buyFeeRate, suffix: "%")
                    }
                }
            } else {
                field(action == .buy ? "加仓份额" : "卖出份额") {
                    plainTextField(
                        action == .buy ? "请输入加仓份额" : availableSharePlaceholder,
                        text: $shares,
                        suffix: "份"
                    )
                }
                if action == .sell {
                    sellShareQuickControls
                    sellFeeInput
                }
            }
        }
    }

    /// 交易确认区：交易日期、时段、参考净值与确认净值日提示。
    private var tradeConfirmSection: some View {
        section("交易确认") {
            HStack(spacing: 10) {
                Text("交易日期")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                PanelNativeDatePicker(selection: $tradeDate, elements: [.yearMonthDay])
                    .frame(width: 122, height: 24)
            }
            timeSelector
            referenceNetValueRow
            tradeDateTip
        }
    }

    /// 参考净值行：显示买入参考净值或卖出预估单价，含净值日期与加载状态。
    private var referenceNetValueRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(action == .buy ? "参考净值" : "预估卖出单价")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(referenceFootnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoadingReferenceNetValue {
                ProgressView()
                    .controlSize(.small)
            } else if let referenceNetValue {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(numberText(referenceNetValue, places: 4))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PanelDesign.accent)
                        .monospacedDigit()
                    if let referenceNetValueDate {
                        Text(referenceNetValueDate)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text("待确认")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 交易模式选择器（金额/份额），仅新增基金可切换。
    private var modeSelector: some View {
        HStack(spacing: 4) {
            ForEach(availableModes) { value in
                selectorButton(title: value.title, isSelected: mode == value) {
                    mode = value
                }
            }
        }
        .padding(2)
        .background(selectorBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 0.6)
        )
    }

    /// 交易时段选择器：15:00 前 / 后。
    private var timeSelector: some View {
        HStack(spacing: 4) {
            ForEach(PositionTimeType.allCases) { value in
                selectorButton(title: value.title, isSelected: tradeTimeType == value) {
                    tradeTimeType = value
                }
            }
        }
        .padding(2)
        .background(selectorBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 0.6)
        )
    }

    /// 卖出份额快捷按钮（1/4、1/3、1/2、全部），按当前持仓比例填充份额。
    private var sellShareQuickControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                quickSellShareButton("1/4", fraction: 0.25)
                quickSellShareButton("1/3", fraction: 1.0 / 3.0)
                quickSellShareButton("1/2", fraction: 0.5)
                quickSellShareButton("全部", fraction: 1)
            }

            Text("当前持仓：\(numberText(fund.migratedShares ?? 0, places: 2)) 份")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 卖出费用输入：可在费率(%)与金额(元)之间切换并录入。
    private var sellFeeInput: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(sellFeeMode == .rate ? "卖出费率" : "卖出费用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    sellFeeMode = sellFeeMode == .rate ? .amount : .rate
                    sellFeeValue = "0"
                } label: {
                    Text("切换为\(sellFeeMode == .rate ? "金额" : "费率")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(actionColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            plainTextField(
                sellFeeMode == .rate ? "例如 0.50" : "请输入卖出费用",
                text: $sellFeeValue,
                suffix: sellFeeMode == .rate ? "%" : "元"
            )
        }
    }

    /// 生成卖出份额快捷按钮：点击按份额比例回填到份额输入框。
    private func quickSellShareButton(_ title: String, fraction: Double) -> some View {
        Button {
            let currentShares = fund.migratedShares ?? 0
            shares = numberText(currentShares * fraction, places: 2)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(PanelDesign.border(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 确认净值日提示：按交易日期与时段算出按哪天净值确认份额/金额。
    private var tradeDateTip: some View {
        let dateText = DateOnlyFormatter.string(from: tradeDate)
        let acceptedDate = TradingCalendar.acceptedTradeDate(positionDate: dateText, timeType: tradeTimeType)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("确认净值日")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(action == .buy ? "按该日净值确认加仓份额" : "按该日净值确认卖出")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(acceptedDate)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(9)
        .background(actionColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(actionColor.opacity(0.13), lineWidth: 0.6)
        )
    }

    /// 确认摘要：列出买入/卖出的各项金额、费率、手续费、预估份额/回款与日期。
    private var confirmationSummary: some View {
        section(action == .buy ? "买入确认" : "卖出确认") {
            VStack(spacing: 9) {
                confirmationRow("基金名称", fund.name)
                if action == .buy {
                    confirmationRow("买入金额", inputAmount.map { MoneyFormatter.plainMoney($0) } ?? "--")
                    confirmationRow("买入费率", "\(numberText(inputBuyFeeRate ?? 0, places: 2))%")
                    confirmationRow("预估手续费", estimatedBuyFee.map { MoneyFormatter.plainMoney($0) } ?? "0.00")
                    confirmationRow("参考净值", referencePriceText)
                    confirmationRow("预估份额", estimatedBuyShares.map { "\(numberText($0, places: 2)) 份" } ?? "待确认")
                    confirmationRow("买入日期", tradeDateText)
                } else {
                    confirmationRow("卖出份额", "\(numberText(inputShares ?? 0, places: 2)) 份")
                    confirmationRow("预估卖出单价") {
                        sellPriceDisplayValue
                    }
                    confirmationRow("卖出费率/费用", sellFeeValueText)
                    confirmationRow("预估手续费") {
                        sellFeeDisplayValue
                    }
                    confirmationRow("预计回款") {
                        sellReturnDisplayValue
                    }
                    confirmationRow("卖出日期", tradeDateText)
                }
                Divider().opacity(0.55)
                confirmationRow("交易时段", tradeTimeType.title)
                Text(referenceBasisText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 持仓变化预览：交易后份额与持仓市值的前后对比。
    private var positionPreview: some View {
        section("持仓变化预览") {
            VStack(spacing: 8) {
                previewTile(
                    title: "持仓份额",
                    before: numberText(fund.migratedShares ?? 0, places: 2),
                    after: previewShares.map { numberText($0, places: 2) } ?? "待确认"
                )
                previewTile(
                    title: "持仓市值（估）",
                    before: {
                        previewCurrentValueBeforeDisplayValue
                    },
                    after: {
                        previewCurrentValueAfterDisplayValue
                    }
                )
            }
        }
    }

    /// 底部操作栏：确认态显示“返回修改”，否则“取消”；主按钮提交或进入确认。
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if isConfirming {
                    isConfirming = false
                    errorMessage = nil
                } else {
                    close()
                }
            } label: {
                Text(isConfirming ? "返回修改" : "取消")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 78, height: 30)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(cardBorder(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button {
                submit()
            } label: {
                Text(submitTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(canSubmit ? actionColor : Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || !canSubmit || (isConfirming && isLoadingReferenceNetValue))
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    /// 校验是否可提交：金额/份额大于 0，且买入有费率、卖出有费用（按模式）。
    private var canSubmit: Bool {
        switch effectiveMode {
        case .amount:
            let hasAmount = (Self.number(amount) ?? 0) > 0
            if action == .buy {
                return hasAmount && inputBuyFeeRate != nil
            }
            return hasAmount
        case .share:
            let hasShares = (Self.number(shares) ?? 0) > 0
            if action == .sell {
                return hasShares && inputSellFeeValue != nil
            }
            return hasShares
        }
    }

    /// 标题栏副标题：随确认态/编辑态/动作变化。
    private var headerSubtitle: String {
        if isConfirming {
            return "确认后写入交易记录并更新持仓"
        }
        if editingRecord != nil {
            return "修改后会重新计算持仓"
        }
        return action == .buy ? "记录一笔追加买入" : "记录一笔卖出赎回"
    }

    /// 标题栏标题：随新增基金/确认态/动作变化。
    private var headerTitle: String {
        if isEditingInitialFund {
            return isConfirming ? "新增基金确认" : "新增基金"
        }
        if isConfirming {
            return action == .buy ? "买入确认" : "卖出确认"
        }
        return action.title
    }

    /// 标题栏图标：确认态用托盘箭头，否则用加减号。
    private var headerSystemImage: String {
        if isConfirming {
            return action == .buy ? "tray.and.arrow.down.fill" : "tray.and.arrow.up.fill"
        }
        return action == .buy ? "plus" : "minus"
    }

    /// 主按钮文案：随编辑/确认/加载状态变化（如“买入确认”“保存中”）。
    private var submitTitle: String {
        if editingRecord != nil {
            return isSaving ? "保存中" : (isConfirming ? "确认保存" : "保存确认")
        }
        if isConfirming {
            if isLoadingReferenceNetValue {
                return "请稍候"
            }
            return isSaving ? "处理中" : "确认\(action == .buy ? "买入" : "卖出")"
        }
        return action == .buy ? "买入确认" : "卖出确认"
    }

    /// 动作主题色：买入为红、卖出为绿。
    private var actionColor: Color {
        action == .buy ? Color(nsColor: .systemRed) : .redFundGreen
    }

    /// 卡片背景色（复用设计系统）。
    private var cardBackground: Color {
        PanelDesign.cardBackground
    }

    /// 选择器背景色（复用设计系统）。
    private var selectorBackground: Color {
        PanelDesign.selectorBackground
    }

    /// 是否允许选择交易模式（仅新增基金可切换）。
    private var canChooseTradeMode: Bool {
        isEditingInitialFund
    }

    /// 是否正在编辑“新增基金”类型的记录。
    private var isEditingInitialFund: Bool {
        editingRecord?.kind == .newFund
    }

    /// 可选交易模式：可切换时全部，否则只允许金额。
    private var availableModes: [PositionMode] {
        canChooseTradeMode ? Array(PositionMode.allCases) : [.amount]
    }

    /// 实际生效的交易模式：可切换时用所选，否则买入=金额、卖出=份额。
    private var effectiveMode: PositionMode {
        if canChooseTradeMode {
            return mode
        }
        return action == .buy ? .amount : .share
    }

    /// 交易日期文本（yyyy-MM-dd）。
    private var tradeDateText: String {
        DateOnlyFormatter.string(from: tradeDate)
    }

    /// 按交易日期 + 时段算出的确认净值日文本。
    private var acceptedDateText: String {
        TradingCalendar.acceptedTradeDate(positionDate: tradeDateText, timeType: tradeTimeType)
    }

    /// 金额输入解析为 Double（非法或空返回 nil）。
    private var inputAmount: Double? {
        Self.number(amount)
    }

    /// 份额输入解析为 Double（非法或空返回 nil）。
    private var inputShares: Double? {
        Self.number(shares)
    }

    /// 买入费率解析（>=0，仅买入且金额模式有效）。
    private var inputBuyFeeRate: Double? {
        guard action == .buy, effectiveMode == .amount else { return nil }
        guard let value = Self.number(buyFeeRate), value >= 0 else { return nil }
        return value
    }

    /// 卖出费用解析（>=0，仅卖出有效）。
    private var inputSellFeeValue: Double? {
        guard action == .sell else { return nil }
        guard let value = Self.number(sellFeeValue), value >= 0 else { return nil }
        return value
    }

    /// 买入净额：金额 / (1 + 费率%)，即扣除费率后用于申购的净额。
    private var estimatedBuyNetAmount: Double? {
        guard let amount = inputAmount else { return nil }
        let feeRate = inputBuyFeeRate ?? 0
        return amount / (1 + feeRate / 100)
    }

    /// 买入预估手续费：金额 - 净额（最低 0）。
    private var estimatedBuyFee: Double? {
        guard let amount = inputAmount,
              let netAmount = estimatedBuyNetAmount
        else { return nil }
        return max(0, amount - netAmount)
    }

    /// 买入预估份额：净额 / 参考净值（保留 2 位）。
    private var estimatedBuyShares: Double? {
        guard action == .buy,
              let netAmount = estimatedBuyNetAmount,
              let referenceNetValue,
              referenceNetValue > 0
        else { return nil }
        return rounded(netAmount / referenceNetValue, places: 2)
    }

    /// 卖出预计回款：毛额 - 手续费。
    private var estimatedSellReturn: Double? {
        guard let grossAmount = estimatedSellGrossAmount,
              let fee = estimatedSellFee
        else { return nil }
        return grossAmount - fee
    }

    /// 卖出毛额：份额 × 参考净值。
    private var estimatedSellGrossAmount: Double? {
        guard action == .sell,
              let shares = inputShares,
              let referenceNetValue,
              referenceNetValue > 0
        else { return nil }
        return shares * referenceNetValue
    }

    /// 卖出手续费：按费率(毛额×费率%)或按金额。
    private var estimatedSellFee: Double? {
        guard let grossAmount = estimatedSellGrossAmount,
              let feeValue = inputSellFeeValue
        else { return nil }
        switch sellFeeMode {
        case .rate:
            return grossAmount * feeValue / 100
        case .amount:
            return feeValue
        }
    }

    /// 仅用于展示的近似回款（无净值时用估算价测算，不写入持仓计算）。
    // Display-only approximation; keep it out of persisted trades and position math.
    private var displayOnlyApproximateSellReturn: Double? {
        guard referenceNetValue == nil,
              let grossAmount = displayOnlyApproximateSellGrossAmount,
              let fee = displayOnlyApproximateSellFee
        else { return nil }
        return max(0, grossAmount - fee)
    }

    /// 仅用于展示的近似卖出毛额：份额 × 估算单价（不写入持仓计算）。
    private var displayOnlyApproximateSellGrossAmount: Double? {
        guard action == .sell,
              let shares = inputShares,
              let price = displayOnlyApproximateSellPrice,
              price > 0
        else { return nil }
        return shares * price
    }

    /// 仅用于展示的估算卖出单价：基于成本或市值×当日涨跌，已更新则用成本；不写入持仓计算。
    private var displayOnlyApproximateSellPrice: Double? {
        guard action == .sell,
              fund.todayRate.isFinite
        else { return nil }
        let basePrice: Double?
        if let currentAmount = fund.currentAmount,
           let totalShares = fund.migratedShares,
           currentAmount > 0,
           totalShares > 0 {
            basePrice = currentAmount / totalShares
        } else if let cost = fund.migratedCost,
                  cost > 0 {
            basePrice = cost
        } else {
            basePrice = nil
        }
        guard let basePrice, basePrice > 0 else { return nil }
        if fund.isUpdated {
            return basePrice
        }
        guard fund.todayRate != 0 else { return nil }
        return basePrice * (1 + fund.todayRate / 100)
    }

    /// 仅用于展示的近似卖出手续费（按费率或金额）。
    private var displayOnlyApproximateSellFee: Double? {
        guard let grossAmount = displayOnlyApproximateSellGrossAmount,
              let feeValue = inputSellFeeValue
        else { return nil }
        switch sellFeeMode {
        case .rate:
            return grossAmount * feeValue / 100
        case .amount:
            return feeValue
        }
    }

    /// 卖出费用显示文本：费率模式显示“x%”，金额模式显示金额。
    private var sellFeeValueText: String {
        let value = inputSellFeeValue ?? 0
        switch sellFeeMode {
        case .rate:
            return "\(numberText(value, places: 2))%"
        case .amount:
            return MoneyFormatter.plainMoney(value)
        }
    }

    /// 卖出单价显示：有净值显示净值，无则显示近似价（橙色），否则“待确认”。
    @ViewBuilder
    private var sellPriceDisplayValue: some View {
        if let referenceNetValue {
            Text(MoneyFormatter.plainMoney(referenceNetValue))
        } else if let displayOnlyApproximateSellPrice {
            Text("≈ \(MoneyFormatter.plainMoney(displayOnlyApproximateSellPrice))")
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else {
            Text("待确认")
        }
    }

    /// 卖出手续费显示：精确值、近似值（橙色）或“待计算”。
    @ViewBuilder
    private var sellFeeDisplayValue: some View {
        if let estimatedSellFee {
            Text(MoneyFormatter.plainMoney(estimatedSellFee))
        } else if let displayOnlyApproximateSellFee {
            Text("≈ \(MoneyFormatter.plainMoney(displayOnlyApproximateSellFee))")
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else {
            Text("待计算")
        }
    }

    /// 预计回款显示：精确值、近似值（橙色）或“待计算”。
    @ViewBuilder
    private var sellReturnDisplayValue: some View {
        if let estimatedSellReturn {
            Text(MoneyFormatter.plainMoney(estimatedSellReturn))
        } else if let displayOnlyApproximateSellReturn {
            Text("≈ \(MoneyFormatter.plainMoney(displayOnlyApproximateSellReturn))")
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else {
            Text("待计算")
        }
    }

    /// 交易后预览份额：买入相加、卖出相减（最低 0）。
    private var previewShares: Double? {
        let currentShares = fund.migratedShares ?? 0
        switch action {
        case .buy:
            guard let estimatedBuyShares else { return nil }
            return currentShares + estimatedBuyShares
        case .sell:
            guard let inputShares else { return nil }
            return max(0, currentShares - inputShares)
        }
    }

    /// 交易前持仓市值（当前份额 × 参考净值）。
    private var previewCurrentValueBefore: Double? {
        guard let referenceNetValue else { return nil }
        return (fund.migratedShares ?? 0) * referenceNetValue
    }

    /// 交易后持仓市值（预览份额 × 参考净值）。
    private var previewCurrentValueAfter: Double? {
        guard let previewShares, let referenceNetValue else { return nil }
        return previewShares * referenceNetValue
    }

    /// 仅用于展示的交易前市值（无净值时用估算单价）。
    private var displayOnlyApproximateCurrentValueBefore: Double? {
        guard referenceNetValue == nil,
              let price = displayOnlyApproximateSellPrice
        else { return nil }
        return (fund.migratedShares ?? 0) * price
    }

    /// 仅用于展示的交易后市值（无净值时用估算单价）。
    private var displayOnlyApproximateCurrentValueAfter: Double? {
        guard referenceNetValue == nil,
              let previewShares,
              let price = displayOnlyApproximateSellPrice
        else { return nil }
        return previewShares * price
    }

    /// 交易前市值显示：精确值、近似值（橙色）或“--”。
    @ViewBuilder
    private var previewCurrentValueBeforeDisplayValue: some View {
        if let previewCurrentValueBefore {
            Text(MoneyFormatter.plainMoney(previewCurrentValueBefore))
                .foregroundStyle(.secondary)
        } else if let displayOnlyApproximateCurrentValueBefore {
            Text("≈ \(MoneyFormatter.plainMoney(displayOnlyApproximateCurrentValueBefore))")
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else {
            Text("--")
                .foregroundStyle(.secondary)
        }
    }

    /// 交易后市值显示：精确值、近似值（橙色）或“待计算”。
    @ViewBuilder
    private var previewCurrentValueAfterDisplayValue: some View {
        if let previewCurrentValueAfter {
            Text(MoneyFormatter.plainMoney(previewCurrentValueAfter))
        } else if let displayOnlyApproximateCurrentValueAfter {
            Text("≈ \(MoneyFormatter.plainMoney(displayOnlyApproximateCurrentValueAfter))")
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else {
            Text("待计算")
        }
    }

    /// 参考净值文本（无则“待确认”）。
    private var referencePriceText: String {
        referenceNetValue.map { MoneyFormatter.plainMoney($0) } ?? "待确认"
    }

    /// 参考净值脚注：说明使用哪日净值，或净值未取到时加入待确认。
    private var referenceFootnote: String {
        if let referenceNetValueDate {
            return "使用 \(referenceNetValueDate) 净值测算"
        }
        return "该日净值未取到时会加入待确认"
    }

    /// 测算依据说明：基于当前参考净值，或未取到净值时确认后保持待确认。
    private var referenceBasisText: String {
        if referenceNetValue == nil {
            return "*净值未取到，确认后将保持待确认"
        }
        return "*基于当前参考净值测算"
    }

    /// 卖出份额占位符：显示当前最多可卖份额。
    private var availableSharePlaceholder: String {
        if action == .sell {
            return "最多 \(numberText(fund.migratedShares ?? 0, places: 2)) 份"
        }
        return "请输入加仓份额"
    }

    /// 通用卡片分区容器：标题 + 自定义内容，统一卡片背景与描边。
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(cardBorder(cornerRadius: 10))
    }

    /// 表单字段封装：上方标题 + 下方内容视图的纵向布局。
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// 确认行便利方法：标题 + 字符串值的右对齐展示。
    private func confirmationRow(_ title: String, _ value: String) -> some View {
        confirmationRow(title) {
            Text(value)
        }
    }

    /// 确认行：标题 + 自定义值视图的右对齐展示（最多两行）。
    private func confirmationRow<Value: View>(
        _ title: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .lineLimit(2)
        }
    }

    /// 预览格便利方法：标题 + 前后字符串值（箭头连接）。
    private func previewTile(title: String, before: String, after: String) -> some View {
        previewTile(title: title) {
            Text(before)
                .foregroundStyle(.secondary)
        } after: {
            Text(after)
        }
    }

    /// 预览格：标题 + 前/后自定义视图（箭头连接），展示交易前后变化。
    private func previewTile<Before: View, After: View>(
        title: String,
        @ViewBuilder before: () -> Before,
        @ViewBuilder after: () -> After
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                before()
                Text("→")
                    .foregroundStyle(.tertiary)
                after()
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 8))
    }

    /// 错误文案视图（红色，最多两行）。
    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.red)
            .lineLimit(2)
    }

    /// 选择器按钮：选中态高亮，点击执行切换动作。
    private func selectorButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? actionColor : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    isSelected ? Color(nsColor: .textBackgroundColor).opacity(0.94) : PanelDesign.inputBackground.opacity(0.88),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            isSelected ? actionColor.opacity(0.18) : Color(nsColor: .separatorColor).opacity(0.42),
                            lineWidth: 0.6
                        )
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 单行输入框：占位符 + 文本绑定 + 后缀单位（带输入框样式）。
    private func plainTextField(_ placeholder: String, text: Binding<String>, suffix: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .monospacedDigit()
            Text(suffix)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.6)
        )
    }

    /// 卡片描边视图（分隔线色细描边）。
    private func cardBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.6)
    }

    /// 提交：确认态则保存交易，否则进入确认页（清空错误）。
    private func submit() {
        guard canSubmit else { return }
        if isConfirming {
            save()
        } else {
            errorMessage = nil
            isConfirming = true
        }
    }

    /// 组装交易草稿并写入：编辑走 editTradeRecord，新增走 adjustFundPosition；成功后回调并关闭。
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        let draftMode = effectiveMode
        let draft = FundTradeDraft(
            action: action,
            code: fund.code,
            mode: draftMode,
            amount: draftMode == .amount ? Self.number(amount) : nil,
            shares: draftMode == .share ? Self.number(shares) : nil,
            tradeDate: DateOnlyFormatter.string(from: tradeDate),
            tradeTimeType: tradeTimeType,
            buyFeeRate: action == .buy && draftMode == .amount ? inputBuyFeeRate : nil,
            sellFeeMode: action == .sell ? sellFeeMode : nil,
            sellFeeValue: action == .sell ? inputSellFeeValue : nil
        )

        Task {
            do {
                if let editingRecord {
                    try await store.editTradeRecord(id: editingRecord.id, with: draft)
                } else {
                    try await store.adjustFundPosition(draft)
                }
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

    /// 取消参考净值任务并关闭编辑器。
    private func close() {
        referenceTask?.cancel()
        onClose?()
    }

    /// 按指定位数格式化数值为字符串。
    private func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)))
    }

    /// 初始化回填用的数值格式化（按指定位数）。
    private static func initialNumberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)))
    }

    /// 把输入文本解析为 Double（去千分位逗号，空或非法返回 nil）。
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    /// 切换日期/时段后异步拉取交易参考净值，回填净值与日期，并清理旧任务。
    private func scheduleReferenceNetValueLookup() {
        referenceTask?.cancel()
        let code = fund.code
        let tradeDate = tradeDateText
        let timeType = tradeTimeType
        isLoadingReferenceNetValue = true
        referenceNetValue = nil
        referenceNetValueDate = nil
        referenceTask = Task {
            let result = await store.fetchTradeReferenceNetValue(
                code: code,
                tradeDate: tradeDate,
                timeType: timeType
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                referenceNetValue = result?.value
                referenceNetValueDate = result?.date
                isLoadingReferenceNetValue = false
            }
        }
    }

    /// 按指定位数四舍五入（用于份额等精度控制）。
    private func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
