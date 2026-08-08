import SwiftUI

/// 基金转换编辑器（新增 / 编辑一笔“转出某基金并转入目标基金”的操作）。
/// 用户选择目标基金、填写份额与费用、选择交易日期/时段，提交前先进入“确认”页预览
/// 转换测算（转出金额、费用、预估转入份额）。支持从已有持仓中选择目标，也支持新增基金。
/// 视图自身只负责收集输入与本地计算，真正的落库由 PortfolioStore 完成。
struct FundConversionEditorView: View {
    /// 滚动坐标系名称，用于通过 GeometryReader/PreferenceKey 追踪滚动偏移。
    private static let scrollCoordinateSpaceName = "fundConversionEditorScroll"

    let store: PortfolioStore
    let sourceFund: FundPosition
    let editingRecord: FundTradeRecord?
    let onSaved: (() async -> Void)?
    let onClose: (() -> Void)?

    @State private var targetCode: String
    @State private var targetName: String
    @State private var targetSearchText: String
    @State private var shares: String
    @State private var tradeDate: Date
    @State private var tradeTimeType: PositionTimeType
    @State private var sellFeeMode: TradeFeeMode
    @State private var sellFeeValue: String
    @State private var buyFeeRate: String
    @State private var isSaving = false
    @State private var isConfirming = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var referenceTask: Task<Void, Never>?
    @State private var autoResolvedTargetName: String?
    @State private var sourceQuote: FundQuote?
    @State private var targetQuote: FundQuote?
    @State private var sourceReferenceNetValue: Double?
    @State private var sourceReferenceNetValueDate: String?
    @State private var targetReferenceNetValue: Double?
    @State private var targetReferenceNetValueDate: String?
    @State private var isLookingUpTarget = false
    @State private var isLoadingReferenceValues = false
    @State private var isTargetSuggestionPresented = false
    @State private var showsAllTargetSuggestions = false
    @State private var isSelectingTargetSuggestion = false
    @State private var scrollContentHeight: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var errorMessage: String?
    @FocusState private var isTargetSearchFocused: Bool

    init(
        store: PortfolioStore,
        sourceFund: FundPosition,
        editingRecord: FundTradeRecord? = nil,
        onSaved: (() async -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.sourceFund = sourceFund
        self.editingRecord = editingRecord
        self.onSaved = onSaved
        self.onClose = onClose

        let initialTargetCode: String
        let initialTargetName: String
        if editingRecord?.kind == .conversionIn {
            initialTargetCode = editingRecord?.code ?? ""
            initialTargetName = editingRecord?.name ?? ""
        } else {
            initialTargetCode = editingRecord?.linkedCode ?? ""
            initialTargetName = editingRecord?.linkedName ?? ""
        }
        let initialTargetSearchText: String
        if initialTargetCode.isEmpty {
            initialTargetSearchText = initialTargetName
        } else if initialTargetName.isEmpty {
            initialTargetSearchText = FundCodeFormatter.display(initialTargetCode)
        } else {
            initialTargetSearchText = "\(initialTargetName) \(FundCodeFormatter.display(initialTargetCode))"
        }
        _targetCode = State(initialValue: initialTargetCode)
        _targetName = State(initialValue: initialTargetName)
        _targetSearchText = State(initialValue: initialTargetSearchText)
        _shares = State(
            initialValue: (editingRecord?.shares ?? editingRecord?.confirmedShares).map {
                Self.initialNumberText($0, places: 2)
            } ?? ""
        )
        _tradeDate = State(initialValue: editingRecord.flatMap { DateOnlyFormatter.parse($0.tradeDate) } ?? .now)
        _tradeTimeType = State(initialValue: editingRecord?.tradeTimeType ?? TradingCalendar.defaultPositionTimeType())
        _sellFeeMode = State(initialValue: editingRecord?.sellFeeMode ?? .rate)
        _sellFeeValue = State(initialValue: editingRecord?.sellFeeValue.map { Self.initialNumberText($0, places: 2) } ?? "0")
        _buyFeeRate = State(initialValue: editingRecord?.buyFeeRate.map { Self.initialNumberText($0, places: 2) } ?? "0")
    }

    /// 视图主体：头部 + 可滚动内容区 + 底部操作栏；统一尺寸与面板背景。
    /// onAppear 时解析已有目标、预取目标基金元数据与参考净值；
    /// 多处 onChange 负责在输入变化时刷新测算与候选列表。
    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: PopoverLayout.editorWidth, height: PopoverLayout.standardChildPanelHeight)
        .background(PanelDesign.panelBackground)
        .onAppear {
            resolveExistingTargetIfNeeded()
            scheduleTargetMetadataLookup(for: targetCode)
            scheduleReferenceValueLookup()
            DispatchQueue.main.async {
                isTargetSearchFocused = false
                isTargetSuggestionPresented = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isTargetSearchFocused = false
                isTargetSuggestionPresented = false
            }
        }
        .onChange(of: targetSearchText) { _, newValue in
            handleTargetSearchTextChange(newValue)
            if isSelectingTargetSuggestion {
                isSelectingTargetSuggestion = false
                return
            }
            showsAllTargetSuggestions = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: isTargetSearchFocused) { _, isFocused in
            if !isFocused {
                isTargetSuggestionPresented = false
            }
        }
        .onChange(of: targetCode) { _, newValue in
            resolveExistingTargetIfNeeded()
            scheduleTargetMetadataLookup(for: newValue)
            scheduleReferenceValueLookup()
        }
        .onChange(of: tradeDate) { _, _ in
            isConfirming = false
            scheduleReferenceValueLookup()
        }
        .onChange(of: tradeTimeType) { _, _ in
            isConfirming = false
            scheduleReferenceValueLookup()
        }
        .onDisappear {
            lookupTask?.cancel()
            referenceTask?.cancel()
        }
    }

    /// 头部：转换图标 + 标题/副标题（随“编辑/确认”状态变化）+ 关闭按钮。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(nsColor: .systemOrange), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    FundConversionEditorPresentation.headerTitle(
                        isEditing: editingRecord != nil,
                        isConfirming: isConfirming
                    )
                )
                    .font(.system(size: 15, weight: .semibold))
                Text(
                    FundConversionEditorPresentation.headerSubtitle(
                        isEditing: editingRecord != nil,
                        isConfirming: isConfirming
                    )
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /// 中间可滚动内容区：根据 isConfirming 在“表单”与“确认预览”间切换，
    /// 并叠加一个自定义的滚动条（conversionEditorScrollIndicator）。
    private var content: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ConversionEditorScrollOffsetPreferenceKey.self,
                                value: max(0, -geometry.frame(in: .named(Self.scrollCoordinateSpaceName)).minY)
                            )
                        }
                        .frame(height: 0)

                        Group {
                            if isConfirming {
                                confirmationContent
                            } else {
                                formContent
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ConversionEditorContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                }
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                .scrollIndicators(.hidden)

                conversionEditorScrollIndicator
                    .padding(.trailing, 4)
            }
            .onAppear {
                scrollViewportHeight = proxy.size.height
            }
            .onChange(of: proxy.size.height) { _, newHeight in
                scrollViewportHeight = newHeight
            }
            .onPreferenceChange(ConversionEditorContentHeightPreferenceKey.self) { newHeight in
                scrollContentHeight = newHeight
            }
            .onPreferenceChange(ConversionEditorScrollOffsetPreferenceKey.self) { newOffset in
                if abs(newOffset - scrollOffset) > 1 {
                    isTargetSuggestionPresented = false
                }
                scrollOffset = newOffset
            }
        }
    }

    /// 自定义滚动条：根据内容高度/视口高度/偏移量计算滑块位置与尺寸（隐藏系统滚动条）。
    @ViewBuilder
    private var conversionEditorScrollIndicator: some View {
        if scrollViewportHeight > 0 {
            let contentHeight = max(scrollContentHeight, scrollViewportHeight + 1)
            let trackHeight = max(0, scrollViewportHeight - 20)
            let thumbHeight = min(trackHeight, max(34, trackHeight * scrollViewportHeight / max(contentHeight, 1)))
            let maxScrollOffset = max(contentHeight - scrollViewportHeight, 1)
            let maxThumbOffset = max(trackHeight - thumbHeight, 0)
            let thumbOffset = min(max(scrollOffset / maxScrollOffset, 0), 1) * maxThumbOffset

            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 5, height: trackHeight)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.52))
                        .frame(width: 5, height: thumbHeight)
                        .offset(y: thumbOffset)
                }
                .padding(.vertical, 10)
                .allowsHitTesting(false)
        }
    }

    /// 编辑表单：转出基金 / 转入基金 / 份额 / 费用 / 交易确认 五个区块。
    private var formContent: some View {
        VStack(spacing: 10) {
            sourceSection
            targetSection
            sharesSection
            feeSection
            tradeConfirmSection
            if let errorMessage {
                errorText(errorMessage)
            }
        }
    }

    /// 确认预览：状态横幅 + 转换效果对比 + 交易信息汇总。
    private var confirmationContent: some View {
        VStack(spacing: 10) {
            conversionStatusBanner
            conversionFlowSection
            confirmationSummarySection
            if let errorMessage {
                errorText(errorMessage)
            }
        }
    }

    /// 转出基金区块：只读展示源基金名称、代码与当前可用份额。
    private var sourceSection: some View {
        section("转出基金") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceFund.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(FundCodeFormatter.display(sourceFund.code))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(numberText(sourceFund.migratedShares ?? 0, places: 2)) 份")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Text("当前份额")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 转入基金区块：基金代码/名称组合输入、匹配状态、必要时可填写基金名称。
    private var targetSection: some View {
        section("转入基金") {
            field("基金代码 / 名称") {
                targetComboInput
            }
            targetMatchStatus
            if shouldShowTargetNameField {
                field("基金名称") {
                    plainTextField("可选，留空则使用基金代码", text: $targetName)
                }
            }
        }
        .zIndex(isTargetSuggestionPresented ? 20 : 0)
    }

    /// 目标匹配状态提示：查询中 / 已匹配现有持仓 / 未匹配（将新增基金）。
    @ViewBuilder
    private var targetMatchStatus: some View {
        if isLookingUpTarget {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在读取目标基金信息")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        } else if selectedExistingTargetFund != nil {
            targetStatusText("已匹配现有持仓")
        } else if shouldShowNewTargetStatus {
            targetStatusText("未匹配现有持仓，为新增基金")
        }
    }

    private func targetStatusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    /// 目标基金组合输入：文本框 + 清空按钮 + 下拉候选按钮，背后挂一个原生弹层桥。
    private var targetComboInput: some View {
        HStack(spacing: 6) {
            TextField("输入基金代码/名称，或从右侧选择", text: $targetSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($isTargetSearchFocused)
                .onTapGesture {
                    isTargetSuggestionPresented = true
                    showsAllTargetSuggestions = targetSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

            if !targetSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    clearTargetSelection()
                    isTargetSearchFocused = true
                    isTargetSuggestionPresented = true
                    showsAllTargetSuggestions = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("清空")
            }

            Button {
                showsAllTargetSuggestions = true
                isTargetSuggestionPresented.toggle()
                isTargetSearchFocused = true
            } label: {
                Image(systemName: isTargetSuggestionPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(isTargetSuggestionPresented ? "收起候选" : "选择已有持仓")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 8))
        .background(targetSuggestionPanelBridge)
    }

    /// 把“候选持仓弹层”桥接到 SwiftUI（见文件末尾的 TargetSuggestionPanelBridge）。
    private var targetSuggestionPanelBridge: some View {
        TargetSuggestionPanelBridge(
            isPresented: targetSuggestionPanelBinding,
            funds: targetSuggestionFunds,
            maxHeight: 256,
            onSelect: selectExistingTargetFund
        )
    }

    /// 弹层显隐绑定：仅在“已展开 且 有候选基金”时为真。
    private var targetSuggestionPanelBinding: Binding<Bool> {
        Binding(
            get: { isTargetSuggestionPresented && !targetSuggestionFunds.isEmpty },
            set: { isTargetSuggestionPresented = $0 }
        )
    }

    /// 转出份额区块：份额输入 + 1/4、1/3、1/2、全部 快速填充按钮。
    private var sharesSection: some View {
        section("转出份额") {
            field("份额") {
                plainTextField("最多 \(numberText(sourceFund.migratedShares ?? 0, places: 2))", text: $shares, suffix: "份")
            }
            HStack(spacing: 6) {
                quickShareButton("1/4", fraction: 0.25)
                quickShareButton("1/3", fraction: 1.0 / 3.0)
                quickShareButton("1/2", fraction: 0.5)
                quickShareButton("全部", fraction: 1)
            }
        }
    }

    /// 费用区块：转出费率/费用（按费率或按金额切换）+ 转入费率。
    private var feeSection: some View {
        section("费用") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(sellFeeMode == .rate ? "转出费率" : "转出费用")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    feeModeSelector
                }
                plainTextField(
                    sellFeeMode == .rate ? "例如 0.50" : "请输入转出费用",
                    text: $sellFeeValue,
                    suffix: sellFeeMode == .rate ? "%" : "元"
                )
            }
            field("转入费率") {
                plainTextField("例如 0.12", text: $buyFeeRate, suffix: "%")
            }
        }
    }

    /// 费用模式切换器（费率 % / 固定金额），选中态以橙色胶囊高亮。
    private var feeModeSelector: some View {
        HStack(spacing: 2) {
            ForEach(TradeFeeMode.allCases) { mode in
                Button {
                    guard sellFeeMode != mode else { return }
                    sellFeeMode = mode
                    sellFeeValue = "0"
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: sellFeeMode == mode ? .semibold : .medium))
                        .foregroundStyle(sellFeeMode == mode ? Color(nsColor: .systemOrange) : Color.secondary)
                        .frame(width: 34, height: 20)
                        .background(
                            sellFeeMode == mode ? Color(nsColor: .systemOrange).opacity(0.15) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("切换为\(mode.title)")
            }
        }
        .padding(2)
        .background(PanelDesign.selectorBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 0.6)
        )
    }

    /// 交易确认区块：交易日期、交易时段（时段类型胶囊）、确认净值日提示。
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
            HStack(spacing: 4) {
                ForEach(PositionTimeType.allCases) { value in
                    selectorButton(title: value.title, isSelected: tradeTimeType == value) {
                        tradeTimeType = value
                    }
                }
            }
            .padding(2)
            .background(PanelDesign.selectorBackground, in: Capsule())
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 0.6))

            HStack {
                Text("确认净值日")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(acceptedDateText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(9)
            .background(Color(nsColor: .systemOrange).opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// 确认页的“交易信息”汇总表（逐行展示转换关键参数）。
    private var confirmationSummarySection: some View {
        section("交易信息") {
            VStack(spacing: 9) {
                let summary = confirmationSummary
                ForEach(summary.rows) { row in
                    confirmationRow(row.title, row.value)
                }
                Divider().opacity(0.55)
                Text(summary.footnote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 确认页状态横幅：净值已确认（蓝）/ 未确认（橙）的提示文案。
    private var conversionStatusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: conversionProjection?.isFullyConfirmed == true ? "checkmark.seal.fill" : "clock.badge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(conversionProjection?.isFullyConfirmed == true ? Color(nsColor: .systemBlue) : Color(nsColor: .systemOrange))
            Text(conversionStateText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 确认页“转换效果”：左右两张卡片对比转出与转入的金额/份额测算。
    private var conversionFlowSection: some View {
        section("转换效果") {
            HStack(spacing: 8) {
                conversionFlowCard(
                    title: "转出",
                    fundName: sourceFund.name,
                    code: sourceFund.code,
                    tint: .redFundGreen,
                    metrics: outgoingMetrics
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(width: 20)

                conversionFlowCard(
                    title: "转入",
                    fundName: targetDisplayName,
                    code: targetCode,
                    tint: Color(nsColor: .systemRed),
                    metrics: incomingMetrics
                )
            }
        }
    }

    /// 转出侧指标：份额、净值（确认/估算）、转出金额、转出费用。
    private var outgoingMetrics: [ConversionFlowMetric] {
        let projection = conversionProjection
        return [
            ConversionFlowMetric(title: "转出份额", value: inputShares.map { "\(numberText($0, places: 2)) 份" } ?? "待输入"),
            ConversionFlowMetric(title: projection?.sourcePrice.isConfirmed == true ? "确认净值" : "估算净值", value: priceText(projection?.sourcePrice)),
            ConversionFlowMetric(title: projection?.sourcePrice.isConfirmed == true ? "转出金额" : "预估转出", value: amountText(projection?.grossAmount, isConfirmed: projection?.sourcePrice.isConfirmed == true), isEmphasized: true),
            ConversionFlowMetric(title: "转出费用", value: amountText(projection?.sellFee, isConfirmed: projection?.sourcePrice.isConfirmed == true))
        ]
    }

    /// 转入侧指标：预估份额、净值、预估转入金额、转入费用。
    private var incomingMetrics: [ConversionFlowMetric] {
        let projection = conversionProjection
        return [
            ConversionFlowMetric(title: projection?.targetPrice.isConfirmed == true ? "确认份额" : "预估份额", value: projection.map { "\(numberText($0.targetShares, places: 2)) 份" } ?? "待计算"),
            ConversionFlowMetric(title: projection?.targetPrice.isConfirmed == true ? "确认净值" : "估算净值", value: priceText(projection?.targetPrice)),
            ConversionFlowMetric(title: projection?.sourcePrice.isConfirmed == true ? "转入金额" : "预估转入", value: amountText(projection?.transferAmount, isConfirmed: projection?.sourcePrice.isConfirmed == true), isEmphasized: true),
            ConversionFlowMetric(title: "转入费用", value: amountText(projection?.buyFee, isConfirmed: projection?.sourcePrice.isConfirmed == true))
        ]
    }

    /// 转出/转入对比卡片（标题、基金名、代码、一组指标）。
    private func conversionFlowCard(
        title: String,
        fundName: String,
        code: String,
        tint: Color,
        metrics: [ConversionFlowMetric]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(FundCodeFormatter.display(code))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(fundName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            VStack(spacing: 5) {
                ForEach(metrics) { metric in
                    HStack(alignment: .firstTextBaseline) {
                        Text(metric.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(metric.value)
                            .font(.system(size: 10.5, weight: metric.isEmphasized ? .bold : .semibold))
                            .foregroundStyle(metric.value.hasPrefix("≈") ? Color(nsColor: .systemOrange) : (metric.isEmphasized ? tint : Color.primary))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.8)
        )
    }

    /// 底部操作栏：取消/返回 + 主操作（确认转换 / 保存）。
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if isConfirming {
                    isConfirming = false
                    errorMessage = nil
                } else {
                    onClose?()
                }
            } label: {
                Text(FundConversionEditorPresentation.cancelTitle(isConfirming: isConfirming))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 78, height: 30)
                    .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(PanelDesign.border(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button {
                submit()
            } label: {
                Text(
                    FundConversionEditorPresentation.primaryTitle(
                        isEditing: editingRecord != nil,
                        isConfirming: isConfirming,
                        isSaving: isSaving
                    )
                )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(canSubmit ? Color(nsColor: .systemOrange) : Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

    /// 提交校验：目标代码非空、不等于源基金、份额>0 且不超可用份额、费用输入合法。
    private var canSubmit: Bool {
        !targetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && targetCode.trimmingCharacters(in: .whitespacesAndNewlines) != sourceFund.code
            && (inputShares ?? 0) > 0
            && (inputShares ?? 0) <= (sourceFund.migratedShares ?? 0) + PortfolioPrecision.shareAvailabilityTolerance
            && inputSellFeeValue != nil
            && inputBuyFeeRate != nil
    }

    /// 把份额文本解析为 Double（nil 表示非法）。
    private var inputShares: Double? {
        Self.number(shares)
    }

    /// 转出费用输入（必须为非负数字）。
    private var inputSellFeeValue: Double? {
        guard let value = Self.number(sellFeeValue), value >= 0 else { return nil }
        return value
    }

    /// 转入费率输入（必须为非负数字，单位 %）。
    private var inputBuyFeeRate: Double? {
        guard let value = Self.number(buyFeeRate), value >= 0 else { return nil }
        return value
    }

    /// 交易日期文本（yyyy-MM-dd）。
    private var tradeDateText: String {
        DateOnlyFormatter.string(from: tradeDate)
    }

    /// 由交易日+时段推导出的“确认净值日”（见 TradingCalendar）。
    private var acceptedDateText: String {
        TradingCalendar.acceptedTradeDate(positionDate: tradeDateText, timeType: tradeTimeType)
    }

    /// 净值确认后真正生效的下一个交易日。
    private var executionDateText: String {
        TradingCalendar.nextFundTradingDate(after: acceptedDateText) ?? acceptedDateText
    }

    /// 可作为转入目标的基金：排除源基金与已清仓的零持仓，按名称排序。
    private var availableTargetFunds: [FundPosition] {
        let records = store.snapshot.tradeRecords ?? []
        return store.snapshot.funds
            .filter {
                $0.code != sourceFund.code
                    && !PendingFundDisplayRules.isClosedZeroPosition($0, tradeRecords: records)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 按搜索文本（代码/名称/组合标题）过滤 availableTargetFunds。
    private var matchingTargetFunds: [FundPosition] {
        let trimmedQuery = targetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return availableTargetFunds
        }
        let normalizedQuery = FundCodeFormatter.display(trimmedQuery)
        return availableTargetFunds.filter { fund in
            FundCodeFormatter.display(fund.code).contains(normalizedQuery)
                || fund.name.localizedCaseInsensitiveContains(trimmedQuery)
                || targetOptionTitle(for: fund).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// 候选列表：搜索文本为空时展示全部，否则展示匹配结果。
    private var targetSuggestionFunds: [FundPosition] {
        showsAllTargetSuggestions ? availableTargetFunds : matchingTargetFunds
    }

    /// 若 targetCode 能对应到现有持仓，则返回该基金（用于匹配状态与金额测算）。
    private var selectedExistingTargetFund: FundPosition? {
        let trimmedCode = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return nil }
        return store.snapshot.funds.first {
            $0.code == trimmedCode && $0.code != sourceFund.code
        }
    }

    /// 未匹配到现有持仓（即新增基金）时，额外显示“基金名称”输入框。
    private var shouldShowTargetNameField: Bool {
        shouldShowNewTargetStatus
    }

    /// 判断当前 6 位数字代码是否表示一个“待新增”的未知基金。
    private var shouldShowNewTargetStatus: Bool {
        let trimmedCode = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty,
              selectedExistingTargetFund == nil,
              !isLookingUpTarget
        else { return false }
        return trimmedCode.count == 6 && trimmedCode.allSatisfy(\.isNumber)
    }

    /// 目标基金展示名：优先用填写的名称，否则回退到代码。
    private var targetDisplayName: String {
        let trimmedName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return FundCodeFormatter.display(targetCode)
    }

    /// 组装确认页所需的交易信息汇总（FundConversionConfirmationSummary）。
    private var confirmationSummary: FundConversionConfirmationSummary {
        FundConversionConfirmationSummary.make(
            sourceFund: sourceFund,
            targetCode: targetCode,
            targetName: targetName,
            shares: inputShares ?? 0,
            sellFeeMode: sellFeeMode,
            sellFeeValue: inputSellFeeValue ?? 0,
            buyFeeRate: inputBuyFeeRate ?? 0,
            tradeDate: tradeDateText,
            tradeTimeType: tradeTimeType
        )
    }

    /// 实时计算转换金额测算（依赖行情/参考净值/费用参数）。
    private var conversionProjection: FundConversionAmountProjection? {
        FundConversionAmountProjection.make(
            sourceFund: sourceFund,
            targetFund: selectedExistingTargetFund,
            sourceQuote: sourceQuote,
            targetQuote: targetQuote,
            sourceReferenceNetValue: sourceReferenceNetValue,
            sourceReferenceNetValueDate: sourceReferenceNetValueDate,
            targetReferenceNetValue: targetReferenceNetValue,
            targetReferenceNetValueDate: targetReferenceNetValueDate,
            acceptedDate: acceptedDateText,
            shares: inputShares ?? 0,
            sellFeeMode: sellFeeMode,
            sellFeeValue: inputSellFeeValue ?? 0,
            buyFeeRate: inputBuyFeeRate ?? 0
        )
    }

    /// 确认页状态文案：提示是“已确认”还是“盘中估算参考”。
    private var conversionStateText: String {
        guard let projection = conversionProjection else {
            return "输入转入基金和份额后显示转换测算"
        }
        if projection.isFullyConfirmed {
            return "净值已确认，\(executionDateText) 00:00 后真正更新持仓"
        }
        return "净值未确认，橙色金额仅按盘中估算参考"
    }

    /// 净值文本：未确认时前缀“≈”。
    private func priceText(_ price: FundConversionPriceProjection?) -> String {
        guard let price else { return "待确认" }
        let prefix = price.isConfirmed ? "" : "≈ "
        return "\(prefix)\(numberText(price.value, places: 4))"
    }

    /// 金额文本：未确认时前缀“≈”，nil 显示“待计算”。
    private func amountText(_ value: Double?, isConfirmed: Bool) -> String {
        guard let value else { return "待计算" }
        let prefix = isConfirmed ? "" : "≈ "
        return "\(prefix)\(MoneyFormatter.plainMoney(value))"
    }

    /// 候选下拉项展示标题（名称 + 代码）。
    private func targetOptionTitle(for fund: FundPosition) -> String {
        "\(fund.name) \(FundCodeFormatter.display(fund.code))"
    }

    /// 主操作按钮逻辑：未达提交条件忽略；首次点击进入确认页；确认页再次点击执行保存。
    private func submit() {
        switch FundConversionEditorPresentation.primaryAction(
            canSubmit: canSubmit,
            isSaving: isSaving,
            isConfirming: isConfirming
        ) {
        case .ignore:
            return
        case .showConfirmation:
            errorMessage = nil
            isConfirming = true
            return
        case .save:
            save()
        }
    }

    /// 从候选列表选中一个现有持仓作为目标基金，回填代码/名称并收起弹层。
    private func selectExistingTargetFund(_ fund: FundPosition) {
        isSelectingTargetSuggestion = true
        targetCode = fund.code
        targetName = fund.name
        targetSearchText = targetOptionTitle(for: fund)
        autoResolvedTargetName = fund.name
        targetQuote = nil
        isTargetSuggestionPresented = false
        showsAllTargetSuggestions = false
    }

    /// 清空目标基金选择（代码/名称/候选状态全部复位）。
    private func clearTargetSelection() {
        targetSearchText = ""
        targetCode = ""
        targetName = ""
        autoResolvedTargetName = nil
        targetQuote = nil
    }

    /// 搜索文本变化时的解析：精确匹配现有持仓则回填；6 位数字则当作新代码；否则清空代码。
    private func handleTargetSearchTextChange(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            clearTargetSelection()
            return
        }

        if let exactFund = availableTargetFunds.first(where: {
            FundCodeFormatter.display($0.code) == FundCodeFormatter.display(trimmedValue)
                || $0.name == trimmedValue
                || targetOptionTitle(for: $0) == trimmedValue
        }) {
            targetCode = exactFund.code
            if targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetName == autoResolvedTargetName {
                targetName = exactFund.name
                autoResolvedTargetName = exactFund.name
            }
            return
        }

        if trimmedValue.count == 6, trimmedValue.allSatisfy(\.isNumber) {
            targetCode = trimmedValue
            if targetName == autoResolvedTargetName {
                targetName = ""
                autoResolvedTargetName = nil
            }
        } else {
            targetCode = ""
        }
    }

    /// 若目标匹配到现有持仓且名称未手动修改，则自动同步其名称。
    private func resolveExistingTargetIfNeeded() {
        guard let selectedExistingTargetFund else { return }
        let trimmedName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || targetName == autoResolvedTargetName {
            targetName = selectedExistingTargetFund.name
            autoResolvedTargetName = selectedExistingTargetFund.name
        }
    }

    /// 目标代码变化时，异步查询目标基金行情与名称（已有持仓直接复用，未知代码走网络查询）。
    /// 用 lookupTask 做去重/取消，回到主线程前校验代码未被用户改掉。
    private func scheduleTargetMetadataLookup(for rawCode: String) {
        lookupTask?.cancel()
        let trimmedCode = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode.count == 6, trimmedCode.allSatisfy(\.isNumber) else {
            isLookingUpTarget = false
            targetQuote = nil
            return
        }
        let existingTargetName = selectedExistingTargetFund?.name
        if let existingTargetName {
            isLookingUpTarget = false
            if targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetName == autoResolvedTargetName {
                targetName = existingTargetName
                autoResolvedTargetName = existingTargetName
            }
        }

        isLookingUpTarget = existingTargetName == nil
        lookupTask = Task {
            try? await Task.sleep(nanoseconds: existingTargetName == nil ? 350_000_000 : 0)
            guard !Task.isCancelled else { return }
            let fetchedQuote = await store.fetchLatestQuote(code: trimmedCode)
            let fetchedName: String?
            if let existingTargetName {
                fetchedName = existingTargetName
            } else if let fetchedQuote, fetchedQuote.name != trimmedCode {
                fetchedName = fetchedQuote.name
            } else {
                fetchedName = await store.lookupFundName(code: trimmedCode)
            }
            await MainActor.run {
                guard !Task.isCancelled,
                      targetCode.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCode
                else {
                    return
                }
                targetQuote = fetchedQuote
                if let fetchedName,
                   targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetName == autoResolvedTargetName {
                    targetName = fetchedName
                    autoResolvedTargetName = fetchedName
                }
                isLookingUpTarget = false
            }
        }
    }

    /// 交易日/时段/目标变化时，并发拉取源基金与目标基金的行情与“交易参考净值”，
    /// 用于计算确认/估算净值。回主线程前校验参数未变，避免竞态覆盖。
    private func scheduleReferenceValueLookup() {
        referenceTask?.cancel()
        let sourceCode = sourceFund.code
        let targetCode = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let tradeDate = tradeDateText
        let timeType = tradeTimeType
        sourceReferenceNetValue = nil
        sourceReferenceNetValueDate = nil
        targetReferenceNetValue = nil
        targetReferenceNetValueDate = nil
        isLoadingReferenceValues = true

        referenceTask = Task {
            async let fetchedSourceQuote = store.fetchLatestQuote(code: sourceCode)
            async let fetchedSourceReference = store.fetchTradeReferenceNetValue(
                code: sourceCode,
                tradeDate: tradeDate,
                timeType: timeType
            )
            let fetchedTargetQuote: FundQuote?
            let fetchedTargetReference: (date: String, value: Double)?
            if targetCode.count == 6, targetCode.allSatisfy(\.isNumber) {
                async let quote = store.fetchLatestQuote(code: targetCode)
                async let reference = store.fetchTradeReferenceNetValue(
                    code: targetCode,
                    tradeDate: tradeDate,
                    timeType: timeType
                )
                fetchedTargetQuote = await quote
                fetchedTargetReference = await reference
            } else {
                fetchedTargetQuote = nil
                fetchedTargetReference = nil
            }
            let sourceQuote = await fetchedSourceQuote
            let sourceReference = await fetchedSourceReference
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled,
                      self.tradeDateText == tradeDate,
                      self.tradeTimeType == timeType,
                      self.targetCode.trimmingCharacters(in: .whitespacesAndNewlines) == targetCode
                else {
                    return
                }
                self.sourceQuote = sourceQuote
                self.targetQuote = fetchedTargetQuote
                self.sourceReferenceNetValue = sourceReference?.value
                self.sourceReferenceNetValueDate = sourceReference?.date
                self.targetReferenceNetValue = fetchedTargetReference?.value
                self.targetReferenceNetValueDate = fetchedTargetReference?.date
                self.isLoadingReferenceValues = false
            }
        }
    }

    /// 落库：把表单组装成 FundConversionDraft，调用 PortfolioStore 新增或编辑转换；
    /// 成功后触发 onSaved 并关闭面板，失败则在界面上显示错误。
    private func save() {
        guard let inputShares, let inputSellFeeValue, let inputBuyFeeRate else { return }
        isSaving = true
        errorMessage = nil
        let draft = FundConversionDraft(
            fromCode: sourceFund.code,
            toCode: targetCode,
            toName: targetName,
            shares: inputShares,
            tradeDate: tradeDateText,
            tradeTimeType: tradeTimeType,
            sellFeeMode: sellFeeMode,
            sellFeeValue: inputSellFeeValue,
            buyFeeRate: inputBuyFeeRate
        )
        Task {
            do {
                if let conversionID = editingRecord?.conversionID {
                    try await store.editConversion(id: conversionID, with: draft)
                } else {
                    try await store.convertFundPosition(draft)
                }
                await onSaved?()
                await MainActor.run {
                    isSaving = false
                    onClose?()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 份额快捷按钮（1/4、1/3、1/2、全部）：按源基金可用份额的比例填充。
    private func quickShareButton(_ title: String, fraction: Double) -> some View {
        Button {
            shares = numberText((sourceFund.migratedShares ?? 0) * fraction, places: 2)
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

    /// 通用胶囊选择器按钮（选中态以橙色高亮）。
    private func selectorButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color(nsColor: .systemOrange) : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(isSelected ? Color(nsColor: .systemOrange).opacity(0.16) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 通用“区块”容器（标题 + 圆角卡片背景），用于各设置分组。
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(10)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 区块内的小字段行（左侧标题 + 右侧内容）。
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// 通用单行输入（含可选的右侧单位后缀，如“份”“%”“元”）。
    private func plainTextField(_ placeholder: String, text: Binding<String>, suffix: String? = nil) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
            if let suffix {
                Text(suffix)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 8))
    }

    /// 确认页汇总表里的一行（标题 + 右对齐值）。
    private func confirmationRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .lineLimit(2)
        }
    }

    /// 错误提示文本（红色）。
    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
    }

    /// 把 Double 格式化为固定小数位的文本（委托 FundConversionFormatter）。
    private func numberText(_ value: Double, places: Int) -> String {
        FundConversionFormatter.numberText(value, places: places)
    }

    /// 把用户输入文本（去千分位逗号）解析为 Double，失败返回 nil。
    private static func number(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    /// 初始化用的数字文本（允许 0...places 位小数，用于回填编辑草稿）。
    private static func initialNumberText(_ value: Double, places: Int) -> String {
        FundConversionFormatter.initialNumberText(value, places: places)
    }
}

/// 主操作按钮的三种语义：忽略（条件不满足）、进入确认页、执行保存。
enum FundConversionEditorPrimaryAction: Equatable {
    case ignore
    case showConfirmation
    case save
}

/// 编辑器界面的纯展示文案与动作决策（标题、副标题、按钮文案、submit 动作类型）。
struct FundConversionEditorPresentation {
    static func headerTitle(isEditing: Bool, isConfirming: Bool) -> String {
        if isConfirming {
            return isEditing ? "保存转换确认" : "转换确认"
        }
        return isEditing ? "编辑转换" : "基金转换"
    }

    static func headerSubtitle(isEditing: Bool, isConfirming: Bool) -> String {
        if isConfirming {
            return "确认后写入两条转换记录，净值更新后自动完成"
        }
        if isEditing {
            return "修改后会重新计算两只基金持仓"
        }
        return "记录一笔转出并转入目标基金"
    }

    static func cancelTitle(isConfirming: Bool) -> String {
        isConfirming ? "返回修改" : "取消"
    }

    static func primaryTitle(isEditing: Bool, isConfirming: Bool, isSaving: Bool) -> String {
        if isSaving {
            return isEditing ? "保存中" : "转换中"
        }
        if isEditing {
            return isConfirming ? "确认保存" : "保存确认"
        }
        return isConfirming ? "确认转换" : "转换确认"
    }

    static func primaryAction(canSubmit: Bool, isSaving: Bool, isConfirming: Bool) -> FundConversionEditorPrimaryAction {
        guard canSubmit, !isSaving else { return .ignore }
        return isConfirming ? .save : .showConfirmation
    }
}

/// 确认页“交易信息”汇总的数据模型（行集合 + 脚注）。
struct FundConversionConfirmationSummary: Equatable {
    struct Row: Identifiable, Equatable {
        let title: String
        let value: String

        var id: String {
            title
        }
    }

    let rows: [Row]
    let footnote: String

    static func make(
        sourceFund: FundPosition,
        targetCode: String,
        targetName: String,
        shares: Double,
        sellFeeMode: TradeFeeMode,
        sellFeeValue: Double,
        buyFeeRate: Double,
        tradeDate: String,
        tradeTimeType: PositionTimeType
    ) -> FundConversionConfirmationSummary {
        let trimmedTargetCode = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDisplayName = trimmedTargetName.isEmpty ? FundCodeFormatter.display(trimmedTargetCode) : trimmedTargetName
        let acceptedDate = TradingCalendar.acceptedTradeDate(positionDate: tradeDate, timeType: tradeTimeType)

        return FundConversionConfirmationSummary(
            rows: [
                Row(title: "转出基金", value: "\(sourceFund.name) \(FundCodeFormatter.display(sourceFund.code))"),
                Row(title: "转入基金", value: "\(targetDisplayName) \(FundCodeFormatter.display(trimmedTargetCode))"),
                Row(title: "转出份额", value: "\(FundConversionFormatter.numberText(shares, places: 2)) 份"),
                Row(title: "转出费率/费用", value: feeText(mode: sellFeeMode, value: sellFeeValue)),
                Row(title: "转入费率", value: "\(FundConversionFormatter.numberText(buyFeeRate, places: 2))%"),
                Row(title: "交易日期", value: tradeDate),
                Row(title: "交易时段", value: tradeTimeType.title),
                Row(title: "确认净值日", value: acceptedDate)
            ],
            footnote: "*净值未取到时会先进入待确认，净值更新后自动完成转换"
        )
    }

    private static func feeText(mode: TradeFeeMode, value: Double) -> String {
        switch mode {
        case .rate:
            return "\(FundConversionFormatter.numberText(value, places: 2))%"
        case .amount:
            return MoneyFormatter.plainMoney(value)
        }
    }
}

/// 转换效果卡片中的单个指标（标题 + 值 + 是否强调）。
struct ConversionFlowMetric: Identifiable, Equatable {
    let title: String
    let value: String
    var isEmphasized = false

    var id: String {
        title
    }
}

/// 单个基金的净值投影：数值 + 是否已确认（参考净值/行情净值 vs 盘中估算）。
struct FundConversionPriceProjection: Equatable {
    var value: Double
    var isConfirmed: Bool
}

/// 整笔转换的金额测算结果（转出/转入净值、各项金额、预估转入份额）。
/// make 与 priceProjection 负责按“参考净值 > 行情净值 > 盘中估算 > 成本/市值推算”的优先级取值。
struct FundConversionAmountProjection: Equatable {
    var sourcePrice: FundConversionPriceProjection
    var targetPrice: FundConversionPriceProjection
    var grossAmount: Double
    var sellFee: Double
    var transferAmount: Double
    var buyFee: Double
    var targetShares: Double

    var isFullyConfirmed: Bool {
        sourcePrice.isConfirmed && targetPrice.isConfirmed
    }

    static func make(
        sourceFund: FundPosition,
        targetFund: FundPosition?,
        sourceQuote: FundQuote?,
        targetQuote: FundQuote?,
        sourceReferenceNetValue: Double?,
        sourceReferenceNetValueDate: String?,
        targetReferenceNetValue: Double?,
        targetReferenceNetValueDate: String?,
        acceptedDate: String,
        shares: Double,
        sellFeeMode: TradeFeeMode,
        sellFeeValue: Double,
        buyFeeRate: Double
    ) -> FundConversionAmountProjection? {
        guard shares > 0,
              let sourcePrice = priceProjection(
                fund: sourceFund,
                quote: sourceQuote,
                referenceNetValue: sourceReferenceNetValue,
                referenceNetValueDate: sourceReferenceNetValueDate,
                acceptedDate: acceptedDate
              ),
              let targetPrice = priceProjection(
                fund: targetFund,
                quote: targetQuote,
                referenceNetValue: targetReferenceNetValue,
                referenceNetValueDate: targetReferenceNetValueDate,
                acceptedDate: acceptedDate
              ),
              targetPrice.value > 0
        else {
            return nil
        }

        let grossAmount = rounded(shares * sourcePrice.value, places: 2)
        let sellFee = rounded(conversionFeeAmount(grossAmount: grossAmount, mode: sellFeeMode, value: sellFeeValue), places: 2)
        let transferAmount = rounded(max(grossAmount - sellFee, 0), places: 2)
        let buyNetAmount = transferAmount / (1 + max(buyFeeRate, 0) / 100)
        let buyFee = rounded(transferAmount - buyNetAmount, places: 2)
        let targetShares = rounded(buyNetAmount / targetPrice.value, places: 2)

        return FundConversionAmountProjection(
            sourcePrice: sourcePrice,
            targetPrice: targetPrice,
            grossAmount: grossAmount,
            sellFee: sellFee,
            transferAmount: transferAmount,
            buyFee: buyFee,
            targetShares: targetShares
        )
    }

    private static func priceProjection(
        fund: FundPosition?,
        quote: FundQuote?,
        referenceNetValue: Double?,
        referenceNetValueDate: String?,
        acceptedDate: String
    ) -> FundConversionPriceProjection? {
        if referenceNetValueDate == acceptedDate,
           let referenceNetValue,
           referenceNetValue > 0 {
            return FundConversionPriceProjection(value: referenceNetValue, isConfirmed: true)
        }
        if quote?.netValueDate == acceptedDate,
           let netValue = quote?.netValue,
           netValue > 0 {
            return FundConversionPriceProjection(value: netValue, isConfirmed: true)
        }
        if let estimatedNetValue = quote?.estimatedNetValue,
           estimatedNetValue > 0 {
            return FundConversionPriceProjection(value: estimatedNetValue, isConfirmed: false)
        }
        guard let fund else { return nil }
        if let currentAmount = fund.currentAmount,
           let totalShares = fund.migratedShares,
           currentAmount > 0,
           totalShares > 0 {
            let basePrice = currentAmount / totalShares
            if fund.isUpdated {
                return FundConversionPriceProjection(value: basePrice, isConfirmed: true)
            }
            return FundConversionPriceProjection(value: basePrice * (1 + fund.todayRate / 100), isConfirmed: false)
        }
        if let cost = fund.migratedCost,
           cost > 0 {
            if fund.isUpdated {
                return FundConversionPriceProjection(value: cost, isConfirmed: true)
            }
            return FundConversionPriceProjection(value: cost * (1 + fund.todayRate / 100), isConfirmed: false)
        }
        return nil
    }

    private static func conversionFeeAmount(grossAmount: Double, mode: TradeFeeMode, value: Double) -> Double {
        let normalizedValue = max(value, 0)
        switch mode {
        case .rate:
            return grossAmount * normalizedValue / 100
        case .amount:
            return min(grossAmount, normalizedValue)
        }
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// 编辑器专用数字格式化工具。
enum FundConversionFormatter {
    static func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    static func initialNumberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)))
    }
}

private struct ConversionEditorContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversionEditorScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 把“目标基金候选下拉”实现为原生 NSPanel（避免 SwiftUI popover 的焦点/定位问题）。
/// 在 SwiftUI 中只是一个零尺寸 NSView 锚点，真正的弹层由 Coordinator 管理。
private struct TargetSuggestionPanelBridge: NSViewRepresentable {
    @Binding var isPresented: Bool
    let funds: [FundPosition]
    let maxHeight: CGFloat
    let onSelect: (FundPosition) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            funds: funds,
            maxHeight: maxHeight,
            anchorView: view,
            onSelect: onSelect
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var panel: NSPanel?
        private var hostingView: NSHostingView<AnyView>?
        private weak var parentWindow: NSWindow?

        private let rowHeight: CGFloat = 32
        private let verticalPadding: CGFloat = 8
        private let horizontalInset: CGFloat = 14
        private let gap: CGFloat = 6

        @MainActor
        func update(
            isPresented: Bool,
            funds: [FundPosition],
            maxHeight: CGFloat,
            anchorView: NSView,
            onSelect: @escaping (FundPosition) -> Void
        ) {
            guard isPresented, !funds.isEmpty, let window = anchorView.window else {
                close()
                return
            }

            let contentSize = contentSize(for: funds, maxHeight: maxHeight, anchorView: anchorView, parentWindow: window)
            let content = TargetSuggestionPanelContent(
                funds: funds,
                onSelect: onSelect
            )
            .frame(width: contentSize.width, height: contentSize.height)

            let panel = ensurePanel(parentWindow: window, size: contentSize)
            updateContent(content, size: contentSize, panel: panel)

            guard let frame = panelFrame(size: contentSize, anchorView: anchorView, parentWindow: window) else {
                close()
                return
            }

            panel.setFrame(frame, display: true)
            if panel.parent == nil || parentWindow !== window {
                parentWindow?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
                parentWindow = window
            }
            panel.orderFrontRegardless()
        }

        @MainActor
        func close() {
            if let panel {
                parentWindow?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            parentWindow = nil
        }

        @MainActor
        private func ensurePanel(parentWindow: NSWindow, size: CGSize) -> NSPanel {
            if let panel {
                return panel
            }

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.level = parentWindow.level
            panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
            self.panel = panel
            return panel
        }

        @MainActor
        private func updateContent(_ content: some View, size: CGSize, panel: NSPanel) {
            if let hostingView {
                hostingView.rootView = PanelFocusAppearance.suppressedRoot(content)
            } else {
                let hostingView = PanelFocusAppearance.hostingView(content)
                hostingView.wantsLayer = true
                hostingView.layer?.backgroundColor = NSColor.clear.cgColor
                hostingView.autoresizingMask = [.width, .height]
                panel.contentView = hostingView
                self.hostingView = hostingView
            }
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView?.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height))
        }

        @MainActor
        private func contentSize(
            for funds: [FundPosition],
            maxHeight: CGFloat,
            anchorView: NSView,
            parentWindow: NSWindow
        ) -> CGSize {
            let anchorWidth = max(anchorView.bounds.width, 260)
            let width = min(anchorWidth, parentWindow.frame.width - horizontalInset * 2)
            let contentHeight = CGFloat(funds.count) * rowHeight + verticalPadding
            let availableHeight = max(96, parentWindow.frame.height - 132)
            return CGSize(width: width, height: min(contentHeight, maxHeight, availableHeight))
        }

        @MainActor
        private func panelFrame(size: CGSize, anchorView: NSView, parentWindow: NSWindow) -> NSRect? {
            guard let anchorWindow = anchorView.window else { return nil }
            let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
            let anchorRect = anchorWindow.convertToScreen(anchorRectInWindow)
            let parentFrame = parentWindow.frame

            let x = min(
                max(anchorRect.minX, parentFrame.minX + horizontalInset),
                parentFrame.maxX - size.width - horizontalInset
            )
            let availableBelow = anchorRect.minY - parentFrame.minY - horizontalInset
            let availableAbove = parentFrame.maxY - anchorRect.maxY - horizontalInset
            let y: CGFloat
            if availableBelow >= size.height || availableBelow >= availableAbove {
                y = max(parentFrame.minY + horizontalInset, anchorRect.minY - gap - size.height)
            } else {
                y = min(parentFrame.maxY - horizontalInset - size.height, anchorRect.maxY + gap)
            }

            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }
}

/// 候选弹层内的真实内容（可滚动基金列表，点击即选中）。
private struct TargetSuggestionPanelContent: View {
    let funds: [FundPosition]
    let onSelect: (FundPosition) -> Void

    /// 视图主体：头部 + 可滚动内容区 + 底部操作栏；统一尺寸与面板背景。
    /// onAppear 时解析已有目标、预取目标基金元数据与参考净值；
    /// 多处 onChange 负责在输入变化时刷新测算与候选列表。
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(funds) { fund in
                    Button {
                        onSelect(fund)
                    } label: {
                        HStack(spacing: 8) {
                            Text(fund.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(FundCodeFormatter.display(fund.code))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.visible)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 9))
    }
}
