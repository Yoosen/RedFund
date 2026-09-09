import AppKit
import SwiftUI

/// 主弹窗（菜单栏点开后的核心界面）相关视图集合。
/// - MainPanelWindowView：弹窗“外壳”——带箭头的气泡形状、可拖拽改变高度、内嵌 PopoverContentView。
/// - PopoverContentView：弹窗“内容”——头部总览（金额/收益/实时收益、更新提示、待确认影响）、
///   工具栏（筛选/排序/操作）、基金列表（或待确认列表）、底部大盘指数条。
/// 所有交互都通过初始化时注入的回调上抛给 StatusBarController 处理。

struct MainPanelWindowView: View {
    let store: PortfolioStore
    let settingsStore: AppSettingsStore
    let marketIndexStore: MarketIndexStore
    let updateStore: AppUpdateStore
    let uiState: PopoverUIState
    @Binding var selectedFundCode: String?
    let onRefresh: (() async -> Void)?
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onOpenPortfolioBreakdown: () -> Void
    let onOpenTodayIncomeRanking: () -> Void
    let onOpenTodayRateRanking: () -> Void
    let onOpenHoldingIncomeRanking: () -> Void
    let onOpenHoldingRateRanking: () -> Void
    let onAddFund: () -> Void
    let onOpenFundDetail: (FundPosition) -> Void
    let onOpenTradeRecords: (FundPosition) -> Void
    let onOpenPendingActivity: (PendingTradeActivity) -> Void
    let onDeletePendingActivity: (PendingTradeActivity) async -> Void
    let onBuyFund: (FundPosition) -> Void
    let onSellFund: (FundPosition) -> Void
    let onEditFund: (FundPosition) -> Void
    let onDeleteFund: (FundPosition) async -> Void
    let onCheckUpdate: (() async -> Void)?
    let onOpenUpdate: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let contentHeight = mainPanelContentHeight(for: proxy.size.height)
            let windowHeight = contentHeight + PopoverLayout.arrowHeight

            ZStack(alignment: .top) {
                PopoverChromeShape(arrowX: uiState.arrowX)
                    .fill(popoverChromeFillColor)
                    .overlay(
                        PopoverChromeShape(arrowX: uiState.arrowX)
                            .stroke(panelBorderColor, lineWidth: 0.5)
                    )

                PopoverContentView(
                    store: store,
                    settingsStore: settingsStore,
                    marketIndexStore: marketIndexStore,
                    updateStore: updateStore,
                    selectedFundCode: $selectedFundCode,
                    onRefresh: onRefresh,
                    onOpenSettings: onOpenSettings,
                    onOpenPortfolioBreakdown: onOpenPortfolioBreakdown,
                    onOpenTodayIncomeRanking: onOpenTodayIncomeRanking,
                    onOpenTodayRateRanking: onOpenTodayRateRanking,
                    onOpenHoldingIncomeRanking: onOpenHoldingIncomeRanking,
                    onOpenHoldingRateRanking: onOpenHoldingRateRanking,
                    onAddFund: onAddFund,
                    onOpenFundDetail: onOpenFundDetail,
                    onOpenTradeRecords: onOpenTradeRecords,
                    onOpenPendingActivity: onOpenPendingActivity,
                    onDeletePendingActivity: onDeletePendingActivity,
                    onBuyFund: onBuyFund,
                    onSellFund: onSellFund,
                    onEditFund: onEditFund,
                    onDeleteFund: onDeleteFund,
                    onCheckUpdate: onCheckUpdate,
                    onOpenUpdate: onOpenUpdate
                )
                .frame(width: PopoverLayout.mainWidth, height: contentHeight)
                .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius, style: .continuous))
                .offset(y: PopoverLayout.arrowHeight)

                MainPanelBottomResizeArea(settingsStore: settingsStore)
                    .frame(height: bottomResizeEdgeHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(10)
            }
            .frame(width: PopoverLayout.mainWidth, height: windowHeight, alignment: .top)
        }
        .frame(width: PopoverLayout.mainWidth)
        .background(Color.clear)
    }

    private func mainPanelContentHeight(for proposedWindowHeight: CGFloat) -> CGFloat {
        guard proposedWindowHeight > PopoverLayout.arrowHeight else {
            return PopoverLayout.clampedMainPanelHeight(CGFloat(settingsStore.settings.mainPanelHeight))
        }
        return PopoverLayout.clampedMainPanelHeight(proposedWindowHeight - PopoverLayout.arrowHeight)
    }

    private var popoverChromeFillColor: Color {
        PanelDesign.panelChromeBackground
    }

    private var bottomResizeEdgeHeight: CGFloat {
        12
    }
}

private struct MainPanelBottomResizeArea: NSViewRepresentable {
    let settingsStore: AppSettingsStore

    func makeNSView(context: Context) -> MainPanelBottomResizeView {
        MainPanelBottomResizeView(settingsStore: settingsStore)
    }

    func updateNSView(_ view: MainPanelBottomResizeView, context: Context) {
        view.settingsStore = settingsStore
    }
}

private final class MainPanelBottomResizeView: NSView {
    var settingsStore: AppSettingsStore
    private var dragStartFrame: NSRect?
    private var dragStartMouseLocation: NSPoint?

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartFrame = window?.frame
        dragStartMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let dragStartFrame,
              let dragStartMouseLocation
        else { return }

        let currentMouseLocation = NSEvent.mouseLocation
        let minWindowHeight = PopoverLayout.mainWindowHeight(forHeight: CGFloat(AppSettings.minMainPanelHeight))
        let maxWindowHeight = PopoverLayout.mainWindowHeight(forHeight: CGFloat(AppSettings.maxMainPanelHeight))
        let proposedHeight = dragStartFrame.height + dragStartMouseLocation.y - currentMouseLocation.y
        let nextHeight = min(max(proposedHeight, minWindowHeight), maxWindowHeight)
        let nextFrame = NSRect(
            x: dragStartFrame.minX,
            y: dragStartFrame.maxY - nextHeight,
            width: PopoverLayout.mainWidth,
            height: nextHeight
        )
        window.setFrame(nextFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartFrame = nil
            dragStartMouseLocation = nil
        }

        guard let window else { return }
        let contentHeight = PopoverLayout.clampedMainPanelHeight(window.frame.height - PopoverLayout.arrowHeight)
        settingsStore.setMainPanelHeight(Int(contentHeight.rounded()))
    }
}

private struct PopoverChromeShape: Shape {
    let arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = PopoverLayout.cornerRadius
        let panelY = PopoverLayout.arrowHeight
        let arrowHalf = PopoverLayout.arrowWidth / 2
        let x = min(max(arrowX, radius + arrowHalf), rect.width - radius - arrowHalf)

        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x + arrowHalf, y: panelY))
        path.addLine(to: CGPoint(x: rect.width - radius, y: panelY))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: panelY + radius), control: CGPoint(x: rect.width, y: panelY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.height - radius), control: CGPoint(x: rect.minX, y: rect.height))
        path.addLine(to: CGPoint(x: rect.minX, y: panelY + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: panelY), control: CGPoint(x: rect.minX, y: panelY))
        path.addLine(to: CGPoint(x: x - arrowHalf, y: panelY))
        path.closeSubpath()
        return path
    }
}

/// 主弹窗内容视图（SwiftUI）。
/// 自上而下：header（总览与状态）→ toolbar（筛选/排序/操作）→ fundList（基金或待确认）
/// → marketIndexFooter（大盘指数条）。顶部还承载刷新状态、行情更新横幅、更新提示行、
/// 待确认交易影响条等。金额可通过隐私开关临时隐藏。
struct PopoverContentView: View {
    let store: PortfolioStore
    let settingsStore: AppSettingsStore
    let marketIndexStore: MarketIndexStore
    let updateStore: AppUpdateStore
    @Binding var selectedFundCode: String?
    let onRefresh: (() async -> Void)?
    let onOpenSettings: () -> Void
    let onOpenPortfolioBreakdown: () -> Void
    let onOpenTodayIncomeRanking: () -> Void
    let onOpenTodayRateRanking: () -> Void
    let onOpenHoldingIncomeRanking: () -> Void
    let onOpenHoldingRateRanking: () -> Void
    let onAddFund: () -> Void
    let onOpenFundDetail: (FundPosition) -> Void
    let onOpenTradeRecords: (FundPosition) -> Void
    let onOpenPendingActivity: (PendingTradeActivity) -> Void
    let onDeletePendingActivity: (PendingTradeActivity) async -> Void
    let onBuyFund: (FundPosition) -> Void
    let onSellFund: (FundPosition) -> Void
    let onEditFund: (FundPosition) -> Void
    let onDeleteFund: (FundPosition) async -> Void
    let onCheckUpdate: (() async -> Void)?
    let onOpenUpdate: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppPreferenceKey.hideHeaderAmounts) private var hidesHeaderAmounts = false
    @AppStorage(AppPreferenceKey.dismissedPendingActivityNoticeIDs)
    private var dismissedPendingActivityNoticeIDsRawValue = ""
    @State private var isRefreshing = false
    @State private var isRefreshStatusPulsing = false
    @State private var filter: FundListFilter = .holding
    @State private var searchText: String = ""
    @State private var sortMode: FundSortMode = .todayRate
    @State private var isSortMenuPresented = false
    @State private var isMarketIndexExpanded = false
    @State private var deletingPendingActivity: PendingTradeActivity?
    @Namespace private var filterSwitchNamespace

    var body: some View {
        // 待确认活动等派生数据构建成本较高，单次 body 求值内只计算一份，
        // 再透传给各子视图，避免 header/toolbar/fundList 各自重复全量重建。
        let listContent = makeDerivedListContent()
        return VStack(spacing: 0) {
            header(listContent)
                .zIndex(1)
            toolbar(listContent)
                .zIndex(3)
            PortfolioSearchBar(searchText: $searchText, filter: $filter)
                .zIndex(2)
            fundList(listContent)
                .layoutPriority(1)
                .zIndex(0)
            if settingsStore.settings.showsMarketIndexes {
                marketIndexFooter
                    .zIndex(1)
            }
        }
        .background(panelSurfaceBackground)
        .alert("删除待确认记录", isPresented: deletePendingActivityConfirmationBinding, presenting: deletingPendingActivity) { activity in
            Button("取消", role: .cancel) {
                deletingPendingActivity = nil
            }
            Button("删除记录", role: .destructive) {
                Task {
                    await onDeletePendingActivity(activity)
                    deletingPendingActivity = nil
                }
            }
        } message: { activity in
            Text(deletePendingActivityConfirmationMessage(for: activity))
        }
        .onAppear {
            normalizePendingActivityNoticeDismissal(listContent)
        }
        .onChange(of: listContent.pendingActivityIDs) { _, _ in
            normalizePendingActivityNoticeDismissal(listContent)
        }
    }

    /// 头部总览：刷新状态 + 市场时段徽标 + 隐私开关；状态横幅/更新提示行；
    /// 持仓金额、持仓收益、持仓收益率三张卡片；待确认影响条；实时收益(元/率) 大区。
    private func header(_ content: DerivedListContent) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 6) {
                    refreshStatusIndicator
                    Text(refreshStatusText)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer()
                marketBadge
                privacyToggleButton
            }

            if let statusMessage {
                statusBanner(statusMessage)
            }

            if shouldShowAppUpdateRow {
                appUpdateRow
            }

            HStack(spacing: 6) {
                Button(action: onOpenPortfolioBreakdown) {
                    metricCard(
                        "持仓金额",
                        headerMoneyText(store.snapshot.totalAmount),
                        isTotal: true
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .frame(maxWidth: .infinity)
                .help("查看持仓占比")
                Button(action: onOpenHoldingIncomeRanking) {
                    metricCard(
                        "持仓收益",
                        headerSignedMoneyText(store.snapshot.holdingIncome),
                        tone: headerMetricTone(store.snapshot.holdingIncome)
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .frame(maxWidth: .infinity)
                .help("打开持仓收益（按金额）")

                Button(action: onOpenHoldingRateRanking) {
                    metricCard(
                        "持仓收益率",
                        headerPercentText(store.snapshot.holdingIncomeRate),
                        tone: store.snapshot.holdingIncomeRate
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .frame(maxWidth: .infinity)
                .help("打开持仓收益（按收益率）")
            }

            if let pendingHeaderImpact = content.pendingHeaderImpact {
                Button {
                    selectFilter(.pending)
                } label: {
                    pendingImpactBar(pendingHeaderImpact)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("查看待确认")
            }

            HStack(alignment: .bottom) {
                Button(action: onOpenTodayIncomeRanking) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("实时收益(元)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            if allConfirmedFundsUpdated {
                                todayIncomeUpdatedTag
                            }
                            disclosureIndicator
                        }
                        todayIncomeAmount(store.snapshot.todayIncome, isMasked: hidesHeaderAmounts)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(headerMetricColor(store.snapshot.todayIncome))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("查看实时收益排行")

                Spacer()

                Button(action: onOpenTodayRateRanking) {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("实时收益率")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            disclosureIndicator
                        }
                        Text(headerPercentText(store.snapshot.todayIncomeRate))
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(toneColor(for: store.snapshot.todayIncomeRate))
                    }
                    .padding(.bottom, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("查看实时收益率排行")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(headerSurfaceBackground)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(nsColor: .separatorColor).opacity(0),
                    Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.22 : 0.18),
                    Color(nsColor: .separatorColor).opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }

    /// 工具栏：左侧持仓/待确认筛选切换，中间排序菜单（点击展开），右侧操作按钮组（添加/刷新/设置等）。
    private func toolbar(_ content: DerivedListContent) -> some View {
        HStack(spacing: 5) {
            filterSwitchControl(content)

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isSortMenuPresented.toggle()
                }
            } label: {
                sortMenuLabel
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("排序")
            .layoutPriority(1)
            .overlay(alignment: .topLeading) {
                if isSortMenuPresented {
                    sortMenuContent
                        .offset(y: 31)
                        .zIndex(10)
                }
            }
            .zIndex(isSortMenuPresented ? 20 : 0)
            .opacity(filter == .pending ? 0 : 1)
            .allowsHitTesting(filter != .pending)
            .accessibilityHidden(filter == .pending)

            toolbarActionGroup
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(toolbarSurfaceBackground)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(colorScheme == .dark ? 0.45 : 0.55)
        }
    }

    /// 搜索栏：仅在持仓筛选下显示（待确认列表本身较短，无需搜索）。
    /// 按基金名称或代码（含展示格式化）不区分大小写关键字过滤 fundList。
    /// 原生 NSTextField：关键点是 `acceptsFirstResponder` 返回 false——
    /// 这样 AppKit 在窗口重新成为 key 窗口时（例如关闭右侧基金详情子面板后，
    /// 主面板窗口重新 key 上来）不会把本字段自动恢复为 first responder，
    /// 从而彻底杜绝"点过搜索框后，打开/关闭详情页光标闪动"的问题。
    /// 但用户真实点击时，仍通过 mouseDown 里手动 makeFirstResponder(self)
    /// 获得焦点以输入（手动设置 first responder 不检查 acceptsFirstResponder）。
    private final class PortfolioSearchTextField: NSTextField {
        /// 仅鼠标按下到抬起之间为 true，允许本次成为 first responder。
        private var allowClickFocus = false

        override var acceptsFirstResponder: Bool {
            // 默认拒绝：窗口 key 状态切换等自动流程都不会聚焦本字段，
            // 只有下面 mouseDown 里显式 makeFirstResponder 才生效。
            false
        }

        override func mouseDown(with event: NSEvent) {
            // 点击时主动抢焦点（绕过 acceptsFirstResponder 的限制），让用户可以输入。
            if let window, window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
            allowClickFocus = true
            super.mouseDown(with: event)
            allowClickFocus = false
        }

        override func becomeFirstResponder() -> Bool {
            // 仅允许真实点击触发的聚焦；其余路径（含窗口自动恢复）一律拒绝。
            guard allowClickFocus else { return false }
            return super.becomeFirstResponder()
        }
    }

    /// 用原生 NSTextField 包装的搜索框：不会在视图重建时自动抢焦点，仅点击时聚焦。
    private struct PortfolioSearchFieldView: NSViewRepresentable {
        @Binding var text: String

        @MainActor
        func makeNSView(context: Context) -> NSTextField {
            let field = PortfolioSearchTextField()
            field.placeholderString = "搜索基金名称或代码"
            field.font = NSFont.systemFont(ofSize: 12)
            field.drawsBackground = false
            field.isBordered = false
            field.focusRingType = .none
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.delegate = context.coordinator
            context.coordinator.onTextChange = { newValue in
                text = newValue
            }
            return field
        }

        @MainActor
        func updateNSView(_ field: NSTextField, context: Context) {
            if field.stringValue != text {
                field.stringValue = text
            }
        }

        @MainActor
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var onTextChange: ((String) -> Void)?

            func controlTextDidChange(_ obj: Notification) {
                guard let field = obj.object as? NSTextField else { return }
                onTextChange?(field.stringValue)
            }
        }
    }

    /// 搜索栏独立子视图：只依赖 searchText / filter 两个绑定，完全不读取 store，
    /// 因此父视图（PopoverContentView）因行情刷新重算 body 时不会被重建，
    /// 从架构上杜绝搜索框 NSTextField 被反复重挂载导致的光标闪动。
    private struct PortfolioSearchBar: View {
        @Binding var searchText: String
        @Binding var filter: FundListFilter
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            if filter != .pending {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)

                    PortfolioSearchFieldView(text: $searchText)
                        .frame(height: 22)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("清除搜索")
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.30 : 0.18), lineWidth: 0.55)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(searchBarSurfaceBackground)
                .overlay(alignment: .bottom) {
                    Divider()
                        .opacity(colorScheme == .dark ? 0.45 : 0.55)
                }
            }
        }

        private var searchBarSurfaceBackground: Color {
            colorScheme == .dark
                ? Color(red: 15 / 255, green: 17 / 255, blue: 21 / 255)
                : Color(red: 250 / 255, green: 248 / 255, blue: 243 / 255)
        }
    }

    private var allConfirmedFundsUpdated: Bool {
        let confirmedFunds = store.snapshot.funds.filter { !$0.status.isPendingDisplay }
        return !confirmedFunds.isEmpty && confirmedFunds.allSatisfy(\.isUpdated)
    }

    private var todayIncomeUpdatedTag: some View {
        Text("已更新")
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 0.6)
            )
    }

    private var shouldShowAppUpdateRow: Bool {
        switch updateStore.presentationStatus {
        case .available, .downloading, .downloaded, .installing:
            return true
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }

    /// 更新提示行：根据 updateStore.presentationStatus 展示“发现新版本/下载中/已下载/安装中”，
    /// 并提供下载/立即更新按钮或进度。
    private var appUpdateRow: some View {
        HStack(alignment: .center, spacing: 10) {
            appUpdateRowIcon
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(appUpdateRowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(appUpdateRowDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if case .downloading = updateStore.presentationStatus {
                    ProgressView(value: updateStore.downloadProgress)
                        .controlSize(.small)
                        .tint(.orange)
                }
            }

            Spacer(minLength: 6)

            appUpdateRowTrailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appUpdateCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(appUpdateCardBorder)
        .overlay(appUpdateCardInnerHighlight)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.13 : 0.04), radius: 9, x: 0, y: 4)
    }

    @ViewBuilder
    private var appUpdateRowIcon: some View {
        switch updateStore.presentationStatus {
        case .available:
            appUpdateIconShell(systemName: "arrow.down", color: appUpdateRowAccentColor)
        case .downloading:
            appUpdateIconShell(systemName: "arrow.down", color: appUpdateRowAccentColor)
        case .downloaded:
            appUpdateIconShell(systemName: "checkmark", color: appUpdateRowAccentColor)
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .idle, .checking, .upToDate, .failed:
            EmptyView()
        }
    }

    private func appUpdateIconShell(systemName: String, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.12))
            Circle()
                .stroke(color.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.8)
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private var appUpdateRowTitle: String {
        switch updateStore.presentationStatus {
        case .available(let info):
            return "发现新版本 v\(info.version)"
        case .downloading:
            return "正在下载更新"
        case .downloaded:
            return "更新已下载"
        case .installing:
            return "正在安装更新"
        case .idle, .checking, .upToDate, .failed:
            return ""
        }
    }

    private var appUpdateRowDetail: String {
        switch updateStore.presentationStatus {
        case .available(let info):
            return "\(info.releaseName.isEmpty ? "red-fund" : info.releaseName) · 点击后先下载，下载完成后再安装。"
        case .downloading:
            return "下载完成后会显示“现在更新”。"
        case .downloaded(let info, _):
            return "v\(info.version) 已准备好。现在更新会退出并重新打开 red-fund。"
        case .installing:
            return "red-fund 将自动退出并重新打开。"
        case .idle, .checking, .upToDate, .failed:
            return ""
        }
    }

    private var appUpdateRowButtonTitle: String? {
        switch updateStore.presentationStatus {
        case .available:
            return "下载"
        case .downloaded:
            return "现在更新"
        case .idle, .checking, .downloading, .installing, .upToDate, .failed:
            return nil
        }
    }

    private var appUpdateRowButtonColor: Color {
        switch updateStore.presentationStatus {
        case .downloaded:
            return .redFundGreen
        case .available, .idle, .checking, .downloading, .installing, .upToDate, .failed:
            return .orange
        }
    }

    private var appUpdateRowAccentColor: Color {
        appUpdateRowButtonColor
    }

    private var appUpdateCardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                appUpdateRowAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.08),
                metricCardBaseBackground
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var appUpdateCardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
                appUpdateRowAccentColor.opacity(colorScheme == .dark ? 0.28 : 0.22),
                lineWidth: 0.9
            )
    }

    private var appUpdateCardInnerHighlight: some View {
        RoundedRectangle(cornerRadius: 9.4, style: .continuous)
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.34), lineWidth: 0.55)
            .padding(0.7)
            .blendMode(.plusLighter)
    }

    @ViewBuilder
    private var appUpdateRowTrailingControl: some View {
        switch updateStore.presentationStatus {
        case .available, .downloaded:
            if let title = appUpdateRowButtonTitle {
                appUpdateRowActionButton(title: title, color: appUpdateRowButtonColor) {
                    onOpenUpdate?()
                }
            }
        case .downloading:
            Text("\(Int(updateStore.downloadProgress * 100))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .frame(width: 36, alignment: .trailing)
                .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在下载更新")
            .accessibilityValue("\(Int(updateStore.downloadProgress * 100))%")
            .help(updateStore.badgeTitle ?? "正在下载更新")
        case .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .help(updateStore.badgeTitle ?? "正在安装更新")
        case .idle, .checking, .upToDate, .failed:
            EmptyView()
        }
    }

    /// 更新提示行右侧的“下载 / 现在更新”操作按钮。
    private func appUpdateRowActionButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(color.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(color.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
    }

    /// 工具栏右侧操作组：添加基金、刷新、设置等按钮。
    private var toolbarActionGroup: some View {
        HStack(spacing: 6) {
            toolbarIconButton("plus", "新增基金", tone: PanelDesign.accent, action: onAddFund)
            toolbarRefreshControl
            toolbarIconButton("gearshape", "设置", action: onOpenSettings)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var toolbarRefreshControl: some View {
        if case .failed(let reason) = store.loadState {
            Button {
                refresh()
            } label: {
                toolbarIconLabel("exclamationmark.triangle.fill", tone: .orange)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(isManualRefreshFeedbackVisible)
            .help("基金数据刷新失败：\(reason)。点击重试")
        } else {
            toolbarIconButton("arrow.clockwise", isManualRefreshFeedbackVisible ? "刷新中" : "刷新") {
                refresh()
            }
            .disabled(isManualRefreshFeedbackVisible)
        }
    }

    private func toolbarIconButton(
        _ systemName: String,
        _ help: String,
        tone: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarIconLabel(systemName, tone: tone)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toolbarIconLabel(_ systemName: String, tone: Color? = nil) -> some View {
        let foreground = tone ?? toolbarIconForeground

        return Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(tone == nil ? .hierarchical : .monochrome)
            .foregroundStyle(foreground)
            .frame(width: toolbarIconButtonSize, height: toolbarIconButtonSize)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: toolbarIconButtonCornerRadius, style: .continuous)
                        .fill(toolbarControlBackground)

                    if let tone {
                        RoundedRectangle(cornerRadius: toolbarIconButtonCornerRadius, style: .continuous)
                            .fill(tone.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    }
                }
            }
            .overlay(toolbarControlBorder(cornerRadius: toolbarIconButtonCornerRadius, tone: tone))
            .overlay(toolbarControlInnerHighlight(cornerRadius: toolbarIconButtonCornerRadius - 0.6))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.025), radius: 3, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: toolbarIconButtonCornerRadius, style: .continuous))
    }

    /// 持仓 / 待确认 筛选切换控件（选中态带滑动高亮）。
    private func filterSwitchControl(_ content: DerivedListContent) -> some View {
        HStack(spacing: 2) {
            ForEach(visibleFilters) { value in
                filterSwitchButton(value, content: content)
            }
        }
        .padding(2)
        .background(filterSwitchBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.14 : 0.10), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help("切换基金筛选")
    }

    private func filterSwitchButton(_ value: FundListFilter, content: DerivedListContent) -> some View {
        let isSelected = filter == value
        let currentCount = count(for: value, in: content)
        let isPending = value == .pending
        let pendingHasItems = isPending && currentCount > 0

        return Button {
            selectFilter(value)
        } label: {
            HStack(spacing: 6) {
                Text(value.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(currentCount)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(filterCountForeground(isSelected: isSelected, isPending: pendingHasItems))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(filterCountBackground(isSelected: isSelected, isPending: pendingHasItems), in: Capsule())
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minWidth: isPending ? 68 : 56, minHeight: 24)
            .background {
                if isSelected {
                    Capsule()
                        .fill(filterSelectedBackground)
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.55)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 7, x: 0, y: 4)
                        .matchedGeometryEffect(id: "filterSwitchSelection", in: filterSwitchNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 切换持仓/待确认筛选，并联动隐藏排序菜单等状态。
    private func selectFilter(_ value: FundListFilter) {
        withAnimation(.easeInOut(duration: 0.12)) {
            filter = value
            isSortMenuPresented = false
        }
    }

    /// 排序菜单的触发标签（显示当前排序方式）。
    private var sortMenuLabel: some View {
        HStack(spacing: 5) {
            Text(sortMode.title)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(width: 88, height: 26)
        .background(toolbarPillBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }

    /// 排序菜单展开内容（按实时收益/收益率/持仓收益等多种方式）。
    private var sortMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FundSortMode.allCases) { mode in
                Button {
                    sortMode = mode
                    isSortMenuPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Text(mode.title)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if sortMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12, weight: sortMode == mode ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .frame(width: 118, height: 26, alignment: .leading)
                    .background(
                        sortMode == mode ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(5)
        .background(sortMenuBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.55)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 14, x: 0, y: 8)
    }

    /// 中部列表区：筛选为“待确认”时显示待确认交易列表，否则显示基金列表。
    /// 手动刷新走工具栏刷新按钮（而非下拉刷新，Mac 菜单栏不采用下拉刷新交互）。
    private func fundList(_ content: DerivedListContent) -> some View {
        ScrollView {
            if filter == .pending {
                VStack(spacing: 0) {
                    MainPopoverNativeScrollConfiguration()
                        .frame(height: 0)
                    pendingActivityList(content)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            } else {
                LazyVStack(spacing: 0) {
                    MainPopoverNativeScrollConfiguration()
                        .frame(height: 0)
                    fundRows(content)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        // 滚动指示条行为由 MainPopoverNativeScrollConfiguration 原生接管：
        // overlay + autohide，滚动时短暂浮现，停止后自动消失，不再常驻
        .frame(maxHeight: .infinity, alignment: .top)
        .background(listSurfaceBackground)
    }

    /// 基金列表行：无数据时空状态；否则逐个渲染 FundRowView（按当前筛选/排序）。
    @ViewBuilder
    private func fundRows(_ content: DerivedListContent) -> some View {
        let rows = filteredFunds(in: content)
        if rows.isEmpty {
            if !searchText.isEmpty {
                ContentUnavailableView(
                    "未找到匹配的基金",
                    systemImage: "magnifyingglass",
                    description: Text("没有名称或代码包含“\(searchText)”的基金。")
                )
                .frame(height: 300)
            } else {
                ContentUnavailableView(
                    "暂无基金数据",
                    systemImage: "tray",
                    description: Text("点击上方 + 添加第一只基金，或在设置中重新查看使用引导。")
                )
                .frame(height: 300)
            }
        } else {
            ForEach(rows) { fund in
                let isClosedZeroPosition = PendingFundDisplayRules.isClosedZeroPosition(
                    fund,
                    tradeRecords: content.tradeRecords
                )
                FundRowView(
                    fund: fund,
                    sortMode: sortMode,
                    isSelected: selectedFundCode == fund.code,
                    isClosedZeroPosition: isClosedZeroPosition,
                    masksAmounts: hidesHeaderAmounts,
                    onOpen: {
                        onOpenFundDetail(fund)
                    }
                )
                Divider()
            }
        }
    }

    /// 待确认交易列表：无数据时空状态；否则渲染待确认提醒条 + 各 PendingTradeActivityRow。
    @ViewBuilder
    private func pendingActivityList(_ content: DerivedListContent) -> some View {
        if content.pendingActivities.isEmpty {
            ContentUnavailableView("暂无待确认交易", systemImage: "clock.badge.checkmark")
                .frame(height: 300)
        } else {
            VStack(spacing: 0) {
                if showsPendingActivityNotice(content) {
                    PendingActivityNotice(onDismiss: { dismissPendingActivityNotice(content) })
                    Divider()
                }
                ForEach(content.pendingActivities) { activity in
                    PendingTradeActivityRow(
                        activity: activity,
                        isSelected: selectedFundCode == activity.code,
                        onDelete: {
                            deletingPendingActivity = activity
                        }
                    ) {
                        onOpenPendingActivity(activity)
                    }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// 底部大盘指数条：折叠时显示一行主指数，展开后显示更多指数与市场宽度。
    private var marketIndexFooter: some View {
        VStack(spacing: 0) {
            if isMarketIndexExpanded {
                marketIndexExpandedContent
            } else {
                marketIndexCollapsedRow
            }
        }
        .background(marketIndexFooterBackground)
        .overlay(alignment: .top) {
            Divider()
                .opacity(colorScheme == .dark ? 0.62 : 0.72)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 8, x: 0, y: -3)
        .onChange(of: settingsStore.settings.showsMarketIndexes) { _, isShown in
            if !isShown {
                isMarketIndexExpanded = false
            }
        }
    }

    /// 大盘指数条折叠态：单行展示主指数行情 + 市场宽度概要。
    private var marketIndexCollapsedRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isMarketIndexExpanded = true
            }
        } label: {
            VStack(spacing: 0) {
                if let breadth = marketIndexStore.marketBreadth {
                    marketBreadthMiniSummary(breadth)
                        .padding(.horizontal, 8)
                        .padding(.top, 7)
                }

                HStack(spacing: 7) {
                    if let quote = primaryMarketIndexQuote {
                        Text(marketIndexDisplayName(quote))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(width: 70, alignment: .leading)

                        Spacer(minLength: 6)

                        Text(marketIndexValueText(quote.value))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(toneColor(for: quote.changeRate))
                            .lineLimit(1)

                        Text(marketIndexChangeText(quote.change))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(toneColor(for: quote.changeRate))
                            .lineLimit(1)
                            .frame(width: 52, alignment: .trailing)

                        Text(MoneyFormatter.percent(quote.changeRate, signed: true))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(toneColor(for: quote.changeRate))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    } else {
                        Text(settingsStore.settings.defaultMarketIndexID.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(width: 70, alignment: .leading)

                        Spacer(minLength: 6)

                        Text(marketIndexStore.isRefreshing ? "加载中" : "暂无数据")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 14)
                .frame(height: marketIndexStore.marketBreadth == nil ? 30 : 25)
            }
            .frame(height: marketIndexStore.marketBreadth == nil ? 30 : 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("展开大盘指数")
    }

    /// 大盘指数条展开态：多指数行情网格 + 市场宽度明细。
    private var marketIndexExpandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isMarketIndexExpanded = false
                }
            } label: {
                HStack(spacing: 7) {
                    Text("大盘指数")
                        .font(.system(size: 11, weight: .semibold))
                    if marketIndexStore.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.64)
                            .frame(width: 14, height: 14)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("收起大盘指数")

            if let breadth = marketIndexStore.marketBreadth {
                marketBreadthSummary(breadth)
                    .padding(.horizontal, 14)
            }

            if marketIndexQuotes.isEmpty {
                Text(marketIndexStore.isRefreshing ? "指数加载中" : "指数暂无数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            } else {
                marketIndexCardStrip
            }
        }
        .padding(.top, 2)
    }

    private var marketIndexQuotes: [MarketIndexQuote] {
        marketIndexStore.orderedQuotes()
    }

    /// 大盘指数横向卡片区：原生 NSScrollView 承载（普通鼠标滚轮默认无法横向滚动，
    /// 滚动条也难以点拖），在 scrollWheel 中把竖向滚轮增量映射为横向滚动，
    /// 鼠标悬停在指数区域滚动滚轮即可左右浏览全部指数。
    private var marketIndexCardStrip: some View {
        MarketIndexNativeWheelStrip {
            HStack(spacing: 7) {
                ForEach(marketIndexQuotes) { quote in
                    marketIndexCardButton(quote)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
        .frame(height: 86)
    }

    private var primaryMarketIndexQuote: MarketIndexQuote? {
        marketIndexStore.primaryQuote(defaultID: settingsStore.settings.defaultMarketIndexID)
    }

    private func marketIndexCardButton(_ quote: MarketIndexQuote) -> some View {
        Button {
            selectMarketIndex(quote.id)
        } label: {
            marketIndexCard(quote)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("选择\(marketIndexDisplayName(quote))")
        .accessibilityLabel("选择\(marketIndexDisplayName(quote))")
    }

    private func marketBreadthSummary(_ breadth: MarketBreadth) -> some View {
        let sentiment = marketBreadthSentiment(for: breadth)

        return VStack(spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("大盘")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(sentiment.title)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(sentiment.color)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(
                                sentiment.color.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                in: Capsule()
                            )
                    }

                    Text(sentiment.detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                marketBreadthMetric(title: "上涨", count: breadth.risingCount, color: toneColor(for: 1))

                Rectangle()
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.14))
                    .frame(width: 0.7, height: 24)

                marketBreadthMetric(title: "下跌", count: breadth.fallingCount, color: toneColor(for: -1))
            }

            marketBreadthBar(breadth)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            marketBreadthSummaryBackground(sentiment.color),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(sentiment.color.opacity(colorScheme == .dark ? 0.14 : 0.09), lineWidth: 0.7)
        )
        .accessibilityLabel("A股全市场上涨\(breadth.risingCount)家，下跌\(breadth.fallingCount)家")
    }

    private func marketBreadthMetric(title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(count.formatted())
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(width: 56, alignment: .trailing)
    }

    private func marketBreadthBar(_ breadth: MarketBreadth) -> some View {
        let total = max(breadth.activeCount, 1)
        let risingRatio = min(max(CGFloat(breadth.risingCount) / CGFloat(total), 0), 1)
        let fallingRatio = 1 - risingRatio

        return GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(toneColor(for: 1).opacity(colorScheme == .dark ? 0.88 : 0.78))
                        .frame(width: width * risingRatio)
                    Rectangle()
                        .fill(toneColor(for: -1).opacity(colorScheme == .dark ? 0.88 : 0.78))
                        .frame(width: width * fallingRatio)
                }
                .clipShape(Capsule())

                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.26 : 0.18))
                    .frame(width: 0.7)
                    .offset(x: width / 2)
            }
        }
        .frame(height: 5)
    }

    private func marketBreadthMiniSummary(_ breadth: MarketBreadth) -> some View {
        HStack(spacing: 4) {
            Text("大盘")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            marketBreadthMiniChip(
                systemName: "arrowtriangle.up.fill",
                count: breadth.risingCount,
                color: toneColor(for: 1)
            )
            .fixedSize(horizontal: true, vertical: false)

            marketBreadthMiniChip(
                systemName: "arrowtriangle.down.fill",
                count: breadth.fallingCount,
                color: toneColor(for: -1)
            )
            .fixedSize(horizontal: true, vertical: false)

            marketBreadthMiniBar(breadth)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(
            Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.06),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.7)
        )
        .accessibilityLabel("大盘上涨\(breadth.risingCount)家，下跌\(breadth.fallingCount)家")
    }

    private func marketBreadthMiniChip(
        systemName: String,
        count: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 6.8, weight: .bold))
                .frame(width: 7, height: 7)
            Text(count.formatted())
                .font(.system(size: 8.5, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(color.opacity(colorScheme == .dark ? 0.92 : 0.84))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .padding(.horizontal, 4)
        .frame(height: 14)
        .background(
            color.opacity(colorScheme == .dark ? 0.14 : 0.08),
            in: Capsule()
        )
    }

    private func marketBreadthMiniBar(_ breadth: MarketBreadth) -> some View {
        let total = max(breadth.activeCount, 1)
        let risingRatio = min(max(CGFloat(breadth.risingCount) / CGFloat(total), 0), 1)
        let fallingRatio = 1 - risingRatio

        return GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.13 : 0.09))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(toneColor(for: 1).opacity(colorScheme == .dark ? 0.78 : 0.66))
                        .frame(width: width * risingRatio)
                    Rectangle()
                        .fill(toneColor(for: -1).opacity(colorScheme == .dark ? 0.78 : 0.66))
                        .frame(width: width * fallingRatio)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func marketBreadthSentiment(for breadth: MarketBreadth) -> (title: String, detail: String, color: Color) {
        let activeCount = max(breadth.activeCount, 1)
        let risingShare = Double(breadth.risingCount) / Double(activeCount)
        let risingShareText = (risingShare * 100).formatted(.number.precision(.fractionLength(0)))
        let detail = "涨占比 \(risingShareText)%"

        if risingShare >= 0.58 {
            return ("偏强", detail, toneColor(for: 1))
        }
        if risingShare <= 0.42 {
            return ("偏弱", detail, toneColor(for: -1))
        }
        return ("均衡", detail, Color.secondary)
    }

    private func marketBreadthSummaryBackground(_ tone: Color) -> some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    tone.opacity(colorScheme == .dark ? 0.12 : 0.065),
                    Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.030)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func selectMarketIndex(_ id: MarketIndexID) {
        settingsStore.setDefaultMarketIndexID(id)
        withAnimation(.easeInOut(duration: 0.16)) {
            isMarketIndexExpanded = false
        }
    }

    private func marketIndexCard(_ quote: MarketIndexQuote) -> some View {
        let isSelected = quote.id == settingsStore.settings.defaultMarketIndexID

        return VStack(alignment: .leading, spacing: 5) {
            Text(marketIndexDisplayName(quote))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(marketIndexValueText(quote.value))
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(toneColor(for: quote.changeRate))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(spacing: 5) {
                Text(marketIndexChangeText(quote.change))
                Text(MoneyFormatter.percent(quote.changeRate, signed: true))
            }
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(toneColor(for: quote.changeRate))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 9)
        .frame(width: 104, height: 74, alignment: .leading)
        .background(
            marketIndexCardBackground(for: quote, isSelected: isSelected),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    toneColor(for: quote.changeRate).opacity(
                        isSelected
                            ? (colorScheme == .dark ? 0.52 : 0.34)
                            : (colorScheme == .dark ? 0.20 : 0.14)
                    ),
                    lineWidth: isSelected ? 1.1 : 0.65
                )
        )
        .shadow(
            color: isSelected
                ? toneColor(for: quote.changeRate).opacity(colorScheme == .dark ? 0.18 : 0.10)
                : Color.clear,
            radius: isSelected ? 4 : 0,
            x: 0,
            y: 1
        )
    }

    private func marketIndexDisplayName(_ quote: MarketIndexQuote) -> String {
        quote.id.title
    }

    private func marketIndexValueText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func marketIndexChangeText(_ value: Double) -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(2))))"
    }

    private func marketIndexCardBackground(for quote: MarketIndexQuote, isSelected: Bool) -> Color {
        toneColor(for: quote.changeRate).opacity(
            isSelected
                ? (colorScheme == .dark ? 0.24 : 0.14)
                : (colorScheme == .dark ? 0.16 : 0.10)
        )
    }

    /// 头部刷新状态指示灯：常驻小圆点；手动刷新时以脉冲动画提示进行中。
    private var refreshStatusIndicator: some View {
        ZStack {
            if isManualRefreshFeedbackVisible {
                Circle()
                    .stroke(refreshStatusColor.opacity(colorScheme == .dark ? 0.52 : 0.36), lineWidth: 1)
                    .frame(width: 14, height: 14)
                    .scaleEffect(isRefreshStatusPulsing ? 1.15 : 0.55)
                    .opacity(isRefreshStatusPulsing ? 0 : 0.78)
            }

            Circle()
                .fill(refreshStatusColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.55), lineWidth: 0.6)
                )
        }
            .frame(width: 14, height: 14)
            .shadow(color: refreshStatusColor.opacity(0.28), radius: 3, x: 0, y: 1)
            .help(refreshStatusHelp)
            .onAppear {
                updateRefreshStatusPulse(isManualRefreshFeedbackVisible)
            }
            .onChange(of: isManualRefreshFeedbackVisible) { _, isRefreshing in
                updateRefreshStatusPulse(isRefreshing)
            }
    }

    /// 市场时段徽标：根据 TradingCalendar 显示 交易中/午休/休市 等状态并着色。
    private var marketBadge: some View {
        let state = TradingCalendar.marketSessionState()
        return Text(state.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.92) : Color.white.opacity(0.96))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(marketBadgeBackground(for: state), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.24), lineWidth: 0.55)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 6, x: 0, y: 3)
    }

    /// 隐私开关：切换头部金额/收益的显示与隐藏（AppStorage 持久化）。
    private var privacyToggleButton: some View {
        Button(action: toggleHeaderAmountPrivacy) {
            Image(systemName: hidesHeaderAmounts ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: 10, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(privacyToggleForeground)
                .frame(width: 22, height: 22)
                .background(privacyToggleBackground, in: Circle())
                .overlay(
                    Circle()
                        .stroke(privacyToggleForeground.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 0.6)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(hidesHeaderAmounts ? "显示顶部金额" : "隐藏顶部金额")
        .accessibilityLabel(hidesHeaderAmounts ? "显示顶部金额" : "隐藏顶部金额")
    }

    private var privacyToggleForeground: Color {
        hidesHeaderAmounts
            ? .orange
            : Color.secondary.opacity(colorScheme == .dark ? 0.86 : 0.72)
    }

    private var privacyToggleBackground: Color {
        hidesHeaderAmounts
            ? Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12)
            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
    }

    /// 切换头部金额/收益是否隐藏（写入 AppStorage）。
    private func toggleHeaderAmountPrivacy() {
        withAnimation(.easeInOut(duration: 0.16)) {
            hidesHeaderAmounts.toggle()
        }
        NotificationCenter.default.post(name: .redFundAmountPrivacyDidChange, object: nil)
    }

    private var hiddenMoneyPlaceholder: String { "***" }

    /// 头部金额文本（隐藏时显示掩码）。
    private func headerMoneyText(_ value: Double) -> String {
        hidesHeaderAmounts ? hiddenMoneyPlaceholder : MoneyFormatter.plainMoney(value)
    }

    private func headerSignedMoneyText(_ value: Double) -> String {
        hidesHeaderAmounts ? hiddenMoneyPlaceholder : MoneyFormatter.money(value, signed: true)
    }

    private func headerPercentText(_ value: Double) -> String {
        MoneyFormatter.percent(value, signed: true)
    }

    private func headerMetricTone(_ value: Double) -> Double? {
        hidesHeaderAmounts ? nil : value
    }

    private func headerMetricColor(_ value: Double) -> Color {
        hidesHeaderAmounts ? hiddenAmountColor : toneColor(for: value)
    }

    private var hiddenAmountColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.84 : 0.78)
    }

    @ViewBuilder
    private var updateButton: some View {
        switch updateStore.presentationStatus {
        case .available:
            Button {
                onOpenUpdate?()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(updateStore.badgeTitle ?? "下载更新")
            .help(updateStore.badgeTitle ?? "发现新版本")
        case .downloaded:
            Button {
                onOpenUpdate?()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(updateStore.badgeTitle ?? "现在更新")
            .help(updateStore.badgeTitle ?? "更新已下载")
        case .downloading:
            UpdateProgressRing(progress: updateStore.downloadProgress)
                .frame(width: 24, height: 24)
                .accessibilityLabel(updateStore.badgeTitle ?? "正在下载更新")
                .help(updateStore.badgeTitle ?? "正在下载更新")
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .help(updateStore.badgeTitle ?? "更新处理中")
        case .failed:
            EmptyView()
        case .idle, .upToDate:
            EmptyView()
        }
    }

    /// 顶部状态横幅要展示的文案（如刷新失败提示），无则隐藏。
    private var statusMessage: String? {
        switch store.loadState {
        case .missingPlainData(let hasLegacyStore) where hasLegacyStore:
            "检测到旧版加密数据，可通过迁移脚本转换后继续使用。"
        case .failed(let reason):
            "基金数据刷新失败：\(reason)"
        default:
            nil
        }
    }

    private var isRefreshRequestInProgress: Bool {
        isRefreshing || store.isRefreshingQuotes
    }

    private var isManualRefreshFeedbackVisible: Bool {
        isRefreshing
    }

    /// 刷新状态文案（如“已更新”“刷新中”）。
    private var refreshStatusText: String {
        if isManualRefreshFeedbackVisible {
            return "正在刷新基金数据..."
        }
        return "刷新 \(refreshTimeText(store.snapshot.updateTime))"
    }

    private var refreshStatusColor: Color {
        if isManualRefreshFeedbackVisible { return .orange }
        switch store.loadState {
        case .loaded:
            return .redFundGreen
        case .loading:
            return .orange
        case .missingPlainData:
            return Color.secondary.opacity(0.45)
        case .failed:
            return Color(red: 239 / 255, green: 77 / 255, blue: 98 / 255)
        }
    }

    private var refreshStatusHelp: String {
        if isManualRefreshFeedbackVisible { return "正在刷新基金数据" }
        switch store.loadState {
        case .loaded:
            return "基金数据刷新正常"
        case .loading:
            return "正在读取基金数据"
        case .missingPlainData:
            return "暂无基金数据文件"
        case .failed(let reason):
            return "基金数据刷新失败：\(reason)"
        }
    }

    private func updateRefreshStatusPulse(_ isRefreshing: Bool) {
        isRefreshStatusPulsing = false
        guard isRefreshing else { return }
        withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) {
            isRefreshStatusPulsing = true
        }
    }

    /// 顶部状态横幅（如刷新失败提示）。
    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: storeFailureSymbol)
            Text(message)
                .lineLimit(2)
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(10)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private var storeFailureSymbol: String {
        if case .failed = store.loadState {
            return "exclamationmark.triangle"
        }
        return "lock.doc"
    }

    /// 头部指标卡片（标题 + 数值，按盈亏/总额着色，支持隐藏）。
    private func metricCard(
        _ title: String,
        _ value: String,
        footnote: String? = nil,
        tone: Double? = nil,
        isTotal: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                disclosureIndicator
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .allowsTightening(true)
                .foregroundStyle(metricCardValueColor(tone, isTotal: isTotal))

            if let footnote {
                Text(footnote)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                    .foregroundStyle(hidesHeaderAmounts ? Color.secondary : pendingAmountFootnoteColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .frame(height: footnote == nil ? 44 : 52)
        .background(metricCardBackground(tone, isTotal: isTotal), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(metricCardBorder)
        .overlay(metricCardInnerHighlight)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035), radius: 8, x: 0, y: 4)
    }

    /// 待确认交易影响条：点按跳到“待确认”筛选，展示其将带来的金额/收益变化。
    private func pendingImpactBar(_ impact: PendingHeaderImpact) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("待确认 \(impact.count) 笔")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)

                Text(pendingImpactActivityText(impact))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if hidesHeaderAmounts {
                Text("***")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                pendingImpactNetSummary(impact)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.68))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pendingImpactNetSummary(_ impact: PendingHeaderImpact) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(pendingNetTitle(impact.netAmount))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(signedCompactPendingMoney(impact.netAmount))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(pendingImpactNetColor(impact.netAmount))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .allowsTightening(true)
        }
        .frame(minWidth: 86, alignment: .trailing)
    }

    private func pendingImpactActivityText(_ impact: PendingHeaderImpact) -> String {
        let hasSubscription = impact.buyAmount > 0.5
        let hasRedemption = impact.sellAmount > 0.5

        switch (hasSubscription, hasRedemption) {
        case (true, true):
            return "申购 \(pendingMoneyText(impact.buyAmount)) · 赎回 \(pendingMoneyText(impact.sellAmount))"
        case (true, false):
            return "申购待确认 \(pendingMoneyText(impact.buyAmount))"
        case (false, true):
            return "赎回待确认 \(pendingMoneyText(impact.sellAmount))"
        case (false, false):
            if impact.conversionCount > 0 {
                return "转换待确认 \(impact.conversionCount)笔"
            }
            return "交易待确认"
        }
    }

    private func pendingNetTitle(_ value: Double) -> String {
        if value > 0.5 { return "净申购" }
        if value < -0.5 { return "净赎回" }
        return "净额"
    }

    /// 指标卡片数值颜色（涨红跌绿，总额默认主色）。
    private func metricCardValueColor(_ tone: Double?, isTotal: Bool) -> Color {
        if hidesHeaderAmounts {
            return hiddenAmountColor
        }
        return isTotal ? totalAmountAccentColor : (tone.map(toneColor(for:)) ?? Color.primary)
    }

    private var disclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 12, height: 12)
    }

    private var toolbarPillBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.035)
    }

    private var toolbarIconForeground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.86)
            : Color(red: 44 / 255, green: 47 / 255, blue: 52 / 255)
    }

    private var toolbarIconButtonSize: CGFloat {
        27
    }

    private var toolbarIconButtonCornerRadius: CGFloat {
        7.5
    }

    private var toolbarControlBackground: some ShapeStyle {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color.white.opacity(0.105),
                    Color.white.opacity(0.060)
                ]
                : [
                    Color.white.opacity(0.92),
                    Color(red: 247 / 255, green: 242 / 255, blue: 233 / 255).opacity(0.90)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func toolbarControlBorder(cornerRadius: CGFloat, tone: Color? = nil) -> some View {
        let borderColor = tone.map {
            $0.opacity(colorScheme == .dark ? 0.50 : 0.36)
        } ?? (
            colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color(red: 213 / 255, green: 204 / 255, blue: 190 / 255).opacity(0.44)
        )

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: 0.85)
    }

    private func toolbarControlInnerHighlight(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.55), lineWidth: 0.65)
            .padding(0.7)
            .blendMode(.plusLighter)
    }

    private var iconButtonHoverSurface: Color {
        Color.primary.opacity(0.001)
    }

    private var filterSwitchBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.035)
    }

    private var filterSelectedBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.105)
            : Color.white.opacity(0.95)
    }

    private var sortMenuBackground: Color {
        colorScheme == .dark
            ? Color(red: 28 / 255, green: 30 / 255, blue: 36 / 255)
            : Color.white.opacity(0.98)
    }

    private var metricCardBaseBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color.white.opacity(0.72)
    }

    private var totalAmountAccentColor: Color {
        colorScheme == .dark
            ? Color(red: 255 / 255, green: 210 / 255, blue: 126 / 255)
            : Color(red: 157 / 255, green: 96 / 255, blue: 18 / 255)
    }

    private var pendingAmountFootnoteColor: Color {
        colorScheme == .dark
            ? Color(red: 255 / 255, green: 188 / 255, blue: 112 / 255).opacity(0.86)
            : Color(red: 174 / 255, green: 96 / 255, blue: 22 / 255).opacity(0.82)
    }

    private var metricCardBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(metricCardBorderColor, lineWidth: 0.9)
    }

    private var metricCardInnerHighlight: some View {
        RoundedRectangle(cornerRadius: 8.4, style: .continuous)
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.30), lineWidth: 0.55)
            .padding(0.7)
            .blendMode(.plusLighter)
    }

    private var metricCardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : Color(red: 204 / 255, green: 190 / 255, blue: 170 / 255).opacity(0.42)
    }

    private func marketBadgeBackground(for state: MarketSessionState) -> some ShapeStyle {
        let colors: [Color] = {
            switch state {
            case .open:
                return colorScheme == .dark
                    ? [
                        Color(red: 48 / 255, green: 191 / 255, blue: 137 / 255),
                        Color(red: 25 / 255, green: 137 / 255, blue: 96 / 255)
                    ]
                    : [
                        Color(red: 66 / 255, green: 185 / 255, blue: 135 / 255),
                        Color(red: 31 / 255, green: 145 / 255, blue: 100 / 255)
                    ]
            case .middayBreak:
                return [
                    Color(red: 255 / 255, green: 198 / 255, blue: 88 / 255),
                    Color(red: 233 / 255, green: 145 / 255, blue: 45 / 255)
                ]
            case .closed:
                return colorScheme == .dark
                    ? [
                        Color(red: 126 / 255, green: 137 / 255, blue: 148 / 255),
                        Color(red: 79 / 255, green: 88 / 255, blue: 98 / 255)
                    ]
                    : [
                        Color(red: 164 / 255, green: 175 / 255, blue: 184 / 255),
                        Color(red: 126 / 255, green: 138 / 255, blue: 148 / 255)
                    ]
            }
        }()

        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var pendingBadgeBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 255 / 255, green: 219 / 255, blue: 103 / 255).opacity(colorScheme == .dark ? 0.94 : 0.78),
                Color(red: 255 / 255, green: 190 / 255, blue: 68 / 255).opacity(colorScheme == .dark ? 0.86 : 0.64)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var pendingBadgeForeground: Color {
        colorScheme == .dark
            ? Color(red: 73 / 255, green: 49 / 255, blue: 12 / 255)
            : Color(red: 174 / 255, green: 103 / 255, blue: 0 / 255)
    }

    private func filterCountForeground(isSelected: Bool, isPending: Bool) -> Color {
        if isPending {
            return Color.orange.opacity(isSelected ? 0.92 : 0.78)
        }
        return isSelected ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.58)
    }

    private func filterCountBackground(isSelected: Bool, isPending: Bool) -> Color {
        if isPending {
            return Color.orange.opacity(isSelected ? 0.15 : 0.09)
        }
        return isSelected
            ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
            : Color(nsColor: .separatorColor).opacity(0.12)
    }

    private var panelSurfaceBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 16 / 255, green: 18 / 255, blue: 22 / 255),
                    Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255)
                ]
                : [
                    Color(red: 250 / 255, green: 247 / 255, blue: 241 / 255),
                    Color(red: 244 / 255, green: 241 / 255, blue: 235 / 255)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var headerSurfaceBackground: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 35 / 255, green: 39 / 255, blue: 46 / 255),
                        Color(red: 18 / 255, green: 21 / 255, blue: 27 / 255),
                        Color(red: 42 / 255, green: 25 / 255, blue: 33 / 255).opacity(0.82)
                    ]
                    : [
                        Color(red: 255 / 255, green: 251 / 255, blue: 242 / 255),
                        Color(red: 255 / 255, green: 242 / 255, blue: 224 / 255),
                        Color(red: 255 / 255, green: 236 / 255, blue: 226 / 255)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.03 : 0.30),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var toolbarSurfaceBackground: some View {
        ZStack {
            Color(red: colorScheme == .dark ? 16 / 255 : 250 / 255,
                  green: colorScheme == .dark ? 18 / 255 : 247 / 255,
                  blue: colorScheme == .dark ? 22 / 255 : 241 / 255)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.22),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var listSurfaceBackground: some View {
        Color(red: colorScheme == .dark ? 15 / 255 : 250 / 255,
              green: colorScheme == .dark ? 17 / 255 : 248 / 255,
              blue: colorScheme == .dark ? 21 / 255 : 243 / 255)
    }

    private var marketIndexFooterBackground: some View {
        Color(red: colorScheme == .dark ? 17 / 255 : 252 / 255,
              green: colorScheme == .dark ? 19 / 255 : 250 / 255,
              blue: colorScheme == .dark ? 23 / 255 : 246 / 255)
    }

    /// 指标卡片背景（按盈亏深浅着色）。
    private func metricCardBackground(_ tone: Double?, isTotal: Bool = false) -> some ShapeStyle {
        if isTotal {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        totalAmountAccentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        metricCardBaseBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        if let tone, tone != 0 {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        toneColor(for: tone).opacity(colorScheme == .dark ? 0.16 : 0.08),
                        metricCardBaseBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(metricCardBaseBackground)
    }

    /// 单次 body 求值内共享的列表派生数据。
    /// `PendingTradeActivityBuilder.make(from:)` 需要全量扫描持仓与交易记录，
    /// 一次 body 求值会被 header/toolbar/fundList 多处消费，因此只构建一次后透传。
    private struct DerivedListContent {
        let funds: [FundPosition]
        let tradeRecords: [FundTradeRecord]
        let pendingActivities: [PendingTradeActivity]
        /// 预计算的派生值：二者在一次 body 求值内会被多处访问
        ///（`pendingActivityIDs` 有 4 处），存下来避免重复 map / 重复构建。
        let pendingActivityIDs: [String]
        let pendingHeaderImpact: PendingHeaderImpact?
    }

    private func makeDerivedListContent() -> DerivedListContent {
        let pendingActivities = PendingTradeActivityBuilder.make(from: store.snapshot)
        return DerivedListContent(
            funds: store.snapshot.funds,
            tradeRecords: store.snapshot.tradeRecords ?? [],
            pendingActivities: pendingActivities,
            pendingActivityIDs: pendingActivities.map(\.id),
            pendingHeaderImpact: PendingHeaderImpact.make(activities: pendingActivities)
        )
    }

    /// 按当前筛选/排序得到的基金列表（供 fundRows 渲染）。
    private func filteredFunds(in content: DerivedListContent) -> [FundPosition] {
        let funds = content.funds.filter { fund in
            switch filter {
            case .holding:
                FundListDisplayRules.isDisplayedHolding(fund, tradeRecords: content.tradeRecords)
            case .pending:
                FundListDisplayRules.isDisplayedPending(fund, tradeRecords: content.tradeRecords)
            }
        }

        let searched = funds.filter { fund in
            searchText.isEmpty ? true : matchesSearch(fund)
        }

        return FundListSorter.sort(searched, mode: sortMode)
    }

    /// 按名称或代码（含展示格式）做不区分大小写的关键字匹配。
    private func matchesSearch(_ fund: FundPosition) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        let name = fund.name.lowercased()
        let code = FundCodeFormatter.display(fund.code).lowercased()
        return name.contains(query) || code.contains(query)
    }

    private func count(for value: FundListFilter, in content: DerivedListContent) -> Int {
        switch value {
        case .holding:
            return content.funds.filter {
                FundListDisplayRules.isDisplayedHolding($0, tradeRecords: content.tradeRecords)
            }.count
        case .pending:
            return content.pendingActivities.count
        }
    }

    private var visibleFilters: [FundListFilter] {
        FundListFilter.allCases
    }

    private var dismissedPendingActivityNoticeIDs: Set<String> {
        PendingActivityNoticePolicy.decodeDismissedActivityIDs(
            from: dismissedPendingActivityNoticeIDsRawValue
        )
    }

    private func showsPendingActivityNotice(_ content: DerivedListContent) -> Bool {
        PendingActivityNoticePolicy.shouldShow(
            activityIDs: content.pendingActivityIDs,
            dismissedActivityIDs: dismissedPendingActivityNoticeIDs
        )
    }

    private func dismissPendingActivityNotice(_ content: DerivedListContent) {
        dismissedPendingActivityNoticeIDsRawValue = PendingActivityNoticePolicy.encodeDismissedActivityIDs(
            Set(content.pendingActivityIDs)
        )
    }

    private func normalizePendingActivityNoticeDismissal(_ content: DerivedListContent) {
        let normalized = PendingActivityNoticePolicy.normalizedDismissedActivityIDs(
            activityIDs: content.pendingActivityIDs,
            dismissedActivityIDs: dismissedPendingActivityNoticeIDs
        )
        let rawValue = PendingActivityNoticePolicy.encodeDismissedActivityIDs(normalized)
        if rawValue != dismissedPendingActivityNoticeIDsRawValue {
            dismissedPendingActivityNoticeIDsRawValue = rawValue
        }
    }

    private var deletePendingActivityConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingPendingActivity != nil },
            set: { isPresented in
                if !isPresented {
                    deletingPendingActivity = nil
                }
            }
        )
    }

    private func deletePendingActivityConfirmationMessage(for activity: PendingTradeActivity) -> String {
        if activity.isConversion {
            return "这是一条基金转换待确认记录。删除后会连带删除同一次转换的转出、转入两条记录，并移除这笔待确认转换；已确认持仓不会被提前改动。"
        }
        if activity.recordID == nil {
            return "确定删除“\(activity.name)”这条待确认基金吗？删除后会移除这条待确认记录，且无法撤销。"
        }
        return "确定删除 \(activity.tradeDate) \(activity.tradeTimeType.title) 的\(activity.kind.title)待确认记录吗？删除后会移除这笔待确认交易，且无法撤销。"
    }

    private func pendingImpactSideText(amount: Double) -> String {
        amount > 0 ? pendingMoneyText(amount) : "--"
    }

    private func signedCompactPendingMoney(_ value: Double) -> String {
        if abs(value) < 0.5 {
            return "持平"
        }
        let sign = value > 0 ? "+" : "-"
        return "\(sign)\(pendingMoneyText(abs(value)))"
    }

    private func pendingImpactNetColor(_ value: Double) -> Color {
        if value > 0.5 {
            return .red
        }
        if value < -0.5 {
            return .redFundGreen
        }
        return .secondary
    }

    private func pendingMoneyText(_ value: Double) -> String {
        "¥\(value.formatted(.number.precision(.fractionLength(2))))"
    }

    private func numberText(_ value: Double, maxFractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...maxFractionDigits)))
    }

    private func refresh() {
        guard !isRefreshRequestInProgress else { return }
        Task {
            await refreshWithFeedback()
        }
    }

    @MainActor
    /// 工具栏刷新按钮触发的异步刷新：调用注入的 onRefresh（手动刷新，会补抓基金类型），
    /// 并短暂显示手动刷新反馈动画。
    private func refreshWithFeedback() async {
        guard !isRefreshRequestInProgress else { return }

        isRefreshing = true
        let startedAt = Date()
        await refreshAsync()

        let remainingDisplayTime = 0.35 - Date().timeIntervalSince(startedAt)
        if remainingDisplayTime > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingDisplayTime * 1_000_000_000))
        }

        // 手动刷新完成：广播信号，通知详情页等子视图强制补充拉取（如十大重仓涨跌幅），绕过定时节流。
        store.signalManualRefresh()
        isRefreshing = false
    }

    private func refreshAsync() async {
        if let onRefresh {
            await onRefresh()
        } else {
            await store.refreshQuotes(backfillTypes: true)
        }
    }
}

private enum FundListFilter: String, CaseIterable, Identifiable {
    case holding
    case pending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holding:
            "持仓"
        case .pending:
            "待确认"
        }
    }
}

enum FundSortMode: String, CaseIterable, Identifiable {
    case todayRate
    case costAmount
    case todayIncome
    case todayTotal
    case holdingIncome
    case holdingRate
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todayRate:
            "今日涨幅"
        case .costAmount:
            "持仓成本"
        case .todayIncome:
            "今日收益"
        case .todayTotal:
            "今日总值"
        case .holdingIncome:
            "持仓收益"
        case .holdingRate:
            "持仓收益率"
        case .name:
            "名称(A-Z)"
        }
    }
}

enum FundListSorter {
    static func sort(_ funds: [FundPosition], mode: FundSortMode) -> [FundPosition] {
        switch mode {
        case .todayRate:
            return sortDescending(funds) { $0.todayRate }
        case .costAmount:
            return sortDescending(funds, value: costAmount)
        case .todayIncome:
            return sortDescending(funds) { $0.todayIncome }
        case .todayTotal:
            return sortDescending(funds, value: currentTotal)
        case .holdingIncome:
            return sortDescending(funds, value: holdingIncome)
        case .holdingRate:
            return sortDescending(funds) { $0.holdingRate ?? -Double.greatestFiniteMagnitude }
        case .name:
            return funds.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    static func costAmount(for fund: FundPosition) -> Double {
        if let shares = fund.migratedShares, let cost = fund.migratedCost {
            return shares * cost
        }
        return fund.migratedPrincipal ?? 0
    }

    static func holdingIncome(for fund: FundPosition) -> Double {
        if let holdingIncome = fund.holdingIncome {
            return holdingIncome
        }
        guard let holdingRate = fund.holdingRate else { return 0 }
        return costAmount(for: fund) * holdingRate / 100
    }

    static func currentTotal(for fund: FundPosition) -> Double {
        if let currentAmount = fund.currentAmount {
            return currentAmount
        }
        if let shares = fund.migratedShares,
           let cost = fund.migratedCost {
            let costTotal = shares * cost
            return costTotal + holdingIncome(for: fund)
        }
        return fund.migratedPrincipal ?? 0
    }

    private static func sortDescending(
        _ funds: [FundPosition],
        value: (FundPosition) -> Double
    ) -> [FundPosition] {
        funds.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct PendingTradeActivity: Identifiable {
    var id: String
    var recordID: String?
    var conversionID: String?
    var kind: FundTradeKind
    var code: String
    var name: String
    var linkedCode: String?
    var linkedName: String?
    var mode: PositionMode
    var amount: Double?
    var shares: Double?
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var acceptedDate: String
    var createdAt: Date
    var displayAmount: PendingActivityAmount?
    var fund: FundPosition?
    var failureReason: String? = nil
    var waitsForExternalConfirmation: Bool = false

    var isConversion: Bool {
        kind == .conversionOut || kind == .conversionIn || conversionID != nil
    }
}

struct PendingActivityPresentation: Equatable {
    static let noticeText = "系统会在受理日次日持续检查正式净值，净值就绪后自动确认；\nQDII 等基金净值发布较晚，继续待确认通常正常。"

    var orderText: String
    var waitingText: String

    init(activity: PendingTradeActivity) {
        let code = FundCodeFormatter.display(activity.code)
        let tradeDate = Self.shortDateText(activity.tradeDate)
        orderText = "\(code) · \(tradeDate) \(activity.tradeTimeType.title)\(activity.isConversion ? "发起" : "下单")"

        if let failureReason = Self.clean(activity.failureReason) {
            waitingText = "暂无法确认 · \(failureReason)"
        } else {
            waitingText = "次日检查确认 · 净值就绪后自动更新"
        }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shortDateText(_ value: String) -> String {
        guard value.count >= 10 else { return value }
        return String(value.dropFirst(5).prefix(5))
    }
}

enum PendingActivityNoticePolicy {
    static func shouldShow(
        activityIDs: [String],
        dismissedActivityIDs: Set<String>
    ) -> Bool {
        let currentIDs = Set(activityIDs)
        guard !currentIDs.isEmpty else { return false }
        return dismissedActivityIDs.isEmpty || !currentIDs.isSubset(of: dismissedActivityIDs)
    }

    static func normalizedDismissedActivityIDs(
        activityIDs: [String],
        dismissedActivityIDs: Set<String>
    ) -> Set<String> {
        let currentIDs = Set(activityIDs)
        guard !currentIDs.isEmpty, !dismissedActivityIDs.isEmpty else { return [] }
        return currentIDs.isSubset(of: dismissedActivityIDs) ? dismissedActivityIDs : []
    }

    static func encodeDismissedActivityIDs(_ activityIDs: Set<String>) -> String {
        activityIDs.sorted().joined(separator: "\n")
    }

    static func decodeDismissedActivityIDs(from rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: "\n").map(String.init))
    }
}

struct PendingActivityAmount {
    enum Source {
        case enteredAmount
        case estimatedNetValue
        case confirmedNetValue
        case latestNetValue
    }

    var value: Double
    var source: Source
    var price: Double?
    var shares: Double?
}

enum PendingTradeActivityBuilder {
    static func make(from snapshot: PortfolioSnapshot) -> [PendingTradeActivity] {
        let fundsByCode = Dictionary(uniqueKeysWithValues: snapshot.funds.map { ($0.code, $0) })
        let records = snapshot.tradeRecords ?? []
        let pendingTrades = snapshot.pendingTrades ?? []
        let pendingTradeRecordIDs = Set(pendingTrades.compactMap(\.recordID))
        let pendingConversionTargetCodes = Set((snapshot.pendingConversions ?? []).map(\.toCode))

        var activities: [PendingTradeActivity] = pendingTrades.map { pendingTrade in
            let record = pendingTrade.recordID.flatMap { id in
                records.first { $0.id == id }
            }
            let fund = fundsByCode[pendingTrade.code]
            let acceptedDate = record?.acceptedDate ?? TradingCalendar.acceptedTradeDate(
                positionDate: pendingTrade.tradeDate,
                timeType: pendingTrade.tradeTimeType
            )
            let kind = record?.kind ?? tradeKind(for: pendingTrade.action)
            let waitsForExternalConfirmation = waitsForExternalConfirmation(
                syncSource: record?.syncSource ?? pendingTrade.syncSource,
                externalStatus: record?.externalStatus ?? pendingTrade.externalStatus,
                explicitFlag: (record?.waitsForExternalConfirmation ?? false)
                    || (pendingTrade.waitsForExternalConfirmation ?? false)
            )
            return PendingTradeActivity(
                id: "pending-trade-\(pendingTrade.id)",
                recordID: record?.id ?? pendingTrade.recordID,
                conversionID: record?.conversionID,
                kind: kind,
                code: pendingTrade.code,
                name: record?.name ?? fund?.name ?? pendingTrade.code,
                linkedCode: record?.linkedCode,
                linkedName: record?.linkedName,
                mode: record?.mode ?? pendingTrade.mode,
                amount: record?.amount ?? pendingTrade.amount,
                shares: record?.shares ?? pendingTrade.shares,
                tradeDate: pendingTrade.tradeDate,
                tradeTimeType: pendingTrade.tradeTimeType,
                acceptedDate: acceptedDate,
                createdAt: pendingTrade.createdAt,
                displayAmount: pendingDisplayAmount(
                    kind: kind,
                    amount: record?.amount ?? pendingTrade.amount,
                    shares: record?.shares ?? pendingTrade.shares,
                    acceptedDate: acceptedDate,
                    fund: fund,
                    snapshot: snapshot
                ),
                fund: fund,
                failureReason: record?.failureReason,
                waitsForExternalConfirmation: waitsForExternalConfirmation
            )
        }

        let pendingRecords = records.filter {
            $0.status == .pending
                && !pendingTradeRecordIDs.contains($0.id)
                && $0.kind != .conversionIn
        }
        activities.append(contentsOf: pendingRecords.map { record in
            PendingTradeActivity(
                id: "pending-record-\(record.id)",
                recordID: record.id,
                conversionID: record.conversionID,
                kind: record.kind,
                code: record.code,
                name: record.name,
                linkedCode: record.linkedCode,
                linkedName: record.linkedName,
                mode: record.mode,
                amount: record.amount,
                shares: record.shares,
                tradeDate: record.tradeDate,
                tradeTimeType: record.tradeTimeType,
                acceptedDate: record.acceptedDate,
                createdAt: record.createdAt,
                displayAmount: pendingDisplayAmount(
                    kind: record.kind,
                    amount: record.amount,
                    shares: record.shares,
                    acceptedDate: record.acceptedDate,
                    fund: fundsByCode[record.code],
                    snapshot: snapshot
                ),
                fund: fundsByCode[record.code],
                failureReason: record.failureReason,
                waitsForExternalConfirmation: waitsForExternalConfirmation(
                    syncSource: record.syncSource,
                    externalStatus: record.externalStatus,
                    explicitFlag: record.waitsForExternalConfirmation ?? false
                )
            )
        })

        let pendingNewFundCodes = Set(
            activities
                .filter { $0.kind == .newFund }
                .map(\.code)
        )
        let legacyPendingFunds = snapshot.funds.filter {
            FundListDisplayRules.isDisplayedPending($0, tradeRecords: records)
                && !pendingNewFundCodes.contains($0.code)
                && !pendingConversionTargetCodes.contains($0.code)
        }
        activities.append(contentsOf: legacyPendingFunds.map { fund in
            let tradeDate = fund.positionDate ?? DateOnlyFormatter.string(from: .now)
            let timeType = fund.positionTimeType ?? .before15
            let acceptedDate = TradingCalendar.acceptedTradeDate(positionDate: tradeDate, timeType: timeType)
            return PendingTradeActivity(
                id: "pending-fund-\(fund.code)",
                recordID: nil,
                conversionID: nil,
                kind: .newFund,
                code: fund.code,
                name: fund.name,
                linkedCode: nil,
                linkedName: nil,
                mode: fund.positionMode ?? .amount,
                amount: fund.pendingAmount,
                shares: fund.migratedShares,
                tradeDate: tradeDate,
                tradeTimeType: timeType,
                acceptedDate: acceptedDate,
                createdAt: .distantPast,
                displayAmount: pendingDisplayAmount(
                    kind: .newFund,
                    amount: fund.pendingAmount,
                    shares: fund.migratedShares,
                    acceptedDate: acceptedDate,
                    fund: fund,
                    snapshot: snapshot
                ),
                fund: fund
            )
        })

        return activities.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func tradeKind(for action: FundTradeAction) -> FundTradeKind {
        switch action {
        case .buy:
            .buy
        case .sell:
            .sell
        }
    }

    private static func waitsForExternalConfirmation(
        syncSource: FundTradeSyncSource?,
        externalStatus: FundTradeExternalStatus?,
        explicitFlag: Bool
    ) -> Bool {
        syncSource == .jdFinance
            && (explicitFlag || externalStatus == .waitingExternalConfirmation)
    }

    private static func pendingDisplayAmount(
        kind: FundTradeKind,
        amount: Double?,
        shares: Double?,
        acceptedDate: String,
        fund: FundPosition?,
        snapshot: PortfolioSnapshot
    ) -> PendingActivityAmount? {
        if let amount, amount > 0 {
            return PendingActivityAmount(value: amount, source: .enteredAmount, price: nil, shares: shares)
        }
        guard let shares, shares > 0,
              let reference = pendingReferenceValue(for: fund, acceptedDate: acceptedDate, snapshot: snapshot)
        else {
            return nil
        }
        return PendingActivityAmount(
            value: shares * reference.price,
            source: reference.source,
            price: reference.price,
            shares: shares
        )
    }

    private static func pendingReferenceValue(
        for fund: FundPosition?,
        acceptedDate: String,
        snapshot: PortfolioSnapshot
    ) -> (price: Double, source: PendingActivityAmount.Source)? {
        guard let fund else { return nil }
        let shares = fund.migratedShares ?? 0
        let currentAmount = PortfolioPanelDisplay.currentAmount(for: fund)
        let basePrice: Double
        if shares > 0, currentAmount > 0 {
            basePrice = currentAmount / shares
        } else if let migratedCost = fund.migratedCost, migratedCost > 0 {
            basePrice = migratedCost
        } else {
            return nil
        }

        let acceptedShortDate = String(acceptedDate.dropFirst(5))
        let updateDate = DateOnlyFormatter.string(from: snapshot.updateTime)
        let dateMatchesAcceptedNetValue = fund.dateText.hasPrefix(acceptedShortDate)
        if dateMatchesAcceptedNetValue && (fund.isUpdated || acceptedDate != updateDate) {
            return (basePrice, .confirmedNetValue)
        }

        if acceptedDate == updateDate, !fund.isUpdated, fund.todayRate != 0 {
            return (basePrice * (1 + fund.todayRate / 100), .estimatedNetValue)
        }

        return (basePrice, .latestNetValue)
    }
}

struct PendingHeaderImpact {
    var count: Int
    var buyAmount: Double = 0
    var sellAmount: Double = 0
    var conversionCount = 0
    var hasEstimatedAmount = false

    static func make(activities: [PendingTradeActivity]) -> PendingHeaderImpact? {
        var impact = PendingHeaderImpact(count: activities.count)
        var conversionKeys = Set<String>()

        for activity in activities {
            if activity.isConversion {
                conversionKeys.insert(activity.conversionID ?? activity.id)
                continue
            }

            guard let displayAmount = activity.displayAmount else {
                continue
            }

            switch activity.kind {
            case .newFund, .buy:
                impact.buyAmount += displayAmount.value
            case .sell:
                impact.sellAmount += displayAmount.value
            case .conversionOut, .conversionIn:
                conversionKeys.insert(activity.conversionID ?? activity.id)
            }

            if displayAmount.source == .estimatedNetValue {
                impact.hasEstimatedAmount = true
            }
        }

        impact.conversionCount = conversionKeys.count
        guard impact.hasAmount || impact.conversionCount > 0 else { return nil }
        return impact
    }

    var hasAmount: Bool {
        buyAmount > 0 || sellAmount > 0
    }

    var netAmount: Double {
        buyAmount - sellAmount
    }
}

private enum PortfolioPanelDisplay {
    static let allocationPalette: [Color] = [
        Color(red: 48 / 255, green: 120 / 255, blue: 214 / 255),
        Color(red: 231 / 255, green: 126 / 255, blue: 48 / 255),
        Color(red: 118 / 255, green: 92 / 255, blue: 196 / 255),
        Color(red: 37 / 255, green: 164 / 255, blue: 149 / 255),
        Color(red: 221 / 255, green: 87 / 255, blue: 133 / 255),
        Color(red: 93 / 255, green: 142 / 255, blue: 65 / 255),
        Color(red: 183 / 255, green: 95 / 255, blue: 40 / 255),
        Color(red: 92 / 255, green: 120 / 255, blue: 145 / 255)
    ]

    static func holdingFunds(in snapshot: PortfolioSnapshot) -> [FundPosition] {
        snapshot.funds.filter { fund in
            fund.status == .holding && currentAmount(for: fund) > 0
        }
    }

    static func currentAmount(for fund: FundPosition) -> Double {
        if let currentAmount = fund.currentAmount {
            return currentAmount
        }
        return principal(for: fund) + holdingIncome(for: fund)
    }

    static func principal(for fund: FundPosition) -> Double {
        if let migratedPrincipal = fund.migratedPrincipal {
            return migratedPrincipal
        }
        guard let shares = fund.migratedShares,
              let cost = fund.migratedCost
        else {
            return 0
        }
        return shares * cost
    }

    static func holdingIncome(for fund: FundPosition) -> Double {
        if let holdingIncome = fund.holdingIncome {
            return holdingIncome
        }
        guard let holdingRate = fund.holdingRate else {
            return 0
        }
        return principal(for: fund) * holdingRate / 100
    }
}

private struct PortfolioAllocationItem: Identifiable {
    let rank: Int
    let fund: FundPosition
    let amount: Double
    let share: Double
    let color: Color

    var id: String { fund.code }
}

private struct PortfolioTreemapSlice: Identifiable {
    let item: PortfolioAllocationItem
    let rect: CGRect

    var id: String { item.id }
}

private struct PortfolioTreemapHoverState {
    let itemID: String
    let location: CGPoint
}

private enum PortfolioTreemapLayout {
    static func slices(for items: [PortfolioAllocationItem], in rect: CGRect) -> [PortfolioTreemapSlice] {
        split(items.filter { $0.amount > 0 }, in: rect)
    }

    private static func split(_ items: [PortfolioAllocationItem], in rect: CGRect) -> [PortfolioTreemapSlice] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        guard items.count > 1 else {
            return [PortfolioTreemapSlice(item: items[0], rect: inset(rect))]
        }

        let total = items.reduce(0) { $0 + $1.amount }
        guard total > 0 else { return [] }

        let splitIndex = balancedSplitIndex(for: items, total: total)
        let leadingItems = Array(items.prefix(splitIndex))
        let trailingItems = Array(items.dropFirst(splitIndex))
        let leadingTotal = leadingItems.reduce(0) { $0 + $1.amount }
        let leadingRatio = min(max(leadingTotal / total, 0.05), 0.95)

        let leadingRect: CGRect
        let trailingRect: CGRect
        if rect.width >= rect.height {
            let leadingWidth = rect.width * leadingRatio
            leadingRect = CGRect(x: rect.minX, y: rect.minY, width: leadingWidth, height: rect.height)
            trailingRect = CGRect(x: rect.minX + leadingWidth, y: rect.minY, width: rect.width - leadingWidth, height: rect.height)
        } else {
            let leadingHeight = rect.height * leadingRatio
            leadingRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: leadingHeight)
            trailingRect = CGRect(x: rect.minX, y: rect.minY + leadingHeight, width: rect.width, height: rect.height - leadingHeight)
        }

        return split(leadingItems, in: leadingRect) + split(trailingItems, in: trailingRect)
    }

    private static func balancedSplitIndex(for items: [PortfolioAllocationItem], total: Double) -> Int {
        guard items.count > 2 else { return 1 }

        var runningTotal = 0.0
        var bestIndex = 1
        var bestDelta = Double.greatestFiniteMagnitude

        for index in 1..<items.count {
            runningTotal += items[index - 1].amount
            let delta = abs(total / 2 - runningTotal)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }

        return min(max(bestIndex, 1), items.count - 1)
    }

    private static func inset(_ rect: CGRect) -> CGRect {
        let insetX = min(rect.width / 8, 1.5)
        let insetY = min(rect.height / 8, 1.5)
        return rect.insetBy(dx: insetX, dy: insetY)
    }
}

private struct PortfolioTreemapChart: View {
    let items: [PortfolioAllocationItem]

    private enum LabelDensity {
        case full
        case stacked
        case compact

        var padding: CGFloat {
            switch self {
            case .full:
                6
            case .stacked:
                5
            case .compact:
                4
            }
        }

        var titleFontSize: CGFloat {
            switch self {
            case .full:
                10
            case .stacked:
                9.5
            case .compact:
                8.5
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverState: PortfolioTreemapHoverState?

    var body: some View {
        GeometryReader { proxy in
            let slices = PortfolioTreemapLayout.slices(
                for: items,
                in: CGRect(origin: .zero, size: proxy.size)
            )

            ZStack(alignment: .topLeading) {
                ForEach(slices) { slice in
                    treemapBlock(slice, isHovered: hoverState?.itemID == slice.id)
                        .frame(width: max(slice.rect.width, 0), height: max(slice.rect.height, 0))
                        .position(x: slice.rect.midX, y: slice.rect.midY)
                }

                if let hoverState,
                   let slice = slices.first(where: { $0.id == hoverState.itemID }) {
                    PortfolioTreemapHoverWindowBridge(
                        item: slice.item,
                        location: hoverState.location,
                        chartSize: proxy.size,
                        colorScheme: colorScheme
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                } else {
                    PortfolioTreemapHoverWindowBridge(
                        item: nil,
                        location: nil,
                        chartSize: proxy.size,
                        colorScheme: colorScheme
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    updateHoverState(for: slices.first { $0.rect.contains(location) }, location: location)
                case .ended:
                    updateHoverState(for: nil, location: nil)
                }
            }
        }
        .accessibilityLabel("持仓占比方块图")
    }

    private func updateHoverState(for slice: PortfolioTreemapSlice?, location: CGPoint?) {
        guard let slice, let location else {
            if hoverState != nil {
                hoverState = nil
            }
            return
        }

        let movementThreshold: CGFloat = 10
        if let hoverState,
           hoverState.itemID == slice.id,
           hypot(hoverState.location.x - location.x, hoverState.location.y - location.y) < movementThreshold {
            return
        }
        hoverState = PortfolioTreemapHoverState(itemID: slice.id, location: location)
    }

    private func treemapBlock(_ slice: PortfolioTreemapSlice, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(blockFill(for: slice.item))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isHovered ? Color.white.opacity(0.86) : Color.white.opacity(colorScheme == .dark ? 0.10 : 0.36),
                        lineWidth: isHovered ? 1.5 : 0.65
                    )
            )
            .overlay(alignment: .topLeading) {
                treemapLabel(for: slice)
                    .frame(width: max(slice.rect.width, 0), height: max(slice.rect.height, 0), alignment: .topLeading)
                    .clipped()
            }
            .shadow(
                color: isHovered ? slice.item.color.opacity(colorScheme == .dark ? 0.36 : 0.24) : .clear,
                radius: isHovered ? 9 : 0,
                x: 0,
                y: isHovered ? 3 : 0
            )
    }

    @ViewBuilder
    private func treemapLabel(for slice: PortfolioTreemapSlice) -> some View {
        if let density = labelDensity(for: slice.rect) {
            VStack(alignment: .leading, spacing: 1) {
                Text(treemapTitle(for: slice.item, density: density, width: slice.rect.width))
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .truncationMode(.tail)

                Text(treemapPercentText(for: slice.item, density: density))
                    .font(.system(size: percentFontSize(for: density), weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
            }
            .foregroundStyle(.white)
            .shadow(color: Color.black.opacity(0.32), radius: 2, x: 0, y: 1)
            .padding(density.padding)
        }
    }

    private func labelDensity(for rect: CGRect) -> LabelDensity? {
        guard rect.width >= 16, rect.height >= 28 else {
            return nil
        }
        if rect.width >= 76, rect.height >= 42 {
            return .full
        }
        if rect.width >= 54, rect.height >= 34 {
            return .stacked
        }
        return .compact
    }

    private func treemapTitle(for item: PortfolioAllocationItem, density: LabelDensity, width: CGFloat) -> String {
        let name = item.fund.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = name.isEmpty ? FundCodeFormatter.display(item.fund.code) : name
        guard density != .full else {
            return source
        }

        let availableWidth = max(width - density.padding * 2, 8)
        let estimatedCharacterWidth: CGFloat = density == .compact ? 8 : 9
        let maxCharacters = max(Int(availableWidth / estimatedCharacterWidth), 1)
        return String(source.prefix(maxCharacters))
    }

    private func treemapPercentText(for item: PortfolioAllocationItem, density: LabelDensity) -> String {
        let value = item.share * 100
        if density == .compact {
            return value.formatted(.number.precision(.fractionLength(0))) + "%"
        }
        return MoneyFormatter.percent(value)
    }

    private func percentFontSize(for density: LabelDensity) -> CGFloat {
        switch density {
        case .full:
            10
        case .stacked:
            9
        case .compact:
            7.5
        }
    }

    private func blockFill(for item: PortfolioAllocationItem) -> LinearGradient {
        LinearGradient(
            colors: [
                item.color.opacity(colorScheme == .dark ? 0.96 : 0.90),
                item.color.opacity(colorScheme == .dark ? 0.70 : 0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

}

private struct PortfolioTreemapHoverWindowBridge: NSViewRepresentable {
    let item: PortfolioAllocationItem?
    let location: CGPoint?
    let chartSize: CGSize
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(
            item: item,
            location: location,
            chartSize: chartSize,
            colorScheme: colorScheme,
            anchorView: view
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
        private var lastItemID: String?
        private var lastLocation: CGPoint?

        private let contentSize = CGSize(width: 238, height: 156)
        private let shadowMargin: CGFloat = 22
        private let gap: CGFloat = 14

        @MainActor
        func update(
            item: PortfolioAllocationItem?,
            location: CGPoint?,
            chartSize: CGSize,
            colorScheme: ColorScheme,
            anchorView: NSView
        ) {
            guard let item, let location, chartSize.width > 0, chartSize.height > 0 else {
                close()
                return
            }

            let movementThreshold: CGFloat = 6
            if lastItemID == item.id,
               let lastLocation,
               hypot(lastLocation.x - location.x, lastLocation.y - location.y) < movementThreshold {
                return
            }

            lastItemID = item.id
            lastLocation = location

            let panel = ensurePanel()
            let content = PortfolioTreemapTooltipWindowContent(
                item: item,
                colorScheme: colorScheme
            )
            .padding(shadowMargin)
            .frame(
                width: contentSize.width + shadowMargin * 2,
                height: contentSize.height + shadowMargin * 2
            )

            if let hostingView {
                hostingView.rootView = PanelFocusAppearance.suppressedRoot(content)
            } else {
                let hostingView = PanelFocusAppearance.hostingView(content)
                hostingView.frame = NSRect(
                    origin: .zero,
                    size: NSSize(
                        width: contentSize.width + shadowMargin * 2,
                        height: contentSize.height + shadowMargin * 2
                    )
                )
                hostingView.autoresizingMask = [.width, .height]
                panel.contentView = hostingView
                self.hostingView = hostingView
            }

            guard let frame = frame(for: location, chartSize: chartSize, anchorView: anchorView) else {
                close()
                return
            }
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }

        @MainActor
        func close() {
            panel?.orderOut(nil)
            lastItemID = nil
            lastLocation = nil
        }

        @MainActor
        private func ensurePanel() -> NSPanel {
            if let panel {
                return panel
            }

            let windowSize = NSSize(
                width: contentSize.width + shadowMargin * 2,
                height: contentSize.height + shadowMargin * 2
            )
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            self.panel = panel
            return panel
        }

        @MainActor
        private func frame(for location: CGPoint, chartSize: CGSize, anchorView: NSView) -> NSRect? {
            let panelSize = NSSize(
                width: contentSize.width + shadowMargin * 2,
                height: contentSize.height + shadowMargin * 2
            )
            guard let screenPoint = screenPoint(for: location, in: anchorView) else {
                return nil
            }
            let horizontalDirection: CGFloat = location.x > chartSize.width * 0.58 ? -1 : 1
            let verticalDirection: CGFloat = location.y > chartSize.height * 0.55 ? -1 : 1
            let center = CGPoint(
                x: screenPoint.x + horizontalDirection * (contentSize.width / 2 + gap),
                y: screenPoint.y - verticalDirection * (contentSize.height / 2 + gap)
            )
            var frame = NSRect(
                x: center.x - panelSize.width / 2,
                y: center.y - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            )

            if let visibleFrame = screen(for: frame)?.visibleFrame {
                let inset: CGFloat = 8
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + inset), visibleFrame.maxX - frame.width - inset)
                frame.origin.y = min(max(frame.origin.y, visibleFrame.minY + inset), visibleFrame.maxY - frame.height - inset)
            }
            return frame
        }

        @MainActor
        private func screenPoint(for location: CGPoint, in anchorView: NSView) -> CGPoint? {
            guard let window = anchorView.window else {
                return nil
            }
            let localPoint = NSPoint(x: location.x, y: anchorView.bounds.height - location.y)
            let windowPoint = anchorView.convert(localPoint, to: nil)
            return window.convertPoint(toScreen: windowPoint)
        }

        @MainActor
        private func screen(for frame: NSRect) -> NSScreen? {
            NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        }
    }
}

private struct PortfolioTreemapTooltipWindowContent: View {
    let item: PortfolioAllocationItem
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(item.color)
                    .frame(width: 7, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fund.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(FundCodeFormatter.display(item.fund.code))
                        Text("第\(item.rank)大持仓")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                alignment: .leading,
                spacing: 7
            ) {
                tooltipMetric("持仓占比", MoneyFormatter.percent(item.share * 100), color: item.color)
                tooltipMetric("持仓金额", MoneyFormatter.plainMoney(item.amount), color: .primary)
                tooltipMetric("今日涨幅", MoneyFormatter.percent(item.fund.todayRate, signed: true), color: toneColor(for: item.fund.todayRate))
                tooltipMetric("今日收益", MoneyFormatter.money(item.fund.todayIncome, signed: true), color: toneColor(for: item.fund.todayIncome))
                tooltipMetric(
                    "持仓收益",
                    MoneyFormatter.money(PortfolioPanelDisplay.holdingIncome(for: item.fund), signed: true),
                    color: toneColor(for: PortfolioPanelDisplay.holdingIncome(for: item.fund))
                )
                tooltipMetric(
                    "持仓收益率",
                    item.fund.holdingRate.map { MoneyFormatter.percent($0, signed: true) } ?? "--",
                    color: item.fund.holdingRate.map(toneColor(for:)) ?? .secondary
                )
            }
        }
        .padding(11)
        .frame(width: 238, height: 156, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tooltipBaseColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tooltipAccentOverlay)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.color.opacity(colorScheme == .dark ? 0.32 : 0.22), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.17), radius: 14, x: 0, y: 8)
    }

    private func tooltipMetric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var tooltipBaseColor: Color {
        colorScheme == .dark
            ? Color(red: 26 / 255, green: 29 / 255, blue: 35 / 255).opacity(0.99)
            : Color(nsColor: .windowBackgroundColor).opacity(0.99)
    }

    private var tooltipAccentOverlay: LinearGradient {
        LinearGradient(
            colors: [
                item.color.opacity(colorScheme == .dark ? 0.10 : 0.055),
                item.color.opacity(colorScheme == .dark ? 0.05 : 0.025)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct PortfolioAllocationPanelView: View {
    let store: PortfolioStore
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "square.grid.3x3.fill",
                title: "持仓占比",
                subtitle: allocationHeaderSubtitle,
                subtitleWeight: .semibold,
                tint: Color(nsColor: .systemBlue),
                onClose: onClose
            )

            ScrollView {
                if allocationItems.isEmpty {
                    ContentUnavailableView("暂无持仓占比", systemImage: "chart.pie")
                        .frame(height: 420)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        allocationSummary
                        allocationChartSection
                        categoryDistributionSection
                            .zIndex(1)
                        allocationBreakdownList
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(PanelDesign.panelBackground)
    }

    private var allocationItems: [PortfolioAllocationItem] {
        let funds = PortfolioPanelDisplay.holdingFunds(in: store.snapshot)
            .sorted {
                let lhsAmount = PortfolioPanelDisplay.currentAmount(for: $0)
                let rhsAmount = PortfolioPanelDisplay.currentAmount(for: $1)
                if lhsAmount != rhsAmount {
                    return lhsAmount > rhsAmount
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        let total = funds.reduce(0) { $0 + PortfolioPanelDisplay.currentAmount(for: $1) }
        guard total > 0 else { return [] }

        return funds.enumerated().map { index, fund in
            let amount = PortfolioPanelDisplay.currentAmount(for: fund)
            return PortfolioAllocationItem(
                rank: index + 1,
                fund: fund,
                amount: amount,
                share: amount / total,
                color: PortfolioPanelDisplay.allocationPalette[index % PortfolioPanelDisplay.allocationPalette.count]
            )
        }
    }

    private var allocationTotal: Double {
        allocationItems.reduce(0) { $0 + $1.amount }
    }

    private var allocationHeaderSubtitle: String {
        guard !allocationItems.isEmpty else { return "暂无持仓基金" }
        return "\(allocationItems.count)只基金 · \(MoneyFormatter.plainMoney(allocationTotal))"
    }

    private var largestAllocationText: String {
        allocationItems.first.map { MoneyFormatter.percent($0.share * 100) } ?? "--"
    }

    private var allocationSummary: some View {
        HStack(spacing: 0) {
            allocationSummaryMetric("持仓金额", MoneyFormatter.plainMoney(allocationTotal), color: .primary)
            summaryDivider
            allocationSummaryMetric("基金数量", "\(allocationItems.count)只", color: .primary)
            summaryDivider
            allocationSummaryMetric("最大占比", largestAllocationText, color: allocationItems.first?.color ?? .secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private var allocationChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelSectionTitle("持仓方块图")
            PortfolioTreemapChart(items: allocationItems)
                .frame(height: 190)
        }
        .padding(12)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 按基金类型分组的资产分布（股票型/QDII/债券型/货币型/...）。
    /// 仅在有基金已抓取 fundType 时展示。
    private var categoryDistributionItems: [(type: FundType, amount: Double, share: Double)] {
        let funds = PortfolioPanelDisplay.holdingFunds(in: store.snapshot)
        guard funds.contains(where: { $0.fundType != nil }) else { return [] }

        var byType: [FundType: Double] = [:]
        for fund in funds {
            let type = fund.fundType ?? .other
            byType[type, default: 0] += PortfolioPanelDisplay.currentAmount(for: fund)
        }
        let total = byType.values.reduce(0, +)
        guard total > 0 else { return [] }

        return byType.map { type, amount in
            (type: type, amount: amount, share: amount / total)
        }
        .sorted { $0.share > $1.share }
    }

    private var categoryDistributionSection: some View {
        CategoryDistributionSectionView(
            items: categoryDistributionItems,
            colorFor: { id in
                FundType(rawValue: id).map { categoryColor($0) } ?? Color(nsColor: .systemGray)
            },
            amountText: { MoneyFormatter.plainMoney($0) },
            percentText: { MoneyFormatter.percent($0 * 100) },
            headerTitle: "资产分布"
        )
        .padding(12)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 资产分布区块。持有悬停状态，气泡绘制在整个卡片顶层 overlay，避免被图例或后续卡片遮挡/裁剪。
    private struct CategoryDistributionSectionView: View {
        let items: [(type: FundType, amount: Double, share: Double)]
        let colorFor: (String) -> Color
        let amountText: (Double) -> String
        let percentText: (Double) -> String
        let headerTitle: String

        @State private var hoverLocation: CGPoint?
        @State private var hoverId: String?
        @State private var donutFrame: CGRect = .zero
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Self.sectionTitle(headerTitle)
                if items.isEmpty {
                    Text("建仓或加仓后将自动识别基金类型")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        CategoryDonutView(
                            items: items.map {
                                CategoryDonutView.Item(
                                    id: $0.type.id,
                                    title: $0.type.title,
                                    amount: $0.amount,
                                    share: $0.share
                                )
                            },
                            colorFor: colorFor,
                            amountText: amountText,
                            percentText: percentText,
                            hoverLocation: $hoverLocation,
                            hoverId: $hoverId
                        )
                        .frame(width: 112, height: 112)
                        .overlay(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: DonutFrameKey.self,
                                    value: proxy.frame(in: .named("categorySection"))
                                )
                            }
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(items, id: \.type.id) { item in
                                HStack(spacing: 6) {
                                    Self.categorySwatch(item.type)
                                    Text(item.type.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(amountText(item.amount))
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    Spacer(minLength: 4)
                                    Text(percentText(item.share))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Self.categoryColor(item.type))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .coordinateSpace(name: "categorySection")
            .overlay(alignment: .topLeading) {
                bubbleOverlay
            }
        }

        @ViewBuilder
        private var bubbleOverlay: some View {
            if let hoverId,
               let item = items.first(where: { $0.type.id == hoverId }) {
                let pt = hoverLocation ?? .zero
                let originX = donutFrame.minX + pt.x + 14
                let originY = donutFrame.minY + pt.y + 14
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colorFor(item.type.id))
                            .frame(width: 8, height: 8)
                        Text(item.type.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 6) {
                        Text(percentText(item.share))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(colorFor(item.type.id))
                        Text(amountText(item.amount))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(width: 136)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark
                              ? Color(white: 0.16)
                              : Color(white: 1.0))
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 5)
                .position(x: originX + 68, y: originY + 28)
            }
        }

        private static func sectionTitle(_ title: String) -> some View {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }

        private static func categorySwatch(_ type: FundType) -> some View {
            Circle()
                .fill(categoryColor(type))
                .frame(width: 9, height: 9)
        }

        fileprivate static func categoryColor(_ type: FundType) -> Color {
            switch type {
            case .stock:  Color(red: 201 / 255, green: 42 / 255, blue: 42 / 255)
            case .index:  Color(red: 222 / 255, green: 111 / 255, blue: 38 / 255)
            case .hybrid: Color(red: 168 / 255, green: 120 / 255, blue: 224 / 255)
            case .qdii:   Color(red: 38 / 255, green: 122 / 255, blue: 224 / 255)
            case .bond:   Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255)
            case .money:  Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)
            case .other:  Color(nsColor: .systemGray)
            }
        }
    }

    private struct DonutFrameKey: PreferenceKey {
        static var defaultValue: CGRect { .zero }
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    private func categoryColor(_ type: FundType) -> Color {
        switch type {
        case .stock:  Color(red: 201 / 255, green: 42 / 255, blue: 42 / 255)
        case .index:  Color(red: 222 / 255, green: 111 / 255, blue: 38 / 255)
        case .hybrid: Color(red: 168 / 255, green: 120 / 255, blue: 224 / 255)
        case .qdii:   Color(red: 38 / 255, green: 122 / 255, blue: 224 / 255)
        case .bond:   Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255)
        case .money:  Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)
        case .other:  Color(nsColor: .systemGray)
        }
    }

/// 资产分布甜甜圈图：支持鼠标悬停高亮对应扇区并弹出类型/占比/金额提示。
private struct CategoryDonutView: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let amount: Double
        let share: Double
    }

    let items: [Item]
    let colorFor: (String) -> Color
    let amountText: (Double) -> String
    let percentText: (Double) -> String

    @Binding var hoverLocation: CGPoint?
    @Binding var hoverId: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let lineWidth: CGFloat = max(diameter * 0.20, 16)
            let radius = (diameter - lineWidth) / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                Canvas { context, _ in
                    var startAngle = Angle.degrees(-90)
                    for item in items {
                        let sweep = Angle.degrees(360 * item.share)
                        let endAngle = startAngle + sweep
                        let isHovered = item.id == hoverId
                        let path = Path { path in
                            path.addArc(
                                center: center,
                                radius: radius,
                                startAngle: startAngle,
                                endAngle: endAngle,
                                clockwise: false
                            )
                        }
                        var color = colorFor(item.id)
                        if hoverId != nil && !isHovered {
                            color = color.opacity(0.35)
                        } else if isHovered {
                            color = color
                        }
                        context.stroke(path, with: .color(color), lineWidth: lineWidth)
                        startAngle = endAngle
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hoverId = hitTest(location: location, size: geometry.size, center: center, radius: radius)
                case .ended:
                    hoverLocation = nil
                    hoverId = nil
                }
            }
        }
    }

    /// 根据鼠标位置判断命中哪个扇区（环内 + 角度区间）。
    /// location 为 SwiftUI 本地坐标（y 向下），onContinuousHover 直接提供，无需翻转。
    private func hitTest(location: CGPoint?, size: CGSize, center: CGPoint, radius: CGFloat) -> String? {
        guard let location, size.width > 0 else { return nil }
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        // 仅命中环带区域（线宽的一半范围内），并处于中心圆之外。
        guard distance >= radius - 6, distance <= radius + 20 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        angle = (angle + 90).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }

        var start = 0.0
        for item in items {
            let end = start + item.share * 360
            if angle >= start, angle < end {
                return item.id
            }
            start = end
        }
        return nil
    }
}

    private var allocationBreakdownList: some View {
        AllocationBreakdownView(items: allocationItems)
    }

    /// 占比明细：按基金类型（股票型/债券型/混合型/QDII/指数型/货币型/其他）分组展示。
    /// 顶部为分类选择条，点击某一分类查看该分类下的基金（基金行展示与原来一致）。
    private struct AllocationBreakdownView: View {
        let items: [PortfolioAllocationItem]
        @State private var selectedType: FundType
        @Environment(\.colorScheme) private var colorScheme

        private var grouped: [(type: FundType, share: Double, funds: [PortfolioAllocationItem])] {
            let total = items.reduce(0) { $0 + $1.amount }
            let present = Set(items.compactMap { $0.fund.fundType })
            let types = FundType.allCases.filter { present.contains($0) }
            return types.map { type in
                let funds = items.filter { ($0.fund.fundType ?? .other) == type }
                let share = total > 0 ? funds.reduce(0) { $0 + $1.amount } / total : 0
                return (type: type, share: share, funds: funds)
            }
            .sorted { $0.share > $1.share }
        }

        init(items: [PortfolioAllocationItem]) {
            self.items = items
            _selectedType = State(initialValue: Self.defaultType(for: items))
        }

        private static func defaultType(for items: [PortfolioAllocationItem]) -> FundType {
            let total = items.reduce(0) { $0 + $1.amount }
            let present = Set(items.compactMap { $0.fund.fundType })
            let shares = FundType.allCases
                .filter { present.contains($0) }
                .map { type -> (FundType, Double) in
                    let sum = items.filter { ($0.fund.fundType ?? .other) == type }
                                    .reduce(0) { $0 + $1.amount }
                    return (type, total > 0 ? sum / total : 0)
                }
            return shares.max(by: { $0.1 < $1.1 })?.0 ?? .stock
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                panelSectionTitle("占比明细")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(grouped, id: \.type.id) { group in
                            categoryChip(type: group.type, isSelected: group.type == selectedType)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 30)

                if let group = grouped.first(where: { $0.type == selectedType }) {
                    VStack(spacing: 7) {
                        ForEach(group.funds) { item in
                            PortfolioAllocationPanelView.allocationRow(item, colorScheme: colorScheme)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(PanelDesign.border(cornerRadius: 10))
        }

        private func panelSectionTitle(_ title: String) -> some View {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }

        @ViewBuilder
        private func categoryChip(type: FundType, isSelected: Bool) -> some View {
            let color = CategoryDistributionSectionView.categoryColor(type)
            Button {
                selectedType = type
            } label: {
                Text(type.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected
                                  ? color.opacity(colorScheme == .dark ? 0.22 : 0.14)
                                  : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? color.opacity(0.6) : Color.clear, lineWidth: 1))
                    .foregroundStyle(isSelected ? color : .primary)
            }
            .buttonStyle(.plain)
        }
    }

    private func allocationSummaryMetric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.30 : 0.22))
            .frame(width: 1, height: 32)
            .padding(.horizontal, 10)
    }

    private static func allocationRow(_ item: PortfolioAllocationItem, colorScheme: ColorScheme) -> some View {
        HStack(spacing: 10) {
            rankBadge(item.rank, color: item.color, colorScheme: colorScheme)

            VStack(alignment: .leading, spacing: 3) {
                Text(FundCodeFormatter.display(item.fund.code))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.fund.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(MoneyFormatter.percent(item.share * 100))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.color)
                Text(MoneyFormatter.plainMoney(item.amount))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(item.color.opacity(colorScheme == .dark ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private static func rankBadge(_ rank: Int, color: Color, colorScheme: ColorScheme) -> some View {
        Text("\(rank)")
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(color.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Circle())
            .overlay(Circle().stroke(color.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.7))
    }

    private func panelSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

private struct TodayIncomeRankItem: Identifiable {
    let rank: Int
    let fund: FundPosition

    var id: String { fund.code }
}

private enum TodayIncomeRankingMode: String, CaseIterable, Identifiable {
    case gain
    case loss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gain:
            "涨幅榜"
        case .loss:
            "跌幅榜"
        }
    }

    var emptyTitle: String {
        switch self {
        case .gain:
            "暂无上涨基金"
        case .loss:
            "暂无下跌基金"
        }
    }

    var summaryTitle: String {
        switch self {
        case .gain:
            "上涨合计"
        case .loss:
            "下跌合计"
        }
    }

    var tint: Color {
        switch self {
        case .gain:
            Color(red: 201 / 255, green: 42 / 255, blue: 42 / 255)
        case .loss:
            Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255)
        }
    }
}

enum IncomeRankingKind: Equatable {
    case today
    case holding

    func title(for metric: IncomeRankingMetric) -> String {
        switch self {
        case .today where metric == .amount:
            return "实时收益排行"
        case .today:
            return "实时收益率排行"
        case .holding where metric == .amount:
            return "持仓收益排行"
        case .holding:
            return "持仓收益率排行"
        }
    }

    var unavailableTitle: String {
        switch self {
        case .today:
            "暂无实时收益"
        case .holding:
            "暂无持仓收益"
        }
    }

    var unavailableSystemImage: String {
        switch self {
        case .today:
            "chart.line.uptrend.xyaxis"
        case .holding:
            "chart.bar.xaxis"
        }
    }

    func gainTitle(for metric: IncomeRankingMetric) -> String {
        metric == .amount ? "收益榜" : "涨幅榜"
    }

    func lossTitle(for metric: IncomeRankingMetric) -> String {
        metric == .amount ? "亏损榜" : "跌幅榜"
    }

    var gainEmptyTitle: String {
        switch self {
        case .today:
            "暂无上涨基金"
        case .holding:
            "暂无盈利基金"
        }
    }

    var lossEmptyTitle: String {
        switch self {
        case .today:
            "暂无下跌基金"
        case .holding:
            "暂无亏损基金"
        }
    }

    var gainSummaryTitle: String {
        switch self {
        case .today:
            "涨"
        case .holding:
            "盈"
        }
    }

    var lossSummaryTitle: String {
        switch self {
        case .today:
            "跌"
        case .holding:
            "亏"
        }
    }
}

enum IncomeRankingMetric: String, CaseIterable, Identifiable {
    case amount
    case rate

    var id: String { rawValue }

    var holdingPickerTitle: String {
        switch self {
        case .amount:
            "按金额"
        case .rate:
            "按收益率"
        }
    }
}

private struct TodayIncomeRankPalette {
    let foreground: Color
    let deep: Color
    let background: Color
    let border: Color
}

private struct TodayIncomeRankMedalPalette {
    let foreground: Color
    let deep: Color
    let light: Color
    let border: Color
}

struct TodayIncomeRankingPanelView: View {
    let store: PortfolioStore
    let kind: IncomeRankingKind
    let metric: IncomeRankingMetric
    let onClose: () -> Void
    var isEmbedded = false
    var metricSelection: Binding<IncomeRankingMetric>? = nil

    @State private var rankingMode: TodayIncomeRankingMode = .gain
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if !isEmbedded {
                PanelHeader(
                    systemImage: "list.number",
                    title: kind.title(for: metric),
                    subtitle: rankingHeaderSubtitle,
                    subtitleWeight: .semibold,
                    tint: toneColor(for: totalValue),
                    accessoryText: updatedHeaderTagText,
                    accessoryColor: .orange,
                    onClose: onClose
                )
            }

            ScrollView {
                if rankableFunds.isEmpty {
                    ContentUnavailableView(kind.unavailableTitle, systemImage: kind.unavailableSystemImage)
                        .frame(height: 420)
                } else {
                    LazyVStack(spacing: 10) {
                        rankingSummary
                        if let metricSelection {
                            rankingControls(metricSelection: metricSelection)
                        } else {
                            rankingModePicker
                        }
                        if rankingItems.isEmpty {
                            ContentUnavailableView(emptyTitle(for: rankingMode), systemImage: rankingMode == .gain ? "arrow.up.right" : "arrow.down.right")
                                .frame(height: 260)
                        } else {
                            ForEach(rankingItems) { item in
                                rankingRow(item)
                            }
                        }
                    }
                    .padding(.horizontal, isEmbedded ? 0 : 14)
                    .padding(.bottom, 14)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(PanelDesign.panelBackground)
        .onAppear {
            selectAvailableRankingModeIfNeeded()
        }
        .onChange(of: metric) { _, _ in
            selectAvailableRankingModeIfNeeded()
        }
    }

    private var rankableFunds: [FundPosition] {
        store.snapshot.funds.filter { fund in
            switch kind {
            case .today:
                !fund.status.isPendingDisplay && (fund.isIncomeActive ?? true)
            case .holding:
                fund.status == .holding && (fund.isIncomeActive ?? true)
            }
        }
    }

    private var rankingItems: [TodayIncomeRankItem] {
        let funds = rankableFunds
            .filter { fund in
                switch rankingMode {
                case .gain:
                    rankingValue(for: fund) > 0
                case .loss:
                    rankingValue(for: fund) < 0
                }
            }
            .sorted { lhs, rhs in
                let lhsValue = rankingValue(for: lhs)
                let rhsValue = rankingValue(for: rhs)
                if lhsValue != rhsValue {
                    return rankingMode == .gain ? lhsValue > rhsValue : lhsValue < rhsValue
                }
                let lhsTieValue = tieBreakValue(for: lhs)
                let rhsTieValue = tieBreakValue(for: rhs)
                if lhsTieValue != rhsTieValue {
                    return rankingMode == .gain ? lhsTieValue > rhsTieValue : lhsTieValue < rhsTieValue
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        return funds.enumerated().map { index, fund in
            TodayIncomeRankItem(rank: index + 1, fund: fund)
        }
    }

    private var updatedFundsCount: Int {
        rankingItems.filter { $0.fund.isUpdated }.count
    }

    private var rankingHeaderSubtitle: String {
        guard !rankableFunds.isEmpty else { return "暂无持仓基金" }
        return "\(rankableFunds.count)只基金 · \(summaryValueText(totalValue))"
    }

    private var updatedHeaderTagText: String? {
        let updatedCount = rankableFunds.filter { $0.isUpdated }.count
        guard updatedCount > 0 else { return nil }
        if updatedCount == rankableFunds.count {
            return "全部已更新"
        }
        return "\(updatedCount)只已更新"
    }

    private var rankingModePicker: some View {
        PanelSegmentedPicker(
            values: TodayIncomeRankingMode.allCases,
            selection: $rankingMode,
            title: { title(for: $0) },
            tint: rankingMode.tint
        )
    }

    private func rankingControls(metricSelection: Binding<IncomeRankingMetric>) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(IncomeRankingMetric.allCases) { value in
                    Button {
                        metricSelection.wrappedValue = value
                    } label: {
                        if value == metricSelection.wrappedValue {
                            Label(value.holdingPickerTitle, systemImage: "checkmark")
                        } else {
                            Text(value.holdingPickerTitle)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(metric.holdingPickerTitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(PanelDesign.selectorBackground, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.6)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusEffectDisabled()
            .accessibilityLabel("排行指标")
            .accessibilityValue(metric.holdingPickerTitle)
            .help("切换按金额或按收益率排行")

            rankingModePicker
        }
    }

    private var gainFunds: [FundPosition] {
        rankableFunds.filter { rankingValue(for: $0) > 0 }
    }

    private var lossFunds: [FundPosition] {
        rankableFunds.filter { rankingValue(for: $0) < 0 }
    }

    private func selectAvailableRankingModeIfNeeded() {
        if rankingMode == .gain, gainFunds.isEmpty, !lossFunds.isEmpty {
            rankingMode = .loss
        } else if rankingMode == .loss, lossFunds.isEmpty, !gainFunds.isEmpty {
            rankingMode = .gain
        }
    }

    private var gainSummaryValue: Double {
        summaryGroupValue(for: gainFunds)
    }

    private var lossSummaryValue: Double {
        summaryGroupValue(for: lossFunds)
    }

    private var totalValue: Double {
        switch kind {
        case .today where metric == .amount:
            store.snapshot.todayIncome
        case .today:
            store.snapshot.todayIncomeRate
        case .holding where metric == .amount:
            store.snapshot.holdingIncome
        case .holding:
            store.snapshot.holdingIncomeRate
        }
    }

    private func rankingValue(for fund: FundPosition) -> Double {
        switch metric {
        case .amount:
            income(for: fund)
        case .rate:
            rate(for: fund)
        }
    }

    private func tieBreakValue(for fund: FundPosition) -> Double {
        switch metric {
        case .amount:
            rate(for: fund)
        case .rate:
            income(for: fund)
        }
    }

    private func income(for fund: FundPosition) -> Double {
        switch kind {
        case .today:
            return fund.todayIncome
        case .holding:
            if let holdingIncome = fund.holdingIncome {
                return holdingIncome
            }
            guard let holdingRate = fund.holdingRate else { return 0 }
            return principal(for: fund) * holdingRate / 100
        }
    }

    private func rate(for fund: FundPosition) -> Double {
        switch kind {
        case .today:
            fund.todayRate
        case .holding:
            fund.holdingRate ?? 0
        }
    }

    private func principal(for fund: FundPosition) -> Double {
        if let migratedPrincipal = fund.migratedPrincipal {
            return migratedPrincipal
        }
        guard let shares = fund.migratedShares,
              let cost = fund.migratedCost
        else {
            return 0
        }
        return shares * cost
    }

    private func title(for mode: TodayIncomeRankingMode) -> String {
        switch mode {
        case .gain:
            kind.gainTitle(for: metric)
        case .loss:
            kind.lossTitle(for: metric)
        }
    }

    private func emptyTitle(for mode: TodayIncomeRankingMode) -> String {
        switch mode {
        case .gain:
            kind.gainEmptyTitle
        case .loss:
            kind.lossEmptyTitle
        }
    }

    private var rankingSummary: some View {
        HStack(spacing: 0) {
            rankingSummaryMetric(
                "合计",
                summaryValueText(totalValue),
                tone: totalValue,
                footnote: "\(rankableFunds.count)只"
            )
            summaryDivider
            rankingSummaryMetric(
                groupSummaryTitle(isGain: true),
                summaryValueText(gainSummaryValue),
                tone: gainSummaryValue,
                footnote: "\(gainFunds.count)只"
            )
            summaryDivider
            rankingSummaryMetric(
                groupSummaryTitle(isGain: false),
                summaryValueText(lossSummaryValue),
                tone: lossSummaryValue,
                footnote: "\(lossFunds.count)只"
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private func summaryGroupValue(for funds: [FundPosition]) -> Double {
        guard !funds.isEmpty else { return 0 }
        switch metric {
        case .amount:
            return funds.reduce(0) { $0 + income(for: $1) }
        case .rate:
            return funds.reduce(0) { $0 + rate(for: $1) } / Double(funds.count)
        }
    }

    private func groupSummaryTitle(isGain: Bool) -> String {
        if kind == .holding, metric == .rate {
            return isGain ? "盈利均值" : "亏损均值"
        }
        return isGain ? kind.gainSummaryTitle : kind.lossSummaryTitle
    }

    private func summaryValueText(_ value: Double) -> String {
        switch metric {
        case .amount:
            MoneyFormatter.money(value, signed: true)
        case .rate:
            MoneyFormatter.percent(value, signed: true)
        }
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.30 : 0.22))
            .frame(width: 1, height: 32)
            .padding(.horizontal, 10)
    }

    private func rankingSummaryMetric(_ title: String, _ value: String, tone: Double?, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(footnote)
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone.map(toneColor(for:)) ?? Color.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 13)
                    .background((tone.map(toneColor(for:)) ?? Color.secondary).opacity(colorScheme == .dark ? 0.14 : 0.08), in: Capsule())
            }
            .lineLimit(1)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(tone.map(toneColor(for:)) ?? Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingRow(_ item: TodayIncomeRankItem) -> some View {
        let isTopRank = item.rank <= 3
        let palette = rankPalette(for: item)
        return HStack(spacing: 10) {
            rankBadge(for: item)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.fund.name)
                        .font(.system(size: isTopRank ? 12.5 : 12, weight: .semibold))
                        .lineLimit(1)
                    if item.fund.isUpdated {
                        updatedTag
                    }
                }

                HStack(spacing: 7) {
                    Text(FundCodeFormatter.display(item.fund.code))
                        .fontWeight(.semibold)
                    Text(item.fund.dateText)
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(primaryValueText(for: item.fund))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .foregroundStyle(palette.foreground)
                Text(secondaryValueText(for: item.fund))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(palette.foreground.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule())
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, isTopRank ? 12 : 10)
        .frame(minHeight: isTopRank ? 70 : 62)
        .background(rowBackground(for: item), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(rowBorder(for: item))
        .shadow(
            color: item.rank <= 3 ? palette.foreground.opacity(colorScheme == .dark ? 0.22 : 0.14) : .clear,
            radius: item.rank <= 3 ? 8 : 0,
            x: 0,
            y: item.rank <= 3 ? 3 : 0
        )
    }

    private func primaryValueText(for fund: FundPosition) -> String {
        switch metric {
        case .amount:
            MoneyFormatter.money(income(for: fund), signed: true)
        case .rate:
            MoneyFormatter.percent(rate(for: fund), signed: true)
        }
    }

    private func secondaryValueText(for fund: FundPosition) -> String {
        switch metric {
        case .amount:
            MoneyFormatter.percent(rate(for: fund), signed: true)
        case .rate:
            MoneyFormatter.money(income(for: fund), signed: true)
        }
    }

    private func rankBadge(for item: TodayIncomeRankItem) -> some View {
        let rank = item.rank
        let palette = rankPalette(for: item)
        if rank <= 3 {
            let medal = medalPalette(for: rank)
            return AnyView(
                VStack(spacing: 1) {
                    Image(systemName: "medal.fill")
                        .font(.system(size: 10, weight: .black))
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .heavy))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.white)
                .shadow(color: medal.deep.opacity(0.30), radius: 1.5, x: 0, y: 0.8)
                .frame(width: 38, height: 38)
                .background(
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        medal.light.opacity(colorScheme == .dark ? 0.78 : 0.96),
                                        medal.foreground.opacity(colorScheme == .dark ? 0.88 : 0.94),
                                        medal.deep.opacity(colorScheme == .dark ? 0.82 : 0.90)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Circle()
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.54), lineWidth: 1.0)
                            .padding(2.5)
                    }
                )
                .overlay(Circle().stroke(medal.border.opacity(colorScheme == .dark ? 0.52 : 0.72), lineWidth: 0.9))
                .shadow(color: medal.deep.opacity(colorScheme == .dark ? 0.24 : 0.16), radius: 6, x: 0, y: 2)
            )
        }

        return AnyView(
            Text("\(rank)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(palette.foreground)
                .frame(width: 28, height: 28)
                .background(circleBackground(for: palette), in: Circle())
                .overlay(Circle().stroke(borderColor(for: palette, isTopRank: false), lineWidth: 0.75))
        )
    }

    private var updatedTag: some View {
        Text("已更新")
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 0.6)
            )
    }

    private func rowBackground(for item: TodayIncomeRankItem) -> some ShapeStyle {
        let palette = rankPalette(for: item)
        if item.rank <= 3 {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        cardBackgroundColor(for: palette, isTopRank: true),
                        palette.foreground.opacity(colorScheme == .dark ? 0.18 : 0.095),
                        PanelDesign.cardBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    cardBackgroundColor(for: palette, isTopRank: false),
                    PanelDesign.cardBackground
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func rowBorder(for item: TodayIncomeRankItem) -> some View {
        let palette = rankPalette(for: item)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
                borderColor(for: palette, isTopRank: item.rank <= 3),
                lineWidth: item.rank <= 3 ? 1.05 : 0.75
            )
    }

    private func rankPalette(for item: TodayIncomeRankItem) -> TodayIncomeRankPalette {
        let isLoss = rankingMode == .loss
        switch item.rank {
        case 1:
            return isLoss
                ? TodayIncomeRankPalette(
                    foreground: Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255),
                    deep: Color(red: 3 / 255, green: 84 / 255, blue: 63 / 255),
                    background: Color(red: 220 / 255, green: 252 / 255, blue: 231 / 255),
                    border: Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
                )
                : TodayIncomeRankPalette(
                    foreground: Color(red: 166 / 255, green: 31 / 255, blue: 23 / 255),
                    deep: Color(red: 122 / 255, green: 28 / 255, blue: 20 / 255),
                    background: Color(red: 255 / 255, green: 224 / 255, blue: 219 / 255),
                    border: Color(red: 240 / 255, green: 68 / 255, blue: 56 / 255)
                )
        case 2:
            return isLoss
                ? TodayIncomeRankPalette(
                    foreground: Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255),
                    deep: Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255),
                    background: Color(red: 229 / 255, green: 253 / 255, blue: 237 / 255),
                    border: Color(red: 110 / 255, green: 231 / 255, blue: 183 / 255)
                )
                : TodayIncomeRankPalette(
                    foreground: Color(red: 201 / 255, green: 42 / 255, blue: 42 / 255),
                    deep: Color(red: 166 / 255, green: 31 / 255, blue: 23 / 255),
                    background: Color(red: 255 / 255, green: 234 / 255, blue: 228 / 255),
                    border: Color(red: 249 / 255, green: 112 / 255, blue: 102 / 255)
                )
        case 3:
            return isLoss
                ? TodayIncomeRankPalette(
                    foreground: Color(red: 18 / 255, green: 183 / 255, blue: 106 / 255),
                    deep: Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255),
                    background: Color(red: 237 / 255, green: 253 / 255, blue: 243 / 255),
                    border: Color(red: 167 / 255, green: 243 / 255, blue: 208 / 255)
                )
                : TodayIncomeRankPalette(
                    foreground: Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255),
                    deep: Color(red: 201 / 255, green: 42 / 255, blue: 42 / 255),
                    background: Color(red: 255 / 255, green: 241 / 255, blue: 236 / 255),
                    border: Color(red: 253 / 255, green: 162 / 255, blue: 155 / 255)
                )
        default:
            return isLoss
                ? TodayIncomeRankPalette(
                    foreground: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
                    deep: Color(red: 18 / 255, green: 183 / 255, blue: 106 / 255),
                    background: Color(red: 240 / 255, green: 253 / 255, blue: 244 / 255),
                    border: Color(red: 187 / 255, green: 247 / 255, blue: 208 / 255)
                )
                : TodayIncomeRankPalette(
                    foreground: Color(red: 239 / 255, green: 96 / 255, blue: 87 / 255),
                    deep: Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255),
                    background: Color(red: 255 / 255, green: 245 / 255, blue: 243 / 255),
                    border: Color(red: 254 / 255, green: 205 / 255, blue: 202 / 255)
                )
        }
    }

    private func cardBackgroundColor(for palette: TodayIncomeRankPalette, isTopRank: Bool) -> Color {
        if colorScheme == .dark {
            return palette.foreground.opacity(isTopRank ? 0.28 : 0.16)
        }
        return isTopRank ? palette.background : palette.background.opacity(0.86)
    }

    private func circleBackground(for palette: TodayIncomeRankPalette) -> Color {
        colorScheme == .dark ? palette.foreground.opacity(0.20) : palette.background
    }

    private func borderColor(for palette: TodayIncomeRankPalette, isTopRank: Bool) -> Color {
        if colorScheme == .dark {
            return palette.foreground.opacity(isTopRank ? 0.54 : 0.32)
        }
        return isTopRank ? palette.border.opacity(0.88) : palette.border.opacity(0.72)
    }

    private func medalPalette(for rank: Int) -> TodayIncomeRankMedalPalette {
        switch rank {
        case 1:
            return TodayIncomeRankMedalPalette(
                foreground: Color(red: 228 / 255, green: 163 / 255, blue: 45 / 255),
                deep: Color(red: 169 / 255, green: 101 / 255, blue: 20 / 255),
                light: Color(red: 255 / 255, green: 223 / 255, blue: 112 / 255),
                border: Color(red: 217 / 255, green: 157 / 255, blue: 45 / 255)
            )
        case 2:
            return TodayIncomeRankMedalPalette(
                foreground: Color(red: 147 / 255, green: 158 / 255, blue: 171 / 255),
                deep: Color(red: 96 / 255, green: 110 / 255, blue: 128 / 255),
                light: Color(red: 234 / 255, green: 238 / 255, blue: 243 / 255),
                border: Color(red: 157 / 255, green: 168 / 255, blue: 183 / 255)
            )
        case 3:
            return TodayIncomeRankMedalPalette(
                foreground: Color(red: 190 / 255, green: 111 / 255, blue: 52 / 255),
                deep: Color(red: 139 / 255, green: 73 / 255, blue: 36 / 255),
                light: Color(red: 242 / 255, green: 181 / 255, blue: 118 / 255),
                border: Color(red: 192 / 255, green: 112 / 255, blue: 56 / 255)
            )
        default:
            return TodayIncomeRankMedalPalette(
                foreground: .secondary,
                deep: .secondary,
                light: .secondary,
                border: .secondary
            )
        }
    }
}

private struct PendingActivityNotice: View {
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(PendingActivityPresentation.noticeText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("关闭提示，出现新的待确认交易时重新显示")
            .offset(y: -3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.055))
    }
}

private struct PendingTradeActivityRow: View {
    let activity: PendingTradeActivity
    let isSelected: Bool
    let onDelete: (() -> Void)?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)
            .focusable(false)

            if let onDelete {
                deleteButton(action: onDelete)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: rowMinHeight)
        .background(selectionBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentColor)
                .frame(width: 3, height: selectionBarHeight)
                .opacity(isSelected ? 1 : 0)
                .padding(.leading, 4)
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            leftColumn
            Spacer(minLength: 6)
            amountColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            tagRow
            titleBlock
            metaContent
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            tag(kindTagTitle, color: kindTagColor)
            tag("待确认", color: .orange)
        }
    }

    private var amountColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(primaryValueText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
            Text(valueCaption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 98, alignment: .trailing)
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 24, height: 24)
                .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(activity.isConversion ? "删除这笔转换待确认记录" : "删除这笔待确认记录")
    }

    private var rowMinHeight: CGFloat {
        activity.isConversion ? 116 : 88
    }

    private var verticalPadding: CGFloat {
        6
    }

    private var selectionBarHeight: CGFloat {
        activity.isConversion ? 82 : 60
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let route = conversionRoute {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.sourceName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(kindTagColor)
                    .frame(height: 10)
                    .accessibilityHidden(true)
                Text(route.targetName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 14, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(titleText)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var metaContent: some View {
        if let route = conversionRoute {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversionMetaText(route))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                waitingStatusText
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.orderText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                waitingStatusText
            }
        }
    }

    private var waitingStatusText: some View {
        Text(presentation.waitingText)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .allowsTightening(true)
    }

    private var accentColor: Color {
        switch activity.kind {
        case .sell, .conversionOut:
            .redFundGreen
        case .newFund, .buy, .conversionIn:
            .red
        }
    }

    private var kindTagColor: Color {
        if activity.isConversion {
            return Color.orange
        }
        if activity.kind == .newFund {
            return .blue
        }
        return accentColor
    }

    private var kindTagTitle: String {
        if activity.isConversion {
            return "转换"
        }
        if activity.kind == .newFund {
            return "新增"
        }
        return activity.kind.title
    }

    private var titleText: String {
        guard let route = conversionRoute else {
            return activity.name
        }
        return "\(route.sourceName)\n→ \(route.targetName)"
    }

    private var valueCaption: String {
        guard activity.isConversion else {
            return activity.mode.title
        }
        switch activity.displayAmount?.source {
        case .estimatedNetValue, .latestNetValue:
            return "估算金额"
        case .confirmedNetValue:
            return "确认金额"
        case .enteredAmount, nil:
            return "金额"
        }
    }

    private var conversionSharesText: String? {
        let shares = activity.shares ?? activity.displayAmount?.shares
        guard let shares, shares > 0 else { return nil }
        return "\(numberText(shares, places: 2))份"
    }

    private var presentation: PendingActivityPresentation {
        PendingActivityPresentation(activity: activity)
    }

    private func conversionMetaText(_ route: (sourceName: String, sourceCode: String, targetName: String, targetCode: String)) -> String {
        let routeText = "\(FundCodeFormatter.display(route.sourceCode)) → \(FundCodeFormatter.display(route.targetCode))"
        guard let conversionSharesText else {
            return routeText
        }
        return "\(routeText) · \(conversionSharesText)"
    }

    private var conversionRoute: (sourceName: String, sourceCode: String, targetName: String, targetCode: String)? {
        guard activity.isConversion else { return nil }
        let currentName = clean(activity.name) ?? FundCodeFormatter.display(activity.code)
        let currentCode = clean(activity.code) ?? activity.code
        let linkedCode = clean(activity.linkedCode) ?? "--"
        let linkedName = clean(activity.linkedName) ?? FundCodeFormatter.display(linkedCode)

        if activity.kind == .conversionIn {
            return (
                sourceName: linkedName,
                sourceCode: linkedCode,
                targetName: currentName,
                targetCode: currentCode
            )
        }
        return (
            sourceName: currentName,
            sourceCode: currentCode,
            targetName: linkedName,
            targetCode: linkedCode
        )
    }

    private var selectionBackground: some View {
        Rectangle()
            .fill(
                isSelected
                    ? accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : Color.clear
            )
    }

    private var primaryValueText: String {
        guard let displayAmount = activity.displayAmount else {
            return "--"
        }
        return MoneyFormatter.plainMoney(displayAmount.value)
    }

    private func tag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .fixedSize()
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)))
    }
}

struct FundRowView: View {
    let fund: FundPosition
    let sortMode: FundSortMode
    let isSelected: Bool
    let isClosedZeroPosition: Bool
    let masksAmounts: Bool
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onOpen) {
            summaryRow
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(fund.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    tag(statusTagTitle, color: statusTagColor)
                    if !isClosedZeroPosition && fund.status == .holding {
                        tag(rowHoldingRateText, color: toneColor(for: rowHoldingRate ?? rowConfirmedHoldingIncome))
                    }
                }

                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        if showsUpdateStar {
                            updatedInlineTag
                        }
                        Text(FundCodeFormatter.display(fund.code))
                            .fontWeight(.semibold)
                            .foregroundStyle(codeTextColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if showsUpdateStar {
                            updateStar
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    Text(rowHoldingAmountText)
                        .foregroundStyle(amountTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.leading, showsUpdateStar ? 5 : 2)
                    Text(rowConfirmedHoldingIncomeText)
                        .foregroundStyle(toneColor(for: rowConfirmedHoldingIncome))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(primaryMetricText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(minWidth: primaryMetricMinimumWidth, maxWidth: 86, minHeight: 24)
                .background(rateBadgeBackground(primaryMetricTone), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(rateBadgeBorderColor(primaryMetricTone), lineWidth: 1.1)
                )
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28), lineWidth: 0.8)
                        .blendMode(.plusLighter)
                }
                .shadow(color: toneColor(for: primaryMetricTone).opacity(primaryMetricTone == 0 ? 0 : 0.24), radius: 7, x: 0, y: 3)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(selectionBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(selectionAccent)
                .frame(width: 3, height: 34)
                .opacity(isSelected ? 1 : 0)
                .padding(.leading, 4)
        }
        .contentShape(Rectangle())
    }

    private var selectionAccent: Color {
        toneColor(for: primaryMetricTone)
    }

    private var selectionBackground: some View {
        Rectangle()
            .fill(
                isSelected
                    ? selectionAccent.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : Color.clear
            )
    }

    private var updateStarColor: Color {
        Color(nsColor: StatusBarTone.menuBarColor(forRate: fund.todayRate))
    }

    private var updatedTagColor: Color {
        Color(red: 239 / 255, green: 168 / 255, blue: 36 / 255)
    }

    private var codeTextColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.72 : 0.58)
    }

    private var amountTextColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.92 : 0.78)
    }

    private var updateStar: some View {
        UpdatedFundStarShape()
            .fill(updateStarColor)
            .frame(width: 10.4, height: 10.4)
            .frame(width: 11, height: 14, alignment: .center)
            .shadow(color: updateStarColor.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 2, x: 0, y: 1)
            .accessibilityLabel("净值已更新")
    }

    private var updatedInlineTag: some View {
        Text("已更新")
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(updatedTagColor)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(updatedTagColor.opacity(colorScheme == .dark ? 0.20 : 0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(updatedTagColor.opacity(colorScheme == .dark ? 0.38 : 0.26), lineWidth: 0.6)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("已更新")
    }

    private var showsUpdateStar: Bool {
        fund.isUpdated
    }

    private var statusTagTitle: String {
        isClosedZeroPosition ? "已清仓" : fund.status.title
    }

    private var statusTagColor: Color {
        if isClosedZeroPosition {
            return .secondary
        }
        return fund.status.isPendingDisplay ? .orange : .blue
    }

    private var rowHoldingIncome: Double {
        if let holdingIncome = fund.holdingIncome {
            return holdingIncome
        }
        guard let holdingRate = fund.holdingRate else {
            return 0
        }
        return principal * holdingRate / 100
    }

    private var rowConfirmedHoldingIncome: Double {
        if let confirmedHoldingIncome = fund.confirmedHoldingIncome {
            return confirmedHoldingIncome
        }
        guard let confirmedHoldingRate = fund.confirmedHoldingRate else {
            return rowHoldingIncome
        }
        return principal * confirmedHoldingRate / 100
    }

    private var rowHoldingRate: Double? {
        fund.confirmedHoldingRate ?? fund.holdingRate
    }

    private var rowHoldingRateText: String {
        rowHoldingRate.map { MoneyFormatter.percent($0, signed: true) } ?? "0.00%"
    }

    private var primaryMetricText: String {
        switch sortMode {
        case .todayIncome:
            return FundRowAmountPrivacyFormatter.signedCompactMoney(fund.todayIncome, isMasked: masksAmounts)
        case .holdingIncome:
            return FundRowAmountPrivacyFormatter.signedCompactMoney(rowHoldingIncome, isMasked: masksAmounts)
        case .holdingRate:
            return MoneyFormatter.percent(rowHoldingRate ?? 0, signed: true)
        case .costAmount:
            return compactUnsignedMoney(principal)
        case .todayTotal:
            return compactUnsignedMoney(rowHoldingAmount)
        case .todayRate, .name:
            return MoneyFormatter.percent(fund.todayRate, signed: true)
        }
    }

    private var primaryMetricTone: Double {
        switch sortMode {
        case .todayIncome:
            return fund.todayIncome
        case .holdingIncome:
            return rowHoldingIncome
        case .holdingRate:
            return rowHoldingRate ?? 0
        case .costAmount, .todayTotal:
            return 0
        case .todayRate, .name:
            return fund.todayRate
        }
    }

    private var primaryMetricMinimumWidth: CGFloat {
        switch sortMode {
        case .todayIncome, .holdingIncome, .costAmount, .todayTotal:
            return 70
        case .todayRate, .holdingRate, .name:
            return 60
        }
    }

    private func compactUnsignedMoney(_ value: Double) -> String {
        FundRowAmountPrivacyFormatter.plainMoney(value, isMasked: masksAmounts)
            .replacingOccurrences(of: "¥ ", with: "")
    }

    private var rowHoldingAmountText: String {
        FundRowAmountPrivacyFormatter.plainMoney(rowHoldingAmount, isMasked: masksAmounts)
    }

    private var rowConfirmedHoldingIncomeText: String {
        FundRowAmountPrivacyFormatter.signedCompactMoney(rowConfirmedHoldingIncome, isMasked: masksAmounts)
    }

    private var rowHoldingAmount: Double {
        if let currentAmount = fund.currentAmount {
            return currentAmount
        }
        return principal + rowHoldingIncome
    }

    private var principal: Double {
        if let migratedPrincipal = fund.migratedPrincipal {
            return migratedPrincipal
        }
        guard let shares = fund.migratedShares,
              let cost = fund.migratedCost
        else {
            return 0
        }
        return shares * cost
    }

    private func tag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.42), lineWidth: 0.6)
            )
    }

    private func rateBadgeBackground(_ value: Double) -> AnyShapeStyle {
        if value == 0 {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.secondary.opacity(colorScheme == .dark ? 0.48 : 0.54),
                        Color.secondary.opacity(colorScheme == .dark ? 0.34 : 0.40)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        let color = toneColor(for: value)
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    color.opacity(colorScheme == .dark ? 0.98 : 0.93),
                    color.opacity(colorScheme == .dark ? 0.76 : 0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func rateBadgeBorderColor(_ value: Double) -> Color {
        if value == 0 {
            return Color.primary.opacity(colorScheme == .dark ? 0.30 : 0.22)
        }

        return toneColor(for: value).opacity(colorScheme == .dark ? 0.76 : 0.60)
    }
}

private struct UpdatedFundStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.56
        let points = (0..<10).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
        var path = Path()

        for index in points.indices {
            let current = points[index]
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            let cornerLength = index.isMultiple(of: 2) ? outerRadius * 0.18 : outerRadius * 0.12
            let start = point(from: current, toward: previous, distance: cornerLength)
            let end = point(from: current, toward: next, distance: cornerLength)

            if index == 0 {
                path.move(to: start)
            } else {
                path.addLine(to: start)
            }
            path.addQuadCurve(to: end, control: current)
        }

        path.closeSubpath()
        return path
    }

    private func point(from start: CGPoint, toward end: CGPoint, distance: CGFloat) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let scale = min(distance / length, 0.45)
        return CGPoint(x: start.x + dx * scale, y: start.y + dy * scale)
    }
}

private enum FundDetailTrendTab: String, CaseIterable, Identifiable {
    case intraday
    case netValue
    case band

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intraday:
            "盘中预估实时涨跌"
        case .netValue:
            "净值业绩走势"
        case .band:
            "波段信号"
        }
    }
}

private enum FundNetValueTrendRange: String, CaseIterable, Identifiable {
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case threeYears

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMonth:
            "近1月"
        case .threeMonths:
            "近3月"
        case .sixMonths:
            "近6月"
        case .oneYear:
            "近1年"
        case .threeYears:
            "近3年"
        }
    }

    var months: Int {
        switch self {
        case .oneMonth:
            1
        case .threeMonths:
            3
        case .sixMonths:
            6
        case .oneYear:
            12
        case .threeYears:
            36
        }
    }
}

private struct FundDailyIncomeDisplayRow: Identifiable {
    let id: String
    let dateText: String
    let amount: Double
}

private func unavailableRoutedFund(code: String) -> FundPosition {
    FundPosition(
        code: code,
        name: "",
        dateText: "--",
        todayIncome: 0,
        todayRate: 0,
        holdingRate: nil,
        status: .watch,
        isUpdated: false
    )
}

struct FundDailyIncomePanelView: View {
    let store: PortfolioStore
    private let fundCode: String
    let onClose: () -> Void

    @State private var netValueHistory: [FundNetValuePoint] = []
    @State private var isSupplementLoading = false
    @State private var didLoadSupplement = false
    @Environment(\.colorScheme) private var colorScheme

    private let supplementService = FundQuoteService()

    init(
        store: PortfolioStore,
        fundCode: String,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.fundCode = fundCode
        self.onClose = onClose
    }

    private var fund: FundPosition {
        store.snapshot.funds.first { $0.code == fundCode } ?? unavailableRoutedFund(code: fundCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "calendar.badge.clock",
                title: "每日收益",
                subtitle: FundCodeFormatter.display(fund.code),
                subtitleWeight: .semibold,
                tint: toneColor(for: latestDailyIncome),
                accessoryText: rowsAccessoryText,
                accessoryColor: .orange,
                onClose: onClose
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isSupplementLoading && !didLoadSupplement {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 360)
                    } else if dailyIncomeRows.isEmpty {
                        ContentUnavailableView("暂无每日收益", systemImage: "chart.bar.doc.horizontal")
                            .frame(height: 360)
                    } else {
                        dailyIncomeTable
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .background(PanelDesign.panelBackground)
        .task(id: fund.code) {
            await loadHistory()
        }
    }

    private var dailyIncomeTable: some View {
        VStack(spacing: 0) {
            dailyIncomeTableHeader
            ForEach(dailyIncomeDisplayRows) { row in
                Divider()
                    .opacity(0.45)
                dailyIncomeRow(row)
            }
        }
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private var dailyIncomeTableHeader: some View {
        HStack(spacing: 12) {
            tableHeaderText("日期", alignment: .leading)
            tableHeaderText("日收益", alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func dailyIncomeRow(_ row: FundDailyIncomeDisplayRow) -> some View {
        HStack(spacing: 12) {
            tableValueText(row.dateText, alignment: .leading)
            tableValueText(MoneyFormatter.money(row.amount, signed: true), alignment: .trailing, tone: row.amount)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func tableHeaderText(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func tableValueText(
        _ text: String,
        alignment: Alignment,
        tone: Double? = nil
    ) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.64)
            .foregroundStyle(tone.map(toneColor(for:)) ?? Color.primary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var rowsAccessoryText: String? {
        dailyIncomeRows.isEmpty ? nil : "\(dailyIncomeRows.count)天"
    }

    private var latestDailyIncome: Double {
        dailyIncomeRows.first?.dailyIncome ?? 0
    }

    private var dailyIncomeDisplayRows: [FundDailyIncomeDisplayRow] {
        dailyIncomeRows.flatMap { row -> [FundDailyIncomeDisplayRow] in
            guard isMeaningfulAmount(row.entryIncome) else {
                return [
                    FundDailyIncomeDisplayRow(
                        id: row.id,
                        dateText: row.dateText,
                        amount: row.dailyIncome
                    )
                ]
            }

            let entryRow = FundDailyIncomeDisplayRow(
                id: "\(row.id)-entry",
                dateText: "\(row.dateText) 录入",
                amount: row.entryIncome
            )
            guard isMeaningfulAmount(row.dailyIncome) else {
                return [entryRow]
            }

            return [
                FundDailyIncomeDisplayRow(
                    id: row.id,
                    dateText: row.dateText,
                    amount: row.dailyIncome
                ),
                entryRow
            ]
        }
    }

    private func isMeaningfulAmount(_ value: Double) -> Bool {
        abs(value) >= 0.005
    }

    private var dailyIncomeRows: [FundDailyIncomeRow] {
        FundDailyIncomeCalculator.rows(lots: effectiveLots, points: sourceNetValuePoints)
    }

    private var sourceNetValuePoints: [FundNetValuePoint] {
        netValueHistory
    }

    private var effectiveLots: [FundPositionLot] {
        if let lots = fund.lots, !lots.isEmpty {
            return lots
        }
        guard let shares = fund.migratedShares,
              shares > 0
        else {
            return []
        }
        return [
            FundPositionLot(
                id: "\(fund.code)-daily-income",
                shares: shares,
                cost: fund.migratedCost ?? 0,
                incomeStartDate: fund.incomeStartDate ?? fund.positionDate ?? "",
                positionDate: fund.positionDate ?? "",
                positionTimeType: fund.positionTimeType ?? .before15
            )
        ]
    }

    @MainActor
    private func loadHistory() async {
        guard !isSupplementLoading else { return }
        isSupplementLoading = true
        netValueHistory = await supplementService.fetchNetValueHistorySafely(code: fund.code)
        didLoadSupplement = true
        isSupplementLoading = false
    }
}

enum FundRowAmountPrivacyFormatter {
    static let maskedText = "***"

    static func plainMoney(_ value: Double, isMasked: Bool) -> String {
        isMasked ? maskedText : MoneyFormatter.plainMoney(value)
    }

    static func signedCompactMoney(_ value: Double, isMasked: Bool) -> String {
        guard !isMasked else { return maskedText }
        return MoneyFormatter.money(value, signed: true)
            .replacingOccurrences(of: "¥ ", with: "")
            .replacingOccurrences(of: "+¥", with: "+")
            .replacingOccurrences(of: "-¥", with: "-")
    }
}

/// 估值准确率分布的一个分桶（用于详情页直方图展示）。
private struct EstimationBucket: Identifiable {
    var id: String { label }
    let label: String
    let count: Int
    let color: Color
}

struct FundDetailView: View {
    let store: PortfolioStore
    /// 设置仓库：仅用于读取「盘中走势数据源」的全局默认值。
    let settingsStore: AppSettingsStore
    private let fundCode: String
    let onBuy: (FundPosition) -> Void
    let onSell: (FundPosition) -> Void
    let onConvert: (FundPosition) -> Void
    let onEdit: (FundPosition) -> Void
    let onOpenTradeRecords: (FundPosition) -> Void
    let onOpenDailyIncome: (FundPosition) -> Void
    let onDelete: (FundPosition) async -> Void
    let onClose: () -> Void

    @State private var isDeleteConfirmationPresented = false
    @State private var supplement: FundDetailSupplement = .empty
    @State private var isSupplementLoading = false
    @State private var didLoadSupplement = false
    /// 本只基金的实时数据本地镜像。详情页 body 只订阅这个 @State，而非整个
    /// store.snapshot.funds——其他基金刷新不会带动本详情页 body 重算，行情刷新
    /// 也只在「这一只」字段变化时才重算（落实「只订阅这一只基金需要的字段」）。
    @State private var liveFund: FundPosition?
    /// 已为「动态部分」重仓补充数据拉取过的「时点槽」，避免同一时点（如当日 15:00 后补充）
    /// 在详情长开期间重复请求。静态部分（重仓名单/行业）由 store.staticHoldingsStillValid
    /// 在季度窗口内控制，不在此去重。
    @State private var fetchedSupplementSlots: Set<String> = []
    @State private var trendTab: FundDetailTrendTab = .intraday
    @State private var netValueTrendRange: FundNetValueTrendRange = .threeMonths
    /// 数据源 2（新浪）的当日分时曲线。
    ///
    /// 新浪接口**不支持批量**（多代码返回空），只能逐只请求，因此绝不能进入
    /// 持仓批量刷新路径——只在用户把本页数据源切到「数据源2（新浪）」时才拉取，
    /// 由 `SinaQuoteService` 内部的进程缓存 + 落盘 + 第二个交易日清除兜底重复开关的场景。
    @State private var sinaIntradayPoints: [FundIntradayRatePoint] = []
    /// 本页当前展示的盘中数据源；进入详情页时取全局设置作为初始值。
    /// 走势图同一时刻只展示一个数据源，单只基金的切换不写回全局设置。
    @State private var intradayDataSource: IntradayDataSource = .eastmoney
    /// 新浪请求进行中（用于区分「加载中」与「该基金确无数据源2」）。
    @State private var isLoadingSinaPoints = false
    @Environment(\.colorScheme) private var colorScheme

    private let supplementService = FundQuoteService()

    init(
        store: PortfolioStore,
        settingsStore: AppSettingsStore,
        fundCode: String,
        onBuy: @escaping (FundPosition) -> Void,
        onSell: @escaping (FundPosition) -> Void,
        onConvert: @escaping (FundPosition) -> Void,
        onEdit: @escaping (FundPosition) -> Void,
        onOpenTradeRecords: @escaping (FundPosition) -> Void,
        onOpenDailyIncome: @escaping (FundPosition) -> Void,
        onDelete: @escaping (FundPosition) async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.fundCode = fundCode
        self.onBuy = onBuy
        self.onSell = onSell
        self.onConvert = onConvert
        self.onEdit = onEdit
        self.onOpenTradeRecords = onOpenTradeRecords
        self.onOpenDailyIncome = onOpenDailyIncome
        self.onDelete = onDelete
        self.onClose = onClose
    }

    private var fund: FundPosition {
        // 优先读本地镜像（body 因此只订阅 liveFund 这个 @State），避免直接订阅整个 snapshot。
        liveFund ?? store.fund(code: fundCode) ?? unavailableRoutedFund(code: fundCode)
    }

    private var tradeRecords: [FundTradeRecord] {
        store.snapshot.tradeRecords ?? []
    }

    private var detailUpdateStarColor: Color {
        Color(nsColor: StatusBarTone.menuBarColor(forRate: fund.todayRate))
    }

    private var detailUpdateStar: some View {
        UpdatedFundStarShape()
            .fill(detailUpdateStarColor)
            .frame(width: 14.5, height: 14.5)
            .frame(width: 17, height: 18, alignment: .center)
            .shadow(color: detailUpdateStarColor.opacity(colorScheme == .dark ? 0.30 : 0.20), radius: 2.5, x: 0, y: 1)
            .accessibilityLabel("净值已更新")
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "chart.line.uptrend.xyaxis",
                title: "基金详情",
                subtitle: FundCodeFormatter.display(fund.code),
                subtitleWeight: .semibold,
                tint: toneColor(for: fund.todayRate),
                actionSystemImage: "list.bullet.rectangle",
                actionTitle: "交易记录",
                actionBadgeText: tradeRecordsBadgeText,
                actionTint: Color(nsColor: .systemGray),
                actionHelp: tradeRecordsEntrySubtitle,
                onAction: {
                    onOpenTradeRecords(fund)
                },
                onClose: onClose
            )

            ScrollView {
                // 用 LazyVStack 替代 VStack：行情刷新导致整页 body 重算时，SwiftUI 只
                // 构建/布局当前可视区的卡片，滑到重仓（或任何尾部区块）时，已滚出屏的
                // 半透明大卡（盘中曲线）不再参与 layout 与合成，消除「滑到那段合成压力
                // 突然上去」的顿挫。重仓/估值区块本身已加 .equatable() 隔离重建。
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 系统“始终显示滚动条”时仅靠 .scrollIndicators(.hidden) 可能压不住，
                    // 借原生配置强制 overlay + autohide，滚动条不再常驻
                    MainPopoverNativeScrollConfiguration()
                        .frame(height: 0)
                    fundTitle
                    todayRateHero
                    pendingTradeSummary
                    metricsGrid
                    trendSection
                    if trendTab == .intraday {
                        FundDetailIntradayTail(
                            estimationDevs: fund.estimationDeviationHistory ?? [],
                            topHoldings: supplement.topHoldings,
                            disclosureDate: supplement.holdingDisclosureDate,
                            trackingIndexName: supplement.indexName,
                            trackingIndexChangeRate: supplement.indexChangeRate,
                            relatedKind: supplement.relatedKind,
                            isHoldingsLoading: isSupplementLoading
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            actionBar
        }
        .background(PanelDesign.panelBackground)
        .onChange(of: store.snapshot.funds) { _, _ in
            // 行情刷新时只同步「这一只」基金到本地镜像，不直接订阅整个 snapshot；
            // 只有本只字段变化才会触发 body 重算，其他基金刷新不带动本详情页。
            liveFund = store.fund(code: fundCode)
        }
        .task(id: fund.code) {
            // 进入详情先同步一次本只基金镜像，后续行情刷新由 onChange 增量更新。
            liveFund = store.fund(code: fundCode)
            // 先恢复已缓存的重仓数据，避免重开/切换基金时闪「暂无重仓数据」。
            if let cached = store.cachedSupplement(for: fund.code) {
                supplement = cached
                didLoadSupplement = true
            }
            // 换基金时清空数据源 2，避免沿用上一只基金的曲线。
            sinaIntradayPoints = []
            // 以全局设置为本页数据源的初始值；之后在本页切换只影响本页。
            // 兜底：即使设置里残留不可用的数据源（如已关闭的新浪），也回落到东财，
            // 避免 UI 已隐藏却仍在请求该数据源。
            intradayDataSource = FeatureAvailability.resolvedIntradayDataSource(
                settingsStore.settings.intradayDataSource
            )
            // 新浪仅在本页数据源切到「数据源2」时才请求，放在重仓请求之前以优先呈现走势图。
            await loadSinaIntradayPointsIfNeeded()
            await loadSupplement()
            // 跨过目标时点（普通基金 15:00 / QDII 08:00）时自动补充一次重仓涨跌幅。
            // 详情页关闭后 .task 自动取消，sleep 到点后不会执行，无需手动停止。
            while !Task.isCancelled {
                guard let target = Self.nextSupplementTargetTime(for: fund, now: .now) else { break }
                let delay = target.timeIntervalSinceNow
                guard delay > 0 else { break }
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                } catch {
                    break
                }
                await loadSupplement()
            }
        }
        // 本页切换数据源时：切到数据源 2（新浪）才按需拉取，切回数据源 1 不产生任何请求。
        .onChange(of: intradayDataSource) { _, _ in
            Task {
                await loadSinaIntradayPointsIfNeeded()
            }
        }
        // 用户主动点击刷新（主面板手动刷新完成）时，无论当前是否交易时段，都强制补充拉取十大重仓涨跌幅。
        .onChange(of: store.manualRefreshToken) { _, _ in
            Task {
                await loadSupplement(force: true)
            }
        }
        .alert("删除基金", isPresented: $isDeleteConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("删除基金", role: .destructive) {
                Task {
                    await onDelete(fund)
                    onClose()
                }
            }
        } message: {
            Text(deleteFundConfirmationMessage)
        }
    }

    private var deleteFundConfirmationMessage: String {
        "确定删除“\(fund.name)”吗？这会同时删除该基金的持仓、待确认交易和全部交易记录，删除后无法撤销。"
    }

    private var fundTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(fund.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if fund.isUpdated {
                    detailUpdateStar
                        .fixedSize()
                }
            }
            HStack(spacing: 7) {
                Text(FundCodeFormatter.display(fund.code))
                    .fontWeight(.semibold)
                Text(fund.dateText)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private var todayRateHero: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("当日涨幅")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if fund.isUpdated {
                        detailTag("已更新", color: updatedDetailTagColor)
                    }
                }

                Text(MoneyFormatter.percent(fund.todayRate, signed: true))
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(toneColor(for: fund.todayRate))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                Text("当日收益")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(signedNumberText(fund.todayIncome))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(toneColor(for: fund.todayIncome))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(todayRateHeroBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(toneColor(for: fund.todayRate).opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var pendingTradeSummary: some View {
        if let title = pendingTradeSummaryTitle,
           let detail = pendingTradeSummaryDetail {
            Button {
                onOpenTradeRecords(fund)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("待确认交易")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(pendingTradeSummaryTone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(pendingTradeSummaryBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.orange.opacity(0.20), lineWidth: 0.7)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            alignment: .leading,
            spacing: 14
        ) {
            metric("持仓金额", numberText(currentTotal, places: 2))
            metric("持仓份额", totalShares > 0 ? numberText(totalShares, places: 2) : "--")
            metric("持仓成本", fund.migratedCost.map { numberText($0, places: 4) } ?? "--")
            dailyIncomeMetricButton("持仓收益", signedNumberText(holdingIncome), tone: holdingIncome)
            metric("持仓收益率", fund.holdingRate.map { MoneyFormatter.percent($0, signed: true) } ?? "0.00%", tone: fund.holdingRate)
            metric("持仓天数", holdingDaysText)
        }
        .padding(12)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSegmentedPicker(
                values: FundDetailTrendTab.allCases,
                selection: $trendTab,
                title: \.title,
                tint: toneColor(for: fund.todayRate),
                widthMode: .content
            )

            switch trendTab {
            case .intraday:
                intradayTrendContent
            case .netValue:
                netValueTrendContent
            case .band:
                bandSignalContent
            }
        }
        .padding(12)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 估值准确率区块：抽成独立子 View 并遵循 Equatable，仅依赖 devs（历史估值偏差，与实时行情无关）。
    /// 行情刷新导致外层 body 重算时输入未变即真正跳过 body，
    /// 避免每次都重算 buckets（4 次 filter）与 4 个 GeometryReader 行，减轻滚动抽帧。
    private struct EstimationAccuracySection: View, Equatable {
        let devs: [EstimationDeviation]

        /// 把最近 30 次估值记录按「与官方净值的绝对偏差」分为四个等级：
        ///   ≤0.3% -> 准确   0.3~0.5% -> 轻微   0.5~1% -> 较大   >1% -> 严重。
        private static func buckets(from devs: [EstimationDeviation]) -> [EstimationBucket] {
            let low = devs.filter { $0.absoluteDeviation <= 0.3 }.count
            let midLow = devs.filter { $0.absoluteDeviation > 0.3 && $0.absoluteDeviation <= 0.5 }.count
            let midHigh = devs.filter { $0.absoluteDeviation > 0.5 && $0.absoluteDeviation <= 1 }.count
            let high = devs.filter { $0.absoluteDeviation > 1 }.count
            let accurate = Color(nsColor: StatusBarTone.menuBarColor(forRate: 1))
            return [
                EstimationBucket(label: "≤0.3%", count: low, color: accurate),
                EstimationBucket(label: "0.3~0.5%", count: midLow, color: Color.yellow),
                EstimationBucket(label: "0.5~1%", count: midHigh, color: Color.orange),
                EstimationBucket(label: ">1%", count: high, color: Color.red)
            ]
        }

        var body: some View {
            let buckets = Self.buckets(from: devs)
            return VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    "估值准确率",
                    trailing: "近 \(min(devs.count, 30)) 天 · \(devs.count) 个样本",
                    titleSupplement: averageDeviationText
                )

                if devs.isEmpty {
                    Text("暂无足够数据。当日净值更新后将自动统计当日估值与实际涨跌幅的偏差，晚间即可查看。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let maxCount = max(buckets.map(\.count).max() ?? 1, 1)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(buckets) { bucket in
                            estimationBucketRow(bucket, maxCount: maxCount)
                        }
                    }
                }
            }
            .padding(12)
            .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(PanelDesign.border(cornerRadius: 10))
        }

        private var averageDeviationText: String? {
            guard !devs.isEmpty else { return nil }
            let average = devs.map(\.absoluteDeviation).reduce(0, +) / Double(devs.count)
            return "平均偏差 ±\(average.formatted(.number.precision(.fractionLength(2))))%"
        }

        private func sectionHeader(
            _ title: String,
            trailing: String? = nil,
            showsLoading: Bool = false,
            titleSupplement: String? = nil
        ) -> some View {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let titleSupplement {
                    Text(titleSupplement)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if showsLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
        }

        private func estimationBucketRow(_ bucket: EstimationBucket, maxCount: Int) -> some View {
            let ratio = maxCount > 0 ? CGFloat(bucket.count) / CGFloat(maxCount) : 0
            return HStack(spacing: 8) {
                Text(bucket.label)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                // Canvas 单趟同步绘制，替代 GeometryReader 的两段式布局，
                // 滚动经过时不再触发额外的布局求解。
                Canvas { context, size in
                    let barWidth = min(
                        max(size.width * ratio, bucket.count > 0 ? 6 : 0),
                        size.width
                    )
                    let barRect = CGRect(
                        x: 0,
                        y: (size.height - 9) / 2,
                        width: barWidth,
                        height: 9
                    )
                    context.fill(
                        Path(roundedRect: barRect, cornerRadius: 4.5),
                        with: .color(bucket.color)
                    )
                }
                .frame(height: 9)

                Text("\(bucket.count)次")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(bucket.count > 0 ? Color.primary : Color.secondary)
            }
        }
    }

    private var estimationAccuracySection: some View {
        // `Equatable` conformance alone does not activate SwiftUI's equality
        // shortcut.  Apply it explicitly so quote updates while scrolling do
        // not re-layout this static section.
        EstimationAccuracySection(devs: fund.estimationDeviationHistory ?? [])
            .equatable()
    }

    private var intradayTrendContent: some View {
        let points = displayedIntradayPoints
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "盘中预估实时涨跌",
                trailing: intradayTrendTrailingText
            )

            // 只有一个可用数据源时无需展示切换下拉（新浪入口由 FeatureAvailability 关闭）。
            if FeatureAvailability.availableIntradayDataSources.count > 1 {
                intradayDataSourcePicker
            }

            if points.isEmpty {
                emptySupplementView(intradayTrendEmptyText)
                    .frame(height: 116)
            } else {
                FundIntradayRateChart(points: points, source: intradayDataSource)
                    .equatable()
                    // 切换数据源时重建图表：内部 @State 复位，从而重新播放从基准线展开的动画。
                    .id(intradayDataSource)
                    .frame(height: 138)
            }
        }
    }

    /// 走势图当前展示的点位：同一时刻**只展示一个数据源**，避免两条曲线互相干扰。
    private var displayedIntradayPoints: [FundIntradayRatePoint] {
        intradayDataSource == .sina ? sinaIntradayPoints : visibleIntradayRatePoints
    }

    /// 本页数据源切换（下拉）。只影响这只基金本次查看，不写回全局设置。
    private var intradayDataSourcePicker: some View {
        Picker("", selection: $intradayDataSource) {
            ForEach(FeatureAvailability.availableIntradayDataSources) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(.system(size: 11))
        .frame(width: 132)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var netValueTrendContent: some View {
        let trendPoints = netValueTrendPoints
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader(
                    "净值业绩走势",
                    trailing: latestNetValuePoint.map { "最新净值 \(numberText($0.value, places: 4))" },
                    showsLoading: isSupplementLoading
                )

                netValueRangeReturnView(for: trendPoints)
            }

            if trendPoints.count >= 2 {
                let holdingCost = fund.migratedCost
                let holdingCostPoint = (holdingCost ?? 0) > 0 ? latestNetValuePoint : nil
                FundTrendMiniChart(points: trendPoints, holdingCost: holdingCost, holdingCostPoint: holdingCostPoint)
                    .equatable()
                    .frame(height: 116)
            } else {
                emptySupplementView(isSupplementLoading ? "走势加载中..." : "暂无走势数据")
                    .frame(height: 86)
            }

            netValueTrendRangePicker

            Divider().opacity(0.45)
            // 历史净值独立成 View：展开状态与筛选结果都由它自己持有，
            // 展开/收起不会牵动本页 body 的走势图等重计算区块。
            FundHistoryNetValueList(points: supplement.history, isLoading: isSupplementLoading)
        }
    }

    private func netValueRangeReturnView(for points: [FundNetValuePoint]) -> some View {
        let returnText: String? = {
            guard points.count >= 2,
                  let first = points.first,
                  let last = points.last,
                  first.value > 0 else { return nil }
            let rate = (last.value - first.value) / first.value
            return MoneyFormatter.percent(rate * 100, signed: true)
        }()

        return Group {
            if let text = returnText {
                let rate = parseSignedPercent(text)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text("涨跌幅 ")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(toneColor(for: rate))
                }
            }
        }
    }

    private func parseSignedPercent(_ text: String) -> Double {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
        return Double(cleaned) ?? 0
    }

    /// 前10重仓股：抽成独立子 View 并遵循 Equatable，仅依赖 topHoldings 数组本身。
    /// 行情刷新导致外层 body 重算时输入未变即真正跳过重建
    /// （不遵循 Equatable 时 SwiftUI 仍会重跑 body），
    /// 避免打开/刷新瞬间滚动详情页时整列 10 行重仓股重建导致抽帧。
    /// 详情页尾部：估值准确率与前10重仓各自独立成卡，与盘中曲线的大卡分离。
    /// 滑到尾部时不再与曲线、半透明大底同屏叠加合成；整体遵循 Equatable，
    /// 且 isHoldingsLoading 有意不参与相等判断——净值历史等动态请求短暂置位
    /// 加载态时，未变化的重仓/估值区块不会整列重建（打开详情后下滑抽帧的主因）。
    private struct FundDetailIntradayTail: View, Equatable {
        let estimationDevs: [EstimationDeviation]
        let topHoldings: [FundStockHolding]
        let disclosureDate: String?
        let trackingIndexName: String?
        let trackingIndexChangeRate: Double?
        /// 关联标的种类："etf" / "index"（决定卡片前缀文案）。
        let relatedKind: String?
        let isHoldingsLoading: Bool

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.estimationDevs == rhs.estimationDevs
                && lhs.topHoldings == rhs.topHoldings
                && lhs.disclosureDate == rhs.disclosureDate
                && lhs.trackingIndexName == rhs.trackingIndexName
                && lhs.trackingIndexChangeRate == rhs.trackingIndexChangeRate
                && lhs.relatedKind == rhs.relatedKind
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                EstimationAccuracySection(devs: estimationDevs)

                if topHoldings.isEmpty {
                    if let trackingIndexName {
                        trackingIndexCard(name: trackingIndexName)
                    } else if isHoldingsLoading {
                        // 仍在拉取重仓/关联标的数据：保留加载占位，避免打开瞬间的空白跳动。
                        holdingsPlaceholderCard
                    }
                    // 加载完成且既无前十大重仓、也无关联场内ETF/跟踪指数（如 001235、
                    // 006331 这类纯主动品种）：整块不展示，避免无意义的占位卡片。
                } else {
                    TopHoldingsSection(
                        topHoldings: topHoldings,
                        disclosureDate: disclosureDate
                    )
                    .padding(12)
                    .background(
                        PanelDesign.cardBackground,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(PanelDesign.border(cornerRadius: 10))
                }
            }
        }

        /// 跟踪指数卡片：仅「无前十大重仓」的品种（场内 ETF、商品基金等）展示，
        /// 其当日涨跌与关联指数高度联动，单独成卡直观呈现实时涨跌。
        private func trackingIndexCard(name: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(relatedKind == "etf" ? "关联ETF · \(name)" : "跟踪指数 · \(name)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let changeRate = trackingIndexChangeRate {
                    Text(MoneyFormatter.percent(changeRate, signed: true))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(toneColor(for: changeRate))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(toneColor(for: changeRate).opacity(0.10), in: Capsule())
                }
            }
            .padding(12)
            .frame(minHeight: 44)
            .background(
                PanelDesign.cardBackground,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(PanelDesign.border(cornerRadius: 10))
        }

        /// 首次打开且尚无任何重仓/指数数据时的占位卡片。
        private var holdingsPlaceholderCard: some View {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .opacity(isHoldingsLoading ? 1 : 0)
                Text(isHoldingsLoading ? "重仓数据加载中…" : "暂无重仓数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .frame(minHeight: 56)
            .background(
                PanelDesign.cardBackground,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(PanelDesign.border(cornerRadius: 10))
        }
    }

    private struct TopHoldingsSection: View, Equatable {
        let topHoldings: [FundStockHolding]
        let disclosureDate: String?
        // 注意：不接收 isLoading——净值历史等动态请求会短暂置位加载态，
        // 若参与相等判断会让未变化的重仓整列重建（打开详情下滑抽帧的来源之一）；
        // 加载占位由 FundDetailIntradayTail 统一承担。
        // 跟踪指数同样不在此展示：仅「无重仓」的品种需要，由 Tail 独立成卡。

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                let trailing: String? = topHoldings.isEmpty ? nil : {
                    if let date = disclosureDate {
                        return "\(topHoldings.count)只 · \(date)"
                    }
                    return "\(topHoldings.count)只"
                }()
                sectionHeader("前10重仓股", trailing: trailing)

                VStack(spacing: 0) {
                    ForEach(Array(topHoldings.enumerated()), id: \.element.code) { index, holding in
                        stockHoldingRow(holding, rank: index + 1)
                        if index < topHoldings.count - 1 {
                            Divider()
                                .opacity(0.55)
                        }
                    }
                }
            }
        }

        private func sectionHeader(_ title: String, trailing: String?) -> some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }

        /// 单行重仓股：排名 + 名称（代码·行业）+ 实时涨跌胶囊 + 占比。

        private func stockHoldingRow(_ holding: FundStockHolding, rank: Int) -> some View {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.name.isEmpty ? holding.code : holding.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let detail = stockHoldingDetailText(holding) {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let changeRate = holding.changeRate {
                    Text(MoneyFormatter.percent(changeRate, signed: true))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(toneColor(for: changeRate))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(toneColor(for: changeRate).opacity(0.10), in: Capsule())
                }

                Text(holding.weight.isEmpty ? "--" : holding.weight)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(height: 38)
        }

        private func stockHoldingDetailText(_ holding: FundStockHolding) -> String? {
            var parts: [String] = []
            if !holding.code.isEmpty {
                parts.append(holding.code)
            }
            if let industryName = holding.industryName, !industryName.isEmpty {
                parts.append(industryName)
            }
            if parts.isEmpty { return nil }
            return parts.joined(separator: " · ")
        }

    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.45)

            HStack(spacing: 8) {
                Button {
                    onBuy(fund)
                } label: {
                    PanelButtonLabel(title: "加仓", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button {
                    onSell(fund)
                } label: {
                    PanelButtonLabel(title: "减仓", systemImage: "minus.circle")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled((fund.migratedShares ?? 0) <= 0)

                Button {
                    onConvert(fund)
                } label: {
                    PanelButtonLabel(title: "转换", systemImage: "arrow.left.arrow.right.circle")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled((fund.migratedShares ?? 0) <= 0)

                Button {
                    onEdit(fund)
                } label: {
                    PanelButtonLabel(title: "编辑", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    PanelButtonLabel(title: "删除", systemImage: "trash", style: .destructive)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(PanelDesign.panelBackground)
    }

    private func sectionHeader(
        _ title: String,
        trailing: String? = nil,
        showsLoading: Bool = false,
        titleSupplement: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if let titleSupplement {
                Text(titleSupplement)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if showsLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptySupplementView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelDesign.selectorBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var recentTradeRecords: [FundTradeRecord] {
        let actualRecords = tradeRecords.filter { $0.code == fund.code }
        let records = actualRecords.contains { $0.kind == .newFund }
            ? actualRecords
            : actualRecords + (inferredInitialTradeRecord(for: fund).map { [$0] } ?? [])
        return records.sorted(by: tradeRecordTimeDescending)
    }

    private var pendingTradeRecords: [FundTradeRecord] {
        recentTradeRecords.filter { $0.status == .pending }
    }

    private var netValueSourcePoints: [FundNetValuePoint] {
        let source = supplement.history.isEmpty ? supplement.trend : supplement.history
        return source.sorted { $0.timestamp < $1.timestamp }
    }

    private var latestNetValuePoint: FundNetValuePoint? {
        netValueSourcePoints.last
    }

    private var netValueTrendPoints: [FundNetValuePoint] {
        let source = netValueSourcePoints
        guard let latestTimestamp = source.last?.timestamp else { return [] }

        let calendar = Calendar.current
        let latestDate = Date(timeIntervalSince1970: TimeInterval(latestTimestamp) / 1000)
        let latestDay = calendar.startOfDay(for: latestDate)
        guard let cutoff = calendar.date(byAdding: .month, value: -netValueTrendRange.months, to: latestDay) else {
            return source
        }

        return source.filter { point in
            let pointDate = Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000)
            return calendar.startOfDay(for: pointDate) >= cutoff
        }
    }

    /// 波段信号·净值序列（含可能拼接的当日盘中估值）。
    ///
    /// 序列口径：**直接使用单位净值（单位净值）**，与 fund.cc.cd 权威实现一致——
    /// 其信号函数 `s(e)` 读取 `e.value`（原始净值），`netValueType:"adjusted"`
    /// 仅用于填充展示字段，不参与信号计算。
    ///
    /// 早前版本曾以最新单位净值为锚、用日增长率链式回推「等价复权净值」。该序列随
    /// 权益基金长期上行，最新点几乎恒处 252 日窗口高位 → 评分长期偏高 → 反复触发
    /// 卖出区（如 010011 全量历史约 79 次）。改为单位净值后，评分围绕中枢震荡，
    /// 与 fund.cc.cd 一致（010011 近一年约 13 次卖出信号）。
    ///
    /// 当日盘中估值：当 `fund.todayRate` 有限、今日日期晚于最新净值日、
    /// 与最近净值的偏差 < 15% 时，把 `lastNav × (1 + todayRate/100)` 拼为
    /// 序列最后一个点，让信号对当天涨跌敏感（与参考站行为一致）。
    private var bandSignalAdjustedSeries: [BandSeriesPoint] {
        let raw = netValueSourcePoints.filter { $0.value.isFinite && $0.value > 0 }
        guard !raw.isEmpty else { return [] }

        var result: [BandSeriesPoint] = []
        result.reserveCapacity(raw.count + 1)
        for point in raw {
            result.append(BandSeriesPoint(
                date: DateOnlyFormatter.string(
                    from: Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000)
                ),
                value: point.value
            ))
        }

        // 拼接当日盘中估值（单位净值口径）
        if let lastPoint = raw.last,
           fund.todayRate.isFinite,
           abs(fund.todayRate) < 15 {
            let lastDate = DateOnlyFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(lastPoint.timestamp) / 1000)
            )
            let todayDate = DateOnlyFormatter.string(from: Date())
            if todayDate > lastDate {
                let estimatedNav = lastPoint.value * (1 + fund.todayRate / 100)
                if estimatedNav.isFinite, estimatedNav > 0,
                   abs(estimatedNav / lastPoint.value - 1) < 0.15 {
                    result.append(BandSeriesPoint(date: todayDate, value: estimatedNav))
                }
            }
        }
        return result
    }

    /// 波段信号是否已拼接当日盘中估值（用于 Section 头部徽标）。
    private var bandSignalHasEstimate: Bool {
        let raw = netValueSourcePoints
        guard let lastPoint = raw.last else { return false }
        let lastDate = DateOnlyFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(lastPoint.timestamp) / 1000)
        )
        let todayDate = DateOnlyFormatter.string(from: Date())
        guard todayDate > lastDate,
              fund.todayRate.isFinite,
              abs(fund.todayRate) < 15
        else { return false }
        let estimatedNav = lastPoint.value * (1 + fund.todayRate / 100)
        return estimatedNav.isFinite
            && estimatedNav > 0
            && abs(estimatedNav / lastPoint.value - 1) < 0.15
    }

/// 波段信号·子栏目（决策板 + 评分走势 + 策略回测），作为趋势卡的第三个标签页内容。
/// 卡片外框由 `trendSection` 统一提供，这里只出内容。
private var bandSignalContent: some View {
    BandSignalSection(
        adjustedSeries: bandSignalAdjustedSeries,
        withEstimate: bandSignalHasEstimate,
        isHistoryLoading: isSupplementLoading
    )
    .equatable()
}

    private var netValueTrendRangePicker: some View {
        HStack(spacing: 4) {
            ForEach(FundNetValueTrendRange.allCases) { value in
                let isSelected = netValueTrendRange == value
                Button {
                    netValueTrendRange = value
                } label: {
                    Text(value.title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? netValueTrendRangeTint : Color.secondary.opacity(0.86))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? netValueTrendRangeTint.opacity(colorScheme == .dark ? 0.22 : 0.15) : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isSelected ? netValueTrendRangeTint.opacity(0.18) : Color.clear, lineWidth: 0.6)
                        }
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.top, 1)
    }

    private var netValueTrendRangeTint: Color {
        toneColor(for: fund.todayRate)
    }

    private var pendingTradeSummaryTitle: String? {
        let summary = pendingTradeSummaryValues
        var parts: [String] = []
        if summary.buyAmount > 0 {
            parts.append("+\(compactPendingMoney(summary.buyAmount))")
        }
        if summary.sellAmount > 0 {
            parts.append("-\(compactPendingMoney(summary.sellAmount))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }

    private var pendingTradeSummaryDetail: String? {
        guard !pendingTradeRecords.isEmpty else { return nil }
        var parts: [String] = []
        let buyCount = pendingTradeRecords.filter { $0.kind == .newFund || $0.kind == .buy }.count
        let sellCount = pendingTradeRecords.filter { $0.kind == .sell }.count
        let conversionCount = Set(pendingTradeRecords.filter { $0.kind == .conversionOut || $0.kind == .conversionIn }.compactMap(\.conversionID)).count
        if buyCount > 0 {
            parts.append("加仓 \(buyCount)笔")
        }
        if sellCount > 0 {
            parts.append("减仓 \(sellCount)笔")
        }
        if conversionCount > 0 {
            parts.append("转换 \(conversionCount)笔")
        }
        if let acceptedDate = pendingTradeRecords.map(\.acceptedDate).sorted().first {
            parts.append("确认 \(acceptedDate)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var pendingTradeSummaryTone: Color {
        pendingTradeSummaryValues.buyAmount > 0
            ? .red
            : .redFundGreen
    }

    private var pendingTradeSummaryBackground: Color {
        Color.orange.opacity(0.08)
    }

    private var pendingTradeSummaryValues: (buyAmount: Double, sellAmount: Double) {
        var buyAmount: Double = 0
        var sellAmount: Double = 0

        for record in pendingTradeRecords {
            switch record.kind {
            case .newFund, .buy:
                if let amount = record.amount, amount > 0 {
                    buyAmount += amount
                } else if let shares = record.confirmedShares ?? record.shares, shares > 0 {
                    buyAmount += pendingTradeSummaryAmount(shares: shares, acceptedDate: record.acceptedDate)
                }
            case .sell:
                if let amount = record.amount, amount > 0 {
                    sellAmount += amount
                } else if let shares = record.confirmedShares ?? record.shares, shares > 0 {
                    sellAmount += pendingTradeSummaryAmount(shares: shares, acceptedDate: record.acceptedDate)
                }
            case .conversionOut:
                if let shares = record.confirmedShares ?? record.shares, shares > 0 {
                    sellAmount += pendingTradeSummaryAmount(shares: shares, acceptedDate: record.acceptedDate)
                }
            case .conversionIn:
                if let amount = record.amount, amount > 0 {
                    buyAmount += amount
                }
            }
        }

        return (buyAmount, sellAmount)
    }

    private func pendingTradeSummaryAmount(shares: Double, acceptedDate: String) -> Double {
        guard let price = pendingTradeSummaryReferencePrice(acceptedDate: acceptedDate) else {
            return 0
        }
        return shares * price
    }

    private func pendingTradeSummaryReferencePrice(acceptedDate: String) -> Double? {
        let shares = fund.migratedShares ?? 0
        let currentAmount = PortfolioPanelDisplay.currentAmount(for: fund)
        let basePrice: Double
        if shares > 0, currentAmount > 0 {
            basePrice = currentAmount / shares
        } else if let migratedCost = fund.migratedCost, migratedCost > 0 {
            basePrice = migratedCost
        } else {
            return nil
        }

        let today = DateOnlyFormatter.string(from: .now)
        if acceptedDate == today, !fund.isUpdated, fund.todayRate != 0 {
            return basePrice * (1 + fund.todayRate / 100)
        }
        return basePrice
    }

    private var tradeRecordsEntrySubtitle: String {
        let pendingCount = recentTradeRecords.filter { $0.status == .pending }.count
        guard pendingCount > 0 else { return "查看新增、加仓、减仓、转换流水" }
        return "含待确认 \(pendingCount) 笔"
    }

    private var tradeRecordsBadgeText: String? {
        let count = recentTradeRecords.count
        return count > 0 ? "\(count)" : nil
    }

    private func stockHoldingRow(_ holding: FundStockHolding, rank: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(holding.name.isEmpty ? holding.code : holding.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let detail = stockHoldingDetailText(holding) {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let changeRate = holding.changeRate {
                Text(MoneyFormatter.percent(changeRate, signed: true))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(toneColor(for: changeRate))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(toneColor(for: changeRate).opacity(0.10), in: Capsule())
            }

            Text(holding.weight.isEmpty ? "--" : holding.weight)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .frame(height: 38)
    }

    private func stockHoldingDetailText(_ holding: FundStockHolding) -> String? {
        var parts: [String] = []
        if !holding.code.isEmpty {
            parts.append(holding.code)
        }
        if let industryName = holding.industryName, !industryName.isEmpty {
            parts.append(industryName)
        }
        if let positionChangeType = holding.positionChangeType, !positionChangeType.isEmpty {
            if let positionChangeRate = holding.positionChangeRate, positionChangeRate != 0 {
                parts.append("\(positionChangeType) \(MoneyFormatter.percent(positionChangeRate, signed: false))")
            } else {
                parts.append(positionChangeType)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: String, tone: Double? = nil, isInteractive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if isInteractive {
                    detailDisclosureIndicator
                }
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(tone.map(toneColor(for:)) ?? Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyIncomeMetricButton(_ title: String, _ value: String, tone: Double? = nil) -> some View {
        Button {
            onOpenDailyIncome(fund)
        } label: {
            metric(title, value, tone: tone, isInteractive: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(Rectangle())
        .help("查看每日收益")
    }

    private var detailDisclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func detailTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 0.6)
            )
    }

    private var updatedDetailTagColor: Color {
        Color(red: 254 / 255, green: 143 / 255, blue: 37 / 255)
    }

    private var todayRateHeroBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                toneColor(for: fund.todayRate).opacity(colorScheme == .dark ? 0.14 : 0.075),
                PanelDesign.cardBackground
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var currentTotal: Double {
        if let currentAmount = fund.currentAmount {
            return currentAmount
        }
        return principal + holdingIncome
    }

    private var principal: Double {
        if let migratedPrincipal = fund.migratedPrincipal {
            return migratedPrincipal
        }
        guard let shares = fund.migratedShares, let cost = fund.migratedCost else {
            return 0
        }
        return shares * cost
    }

    private var holdingIncome: Double {
        if let holdingIncome = fund.holdingIncome {
            return holdingIncome
        }
        guard let holdingRate = fund.holdingRate else {
            return 0
        }
        return principal * holdingRate / 100
    }

    private var totalShares: Double {
        if let shares = fund.migratedShares {
            return shares
        }
        return fund.lots?.reduce(0) { $0 + $1.shares } ?? 0
    }

    private var effectiveLots: [FundPositionLot] {
        if let lots = fund.lots, !lots.isEmpty {
            return lots
        }
        guard let shares = fund.migratedShares,
              shares > 0
        else {
            return []
        }
        return [
            FundPositionLot(
                id: "\(fund.code)-detail",
                shares: shares,
                cost: fund.migratedCost ?? 0,
                incomeStartDate: fund.incomeStartDate ?? fund.positionDate ?? "",
                positionDate: fund.positionDate ?? "",
                positionTimeType: fund.positionTimeType ?? .before15
            )
        ]
    }

    private var intradayRatePoints: [FundIntradayRatePoint] {
        FundIntradayRateHistoryRecorder.activePoints(for: fund)
    }

    private var visibleIntradayRatePoints: [FundIntradayRatePoint] {
        if !intradayRatePoints.isEmpty {
            return intradayRatePoints
        }

        switch TradingCalendar.marketSessionState() {
        case .open:
            return intradayCurrentValueFallbackPoints
        case .middayBreak, .closed:
            guard fund.intradayRateDate == FundIntradayRateHistoryRecorder.tradingDayString(from: .now) else {
                return intradayCurrentValueFallbackPoints
            }
            // 存储序列由 `FundIntradayRateHistoryRecorder.normalizedPoints` 保证按时间升序，
            // 无需在视图 body 里重复排序（该分支在面板可见期间会随每次求值而执行）。
            // 下游 `intradayTrendTrailingText` 取 `.last` 本就依赖这一不变量。
            let storedPoints = fund.intradayRateHistory ?? []
            return storedPoints.isEmpty ? intradayCurrentValueFallbackPoints : storedPoints
        }
    }

    private var intradayTrendTrailingText: String? {
        guard let lastPoint = displayedIntradayPoints.last else { return nil }
        return "\(MoneyFormatter.percent(lastPoint.rate, signed: true)) · \(dateText(lastPoint.timestamp, format: "HH:mm"))"
    }

    private var intradayTrendEmptyText: String {
        if intradayDataSource == .sina {
            // 新浪覆盖率有限（约 81%），部分基金本就没有该数据源。
            return isLoadingSinaPoints ? "正在加载数据源2（新浪）盘中估值…" : "该基金暂无数据源2（新浪）的盘中估值"
        }
        switch TradingCalendar.marketSessionState() {
        case .open:
            return "等待下一次盘中估值刷新"
        case .middayBreak:
            return "午休中，盘中曲线暂停更新"
        case .closed:
            return "休市中，盘中曲线停止更新"
        }
    }

    private var intradayCurrentValueFallbackPoints: [FundIntradayRatePoint] {
        guard fund.todayRate.isFinite,
              fund.todayRate != 0
        else {
            return []
        }

        return [
            FundIntradayRatePoint(
                timestamp: intradayFallbackTimestamp,
                rate: fund.todayRate,
                estimateTime: fund.dateText
            )
        ]
    }

    private var intradayFallbackTimestamp: Int64 {
        if let parsedDate = parseFundDateText(fund.dateText) {
            return Int64((parsedDate.timeIntervalSince1970 * 1000).rounded())
        }
        return Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private var holdingDaysText: String {
        guard let positionDate = fund.positionDate,
              let startDate = DateOnlyFormatter.parse(positionDate)
        else {
            return "--"
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: .now)
        let days = max((calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1, 1)
        return "\(days)"
    }

    private func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    private func signedNumberText(_ value: Double) -> String {
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        return "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(2))))"
    }

    private func compactPendingMoney(_ value: Double) -> String {
        "¥\(value.formatted(.number.precision(.fractionLength(0...2))))"
    }

    private func compactPendingShares(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func dateText(_ timestamp: Int64, format: String) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return FundDetailDateFormatting.string(from: date, format: format)
    }

    private func parseFundDateText(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 11 else { return nil }

        let calendar = FundDetailDateFormatting.gregorianCalendar()
        let year = calendar.component(.year, from: .now)
        let fullText = "\(year)-\(trimmed)"
        return FundDetailDateFormatting.date(
            from: fullText,
            format: "yyyy-MM-dd HH:mm",
            calendar: calendar
        )
    }

    @MainActor
    private func loadSupplement(force: Bool = false) async {
        guard !isSupplementLoading else { return }

        // 静态部分（十大重仓股名单/占比/相关行业）按季度披露日变化，两次报告之间基本不变。
        // 披露日仍有效（且非强制刷新）时跳过这部分请求，直接复用缓存，显著减少重仓接口调用。
        let staticStillValid = !force && store.staticHoldingsStillValid(for: fund.code)

        // 动态部分（净值走势、资产配置、重仓股当日涨跌幅）按交易时段节流；force 时跳过门控。
        let dynamicSlot: String? = force
            ? "manual-\(DateOnlyFormatter.string(from: .now))"
            : Self.supplementRefreshSlot(for: fund, now: .now)

        // 重仓股涨跌幅过期检测：盘后保留的涨跌幅若来自「今天之前」的交易日（例如昨天盘后
        // 拉到、今天尚未触发新的 after15 补拉），则需强制重新拉一次当日值，避免详情页一直
        // 展示上一交易日的重仓股涨跌（紫金矿业-0.58% vs 同花顺-2.40% 即此 bug）。
        let todayKey = DateOnlyFormatter.string(from: .now)
        let holdingsStaleForToday = !force
            && !supplement.topHoldings.isEmpty
            && supplement.topHoldingsChangeDate != todayKey
            && TradingCalendar.isFundTradingDay(.now)

        // 无前十大重仓的品种（ETF 联接/商品/债券等）需刷新「关联标的」（场内 ETF 或跟踪指数），
        // 优先级应覆盖静态披露日短路：否则盘前/非交易时段 staticStillValid 直接 return，
        // 界面会一直停留在磁盘缓存里的旧关联标的（如 004253 展示跟踪指数而非场内 518800）。
        let trackIndexPending = supplement.topHoldings.isEmpty

        guard !staticStillValid || dynamicSlot != nil || holdingsStaleForToday || trackIndexPending else { return }
        // 涨跌幅过期时，即便 today 的 after15 槽已拉过，也允许在「非交易时段」补拉一次当日值。
        let dynamicSlotEffective = (dynamicSlot ?? (holdingsStaleForToday ? "stale-\(todayKey)" : nil))
        let dynamicPending = dynamicSlotEffective != nil
            && fetchedSupplementSlots.contains("dynamic-\(dynamicSlotEffective!)") == false

        guard !staticStillValid || dynamicPending || trackIndexPending else { return }
        if !dynamicPending, staticStillValid, trackIndexPending {
            // 仅需刷新跟踪指数：跳过静态/动态重拉，也不登记槽位。
            await refreshTrackIndexOnly()
            return
        }
        guard fetchedSupplementSlots.contains("dynamic-\(dynamicSlotEffective ?? "")") == false else { return }

        isSupplementLoading = true
        defer { isSupplementLoading = false }

        // 拉取静态部分（重仓名单/占比/行业）：仅在缺失、披露日过期或强制刷新时。
        // 注意：此处不做 fetchedSupplementSlots 去重——静态部分由 store.staticHoldingsStillValid
        // 控制（季度末起的窗口内会持续尝试，直到拉到最新报告日才稳定），否则会漏掉窗口内
        // 新披露的定期报告。
        var merged = supplement
        if !staticStillValid {
            let position = await supplementService.fetchPositionSupplementSafely(code: fund.code)
            let industry = await supplementService.fetchSectorAllocationSafely(
                code: fund.code,
                date: position.holdingDisclosureDate
            )
            merged.topHoldings = position.topHoldings
            merged.relatedSectors = position.relatedSectors
            merged.holdingDisclosureDate = position.holdingDisclosureDate
            merged.industryAllocation = industry
            merged.industryDisclosureDate = industry.first?.date
        }

        // 拉取动态部分（净值走势 + 资产配置 + 重仓股当日涨跌幅）。
        if let dynamicSlotEffective, !fetchedSupplementSlots.contains("dynamic-\(dynamicSlotEffective)") {
            async let history = supplementService.fetchNetValueHistorySafely(code: fund.code)
            async let asset = supplementService.fetchAssetAllocationSafely(code: fund.code)
            let (historyPoints, assetItems) = await (history, asset)
            merged.history = historyPoints
            merged.assetAllocation = assetItems
            merged.assetAllocationDate = assetItems.first?.date
            merged.yesterdayPoint = FundQuoteService.yesterdayNetValuePoint(from: historyPoints, now: .now)
            fetchedSupplementSlots.insert("dynamic-\(dynamicSlotEffective)")

            // 重仓股当日涨跌幅：静态名单有效但涨跌幅来自更早交易日时（holdingsStaleForToday），
            // 名单不会重新拉取，需单独用腾讯接口刷新各股当日涨跌幅，并打上今日日期。
            if !merged.topHoldings.isEmpty {
                if let changes = try? await supplementService.fetchStockChanges(for: merged.topHoldings.map(\.code)) {
                    merged.topHoldings = merged.topHoldings.map { holding in
                        var next = holding
                        if let rate = changes[holding.code] {
                            next.changeRate = rate
                        }
                        return next
                    }
                }
                merged.topHoldingsChangeDate = todayKey
            }
        }

        // 跟踪指数：仅「无前十大重仓」的品种需要（典型如场内 ETF、商品基金）。
        // 刻意放在动态槽位之外：涨跌幅要跟随行情保持新鲜（跨过 15:00 后切换收盘口径），
        // 并自愈旧版本缓存的费率脏值；频率仍受 .task 时点循环与手动刷新约束。
        await applyTrackIndexIfApplicable(to: &merged)

        supplement = merged
        store.cacheSupplement(supplement, for: fund.code)
        didLoadSupplement = true
    }

    /// 按需加载数据源 2（新浪）的当日分时曲线。
    ///
    /// 与 `loadSupplement` 的关键区别：新浪接口不支持批量，只能逐只请求，
    /// 因此**只在用户打开这只基金的详情页时调用一次**，不参与持仓批量刷新，
    /// 也不跟随行情定时器。重复开关详情页由 `SinaQuoteService` 的当日缓存 + 节流兜底。
    ///
    /// 休市时段该曲线已定格且无新数据产生，直接跳过请求。
    @MainActor
    private func loadSinaIntradayPoints() async {
        // 不在此处按交易日拦截：收盘后/非交易日仍优先读落盘，展示已定格的曲线；
        // 真正无缓存且无交易日的场景由 SinaQuoteService 内部兜底（不发起无意义请求）。
        sinaIntradayPoints = await SinaQuoteService.fetchIntradayRatePoints(code: fund.code)
    }

    /// 仅在本页数据源为「数据源2（新浪）」时才取数。
    /// 默认的数据源 1（东财）走持仓批量刷新，**完全不触碰新浪接口**；
    /// 重复切换/重复进入由 `SinaQuoteService` 的 5 分钟节流 + 落盘兜底，不会形成请求风暴。
    private func loadSinaIntradayPointsIfNeeded() async {
        guard intradayDataSource == .sina else { return }
        isLoadingSinaPoints = true
        await loadSinaIntradayPoints()
        isLoadingSinaPoints = false
    }

    /// 仅刷新跟踪指数的轻量路径（静态/动态均无需重拉时）。
    @MainActor
    private func refreshTrackIndexOnly() async {
        var merged = supplement
        await applyTrackIndexIfApplicable(to: &merged)
        guard merged != supplement else { return }
        supplement = merged
        store.cacheSupplement(supplement, for: fund.code)
    }

    /// 刷新「关联标的」：仅对无前十大重仓的品种生效。优先级：① 关联场内 ETF；② 跟踪指数。
    /// 避免展示分支在「重仓卡 ↔ 指数卡」之间抖动。
    @MainActor
    private func applyTrackIndexIfApplicable(to merged: inout FundDetailSupplement) async {
        if !merged.topHoldings.isEmpty {
            merged.indexCode = nil
            merged.indexName = nil
            merged.indexChangeRate = nil
            merged.relatedKind = nil
            return
        }

        // 关联场内 ETF 字段（linkedETFCode）来自持仓接口，但持仓拉取受 staticStillValid
        // 控制：盘后季报已披露时静态部分会被跳过，导致 linkedETFCode 为空、直接退回跟踪指数。
        // 此处若尚未获取（且走关联标的路径），补拉一次持仓接口仅取 etfCode/etfName，
        // 确保 004253 → 518800 这类场内 ETF 映射不被漏掉（优先于跟踪指数）。
        if merged.linkedETFCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            let position = await supplementService.fetchPositionSupplementSafely(code: fund.code)
            merged.linkedETFCode = position.linkedETFCode
            merged.linkedETFName = position.linkedETFName
        }

        // ① 关联场内 ETF：ETF 联接基金持有的目标基金，市价实时涨跌最贴近净值，
        //    腾讯实时通道直接覆盖（如 000216 → 518880 黄金ETF华安）。
        if let etfCode = merged.linkedETFCode?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !etfCode.isEmpty,
           etfCode.range(of: "^\\d{6}$", options: .regularExpression) != nil,
           let etfRate = await supplementService.fetchRealtimeChangeRateSafely(code: etfCode) {
            if merged.indexCode != etfCode { merged.indexCode = etfCode }
            let trimmedETFName = merged.linkedETFName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let etfName = (trimmedETFName?.isEmpty == false) ? trimmedETFName! : "场内ETF"
            if merged.indexName != etfName { merged.indexName = etfName }
            if merged.indexChangeRate != etfRate { merged.indexChangeRate = etfRate }
            if merged.relatedKind != "etf" { merged.relatedKind = "etf" }
            return
        }

        // ② 跟踪指数：腾讯实时通道 → 东财日K兜底；上金所现货（AU9999 等）两者均拿不到时，
        //    用基础信息接口的 RATE（即跟踪标的当日涨跌幅）兜底。
        guard let track = await supplementService.fetchTrackIndexSafely(code: fund.code) else {
            // 既无关联场内 ETF，也无跟踪指数（如 001235 / 006331 这类纯主动或特殊品种）：
            // 显式清空关联标的字段，避免旧缓存脏值（如历史遗留的 indexName/changeRate）
            // 残留展示出「无名称却带涨跌幅」的怪异卡片。
            merged.indexCode = nil
            merged.indexName = nil
            merged.indexChangeRate = nil
            merged.relatedKind = nil
            return
        }
        if merged.indexCode != track.code { merged.indexCode = track.code }
        if merged.indexName != track.name { merged.indexName = track.name }
        if merged.relatedKind != "index" { merged.relatedKind = "index" }
        let rate = await supplementService.fetchRealtimeChangeRateSafely(code: track.code) ?? track.rate
        if merged.indexChangeRate != rate { merged.indexChangeRate = rate }
    }

    /// 当前时刻是否应拉取「重仓补充数据」的时点槽；返回 nil 表示此刻不应请求。
    /// - 非交易日：不请求（重仓股为静态数据）。
    /// - 普通基金：交易时段内（开市）→ intraday 槽；15:00 之后 → after15 槽（补充当日涨跌幅，最多一次）；其余（盘前/午休/深夜）→ nil。
    /// - QDII：北京时间 08:00 之后 → qdii8 槽（海外净值/涨跌在早上公布，每日更新一次）；其余 → nil。
    private static func supplementRefreshSlot(for fund: FundPosition, now: Date) -> String? {
        guard TradingCalendar.isFundTradingDay(now) else { return nil }
        let cal = supplementChinaCalendar
        let hour = cal.component(.hour, from: now)
        let dayKey = DateOnlyFormatter.string(from: now)
        if fund.fundType == .qdii {
            return hour >= 8 ? "\(dayKey)-qdii-8" : nil
        }
        if TradingCalendar.marketSessionState(now: now) == .open {
            return "\(dayKey)-intraday"
        }
        if hour >= 15 {
            return "\(dayKey)-after15"
        }
        return nil
    }

    /// 下一个需要补充重仓数据的目标时刻（普通基金 15:00 / QDII 08:00），取未来最近的一个基金交易日对应时点。
    private static func nextSupplementTargetTime(for fund: FundPosition, now: Date) -> Date? {
        let cal = supplementChinaCalendar
        let targetHour = fund.fundType == .qdii ? 8 : 15
        var day = cal.startOfDay(for: now)
        for _ in 0..<366 {
            if TradingCalendar.isFundTradingDay(day),
               let target = cal.date(bySettingHour: targetHour, minute: 0, second: 0, of: day),
               target > now {
                return target
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return nil
    }

    private static let supplementChinaCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()
}

private enum TradeRecordFilter: String, CaseIterable, Identifiable {
    case all
    case buy
    case sell
    case conversion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "全部"
        case .buy:
            "加仓"
        case .sell:
            "减仓"
        case .conversion:
            "转换"
        }
    }

    func matches(_ record: FundTradeRecord) -> Bool {
        switch self {
        case .all:
            true
        case .buy:
            record.kind == .buy || record.kind == .newFund
        case .sell:
            record.kind == .sell
        case .conversion:
            record.kind == .conversionOut || record.kind == .conversionIn
        }
    }
}

struct FundTradeRecordsPanelView: View {
    let store: PortfolioStore
    let fundCode: String
    let onEdit: (FundTradeRecord) -> Void
    let onDelete: (FundTradeRecord) async -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var filter: TradeRecordFilter = .all
    @State private var deletingRecord: FundTradeRecord?

    private var fund: FundPosition {
        store.snapshot.funds.first { $0.code == fundCode } ?? unavailableRoutedFund(code: fundCode)
    }

    private var tradeRecords: [FundTradeRecord] {
        store.snapshot.tradeRecords ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "clock.arrow.circlepath",
                title: "交易记录",
                subtitle: tradeRecordsHeaderSubtitle,
                subtitleWeight: .semibold,
                onClose: onClose
            )

            filterBar
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if filteredTradeRecords.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "tray")
                            .frame(height: 320)
                    } else {
                        ForEach(filteredTradeRecords) { record in
                            tradeRecordRow(record)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(PanelDesign.panelBackground)
        .alert("删除交易记录", isPresented: deleteConfirmationBinding, presenting: deletingRecord) { record in
            Button("取消", role: .cancel) {
                deletingRecord = nil
            }
            Button("删除记录", role: .destructive) {
                Task {
                    await onDelete(record)
                    deletingRecord = nil
                }
            }
        } message: { record in
            Text(deleteTradeRecordConfirmationMessage(for: record))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(TradeRecordFilter.allCases) { value in
                Button {
                    filter = value
                } label: {
                    Text(value.title)
                        .font(.system(size: 11, weight: filter == value ? .semibold : .medium))
                        .foregroundStyle(filter == value ? Color.blue : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            filter == value ? Color.blue.opacity(0.11) : PanelDesign.selectorBackground.opacity(0.72),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(filter == value ? Color.blue.opacity(0.16) : Color.clear, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    private var recentTradeRecords: [FundTradeRecord] {
        let actualRecords = tradeRecords.filter { $0.code == fund.code }
        let records = actualRecords.contains { $0.kind == .newFund }
            ? actualRecords
            : actualRecords + (inferredInitialTradeRecord(for: fund).map { [$0] } ?? [])
        return records.sorted(by: tradeRecordTimeDescending)
    }

    private var filteredTradeRecords: [FundTradeRecord] {
        recentTradeRecords.filter(filter.matches)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingRecord != nil },
            set: { isPresented in
                if !isPresented {
                    deletingRecord = nil
                }
            }
        )
    }

    private var emptyTitle: String {
        filter == .all ? "暂无交易记录" : "暂无\(filter.title)记录"
    }

    private var tradeRecordsHeaderSubtitle: String {
        let code = FundCodeFormatter.display(fund.code)
        let name = fund.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? code : "\(code) · \(name)"
    }

    private func deleteTradeRecordConfirmationMessage(for record: FundTradeRecord) -> String {
        "确定删除 \(tradeDateTimeText(record)) 的\(record.kind.title)记录（\(tradeRecordAmountText(record))）吗？删除后会重新计算这只基金的持仓金额、持仓份额和成本，且无法撤销。"
    }

    private func tradeRecordRow(_ record: FundTradeRecord) -> some View {
        let kindColor = tradeKindColor(record.kind)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    recordKindBadge(record.kind)

                    Text(tradeDateTimeText(record))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                Text(tradeRecordAmountText(record))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(kindColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                    .frame(minWidth: 96, alignment: .trailing)
            }
            .frame(height: 22, alignment: .center)

            HStack(alignment: .center, spacing: 8) {
                Text(recordConfirmationText(record))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 19, alignment: .center)

                Spacer(minLength: 4)

                recordStatusBadge(record)
            }
            .frame(height: 22, alignment: .center)

            HStack(alignment: .center, spacing: 8) {
                recordPriceShareLine(record, color: kindColor)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                recordActionStack(record)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(height: 22, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 88)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(recordCardBackground(record.kind))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(kindColor.opacity(colorScheme == .dark ? 0.24 : 0.16), lineWidth: 0.8)
        }
    }

    private func recordActionButton(
        systemName: String,
        title: String,
        color: Color = .secondary,
        backgroundOpacity: Double = 0.06,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
    }

    private func canEdit(_ record: FundTradeRecord) -> Bool {
        !isInferredInitialTradeRecord(record)
    }

    private func recordActionStack(_ record: FundTradeRecord) -> some View {
        HStack(spacing: 5) {
            if canEdit(record) {
                recordActionButton(systemName: "pencil", title: "编辑") {
                    onEdit(record)
                }
            }
            if !isInferredInitialTradeRecord(record) {
                recordActionButton(systemName: "trash", title: "删除", color: .red, backgroundOpacity: 0.08) {
                    deletingRecord = record
                }
            }
        }
    }

    private func recordKindBadge(_ kind: FundTradeKind) -> some View {
        let color = tradeKindColor(kind)
        return Text(recordKindTitle(kind))
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(color.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.6)
            )
    }

    private func recordStatusBadge(_ record: FundTradeRecord) -> some View {
        let title = recordStatusTitle(record)
        let color = tradeStatusColor(record.status)
        return Text(title)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(minWidth: 50)
            .frame(height: 19)
            .background(color.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.6)
            )
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
    }

    private func recordTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func recordKindTitle(_ kind: FundTradeKind) -> String {
        switch kind {
        case .newFund:
            "新增"
        case .buy:
            "加仓"
        case .sell:
            "减仓"
        case .conversionOut:
            "转出"
        case .conversionIn:
            "转入"
        }
    }

    private func tradeDateTimeText(_ record: FundTradeRecord) -> String {
        if record.kind == .newFund, record.mode == .amount {
            return "首次录入"
        }
        return "\(record.tradeDate) \(record.tradeTimeType.title)"
    }

    private func recordConfirmationText(_ record: FundTradeRecord) -> String {
        if record.status == .pending,
           isConversionRecord(record),
           record.amount != nil,
           let executionDate = TradingCalendar.nextFundTradingDate(after: record.acceptedDate) {
            return "执行 \(executionDate) 00:00后"
        }
        return "确认 \(record.acceptedDate)"
    }

    private func recordStatusTitle(_ record: FundTradeRecord) -> String {
        if record.status == .pending,
           isConversionRecord(record),
           record.amount != nil {
            return "待执行"
        }
        if record.status == .pending,
           isConversionRecord(record) {
            return "待净值"
        }
        return record.status.title
    }

    private func isConversionRecord(_ record: FundTradeRecord) -> Bool {
        record.kind == .conversionOut || record.kind == .conversionIn
    }

    @ViewBuilder
    private func recordPriceShareLine(_ record: FundTradeRecord, color: Color) -> some View {
        let priceText = record.price.map { numberText($0, places: 4) }
        let sharesText = (record.confirmedShares ?? record.shares).map { "\(numberText($0, places: 2))份" }

        if priceText == nil && sharesText == nil {
            Text(record.kind == .newFund && record.mode == .amount ? "手工录入" : "待确认净值和份额")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                if let priceText {
                    recordMetricText(
                        label: record.kind == .newFund && record.mode == .amount ? "参考净值" : "净值",
                        value: priceText,
                        color: color
                    )
                }

                if let sharesText {
                    recordMetricText(label: "份额", value: sharesText, color: color)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .allowsTightening(true)
        }
    }

    private func recordMetricText(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary.opacity(colorScheme == .dark ? 0.82 : 0.70))
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color.opacity(colorScheme == .dark ? 0.95 : 0.82))
        }
        .monospacedDigit()
    }

    private func tradeRecordAmountText(_ record: FundTradeRecord) -> String {
        if let amount = record.amount {
            return MoneyFormatter.plainMoney(amount)
        }
        if let shares = record.shares ?? record.confirmedShares {
            return "\(numberText(shares, places: 2))份"
        }
        return "--"
    }

    private func tradeKindColor(_ kind: FundTradeKind) -> Color {
        switch kind {
        case .newFund:
            Color(nsColor: .systemBlue)
        case .buy:
            Color(nsColor: .systemRed)
        case .sell, .conversionOut:
            .redFundGreen
        case .conversionIn:
            Color(nsColor: .systemRed)
        }
    }

    private func recordCardBackground(_ kind: FundTradeKind) -> LinearGradient {
        let color = tradeKindColor(kind)
        return LinearGradient(
            colors: [
                color.opacity(colorScheme == .dark ? 0.18 : 0.10),
                color.opacity(colorScheme == .dark ? 0.10 : 0.055),
                PanelDesign.cardBackground.opacity(colorScheme == .dark ? 0.82 : 0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func tradeStatusColor(_ status: FundTradeRecordStatus) -> Color {
        switch status {
        case .pending:
            .orange
        case .confirmed:
            .blue
        case .failed:
            .red
        }
    }

    private func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

/// 遵循 Equatable：父级重算而点位未变时跳过 body，避免滚动中重建折线 Path。
private struct FundIntradayRateChart: View, Equatable {
    /// 当前展示的数据源曲线（同一时刻只展示一个数据源）。
    let points: [FundIntradayRatePoint]
    /// 当前数据源：决定线色（数据源 2 用固定蓝，与数据源 1 的涨跌红绿区分）。
    var source: IntradayDataSource = .eastmoney

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredIndex: Int?

    /// 展开动画进度：0 = 整条线贴在 0% 基准线上，1 = 真实涨跌走势。
    /// 纵轴范围按**真实点位**计算，因此展开过程中基准线与刻度始终不动。
    @State private var revealProgress: CGFloat = 0

    /// 展开动画时长（缓慢展开，切换数据源时不生硬）。
    private static let revealDuration: Double = 0.9

    // @State 会阻止 Equatable 自动合成，手动只比较数据输入；
    // 悬停状态/展开进度各自拥有独立的重渲染机制，不依赖父级失效。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.source == rhs.source
    }

    private static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                yAxisLabels
                    .frame(width: 36, height: 108)

                GeometryReader { proxy in
                    ZStack {
                        gridLines(in: proxy.size)
                            .stroke(gridColor, lineWidth: 0.7)
                        zeroLine(in: proxy.size)
                            .stroke(zeroLineColor, style: StrokeStyle(lineWidth: 0.9, dash: [6, 5]))
                        chartBorder(in: proxy.size)
                            .stroke(borderColor, lineWidth: 0.75)

                        if renderedPoints.count >= 2 {
                            areaPath(in: proxy.size)
                                .fill(areaFill)
                            linePath(in: proxy.size)
                                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        } else if let point = renderedPoints.first {
                            singlePointPath(for: point, in: proxy.size)
                                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            Circle()
                                .fill(lineColor)
                                .frame(width: 7, height: 7)
                                .overlay(
                                    Circle()
                                        .stroke(PanelDesign.cardBackground.opacity(colorScheme == .dark ? 0.9 : 0.96), lineWidth: 1.4)
                                )
                                .position(pointPosition(for: point, in: proxy.size))
                        }

                        if let hoveredIndex,
                           renderedPoints.indices.contains(hoveredIndex) {
                            hoverOverlay(for: hoveredIndex, in: proxy.size)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = nearestIndex(for: location.x, width: proxy.size.width)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                }
                .frame(height: 108)
            }

            xAxisLabels
        }
        .accessibilityLabel("盘中预估实时涨跌走势图")
        .onAppear {
            // 首次出现（含切换数据源后重建）时从 0% 基准线缓慢展开到真实走势。
            guard revealProgress < 1 else { return }
            withAnimation(.easeInOut(duration: Self.revealDuration)) {
                revealProgress = 1
            }
        }
    }

    private var sortedPoints: [FundIntradayRatePoint] {
        points.sorted { $0.timestamp < $1.timestamp }
    }

    private var renderedPoints: [FundIntradayRatePoint] {
        sortedPoints
    }

    /// 纵轴范围按**真实点位**计算：展开动画只改变绘制位置，不参与范围计算，
    /// 这样 0% 基准线与上下刻度在整段动画里保持固定。
    private var yAxisBounds: (min: Double, max: Double) {
        let rates = sortedPoints.map(\.rate)
        let rawMin = min(rates.min() ?? 0, 0)
        let rawMax = max(rates.max() ?? 0, 0)
        var minValue = floor(rawMin)
        var maxValue = ceil(rawMax)

        if minValue >= rawMin, rawMin < 0 {
            minValue -= 1
        }
        if maxValue <= rawMax, rawMax > 0 {
            maxValue += 1
        }

        if minValue == maxValue {
            minValue -= 0.5
            maxValue += 0.5
        }

        return (minValue, maxValue)
    }

    /// 数据源 1 沿用涨跌红绿；数据源 2 用固定蓝，避免切换后与数据源 1 观感混淆。
    private var lineColor: Color {
        guard source == .sina else {
            return toneColor(for: sortedPoints.last?.rate ?? 0)
        }
        return Self.secondaryLineColor
    }

    /// 数据源 2 的固定线色（与主线的涨跌红绿区分）。
    static let secondaryLineColor = Color.blue

    private var areaFill: LinearGradient {
        LinearGradient(
            colors: [
                lineColor.opacity(colorScheme == .dark ? 0.26 : 0.18),
                lineColor.opacity(colorScheme == .dark ? 0.08 : 0.035)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var gridColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.14)
    }

    private var zeroLineColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.38 : 0.32)
    }

    private var borderColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.16)
    }

    private var yAxisLabels: some View {
        let bounds = yAxisBounds
        return VStack(alignment: .trailing, spacing: 0) {
            Text(MoneyFormatter.percent(bounds.max, signed: true))
            Spacer()
            Text(MoneyFormatter.percent(bounds.min, signed: true))
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var xAxisLabels: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Spacer()
                .frame(width: 42)
            Text("09:30")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("11:30/13:00")
                .frame(maxWidth: .infinity, alignment: .center)
            Text("15:00")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func gridLines(in size: CGSize) -> Path {
        Path { path in
            for ratio in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                let x = size.width * ratio
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            for ratio in [CGFloat(0), 1] {
                let y = size.height * ratio
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }

    private func zeroLine(in size: CGSize) -> Path {
        Path { path in
            let y = yPosition(for: 0, height: size.height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
    }

    private func chartBorder(in size: CGSize) -> Path {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
        }
    }

    private func linePath(in size: CGSize) -> Path {
        let points = renderedPoints
        return Path { path in
            for (index, point) in points.enumerated() {
                let position = pointPosition(for: point, in: size)
                if index == 0 {
                    path.move(to: position)
                } else {
                    path.addLine(to: position)
                }
            }
        }
    }

    private func areaPath(in size: CGSize) -> Path {
        let points = renderedPoints
        return Path { path in
            guard let first = points.first,
                  let last = points.last
            else {
                return
            }

            for (index, point) in points.enumerated() {
                let position = pointPosition(for: point, in: size)
                if index == 0 {
                    path.move(to: position)
                } else {
                    path.addLine(to: position)
                }
            }

            let zeroY = yPosition(for: 0, height: size.height)
            path.addLine(to: CGPoint(x: xPosition(for: last, width: size.width), y: zeroY))
            path.addLine(to: CGPoint(x: xPosition(for: first, width: size.width), y: zeroY))
            path.closeSubpath()
        }
    }

    private func singlePointPath(for point: FundIntradayRatePoint, in size: CGSize) -> Path {
        Path { path in
            let position = pointPosition(for: point, in: size)
            let startX: CGFloat
            let endX: CGFloat
            if position.x >= size.width / 2 {
                startX = max(0, position.x - 28)
                endX = position.x
            } else {
                startX = position.x
                endX = min(size.width, position.x + 28)
            }
            path.move(to: CGPoint(x: startX, y: position.y))
            path.addLine(to: CGPoint(x: endX, y: position.y))
        }
    }

    private func hoverOverlay(for index: Int, in size: CGSize) -> some View {
        let points = renderedPoints
        let point = points[index]
        let position = pointPosition(for: point, in: size)
        let xLabelX = min(max(position.x, 24), max(size.width - 24, 24))
        let yLabelY = min(max(position.y, 9), max(size.height - 9, 9))

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: position.x, y: 0))
                path.addLine(to: CGPoint(x: position.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: position.y))
                path.addLine(to: CGPoint(x: size.width, y: position.y))
            }
            .stroke(Color.secondary.opacity(0.42), style: StrokeStyle(lineWidth: 0.9, dash: [4, 3]))

            Circle()
                .fill(lineColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(PanelDesign.cardBackground.opacity(colorScheme == .dark ? 0.9 : 0.96), lineWidth: 1.4)
                )
                .position(position)

            hoverAxisLabel(MoneyFormatter.percent(point.rate, signed: true), width: 54)
                .position(x: -31, y: yLabelY)

            hoverAxisLabel(Self.timeFormatter.string(from: date(from: point.timestamp)), width: 42)
                .position(x: xLabelX, y: size.height - 10)
        }
        .allowsHitTesting(false)
    }

    private func hoverAxisLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(lineColor)
            .frame(width: width, height: 18)
            .background(hoverAxisLabelBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(lineColor.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.65)
            )
    }

    private var hoverAxisLabelBackground: Color {
        colorScheme == .dark
            ? PanelDesign.cardBackground.opacity(0.92)
            : Color.white.opacity(0.94)
    }

    private func pointPosition(for point: FundIntradayRatePoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(for: point, width: size.width),
            y: revealedY(for: point.rate, height: size.height)
        )
    }

    /// 展开动画中的纵坐标：以 0% 基准线为锚，按 `revealProgress` 向上下散开。
    /// 进度为 0 时整条线贴在基准线上，进度为 1 时回到真实位置。
    private func revealedY(for rate: Double, height: CGFloat) -> CGFloat {
        let realY = yPosition(for: rate, height: height)
        guard revealProgress < 1 else { return realY }
        let baseY = yPosition(for: 0, height: height)
        return baseY + (realY - baseY) * revealProgress
    }

    private func xPosition(for point: FundIntradayRatePoint, width: CGFloat) -> CGFloat {
        sessionProgress(for: point.timestamp) * width
    }

    private func yPosition(for rate: Double, height: CGFloat) -> CGFloat {
        let bounds = yAxisBounds
        let range = bounds.max - bounds.min
        guard range > 0 else { return height / 2 }
        let clampedRate = min(max(rate, bounds.min), bounds.max)
        return CGFloat((bounds.max - clampedRate) / range) * height
    }

    private func sessionProgress(for timestamp: Int64) -> CGFloat {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = Self.chinaTimeZone

        let date = date(from: timestamp)
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0)) + Double(components.second ?? 0) / 60

        let morningOpen = 9.0 * 60 + 30
        let morningClose = 11.0 * 60 + 30
        let afternoonOpen = 13.0 * 60
        let afternoonClose = 15.0 * 60
        let activeMinutes = (morningClose - morningOpen) + (afternoonClose - afternoonOpen)

        if minute <= morningOpen {
            return 0
        }
        if minute <= morningClose {
            return CGFloat((minute - morningOpen) / activeMinutes)
        }
        if minute < afternoonOpen {
            return 0.5
        }
        if minute <= afternoonClose {
            return CGFloat((morningClose - morningOpen + minute - afternoonOpen) / activeMinutes)
        }
        return 1
    }

    private func nearestIndex(for x: CGFloat, width: CGFloat) -> Int? {
        let points = renderedPoints
        guard !points.isEmpty, width > 0 else { return nil }
        return points.indices.min { lhs, rhs in
            abs(xPosition(for: points[lhs], width: width) - x) < abs(xPosition(for: points[rhs], width: width) - x)
        }
    }

    private func date(from timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }
}

/// 净值业绩走势图。仅展示一条持仓成本参考线（及成本点位），不再叠加多笔购入标记。
/// 遵循 Equatable：父级重算而走势数据未变时跳过 body。
private struct FundTrendMiniChart: View, Equatable {
    let points: [FundNetValuePoint]
    let holdingCost: Double?
    let holdingCostPoint: FundNetValuePoint?

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredIndex: Int?

    // 同 FundIntradayRateChart：手动只比较数据输入
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points
            && lhs.holdingCost == rhs.holdingCost
            && lhs.holdingCostPoint == rhs.holdingCostPoint
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                yAxisLabels
                    .frame(width: 42, height: 90)

                GeometryReader { proxy in
                    ZStack {
                        chartGrid
                        chartAxes
                        if let costPoint = holdingCostPoint,
                           let cost = holdingCost, cost.isFinite, cost > 0 {
                            costReferenceLine(at: cost, in: proxy.size)
                            costReferenceDot(for: costPoint, at: cost, in: proxy.size)
                            costReferenceLabel(at: cost, in: proxy.size)
                        }
                        linePath(in: proxy.size)
                            .stroke(lineColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        if let hoveredIndex,
                           points.indices.contains(hoveredIndex) {
                            hoverOverlay(for: hoveredIndex, in: proxy.size)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = nearestIndex(for: location.x, width: proxy.size.width)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                }
                .frame(height: 90)
            }

            HStack {
                Spacer()
                    .frame(width: 48)
                Text(dateText(points.first?.timestamp))
                Spacer()
                Text(dateText(points.last?.timestamp))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private var chartGrid: some View {
        GeometryReader { proxy in
            Path { path in
                let rows: [CGFloat] = [0, 0.5, 1]
                for row in rows {
                    let y = row * proxy.size.height
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
        }
    }

    private var chartAxes: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
            }
            .stroke(Color.secondary.opacity(0.24), lineWidth: 0.8)
        }
    }

    private var lineColor: Color {
        toneColor(for: points.last?.equityReturn ?? 0)
    }

    private var yValueBounds: (min: Double, max: Double) {
        var values = points.map(\.value)
        if let cost = holdingCost, cost.isFinite {
            values.append(cost)
        }
        guard let minValue = values.min(),
              let maxValue = values.max()
        else {
            return (0, 1)
        }

        let range = max(maxValue - minValue, 0.0001)
        let padding = max(range * 0.12, 0.01)
        return (minValue - padding, maxValue + padding)
    }

    private var yAxisLabels: some View {
        let bounds = yValueBounds
        let middleValue = (bounds.min + bounds.max) / 2

        return VStack(alignment: .trailing, spacing: 0) {
            Text(numberText(bounds.max))
            Spacer()
            Text(numberText(middleValue))
            Spacer()
            Text(numberText(bounds.min))
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func costReferenceLine(at cost: Double, in size: CGSize) -> some View {
        Path { path in
            let y = yPosition(for: cost, height: size.height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(holdingCostColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .allowsHitTesting(false)
    }

    private func costReferenceDot(for point: FundNetValuePoint, at cost: Double, in size: CGSize) -> some View {
        let x = CGFloat(points.count - 1) / CGFloat(points.count - 1) * size.width
        let y = yPosition(for: cost, height: size.height)
        return Circle()
            .fill(holdingCostColor)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(PanelDesign.cardBackground.opacity(colorScheme == .dark ? 0.9 : 0.96), lineWidth: 1.3)
            )
            .position(CGPoint(x: x, y: y))
            .allowsHitTesting(false)
    }

    private func costReferenceLabel(at cost: Double, in size: CGSize) -> some View {
        let labelWidth: CGFloat = 44
        let y = min(max(yPosition(for: cost, height: size.height), 9), max(size.height - 9, 9))
        return Text("成本 \(numberText(cost))")
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(holdingCostColor)
            .frame(width: labelWidth, height: 16)
            .background(hoverAxisLabelBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(holdingCostColor.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.65)
            )
            .position(x: size.width - labelWidth / 2 - 4, y: y)
            .allowsHitTesting(false)
    }

    private var holdingCostColor: Color {
        .orange
    }

    private func hoverOverlay(for index: Int, in size: CGSize) -> some View {
        let point = points[index]
        let pointPosition = pointPosition(for: index, in: size)
        let xLabelX = min(max(pointPosition.x, 24), max(size.width - 24, 24))
        let yLabelY = min(max(pointPosition.y, 9), max(size.height - 9, 9))

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: pointPosition.x, y: 0))
                path.addLine(to: CGPoint(x: pointPosition.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: pointPosition.y))
                path.addLine(to: CGPoint(x: size.width, y: pointPosition.y))
            }
            .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 0.9, dash: [4, 3]))

            Circle()
                .fill(lineColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(PanelDesign.cardBackground.opacity(colorScheme == .dark ? 0.9 : 0.96), lineWidth: 1.4)
                )
                .position(pointPosition)

            hoverAxisLabel(numberText(point.value), width: 54)
                .position(x: -31, y: yLabelY)

            hoverAxisLabel(dateText(point.timestamp), width: 42)
                .position(x: xLabelX, y: size.height - 10)
        }
        .allowsHitTesting(false)
    }

    private func hoverAxisLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(lineColor)
            .frame(width: width, height: 18)
            .background(hoverAxisLabelBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(lineColor.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.65)
            )
    }

    private var hoverAxisLabelBackground: Color {
        colorScheme == .dark
            ? PanelDesign.cardBackground.opacity(0.92)
            : Color.white.opacity(0.94)
    }

    private func nearestIndex(for x: CGFloat, width: CGFloat) -> Int? {
        guard points.count > 1, width > 0 else { return nil }
        let ratio = min(max(x / width, 0), 1)
        return min(max(Int((ratio * CGFloat(points.count - 1)).rounded()), 0), points.count - 1)
    }

    private func pointPosition(for index: Int, in size: CGSize) -> CGPoint {
        guard points.indices.contains(index),
              points.count > 1,
              size.width > 0,
              size.height > 0
        else {
            return .zero
        }
        let x = CGFloat(index) / CGFloat(points.count - 1) * size.width
        let y = yPosition(for: points[index].value, height: size.height)
        return CGPoint(x: x, y: y)
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        let bounds = yValueBounds
        let range = max(bounds.max - bounds.min, 0.0001)
        let clampedValue = min(max(value, bounds.min), bounds.max)
        return (1 - CGFloat((clampedValue - bounds.min) / range)) * height
    }

    private func linePath(in size: CGSize) -> Path {
        guard points.count > 1,
              size.width > 0,
              size.height > 0
        else {
            return Path()
        }

        var path = Path()
        for (index, point) in points.enumerated() {
            let x = CGFloat(index) / CGFloat(points.count - 1) * size.width
            let y = yPosition(for: point.value, height: size.height)
            let cgPoint = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: cgPoint)
            } else {
                path.addLine(to: cgPoint)
            }
        }
        return path
    }

    private func numberText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(4)))
    }

    private func dateText(_ timestamp: Int64?) -> String {
        guard let timestamp else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return FundDetailDateFormatting.string(from: date, format: "MM-dd")
    }

    private func dateOnlyText(_ timestamp: Int64) -> String {
        DateOnlyFormatter.string(from: date(from: timestamp))
    }

    private func date(from timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }

}

let panelBorderColor = Color(nsColor: .separatorColor).opacity(0.12)

/// 详情页时间文本的格式化缓存。
/// DateFormatter 初始化涉及 ICU 设置，开销较大；走势图悬停等高频路径
/// 每次移动都会触发格式化，必须复用实例。
@MainActor
private enum FundDetailDateFormatting {
    static let chinaLocale = Locale(identifier: "zh_CN")
    static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static var formattersByFormat: [String: DateFormatter] = [:]

    /// 按dateFormat复用DateFormatter实例。
    private static func formatter(for format: String) -> DateFormatter {
        if let cached = formattersByFormat[format] { return cached }
        let formatter = DateFormatter()
        formatter.locale = chinaLocale
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = format
        formattersByFormat[format] = formatter
        return formatter
    }

    /// 格式化时间戳文本（如 "yyyy-MM-dd"、"HH:mm"）。
    static func string(from date: Date, format: String) -> String {
        formatter(for: format).string(from: date)
    }

    /// 解析时间文本；calendar 仅影响解析所用的年月日基准。
    static func date(from text: String, format: String, calendar: Calendar) -> Date? {
        let cachedFormatter = formatter(for: format)
        cachedFormatter.calendar = calendar
        cachedFormatter.timeZone = calendar.timeZone
        return cachedFormatter.date(from: text)
    }

    /// 中国时区的公历日历（用于按本地交易日取年份等场景）。
    static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = chinaLocale
        calendar.timeZone = chinaTimeZone
        return calendar
    }
}

/// 大盘指数横向卡片的原生滚动容器：NSScrollView 承载内容（无可见滚动条），
/// 并在 scrollWheel 中把竖向滚轮增量映射为横向滚动，
/// 不依赖应用激活状态，普通鼠标与触控板都能稳定浏览全部指数。
private struct MarketIndexNativeWheelStrip<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> HorizontalWheelScrollView {
        let scrollView = HorizontalWheelScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        // 关键：避免 NSScrollView 自行按主轴线判定滚动方向而吞掉纵向滚轮事件，
        // 全部交给 scrollWheel 手动映射为横向滚动。
        scrollView.usesPredominantAxisScrolling = false

        let hosting = PanelFocusAppearance.hostingView(content())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = hosting
        scrollView.resizeDocumentViewToFitContent()
        return scrollView
    }

    func updateNSView(_ nsView: HorizontalWheelScrollView, context: Context) {
        guard let hosting = nsView.documentView as? NSHostingView<AnyView> else { return }
        hosting.rootView = PanelFocusAppearance.suppressedRoot(content())
        // 内容数量/宽度可能随行情数据变化，重新量取并保持当前阅读位置
        hosting.invalidateIntrinsicContentSize()
        nsView.resizeDocumentViewToFitContent()
    }

    final class HorizontalWheelScrollView: NSScrollView {
        /// 依据内容固有尺寸调整 documentView 尺寸（宽度不足时撑满可视区）。
        func resizeDocumentViewToFitContent() {
            guard let hosting = documentView as? NSHostingView<AnyView> else { return }
            hosting.layoutSubtreeIfNeeded()
            // NSHostingView 的 fittingSize 不可靠（常为 0），改用 intrinsicContentSize。
            let intrinsic = hosting.intrinsicContentSize
            let width = max(intrinsic.width, bounds.width)
            let height = max(intrinsic.height, bounds.height)
            hosting.frame = NSRect(x: 0, y: 0,  width: width, height: height)
        }

        /// 竖向滚轮（普通鼠标）按横向处理；触控板横扫走同一映射，方向与系统习惯一致。
        override func scrollWheel(with event: NSEvent) {
            guard let doc = documentView else {
                super.scrollWheel(with: event)
                return
            }
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            // 滚动速度放大，让普通鼠标滚轮也能较快浏览全部指数。
            let scrollSpeed: CGFloat = 6.0
            let dominantDelta = (abs(deltaX) >= abs(deltaY) ? deltaX : deltaY) * scrollSpeed
            guard dominantDelta != 0 else { return }

            let clipView = contentView
            let clipWidth = clipView.bounds.width
            let maxX = max(0, doc.frame.width - clipWidth)
            guard maxX > 0 else {
                super.scrollWheel(with: event)
                return
            }
            let newX = min(max(clipView.bounds.origin.x - dominantDelta, 0), maxX)
            clipView.bounds.origin.x = newX
        }
    }
}

private func toneColor(for value: Double) -> Color {
    if value > 0 { return Color(red: 239 / 255, green: 77 / 255, blue: 98 / 255) }
    if value < 0 { return .redFundGreen }
    return Color.secondary
}

/// 实时收益(元)文本：隐藏金额时显示掩码，否则按涨跌着色。
private func todayIncomeAmount(_ value: Double, isMasked: Bool = false) -> Text {
    if isMasked {
        return Text("***")
            .font(.system(size: 30, weight: .semibold))
    }
    let sign = value > 0 ? "+" : value < 0 ? "-" : ""
    let amount = abs(value).formatted(.number.precision(.fractionLength(2)))
    return Text("\(sign)\(amount)")
        .font(.system(size: 30, weight: .semibold))
}

func inferredInitialTradeRecord(for fund: FundPosition) -> FundTradeRecord? {
    let shares = fund.migratedShares ?? 0
    let amount = inferredInitialTradeRecordAmount(for: fund)
    guard shares > 0 || (amount ?? 0) > 0 else {
        return nil
    }

    let tradeDate = fund.positionDate ?? fund.incomeStartDate ?? ""
    let acceptedDate = fund.incomeStartDate ?? fund.positionDate ?? tradeDate
    let status: FundTradeRecordStatus = fund.status.isPendingDisplay ? .pending : .confirmed
    return FundTradeRecord(
        id: inferredInitialTradeRecordID(for: fund.code),
        kind: .newFund,
        status: status,
        code: fund.code,
        name: fund.name,
        mode: fund.positionMode ?? .share,
        amount: amount,
        shares: fund.positionMode == .amount ? nil : (shares > 0 ? shares : nil),
        confirmedShares: fund.positionMode == .amount ? nil : (status == .confirmed && shares > 0 ? shares : nil),
        price: fund.positionMode == .amount ? nil : fund.migratedCost,
        profit: fund.positionMode == .amount ? fund.pendingProfit : nil,
        tradeDate: tradeDate,
        tradeTimeType: fund.positionTimeType ?? .before15,
        acceptedDate: acceptedDate,
        createdAt: .distantPast,
        confirmedAt: status == .confirmed ? .distantPast : nil,
        failureReason: nil
    )
}

private func inferredInitialTradeRecordAmount(for fund: FundPosition) -> Double? {
    if fund.positionMode == .amount {
        return firstPositiveAmount(fund.pendingAmount, fund.migratedPrincipal, fund.currentAmount)
    }
    return firstPositiveAmount(fund.migratedPrincipal, fund.pendingAmount, fund.currentAmount)
}

private func firstPositiveAmount(_ values: Double?...) -> Double? {
    for value in values {
        if let value, value > 0 {
            return value
        }
    }
    return nil
}

private func inferredInitialTradeRecordID(for code: String) -> String {
    "inferred-new-fund-\(code)"
}

private func isInferredInitialTradeRecord(_ record: FundTradeRecord) -> Bool {
    record.id == inferredInitialTradeRecordID(for: record.code)
}

private func tradeRecordTimeDescending(_ lhs: FundTradeRecord, _ rhs: FundTradeRecord) -> Bool {
    if lhs.tradeDate != rhs.tradeDate {
        return lhs.tradeDate > rhs.tradeDate
    }
    if lhs.tradeTimeType != rhs.tradeTimeType {
        return lhs.tradeTimeType.sortOrder > rhs.tradeTimeType.sortOrder
    }
    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
    }
    return lhs.id > rhs.id
}

private extension PositionTimeType {
    var sortOrder: Int {
        switch self {
        case .before15:
            0
        case .after15:
            1
        }
    }
}

// MARK: - 历史净值列表

/// 详情页「历史净值」区块：默认展示最近 7 条，点「查看更多」展开近 1 月全量。
///
/// 刻意独立成 View 并自持 `isExpanded` 与筛选结果 `rows`：
///
/// 1. **展开状态**：若 `isExpanded` 放在 `FundDetailView` 上，每次点按都会重算整个详情页
///    body——净值走势图、盘中曲线、重仓股、交易记录全部重建，`supplement.history`
///    （老基金可达 3000+ 点）会被重复 sort / filter 多次，肉眼可见卡顿。
///    状态下沉后，点按只重算本 View（量级 20 余行）。
///
/// 2. **筛选结果缓存**：`rows` 只在净值序列变化时算一次。详情页 body 每 5 秒随行情重算，
///    若把筛选写成 computed property，`sorted` 与 `filter` 里的 `Calendar.startOfDay`
///    （逐点调用，比纯数值比较贵 1~2 个数量级）会每轮跑上数千次。
///
/// 本 View 刻意**不**遵循 Equatable：入参是可能长达数千点的原始数组，等值比较本身就要
/// 遍历全量元素，比直接重算 body（此时只读已缓存的 20 余行）更贵。
private struct FundHistoryNetValueList: View {
    /// 该基金的完整净值序列（接口原始可达 3000+ 点）。
    let points: [FundNetValuePoint]
    let isLoading: Bool

    /// 折叠态展示条数。
    private static let collapsedCount = 7
    /// 纳入列表的时间窗口（天）。
    private static let windowDays = 30

    /// 窗口内的净值点，按时间倒序。仅在 `points` 变化时重算。
    @State private var rows: [FundNetValuePoint] = []
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if rows.isEmpty {
                Text(isLoading ? "净值加载中..." : "暂无历史净值")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 74)
                    .background(
                        PanelDesign.selectorBackground.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            } else {
                VStack(spacing: 0) {
                    columnHeader
                    Divider().opacity(0.45)
                    rowList
                    if rows.count > Self.collapsedCount {
                        expandToggle
                    }
                }
            }
        }
        // 净值序列加载/刷新后重算窗口。`initial: true` 保证首帧即有数据，不闪加载态。
        //
        // key 用「条数 + 最新时间戳」而非数组本身：数组等值比较要遍历数千元素，
        // 而这两个标量是 O(1) 比较。仅用条数会漏掉「同一天重复拉取、条数不变但
        // 最新净值已更新」的情况。
        .onChange(of: Self.dataFingerprint(of: points), initial: true) { _, _ in
            rows = Self.recentRows(from: points)
        }
    }

    /// 净值序列的廉价指纹，用于判断是否需要重算窗口。
    private static func dataFingerprint(of points: [FundNetValuePoint]) -> DataFingerprint {
        DataFingerprint(
            count: points.count,
            latestTimestamp: points.max(by: { $0.timestamp < $1.timestamp })?.timestamp ?? 0
        )
    }

    /// 见 `dataFingerprint`。用结构体而非元组——元组无法遵循 `Equatable`，
    /// 而 `onChange(of:)` 要求该约束。
    private struct DataFingerprint: Equatable {
        let count: Int
        let latestTimestamp: Int64
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("历史净值")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            // 统计始终按窗口内全量条数显示，避免折叠时误以为只有 7 条。
            Text(rows.isEmpty ? "近1月" : "近1月 · \(rows.count)条")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
    }

    private var columnHeader: some View {
        HStack {
            columnTitle("日期", alignment: .leading)
            columnTitle("净值", alignment: .center)
            columnTitle("日涨幅", alignment: .trailing)
        }
        .frame(height: 26)
    }

    private func columnTitle(_ title: String, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var rowList: some View {
        let visible = isExpanded ? rows : Array(rows.prefix(Self.collapsedCount))
        return VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, point in
                row(point)
                if index < visible.count - 1 {
                    Divider().opacity(0.34)
                }
            }
        }
    }

    private func row(_ point: FundNetValuePoint) -> some View {
        HStack(spacing: 8) {
            Text(dateText(point.timestamp))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(point.value.formatted(.number.precision(.fractionLength(4))))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(point.equityReturn.map { MoneyFormatter.percent($0, signed: true) } ?? "--")
                .foregroundStyle(point.equityReturn.map(toneColor(for:)) ?? Color.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .frame(height: 34)
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "收起" : "查看更多")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "收起历史净值" : "展开近1月全部历史净值")
    }

    private func dateText(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return FundDetailDateFormatting.string(from: date, format: "yyyy-MM-dd")
    }

    /// 取最近 `windowDays` 天内的净值点，按时间倒序。
    private static func recentRows(from points: [FundNetValuePoint]) -> [FundNetValuePoint] {
        guard let latestTimestamp = points.max(by: { $0.timestamp < $1.timestamp })?.timestamp else {
            return []
        }
        // 窗口按毫秒直接比较，避免对每个点调用 `Calendar.startOfDay`（数千次调用，
        // 是这段筛选的主要开销）。与原先按自然日对齐的口径略有差异，但列表只按
        // 交易日呈现净值点，实际结果一致。
        let cutoff = latestTimestamp - Int64(Self.windowDays) * 86_400_000
        return points
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
    }
}

private struct MainPopoverNativeScrollConfiguration: NSViewRepresentable {
    @MainActor
    func makeNSView(context: Context) -> NativeScrollConfigurationView {
        NativeScrollConfigurationView(frame: .zero)
    }

    // 有意留空：绑定为幂等操作，且已在 superview/window 变化时触发；
    // 父视图每次重算都重入会反复拆装 observer/timer，滚动时放大主线程开销。
    @MainActor
    func updateNSView(_ view: NativeScrollConfigurationView, context: Context) {}
}

@MainActor
private final class NativeScrollConfigurationView: NSView {
    private var hideTimer: Timer?
    private weak var observedScrollView: NSScrollView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }

    func configureEnclosingScrollView() {
        // 幂等：已绑定同一 ScrollView 时直接返回，避免重复拆装 observer/timer。
        let enclosing = superview?.enclosingScrollView
        if let observedScrollView, observedScrollView === enclosing {
            return
        }

        // 切换绑定时先注销旧监听并停掉淡出计时，避免泄漏与重复回调。
        if let prev = observedScrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: prev.contentView
            )
        }
        hideTimer?.invalidate()
        hideTimer = nil
        observedScrollView = nil

        guard let scrollView = enclosing else { return }
        bind(scrollView)
        observedScrollView = scrollView
    }

    private func bind(_ scrollView: NSScrollView) {
        drawsBackgroundlessSetup(on: scrollView)

        if let scroller = scrollView.verticalScroller {
            scroller.controlSize = .small
            scroller.knobStyle = .default
            // 默认隐藏：系统“始终显示滚动条”偏好会忽略 autohidesScrollers，
            // 这里用透明 + 滚动监听自行实现“滚动时浮现、停止后淡出”。
            scroller.alphaValue = 0
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func drawsBackgroundlessSetup(on scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 2)
    }

    /// 列表发生滚动：仅在滚动条尚未完全可见时才启动浮现动画（避免每帧重开动画），
    /// 并安排 0.8s 无滚动后淡出。
    @objc private func contentScrolled(_ note: Notification) {
        hideTimer?.invalidate()
        guard let scroller = observedScrollView?.verticalScroller else { return }
        if scroller.alphaValue < 1 {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.15
            scroller.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fadeOutScroller()
            }
        }
    }

    private func fadeOutScroller() {
        guard let scroller = observedScrollView?.verticalScroller else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.3
        scroller.animator().alphaValue = 0
        NSAnimationContext.endGrouping()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            hideTimer?.invalidate()
        }
    }
}

private let refreshTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter
}()

private func refreshTimeText(_ date: Date) -> String {
    refreshTimeFormatter.string(from: date)
}
