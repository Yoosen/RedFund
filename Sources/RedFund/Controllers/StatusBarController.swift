// MARK: - 文件概述
// StatusBarController.swift 是 RedFund 的"总调度中枢"：
// - 在系统菜单栏（status bar）渲染图标与今日收益文字
// - 管理主面板（main panel）与各类子面板（child panel）窗口的弹出、定位、外观切换
// - 提供右键上下文菜单（刷新 / 设置 / 检查更新 / 导入导出 / 退出）
// - 维护自动刷新定时器、操作提醒（交易日开盘）与基金阈值提醒通知
// - 协调京东金融登录 / 同步等内嵌网页面板

import AppKit
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

// 操作提醒通知的固定标识符（及应用内前缀，用于批量识别与清理）
private let operationReminderNotificationID = "red-fund.operation-reminder"
// 基金阈值提醒"上次发送时间"在 UserDefaults 中的存储键
private let fundThresholdReminderLastSentDefaultsKey = "red-fund.threshold-reminder.last-sent-times"
private let operationReminderNotificationPrefix = "\(operationReminderNotificationID)."
// 外观切换时用于盖一层的过渡遮罩视图标识符
private let appearanceTransitionOverlayIdentifier = NSUserInterfaceItemIdentifier("red-fund.appearance-transition-overlay")
// 专门记录"状态栏更新检查"相关日志的 Logger
private let statusBarUpdateLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.iamzjt.frontend.red-fund.swift",
    category: "AppUpdate"
)

// 线程安全的"一次性结果容器"：用于把后台更新检查的结果安全地交还给主线程。
// @unchecked Sendable 是因为要用锁保护可变状态。
private final class ContextMenuUpdateCheckResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: AppUpdateCheckCompletion?

    // 仅当还没有结果时才写入（避免重复覆盖）
    func set(_ completion: AppUpdateCheckCompletion) {
        lock.lock()
        defer { lock.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
    }

    // 取出并清空结果（取出即消费）
    func take() -> AppUpdateCheckCompletion? {
        lock.lock()
        defer { lock.unlock() }
        let completion = completion
        self.completion = nil
        return completion
    }
}

// 一次右键菜单触发的更新检查：包含唯一 ID、请求、结果容器与执行任务
private struct ContextMenuUpdateCheck {
    var id: UUID
    var request: AppUpdateCheckRequest
    var resultBox: ContextMenuUpdateCheckResultBox
    var task: Task<Void, Never>
}

// 把应用的"外观模式"（跟随系统/浅色/深色）映射为 AppKit 的 NSAppearance
private extension AppAppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil                 // 跟随系统：不强制设置
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

// 外观切换时覆盖在面板上的"渐变遮罩"，用来做明暗过渡动画（盖住瞬间跳变）
private final class AppearanceTransitionOverlayView: NSView {
    private let gradientLayer = CAGradientLayer()

    init(appearance: NSAppearance) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = gradientLayer
        configure(for: appearance)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    // 让遮罩本身不接收任何鼠标事件（穿透到下层面板）
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // 依据浅/深色生成对应的起始/结束渐变色
    private func configure(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let leading = isDark
            ? NSColor(red: 17 / 255, green: 19 / 255, blue: 24 / 255, alpha: 0.96)
            : NSColor(red: 251 / 255, green: 249 / 255, blue: 245 / 255, alpha: 0.94)
        let trailing = isDark
            ? NSColor(red: 29 / 255, green: 33 / 255, blue: 42 / 255, alpha: 0.86)
            : NSColor(red: 242 / 255, green: 238 / 255, blue: 229 / 255, alpha: 0.80)
        gradientLayer.colors = [leading.cgColor, trailing.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    }
}

// 菜单栏状态项的展示参数：高度、图标尺寸，以及根据文字计算占用宽度
private enum StatusItemPresentation {
    static let height: CGFloat = 24
    static let iconSize: CGFloat = 16

    // 估算"图标 + 文字"的总视觉宽度，用于设置状态项长度
    static func visualLength(
        for text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        return ceil(iconSize + textWidth)
    }
}

// 菜单栏标题的一次性计算结果（文字、富文本属性、视觉宽度）
private struct StatusTitlePresentation {
    let text: String
    let attributes: [NSAttributedString.Key: Any]
    let visualLength: CGFloat
}

// 用贝塞尔路径手绘 RedFund 的"心跳脉冲"图标，tintColor 为 nil 时当作模板图（随系统着色）
private func makeStatusPulseImage(size: NSSize, tintColor: NSColor? = nil) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
        let color = tintColor ?? .labelColor
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.lineWidth = tintColor == nil ? 1.8 : 2.05
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: rect.minX + 1.6, y: rect.minY + 8.0))
        path.line(to: NSPoint(x: rect.minX + 4.6, y: rect.minY + 8.0))
        path.line(to: NSPoint(x: rect.minX + 6.4, y: rect.minY + 13.0))
        path.line(to: NSPoint(x: rect.minX + 9.5, y: rect.minY + 4.0))
        path.line(to: NSPoint(x: rect.minX + 11.5, y: rect.minY + 10.0))
        path.line(to: NSPoint(x: rect.minX + 14.4, y: rect.minY + 10.0))
        path.stroke()

        NSBezierPath(
            ovalIn: NSRect(
                x: rect.minX + 12.0,
                y: rect.minY + 12.5,
                width: 2.8,
                height: 2.8
            )
        ).fill()
        return true
    }
    image.isTemplate = tintColor == nil
    return image
}

// 集中定义所有面板/窗口的尺寸与外观常量（主面板、各子面板、京东金融网页、圆角、箭头等）
enum PopoverLayout {
    static let mainWidth: CGFloat = 360
    static let jdFinanceLoginWidth: CGFloat = 1040              // 京东登录网页面板较宽
    static let jdFinancePreviewWidth: CGFloat = 430
    static let jdFinanceSyncWidth: CGFloat = 500
    static let jdFinanceSyncHeight: CGFloat = 720
    static let standardChildPanelWidth: CGFloat = 360
    static let settingsWidth: CGFloat = standardChildPanelWidth
    static let editorWidth: CGFloat = standardChildPanelWidth
    static let standardChildPanelHeight: CGFloat = 660
    static let editorHeight: CGFloat = 600
    static let tradeRecordsHeight: CGFloat = standardChildPanelHeight
    static let settingsHeight: CGFloat = 750
    static let portfolioBreakdownWidth: CGFloat = standardChildPanelWidth
    static let todayIncomeRankingWidth: CGFloat = standardChildPanelWidth
    static let fundDailyIncomeWidth: CGFloat = standardChildPanelWidth
    static let fundDailyIncomeHeight: CGFloat = 600
    static let onboardingWidth: CGFloat = standardChildPanelWidth
    static let privacyDisclaimerWidth: CGFloat = onboardingWidth
    static let sampleExperienceWidth: CGFloat = 430
    static let portfolioPerformanceWidth: CGFloat = 430
    static let height: CGFloat = CGFloat(AppSettings.defaultMainPanelHeight) // 主面板默认高度
    static let arrowHeight: CGFloat = 10                        // 指向状态栏的小三角高度
    static let arrowWidth: CGFloat = 22
    static let cornerRadius: CGFloat = 16                       // 面板圆角
    static let panelGap: CGFloat = 3                            // 主/子面板之间的间隙

    // 主面板的内容尺寸、窗口总高（含箭头）、窗口整体尺寸
    static let mainSize = mainContentSize(forHeight: height)
    static let windowHeight: CGFloat = mainWindowHeight(forHeight: height)
    static let mainWindowSize = mainWindowFrameSize(forHeight: height)
    // 各业务面板的最终 NSSize
    static let jdFinanceLoginSize = NSSize(width: jdFinanceLoginWidth, height: jdFinanceSyncHeight)
    static let jdFinanceNetworkProbeSize = NSSize(width: jdFinancePreviewWidth, height: jdFinanceSyncHeight)
    static let jdFinanceSyncSize = NSSize(width: jdFinanceSyncWidth, height: jdFinanceSyncHeight)
    static let settingsSize = NSSize(width: settingsWidth, height: settingsHeight)
    static let editorSize = NSSize(width: editorWidth, height: editorHeight)
    static let tradeEditorSize = NSSize(width: editorWidth, height: standardChildPanelHeight)
    static let fundDetailSize = NSSize(width: editorWidth, height: standardChildPanelHeight)
    static let tradeRecordsSize = NSSize(width: editorWidth, height: tradeRecordsHeight)
    static let portfolioBreakdownSize = NSSize(width: portfolioBreakdownWidth, height: standardChildPanelHeight)
    static let todayIncomeRankingSize = NSSize(width: todayIncomeRankingWidth, height: standardChildPanelHeight)
    static let fundDailyIncomeSize = NSSize(width: fundDailyIncomeWidth, height: fundDailyIncomeHeight)
    static let onboardingSize = NSSize(width: onboardingWidth, height: standardChildPanelHeight)
    static let sampleExperienceSize = NSSize(width: sampleExperienceWidth, height: standardChildPanelHeight)
    static let privacyDisclaimerSize = NSSize(width: privacyDisclaimerWidth, height: standardChildPanelHeight)
    static let portfolioPerformanceSize = NSSize(width: portfolioPerformanceWidth, height: standardChildPanelHeight)
    static let jdFinancePerformanceSyncSize = portfolioPerformanceSize

    // 高度先做合法性裁剪（避免用户设置越界）
    static func clampedMainPanelHeight(_ height: CGFloat) -> CGFloat {
        CGFloat(AppSettings.clampedMainPanelHeight(Int(height.rounded())))
    }

    static func mainContentSize(forHeight height: CGFloat) -> NSSize {
        NSSize(width: mainWidth, height: clampedMainPanelHeight(height))
    }

    static func mainWindowHeight(forHeight height: CGFloat) -> CGFloat {
        clampedMainPanelHeight(height) + arrowHeight
    }

    static func mainWindowFrameSize(forHeight height: CGFloat) -> NSSize {
        NSSize(width: mainWidth, height: mainWindowHeight(forHeight: height))
    }

}

// 可观察的 UI 状态：仅持有"小三角箭头横向位置"，供 SwiftUI 视图响应式读取
@Observable
@MainActor
final class PopoverUIState {
    var arrowX: CGFloat = PopoverLayout.mainWidth / 2
}

// 自定义无边框面板：作为主/子面板与京东金融网页的容器窗口
private final class RedFundPanel: NSPanel {
    var onOrderOut: (() -> Void)?   // 面板被移出屏幕时回调
    var onClose: (() -> Void)?      // 面板被关闭时回调
    var onCancel: (() -> Void)?     // 用户按 Esc 取消时回调

    // 允许成为 key/main 窗口，才能正常接收键盘与焦点
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], // 无边框、且不抢占主应用激活状态
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar            // 显示在状态栏层级
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    // 仅在可见时被隐藏时触发回调，避免重复调用
    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        if wasVisible {
            onOrderOut?()
        }
    }

    override func close() {
        let wasVisible = isVisible
        super.close()
        if wasVisible {
            onClose?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// 包裹一层"卡片容器"：负责圆角裁剪、按浅/深色设置背景与边框色
final class PanelCardContainerView: NSView {
    let hostedContentView: NSView

    init(contentView: NSView, cornerRadius: CGFloat = PopoverLayout.cornerRadius) {
        hostedContentView = contentView
        super.init(frame: .zero)

        if let hostingView = contentView as? NSHostingView<AnyView> {
            hostingView.sizingOptions = []
        }

        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        updateAppearanceColors()

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // 让被包裹内容与容器四边对齐
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var fittingSize: NSSize {
        hostedContentView.fittingSize
    }

    // 系统外观变化时刷新颜色
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        self.appearance = appearance
        hostedContentView.appearance = appearance
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        let appearance = effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark
            ? NSColor(red: 17 / 255, green: 19 / 255, blue: 24 / 255, alpha: 0.98)
            : NSColor(red: 251 / 255, green: 249 / 255, blue: 245 / 255, alpha: 0.99)
        ).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.06)
        ).cgColor
    }
}

// 引导流程中"添加基金"子步骤的状态：记录用户是否成功保存，用于决定跳回引导还是结束引导
@MainActor
private final class OnboardingAddFlowState {
    var didSave = false
}

@MainActor
final class StatusBarController: NSObject {
    // ---- 核心依赖 ----
    private let statusItem: NSStatusItem             // 系统菜单栏上的状态项（图标+文字）
    private let store: PortfolioStore               // 持仓数据仓库
    private let settingsStore: AppSettingsStore     // 设置仓库
    private let marketIndexStore: MarketIndexStore // 大盘指数仓库
    private let updateStore: AppUpdateStore         // 更新仓库
    private let appVersion: String
    private let popoverState = PopoverUIState()     // 面板 UI 状态（如箭头位置）
    private lazy var statusPulseImage = makeStatusPulseImage( // 菜单栏用的心跳图标（模板图）
        size: NSSize(width: StatusItemPresentation.iconSize, height: StatusItemPresentation.iconSize)
    )
    // 由 AppDelegate 注入的检查更新/打开更新回调
    private let onCheckUpdate: (AppUpdateCheckMode) async -> Void
    private let onOpenUpdate: () -> Void

    // ---- 窗口与交互状态 ----
    private var mainPanelWindow: RedFundPanel?        // 主面板窗口
    private var childPanelWindow: RedFundPanel?       // 当前子面板窗口
    private var jdFinanceLoginWindow: RedFundPanel?   // 京东金融网页面板
    private var mainPanelHostingView: NSHostingView<AnyView>?
    private var activeChildPanel: ChildPanelRoute?      // 当前打开的子面板路由
    private var childPanelReturnRoute: ChildPanelRoute? // 交易/编辑类子面板的"返回路由"（取消时回退到上一步，而非直接关闭）
    private var selectedFundCode: String?               // 当前选中的基金代码
    private var jdFinanceLoginCompletion: ((String?) -> Void)? // 京东登录完成回调（cookieHeader 或 nil）
    private var localEventMonitor: Any?                 // 应用内事件监听（点窗外关闭等）
    private var globalEventMonitor: Any?                // 全局鼠标事件监听
    private var deactivateObserver: NSObjectProtocol?    // 应用失活时关闭面板
    private var mainPanelAnchorFrame: NSRect?           // 主面板定位所依据的状态栏按钮位置
    private var autoRefreshTimer: Timer?                // 自动刷新行情定时器
    private weak var contextMenuUpdateItem: NSMenuItem? // 右键菜单里的"更新"项
    private var contextMenuUpdateRefreshTimer: Timer?   // 右键菜单打开时刷新更新状态的定时器
    private var contextMenuUpdateAnimationFrame = 2     // 更新项动画帧计数
    private var contextMenuUpdateStatusOverride: AppUpdateStatus?
    private var contextMenuUpdateCheck: ContextMenuUpdateCheck? // 正在进行的菜单内更新检查
    private var fundThresholdReminderLastSentAt: [String: Date] = [:] // 阈值提醒去重用：各 key 上次发送时间
    private var pendingFundThresholdReminderKeys: Set<String> = []   // 正在发送、尚未确认完成的提醒 key
    private let operationReminderScheduler: OperationReminderNotificationScheduler // 操作提醒（交易日开盘）调度器
    private var settingsSectionSession = SettingsSectionSession() // 记住设置面板上次所在分区
    private var onboardingResumeStep = 0                // 引导流程可恢复的步数
    // 持仓表现面板的状态记忆（分页/指标/区间/月份）
    private var holdingPerformancePage: HoldingPerformancePage = .ranking
    private var holdingPerformanceMetric: IncomeRankingMetric = .amount
    private var holdingPerformanceRange: PortfolioPerformanceRange = .threeMonths
    private var holdingPerformanceMonth: Date?
#if DEBUG
    private var debugPerformanceStore: PortfolioPerformanceStore? // 调试用：可注入样例表现数据
#endif

    // 构建操作提醒调度器：把系统通知中心的增删查、授权等能力适配给调度器
    private static func makeOperationReminderScheduler() -> OperationReminderNotificationScheduler {
        let center = UNUserNotificationCenter.current()
        return OperationReminderNotificationScheduler(
            maximumRemovalAttempts: 40,
            pendingRequests: {
                await center.pendingNotificationRequests().map(
                    Self.operationReminderNotificationCandidate(from:)
                )
            },
            removePendingRequests: {
                center.removePendingNotificationRequests(withIdentifiers: $0)
            },
            deliveredNotifications: {
                await center.deliveredNotifications().map {
                    Self.operationReminderNotificationCandidate(from: $0.request)
                }
            },
            removeDeliveredNotifications: {
                center.removeDeliveredNotifications(withIdentifiers: $0)
            },
            requestAuthorization: {
                try await center.requestAuthorization(options: [.alert, .sound])
            },
            addRequest: { request in
                let content = UNMutableNotificationContent()
                content.title = request.title
                content.body = request.body
                content.sound = .default

                // 按交易日历计算触发时间（开盘前提醒）
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: TradingCalendar.notificationDateComponents(from: request.fireDate),
                    repeats: false
                )
                try await center.add(
                    UNNotificationRequest(
                        identifier: request.identifier,
                        content: content,
                        trigger: trigger
                    )
                )
            },
            waitAfterRemovalAttempt: {
                try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
            }
        )
    }

    // 主面板高度（按设置裁剪后）
    private var mainPanelHeight: CGFloat {
        PopoverLayout.clampedMainPanelHeight(CGFloat(settingsStore.settings.mainPanelHeight))
    }

    // 主面板整体窗口尺寸（内容高 + 箭头高）
    private var mainPanelWindowSize: NSSize {
        PopoverLayout.mainWindowFrameSize(forHeight: mainPanelHeight)
    }

    // 当前应选择的外观（跟随系统/浅/深）
    private var panelAppearance: NSAppearance? {
        settingsStore.settings.appearanceMode.nsAppearance
    }

    // 用于展示的"持仓表现"数据仓库（Debug 可替换为样例数据）
    private var performanceStoreForPresentation: PortfolioPerformanceStore {
#if DEBUG
        debugPerformanceStore ?? store.performanceStore
#else
        store.performanceStore
#endif
    }

    // 依赖注入构造；super.init 之后完成状态项配置与首轮刷新
    init(
        store: PortfolioStore,
        settingsStore: AppSettingsStore,
        marketIndexStore: MarketIndexStore,
        updateStore: AppUpdateStore,
        appVersion: String,
        onCheckUpdate: @escaping (AppUpdateCheckMode) async -> Void,
        onOpenUpdate: @escaping () -> Void
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.marketIndexStore = marketIndexStore
        self.updateStore = updateStore
        self.appVersion = appVersion
        self.onCheckUpdate = onCheckUpdate
        self.onOpenUpdate = onOpenUpdate
        self.operationReminderScheduler = Self.makeOperationReminderScheduler()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        fundThresholdReminderLastSentAt = Self.loadFundThresholdReminderLastSentAt() // 恢复阈值提醒发送记录
        configureStatusItem()                 // 配置菜单栏按钮
        updateStatusTitle()                   // 刷新菜单栏标题
        configureAutoRefreshTimer()           // 启动自动刷新
        configureOperationReminder()          // 配置开盘提醒
        sendFundThresholdRemindersIfNeeded()  // 发送积压的阈值提醒
        refreshQuotesAndStatusTitle()         // 首屏拉取一次行情
    }

    // 应用退出/控制器销毁时：关闭京东面板、停定时器、停更新检查、停提醒、移除事件监听
    func invalidate() {
        hideJDFinanceLoginPanel(reportCancellation: true)
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        stopContextMenuUpdateRefresh(cancelPendingCheck: true)
        operationReminderScheduler.invalidate()
        removeEventMonitors()
    }

    // 首次启动且符合条件时，弹出引导流程
    func presentInitialExperienceIfNeeded() {
        // 是否应当展示引导：依据设置来源、持仓加载状态等判断
        guard OnboardingEligibility.shouldPresent(
            settings: settingsStore.settings,
            settingsLoadOrigin: settingsStore.loadOrigin,
            portfolioLoadState: store.loadState
        ) else { return }

        onboardingResumeStep = 0
        NSApp.activate(ignoringOtherApps: true) // 激活应用（菜单栏应用默认不激活）
        showMainPanel()
        showChildPanel(.onboarding(origin: .firstLaunch))
    }

// MARK: - Debug 专属：通过启动参数 --debug-panel <route> 直接弹出指定面板，便于开发调试
#if DEBUG
    func presentDebugPanelIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let flagIndex = arguments.firstIndex(of: "--debug-panel"),
              arguments.indices.contains(flagIndex + 1)
        else { return }

        let route: ChildPanelRoute
        switch arguments[flagIndex + 1] {
        case "onboarding":
            route = .onboarding(origin: .settings)
        case "sample":
            route = .sampleExperience(origin: .settings)
        case "privacy":
            route = .privacyDisclaimer(origin: .settings)
        case "support":
            settingsSectionSession.select(.support)
            route = .settings
        case "performance":
            holdingPerformancePage = .ranking
            route = .portfolioPerformance
        case "performance-sample":
            debugPerformanceStore = makeDebugPerformanceStore()
            holdingPerformancePage = .curve
            route = .portfolioPerformance
        case "performance-calendar-sample":
            debugPerformanceStore = makeDebugPerformanceStore()
            holdingPerformancePage = .calendar
            route = .portfolioPerformance
        case "performance-sync":
            holdingPerformancePage = .curve
            route = .jdFinancePerformanceSync
        case "settings":
            route = .settings
        default:
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        showMainPanel()
        showChildPanel(route)
    }

    private func makeDebugPerformanceStore() -> PortfolioPerformanceStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "red-fund-performance-preview-\(UUID().uuidString)")
        let previewStore = PortfolioPerformanceStore(dataDirectory: directory)
        let sample = SampleExperienceFactory.make()
        let days = sample.dailyPerformance.enumerated().map { index, item in
            PortfolioPerformanceDay(
                date: DateOnlyFormatter.string(from: item.date),
                profit: item.dailyIncome,
                returnRate: item.dailyIncomeRate,
                status: index == sample.dailyPerformance.count - 1 ? .estimated : .confirmed,
                updatedAt: sample.generatedAt
            )
        }
        try? previewStore.replace(
            PortfolioPerformanceSnapshot(
                trackingStartDate: days.first?.date,
                days: days
            )
        )
        return previewStore
    }
#endif

    // 配置菜单栏状态项按钮：设置图标、响应左/右键事件、清除背景
    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = statusPulseImage
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp]) // 左键/右键都触发
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        statusItem.length = StatusItemPresentation.iconSize
    }

    // 刷新菜单栏标题文字（今日收益/涨跌幅）及其着色
    func updateStatusTitle(animated: Bool = false) {
        let presentation = currentStatusTitlePresentation()
        guard let button = statusItem.button else { return }
        button.toolTip = "red-fund"
        button.image = statusPulseImage
        button.imagePosition = .imageLeft
        button.attributedTitle = NSAttributedString(
            string: presentation.text,
            attributes: presentation.attributes
        )
        setStatusItemLength(for: presentation)
    }

    // 根据当前设置与持仓快照，计算菜单栏标题的"文字 + 属性 + 视觉宽度"
    private func currentStatusTitlePresentation() -> StatusTitlePresentation {
        let contentMode = settingsStore.settings.menuBarContentMode
        let amountValue = store.snapshot.todayIncome
        let rateValue = store.snapshot.todayIncomeRate
        let font = statusTitleFont()
        let statusText = MenuBarStatusFormatter.text(
            amount: amountValue,
            rate: rateValue,
            mode: contentMode
        )
        let toneValue = statusTitleToneValue(rate: rateValue)
        let attributes = statusTitleAttributes(for: toneValue, font: font)
        let visualLength = StatusItemPresentation.visualLength(
            for: statusText,
            attributes: attributes
        )

        return StatusTitlePresentation(
            text: statusText,
            attributes: attributes,
            visualLength: visualLength
        )
    }

    // 根据视觉宽度 + 系统内边距，设置状态项整体长度
    private func setStatusItemLength(for presentation: StatusTitlePresentation) {
        let systemButtonPadding: CGFloat = 10
        statusItem.length = ceil(presentation.visualLength + systemButtonPadding)
    }

    private func statusTitleFont() -> NSFont {
        return .systemFont(ofSize: NSFont.systemFontSize)
    }

    private func statusTitleToneValue(rate: Double) -> Double {
        rate // 涨跌幅本身作为"色调值"（正红负绿）
    }

    private func statusTitleAttributes(
        for value: Double,
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let color = statusTitleColor(for: value)
        return [
            .font: font,
            .foregroundColor: color
        ]
    }

    // 文字颜色：若开启"涨跌色"则红涨绿跌（A股习惯），否则用系统默认标签色
    private func statusTitleColor(for value: Double) -> NSColor {
        guard settingsStore.settings.menuBarDisplayMode.usesGrowthColor else {
            return .labelColor
        }

        if value > 0 { return .systemRed }
        if value < 0 { return .systemGreen }
        return .secondaryLabelColor
    }

    // 左键点击状态项：如果主面板已显示则关闭，否则弹出
    private func toggleMainPanelFromStatusItem() {
        if let mainPanelWindow, mainPanelWindow.isVisible {
            closeAllPanels()
        } else {
            showMainPanel()
        }
    }

    // 状态项点击事件：右键或 Ctrl+左键 => 弹出右键菜单；否则左键切换主面板
    @objc private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu(relativeTo: sender)
            return
        }

        toggleMainPanelFromStatusItem()
    }

    // 显示主面板：懒创建窗口、应用外观、加载数据、定位并前置、安装事件监听、刷新行情与更新
    private func showMainPanel() {
        let window = mainPanelWindow ?? createMainPanelWindow()
        applyPanelAppearance(to: window)
        setStatusItemHighlighted(true) // 图标高亮，表示面板已展开

        store.load()
        updateStatusTitle()
        sendFundThresholdRemindersIfNeeded()
        updateMainPanelRootView()
        mainPanelAnchorFrame = currentStatusButtonFrame() // 记录定位锚点（指向状态栏按钮）

        let size = mainPanelWindowSize
        window.setContentSize(size)
        positionMainPanel(window: window, size: size)
        window.orderFrontRegardless()
        window.makeKey()
        installEventMonitorsIfNeeded()

        refreshQuotesAndStatusTitle()
        updateStore.autoUpdateCheckEnabled = settingsStore.settings.autoUpdateCheckEnabled
        if settingsStore.settings.autoUpdateCheckEnabled {
            checkForUpdates()
        }
    }

    // 首次创建主面板窗口：设置收尾回调、HostingView，并应用外观
    private func createMainPanelWindow() -> RedFundPanel {
        let window = RedFundPanel()
        window.acceptsMouseMovedEvents = true
        window.onOrderOut = { [weak self] in
            self?.handleMainPanelDidHide()
        }
        window.onClose = { [weak self] in
            self?.handleMainPanelDidHide()
        }
        window.onCancel = { [weak self] in
            self?.closeAllPanels()
        }

        let hostingView = PanelFocusAppearance.hostingView(makeMainPanelRootView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.appearance = panelAppearance
        mainPanelHostingView = hostingView
        window.contentView = hostingView
        mainPanelWindow = window
        applyPanelAppearance(to: window)
        return window
    }

    // 重建主面板根视图（数据或设置变化后刷新内容）
    private func updateMainPanelRootView() {
        mainPanelHostingView?.rootView = PanelFocusAppearance.suppressedRoot(
            makeMainPanelRootView()
        )
    }

    // 构建主面板根视图，并把各类交互回调（刷新/设置/加基金/详情/买卖/更新等）连接到对应处理方法
    private func makeMainPanelRootView() -> MainPanelWindowView {
        MainPanelWindowView(
            store: store,
            settingsStore: settingsStore,
            marketIndexStore: marketIndexStore,
            updateStore: updateStore,
            uiState: popoverState,
            selectedFundCode: selectedFundCode,
            onRefresh: { [weak self] in
                await self?.refreshQuotesAndStatusTitleAsync(backfillTypes: true)
            },
            onOpenSettings: { [weak self] in
                self?.showChildPanel(.settings)
            },
            onClose: { [weak self] in
                self?.closeAllPanels()
            },
            onOpenPortfolioBreakdown: { [weak self] in
                self?.showChildPanel(.portfolioBreakdown)
            },
            onOpenTodayIncomeRanking: { [weak self] in
                self?.showChildPanel(.todayIncomeRanking(.amount))
            },
            onOpenTodayRateRanking: { [weak self] in
                self?.showChildPanel(.todayIncomeRanking(.rate))
            },
            onOpenHoldingIncomeRanking: { [weak self] in
                self?.holdingPerformancePage = .ranking
                self?.holdingPerformanceMetric = .amount
                self?.showChildPanel(.portfolioPerformance)
            },
            onOpenHoldingRateRanking: { [weak self] in
                self?.holdingPerformancePage = .ranking
                self?.holdingPerformanceMetric = .rate
                self?.showChildPanel(.portfolioPerformance)
            },
            onAddFund: { [weak self] in
                self?.showChildPanel(.addFund)
            },
            onOpenFundDetail: { [weak self] fund in
                self?.showChildPanel(.fundDetail(fundCode: fund.code))
            },
            onOpenTradeRecords: { [weak self] fund in
                self?.showChildPanel(.tradeRecords(fundCode: fund.code))
            },
            onOpenPendingActivity: { [weak self] activity in
                self?.showPendingActivity(activity)
            },
            onDeletePendingActivity: { [weak self] activity in
                await self?.deletePendingActivity(activity)
            },
            onBuyFund: { [weak self] fund in
                self?.showChildPanel(.buyFund(fundCode: fund.code))
            },
            onSellFund: { [weak self] fund in
                self?.showChildPanel(.sellFund(fundCode: fund.code))
            },
            onEditFund: { [weak self] fund in
                self?.showChildPanel(.editFund(fundCode: fund.code))
            },
            onDeleteFund: { [weak self] fund in
                await self?.deleteFund(fund)
            },
            onCheckUpdate: { [weak self] in
                await self?.onCheckUpdate(.interactive)
            },
            onOpenUpdate: { [weak self] in
                self?.onOpenUpdate()
            }
        )
    }

    // 弹出指定的子面板（路由）。流程：确保主面板已开 -> 处理京东面板归属 -> 校验路由有效性 -> 构建内容 -> 定位并前置
    private func showChildPanel(_ route: ChildPanelRoute) {
        // 若主面板还没开，先开主面板（子面板附在其右侧）
        if mainPanelWindow?.isVisible != true {
            showMainPanel()
        }

        // 切换到一个不归属京东登录面板的新路由时，先收起京东面板
        if let activeChildPanel,
           activeChildPanel.ownsJDFinanceLoginPanel,
           activeChildPanel != route {
            hideJDFinanceLoginPanel(reportCancellation: false)
        }

        // 路由校验：数据缺失时可能"关闭"或"重定向"到一个兜底路由
        switch ChildPanelRouteResolver.disposition(for: route, in: store.snapshot) {
        case .available:
            break
        case .redirect(let fallbackRoute):
            showChildPanel(fallbackRoute)
            return
        case .close:
            hideChildPanel()
            return
        }

        // 根据路由构建对应的 SwiftUI 视图与尺寸
        guard let (contentView, size) = makeChildPanelContent(for: route) else { return }
        activeChildPanel = route
        selectedFundCode = route.selectedFundCode
        updateMainPanelRootView() // 让主面板知道当前选中的基金/子面板，用于高亮等

        if case .fundDetail = route {
            // 进入基金详情时立即刷新一次行情，避免估值停留在上一次成功刷新的结果。
            refreshQuotesAndStatusTitle()
        }

        let window = childPanelWindow ?? createChildPanelWindow()
        let container = PanelCardContainerView(contentView: contentView)
        container.frame = NSRect(origin: .zero, size: size)
        container.applyAppearance(panelAppearance)
        window.contentView = container
        applyPanelAppearance(to: window)
        window.setContentSize(size)
        positionChildPanel(window: window, size: size) // 定位到主面板右侧（空间不足则左侧）
        window.orderFrontRegardless()
        window.makeKey()
        installEventMonitorsIfNeeded()
    }

    // 弹出"京东金融持仓同步"面板（从主面板"导入/同步"入口调用）
    private func showJDFinanceSyncPanel() {
        showChildPanel(.jdFinanceSync)
    }

    private func createChildPanelWindow() -> RedFundPanel {
        let window = RedFundPanel()
        window.acceptsMouseMovedEvents = true
        window.onOrderOut = { [weak self] in
            self?.clearChildPanelState()
        }
        window.onClose = { [weak self] in
            self?.clearChildPanelState()
        }
        window.onCancel = { [weak self] in
            self?.handleChildPanelCancel()
        }
        childPanelWindow = window
        return window
    }

    // 弹出京东金融登录网页面板，并把登录完成后的回调保存下来
    private func showJDFinanceLoginPanel(onLoggedIn: @escaping (String?) -> Void) {
        jdFinanceLoginCompletion = onLoggedIn

        let window = jdFinanceLoginWindow ?? createJDFinanceLoginWindow()
        let view = JDFinanceLoginPanelView(
            onLoggedIn: { [weak self] cookieHeader in
                self?.completeJDFinanceLogin(cookieHeader: cookieHeader)
            },
            onClose: { [weak self] in
                self?.hideJDFinanceLoginPanel(reportCancellation: true)
            }
        )
        let size = PopoverLayout.jdFinanceLoginSize
        let container = PanelCardContainerView(contentView: PanelFocusAppearance.hostingView(view))
        container.frame = NSRect(origin: .zero, size: size)
        container.applyAppearance(panelAppearance)
        window.contentView = container
        applyPanelAppearance(to: window)
        window.setContentSize(size)
        positionJDFinanceLoginPanel(window: window, size: size)
        window.orderFrontRegardless()
        window.makeKey()
        installEventMonitorsIfNeeded()
    }

    // 弹出京东金融"网页调试/网络探测"面板（用于排查同步接口）
    private func showJDFinanceNetworkProbePanel(networkProbe: JDFinanceNetworkProbe) {
        jdFinanceLoginCompletion = nil

        let window = jdFinanceLoginWindow ?? createJDFinanceLoginWindow()
        let view = JDFinanceLoginPanelView(
            title: "京东金融网页调试",
            initialURL: JDFinanceWebSession.tradeOrderURL,
            reloadButtonTitle: "刷新网页",
            autoCompleteLogin: false,
            networkProbe: networkProbe,
            onLoggedIn: { _ in },
            onClose: { [weak self, weak networkProbe] in
                networkProbe?.clear()
                self?.hideJDFinanceLoginPanel(reportCancellation: false)
            }
        )
        let size = PopoverLayout.jdFinanceNetworkProbeSize
        let container = PanelCardContainerView(contentView: PanelFocusAppearance.hostingView(view))
        container.frame = NSRect(origin: .zero, size: size)
        container.applyAppearance(panelAppearance)
        window.contentView = container
        applyPanelAppearance(to: window)
        window.setContentSize(size)
        positionJDFinanceLoginPanel(window: window, size: size)
        window.orderFrontRegardless()
        window.makeKey()
        installEventMonitorsIfNeeded()
    }

    private func createJDFinanceLoginWindow() -> RedFundPanel {
        let window = RedFundPanel()
        window.acceptsMouseMovedEvents = true
        window.onOrderOut = { [weak self] in
            self?.jdFinanceLoginCompletion = nil
        }
        window.onClose = { [weak self] in
            self?.hideJDFinanceLoginPanel(reportCancellation: true)
        }
        window.onCancel = { [weak self] in
            self?.hideJDFinanceLoginPanel(reportCancellation: true)
        }
        jdFinanceLoginWindow = window
        return window
    }

    // 登录成功：取出并清空回调、收起面板、把拿到的 cookie 头部回传
    private func completeJDFinanceLogin(cookieHeader: String) {
        let completion = jdFinanceLoginCompletion
        jdFinanceLoginCompletion = nil
        jdFinanceLoginWindow?.orderOut(nil)
        completion?(cookieHeader)
    }

    // 收起京东登录面板；reportCancellation=true 时以 nil 回调表示"用户取消"
    private func hideJDFinanceLoginPanel(reportCancellation: Bool = false) {
        let completion = jdFinanceLoginCompletion
        jdFinanceLoginCompletion = nil
        jdFinanceLoginWindow?.orderOut(nil)
        if reportCancellation {
            completion?(nil)
        }
    }

    // 工厂方法：根据路由返回"对应的 SwiftUI 视图 + 推荐尺寸"。每个 case 对应一个业务面板。
    private func makeChildPanelContent(for route: ChildPanelRoute) -> (NSView, NSSize)? {
        switch route {
        // 隐私声明页：返回上一页（设置/引导）
        case .privacyDisclaimer(let origin):
            let view = PrivacyDisclaimerView(
                onBack: { [weak self] in
                    self?.returnFromPrivacyDisclaimer(origin)
                },
                onOpenURL: { url in
                    NSWorkspace.shared.open(url)
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.privacyDisclaimerSize)

        case .onboarding(let origin):
            let view = OnboardingView(
                initialStep: onboardingResumeStep,
                onAddFund: { [weak self] in
                    self?.showChildPanel(.onboardingAddFund(origin: origin))
                },
                onImportPortfolio: { [weak self] in
                    guard let self, importFundConfiguration() else { return }
                    finishOnboarding(origin)
                },
                onOpenSample: { [weak self] in
                    self?.showChildPanel(.sampleExperience(origin: origin))
                },
                onStartEmpty: { [weak self] in
                    self?.finishOnboarding(origin)
                },
                onOpenPrivacy: { [weak self] in
                    self?.onboardingResumeStep = 1
                    self?.showChildPanel(.privacyDisclaimer(origin: .onboarding(origin)))
                },
                onClose: { [weak self] in
                    self?.closeOnboarding(origin)
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.onboardingSize)

        case .sampleExperience(let origin):
            let view = SampleExperienceView(
                onClose: { [weak self] in
                    self?.onboardingResumeStep = 2
                    self?.showChildPanel(.onboarding(origin: origin))
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.sampleExperienceSize)

        case .portfolioPerformance:
            let view = PortfolioPerformanceView(
                portfolioStore: store,
                store: performanceStoreForPresentation,
                initialPage: holdingPerformancePage,
                initialRankingMetric: holdingPerformanceMetric,
                initialRange: holdingPerformanceRange,
                initialDisplayedMonth: holdingPerformanceMonth,
                betaFeaturesEnabled: settingsStore.settings.betaFeaturesEnabled,
                onOpenJDFinanceSync: { [weak self] in
                    self?.showChildPanel(.jdFinancePerformanceSync)
                },
                onNavigationChange: { [weak self] page, metric, range, month in
                    self?.holdingPerformancePage = page
                    self?.holdingPerformanceMetric = metric
                    self?.holdingPerformanceRange = range
                    self?.holdingPerformanceMonth = month
                },
                onBack: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.portfolioPerformanceSize)

        case .jdFinancePerformanceSync:
            let view = JDFinancePerformanceSyncView(
                portfolioStore: store,
                performanceStore: performanceStoreForPresentation,
                onRequestLogin: { [weak self] completion in
                    self?.showJDFinanceLoginPanel(onLoggedIn: completion)
                },
                onClose: { [weak self] in
                    self?.showChildPanel(.portfolioPerformance)
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.jdFinancePerformanceSyncSize)

        case .settings:
            let view = SettingsView(
                store: store,
                settingsStore: settingsStore,
                updateStore: updateStore,
                appVersion: appVersion,
                onSettingsChanged: { [weak self] in
                    self?.handleSettingsChanged()
                },
                onRefresh: { [weak self] in
                    await self?.refreshQuotesAndStatusTitleAsync(backfillTypes: true)
                },
                onCheckUpdate: { [weak self] in
                    await self?.onCheckUpdate(.interactive)
                },
                onOpenJDFinanceSync: { [weak self] in
                    self?.showJDFinanceSyncPanel()
                },
                onOpenPrivacyDisclaimer: { [weak self] in
                    self?.showChildPanel(.privacyDisclaimer(origin: .settings))
                },
                onOpenOnboarding: { [weak self] in
                    self?.showChildPanel(.onboarding(origin: .settings))
                },
                onOpenExternalURL: { url in
                    NSWorkspace.shared.open(url)
                },
                initialSection: settingsSectionSession.selectedSection,
                onSectionChanged: { [weak self] section in
                    self?.settingsSectionSession.select(section)
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.settingsSize)

        case .jdFinanceSync:
            let view = JDFinanceHoldingsSyncView(
                portfolioStore: store,
                onRequestLogin: { [weak self] completion in
                    self?.showJDFinanceLoginPanel(onLoggedIn: completion)
                },
                onRequestNetworkProbe: { [weak self] networkProbe in
                    self?.showJDFinanceNetworkProbePanel(networkProbe: networkProbe)
                },
                onMainPanelRefreshNeeded: { [weak self] in
                    self?.refreshQuotesAndStatusTitle()
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.jdFinanceSyncSize)

        case .portfolioBreakdown:
            let view = PortfolioAllocationPanelView(
                store: store,
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.portfolioBreakdownSize)

        case .todayIncomeRanking(let metric):
            let view = TodayIncomeRankingPanelView(
                store: store,
                kind: .today,
                metric: metric,
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.todayIncomeRankingSize)

        case .addFund:
            let view = FundPositionEditorView(
                store: store,
                fund: nil,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.editorSize)

        case .onboardingAddFund(let origin):
            let flowState = OnboardingAddFlowState()
            let view = FundPositionEditorView(
                store: store,
                fund: nil,
                onSaved: { [weak self, flowState] in
                    await MainActor.run {
                        flowState.didSave = true
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self, flowState] in
                    guard let self else { return }
                    if flowState.didSave {
                        finishOnboarding(origin)
                    } else {
                        onboardingResumeStep = 2
                        showChildPanel(.onboarding(origin: origin))
                    }
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.editorSize)

        case .fundDetail(let fundCode):
            let view = FundDetailView(
                store: store,
                fundCode: fundCode,
                onBuy: { [weak self] fund in
                    self?.childPanelReturnRoute = .fundDetail(fundCode: fund.code)
                    self?.showChildPanel(.buyFund(fundCode: fund.code))
                },
                onSell: { [weak self] fund in
                    self?.childPanelReturnRoute = .fundDetail(fundCode: fund.code)
                    self?.showChildPanel(.sellFund(fundCode: fund.code))
                },
                onConvert: { [weak self] fund in
                    self?.childPanelReturnRoute = .fundDetail(fundCode: fund.code)
                    self?.showChildPanel(.convertFund(fundCode: fund.code))
                },
                onEdit: { [weak self] fund in
                    self?.childPanelReturnRoute = .fundDetail(fundCode: fund.code)
                    self?.showChildPanel(.editFund(fundCode: fund.code))
                },
                onOpenTradeRecords: { [weak self] fund in
                    self?.showChildPanel(.tradeRecords(fundCode: fund.code))
                },
                onOpenDailyIncome: { [weak self] fund in
                    self?.showChildPanel(.fundDailyIncome(fundCode: fund.code))
                },
                onDelete: { [weak self] fund in
                    await self?.deleteFund(fund)
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.fundDetailSize)

        case .fundDailyIncome(let fundCode):
            let view = FundDailyIncomePanelView(
                store: store,
                fundCode: fundCode,
                onClose: { [weak self] in
                    self?.showChildPanel(.fundDetail(fundCode: fundCode))
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.fundDailyIncomeSize)

        case .tradeRecords(let fundCode):
            let view = FundTradeRecordsPanelView(
                store: store,
                fundCode: fundCode,
                onEdit: { [weak self] record in
                    if record.kind == .conversionOut || record.kind == .conversionIn {
                        let sourceCode = record.kind == .conversionOut ? record.code : (record.linkedCode ?? fundCode)
                        self?.showChildPanel(
                            .editConversion(
                                sourceFundCode: sourceCode,
                                recordID: record.id,
                                returnFundCode: fundCode
                            )
                        )
                    } else {
                        self?.showChildPanel(.editTradeRecord(fundCode: fundCode, recordID: record.id))
                    }
                },
                onDelete: { [weak self] record in
                    await self?.deleteTradeRecord(record, returningToFundCode: fundCode)
                },
                onClose: { [weak self] in
                    self?.showChildPanel(.fundDetail(fundCode: fundCode))
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeRecordsSize)

        case .buyFund(let fundCode):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }) else { return nil }
            let view = FundTradeEditorView(
                store: store,
                fund: fund,
                action: .buy,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self] in
                    self?.dismissChildPanelToReturnRoute()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .sellFund(let fundCode):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }) else { return nil }
            let view = FundTradeEditorView(
                store: store,
                fund: fund,
                action: .sell,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self] in
                    self?.dismissChildPanelToReturnRoute()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .convertFund(let fundCode):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }) else { return nil }
            let view = FundConversionEditorView(
                store: store,
                sourceFund: fund,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self] in
                    self?.dismissChildPanelToReturnRoute()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .editTradeRecord(let fundCode, let recordID):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }),
                  let record = store.snapshot.tradeRecords?.first(where: { $0.id == recordID })
            else { return nil }
            let action: FundTradeAction = record.kind == .sell ? .sell : .buy
            let view = FundTradeEditorView(
                store: store,
                fund: fund,
                action: action,
                editingRecord: record,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                        self?.showChildPanel(.tradeRecords(fundCode: fundCode))
                    }
                },
                onClose: { [weak self] in
                    self?.showChildPanel(.tradeRecords(fundCode: fundCode))
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .editConversion(let sourceFundCode, let recordID, let returnFundCode):
            guard let fund = store.snapshot.funds.first(where: { $0.code == sourceFundCode }),
                  let record = store.snapshot.tradeRecords?.first(where: { $0.id == recordID })
            else { return nil }
            let view = FundConversionEditorView(
                store: store,
                sourceFund: fund,
                editingRecord: record,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                        self?.showChildPanel(.tradeRecords(fundCode: returnFundCode))
                    }
                },
                onClose: { [weak self] in
                    self?.showChildPanel(.tradeRecords(fundCode: returnFundCode))
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .editPendingTradeRecord(let fundCode, let recordID):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }),
                  let record = store.snapshot.tradeRecords?.first(where: { $0.id == recordID })
            else { return nil }
            let action: FundTradeAction = record.kind == .sell ? .sell : .buy
            let view = FundTradeEditorView(
                store: store,
                fund: fund,
                action: action,
                editingRecord: record,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                        self?.hideChildPanel()
                    }
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .editPendingConversion(let fundCode, let recordID):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }),
                  let record = store.snapshot.tradeRecords?.first(where: { $0.id == recordID })
            else { return nil }
            let view = FundConversionEditorView(
                store: store,
                sourceFund: fund,
                editingRecord: record,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                        self?.hideChildPanel()
                    }
                },
                onClose: { [weak self] in
                    self?.hideChildPanel()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.tradeEditorSize)

        case .editFund(let fundCode):
            guard let fund = store.snapshot.funds.first(where: { $0.code == fundCode }) else { return nil }
            let view = FundPositionEditorView(
                store: store,
                fund: fund,
                onSaved: { [weak self] in
                    await MainActor.run {
                        self?.updateStatusTitle()
                        self?.sendFundThresholdRemindersIfNeeded()
                    }
                },
                onClose: { [weak self] in
                    self?.dismissChildPanelToReturnRoute()
                }
            )
            return (PanelFocusAppearance.hostingView(view), PopoverLayout.editorSize)
        }
    }

    // 根据"待确认交易活动"找到对应记录/基金，弹出合适的编辑面板
    // （优先按记录 ID / 转换 ID 匹配，否则按"待确认+代码+类型+日期"匹配，实在没有则按活动类型开新建面板）
    private func showPendingActivity(_ activity: PendingTradeActivity) {
        // 从主面板"待确认活动"进入的编辑面板，取消后应回到主面板（无返回路由）
        childPanelReturnRoute = nil
        let records = store.snapshot.tradeRecords ?? []
        let matchingRecord = pendingActivityRecord(activity, records: records)
        let matchingFund = activity.fund ?? store.snapshot.funds.first { $0.code == activity.code }

        if let record = matchingRecord {
            // 转换类记录：定位源基金，弹出"编辑待确认转换"面板
            if record.kind == .conversionOut || record.kind == .conversionIn {
                let sourceCode = record.kind == .conversionOut ? record.code : (record.linkedCode ?? activity.code)
                guard store.snapshot.funds.contains(where: { $0.code == sourceCode }) || matchingFund?.code == sourceCode else {
                    return
                }
                showChildPanel(.editPendingConversion(fundCode: sourceCode, recordID: record.id))
            } else if let fund = store.snapshot.funds.first(where: { $0.code == record.code }) ?? matchingFund {
                // 普通买卖记录：弹出"编辑待确认交易"面板
                showChildPanel(.editPendingTradeRecord(fundCode: fund.code, recordID: record.id))
            }
            return
        }

        // 未匹配到已有记录：按活动类型直接打开新增/买卖/转换面板
        guard let fund = matchingFund else { return }
        switch activity.kind {
        case .sell:
            showChildPanel(.sellFund(fundCode: fund.code))
        case .conversionOut, .conversionIn:
            showChildPanel(.convertFund(fundCode: fund.code))
        case .newFund:
            showChildPanel(.editFund(fundCode: fund.code))
        case .buy:
            showChildPanel(.buyFund(fundCode: fund.code))
        }
    }

    // 在交易记录中查找与"待确认活动"匹配的那条：先按记录 ID，再按转换 ID，最后按多字段组合匹配
    private func pendingActivityRecord(
        _ activity: PendingTradeActivity,
        records: [FundTradeRecord]
    ) -> FundTradeRecord? {
        if let recordID = activity.recordID,
           let record = records.first(where: { $0.id == recordID }) {
            return record
        }

        if let conversionID = activity.conversionID,
           let record = records.first(where: { $0.conversionID == conversionID && $0.kind == .conversionOut })
                ?? records.first(where: { $0.conversionID == conversionID }) {
            return record
        }

        return records.first {
            $0.status == .pending
                && $0.code == activity.code
                && $0.kind == activity.kind
                && $0.tradeDate == activity.tradeDate
                && $0.tradeTimeType == activity.tradeTimeType
        }
    }

    // 收起子面板（若其归属于京东登录面板，先收起京东面板），并清理子面板状态
    private func hideChildPanel() {
        if activeChildPanel?.ownsJDFinanceLoginPanel == true {
            hideJDFinanceLoginPanel(reportCancellation: false)
        }
        childPanelWindow?.orderOut(nil)
        clearChildPanelState()
    }

    /// 关闭交易/编辑类子面板时"返回上一步"：若存在返回路由则回到对应面板（如基金详情），否则直接关闭回到主面板。
    /// 用于修正"在基金详情页点加仓/减仓/编辑后取消，却直接关掉详情页"的问题。
    private func dismissChildPanelToReturnRoute() {
        if let returnRoute = childPanelReturnRoute {
            childPanelReturnRoute = nil
            showChildPanel(returnRoute)
        } else {
            hideChildPanel()
        }
    }

    // 隐私声明页"返回"：根据来源回到设置或引导
    private func returnFromPrivacyDisclaimer(_ origin: PrivacyDisclaimerOrigin) {
        switch origin {
        case .settings:
            showChildPanel(.settings)
        case .onboarding(let onboardingOrigin):
            showChildPanel(.onboarding(origin: onboardingOrigin))
        }
    }

    // 关闭引导：首次启动则直接收起；从设置进入则回到设置
    private func closeOnboarding(_ origin: OnboardingOrigin) {
        switch origin {
        case .firstLaunch:
            hideChildPanel()
        case .settings:
            showChildPanel(.settings)
        }
    }

    // 完成引导：首次启动需写入"已完成引导"标记；从设置进入则回到设置
    private func finishOnboarding(_ origin: OnboardingOrigin) {
        switch origin {
        case .firstLaunch:
            do {
                try settingsStore.completeOnboarding()
                onboardingResumeStep = 0
                hideChildPanel()
            } catch {
                presentConfigurationError(title: "保存首次设置失败", error: error)
            }
        case .settings:
            onboardingResumeStep = 0
            showChildPanel(.settings)
        }
    }

    // 按 Esc 或系统取消时，依据当前子面板类型决定"返回到哪一层"（详情/引导/设置等）
    private func handleChildPanelCancel() {
        if case .tradeRecords(let fundCode) = activeChildPanel {
            showChildPanel(.fundDetail(fundCode: fundCode))
        } else if case .fundDailyIncome(let fundCode) = activeChildPanel {
            showChildPanel(.fundDetail(fundCode: fundCode))
        } else if case .sampleExperience(let origin) = activeChildPanel {
            onboardingResumeStep = 2
            showChildPanel(.onboarding(origin: origin))
        } else if case .privacyDisclaimer(let origin) = activeChildPanel {
            returnFromPrivacyDisclaimer(origin)
        } else if case .onboardingAddFund(let origin) = activeChildPanel {
            onboardingResumeStep = 2
            showChildPanel(.onboarding(origin: origin))
        } else if case .onboarding(let origin) = activeChildPanel {
            closeOnboarding(origin)
        } else if case .jdFinancePerformanceSync = activeChildPanel {
            showChildPanel(.portfolioPerformance)
        } else {
            hideChildPanel()
        }
    }

    // 主面板被隐藏（orderOut/close）时：收起京东面板与子面板、清理状态、移除监听、取消高亮
    private func handleMainPanelDidHide() {
        hideJDFinanceLoginPanel(reportCancellation: true)
        childPanelWindow?.orderOut(nil)
        clearChildPanelState()
        mainPanelAnchorFrame = nil
        removeEventMonitors()
        setStatusItemHighlighted(false)
    }

    // 关闭所有面板（主 + 子 + 京东），并清理监听与高亮
    private func closeAllPanels() {
        hideJDFinanceLoginPanel(reportCancellation: true)
        mainPanelWindow?.orderOut(nil)
        childPanelWindow?.orderOut(nil)
        clearChildPanelState()
        mainPanelAnchorFrame = nil
        removeEventMonitors()
        setStatusItemHighlighted(false)
    }

    // 清空子面板状态；若此前有打开的面板/选中基金，则刷新主面板根视图以更新高亮
    private func clearChildPanelState() {
        let shouldRefreshMainPanel = activeChildPanel != nil || selectedFundCode != nil
        activeChildPanel = nil
        selectedFundCode = nil
        if shouldRefreshMainPanel {
            updateMainPanelRootView()
        }
    }

    private func refreshVisiblePanels() {
        refreshVisiblePanels(animatedAppearance: false)
    }

    // 持仓快照变化后：先校验当前子面板路由是否仍然有效，再重绘可见面板
    private func handleStoreSnapshotChanged() {
        reconcileActiveChildPanelRoute()
        refreshVisiblePanels()
    }

    // 若当前子面板依赖的数据已不存在，按 resolver 结果重定向或关闭
    private func reconcileActiveChildPanelRoute() {
        guard let route = activeChildPanel else { return }
        switch ChildPanelRouteResolver.disposition(for: route, in: store.snapshot) {
        case .available:
            return
        case .redirect(let fallbackRoute):
            showChildPanel(fallbackRoute)
        case .close:
            hideChildPanel()
        }
    }

    // 重新应用外观并调整主/子面板尺寸与位置（设置变更、外观切换时调用）
    private func refreshVisiblePanels(animatedAppearance: Bool) {
        guard let mainPanelWindow, mainPanelWindow.isVisible else { return }
        applyPanelAppearance(to: mainPanelWindow, animated: animatedAppearance)
        let mainSize = mainPanelWindowSize
        mainPanelWindow.setContentSize(mainSize)
        positionMainPanel(window: mainPanelWindow, size: mainSize)

        guard let childPanelWindow, childPanelWindow.isVisible else { return }
        applyPanelAppearance(to: childPanelWindow, animated: animatedAppearance)
        // 根据当前子面板路由选取对应尺寸
        let size: NSSize
        switch activeChildPanel {
        case .settings:
            size = PopoverLayout.settingsSize
        case .privacyDisclaimer:
            size = PopoverLayout.privacyDisclaimerSize
        case .onboarding:
            size = PopoverLayout.onboardingSize
        case .sampleExperience:
            size = PopoverLayout.sampleExperienceSize
        case .portfolioPerformance:
            size = PopoverLayout.portfolioPerformanceSize
        case .jdFinancePerformanceSync:
            size = PopoverLayout.jdFinancePerformanceSyncSize
        case .jdFinanceSync:
            size = PopoverLayout.jdFinanceSyncSize
        case .portfolioBreakdown:
            size = PopoverLayout.portfolioBreakdownSize
        case .todayIncomeRanking:
            size = PopoverLayout.todayIncomeRankingSize
        case .fundDetail:
            size = PopoverLayout.fundDetailSize
        case .fundDailyIncome:
            size = PopoverLayout.fundDailyIncomeSize
        case .tradeRecords:
            size = PopoverLayout.tradeRecordsSize
        case .addFund, .onboardingAddFund, .editFund:
            size = PopoverLayout.editorSize
        case .buyFund, .sellFund, .convertFund, .editTradeRecord, .editConversion, .editPendingTradeRecord, .editPendingConversion:
            size = PopoverLayout.tradeEditorSize
        case nil:
            return
        }
        childPanelWindow.setContentSize(size)
        positionChildPanel(window: childPanelWindow, size: size)
    }

    // 仅重新设定主面板尺寸与位置（如高度设置变化）
    private func resizeAndPositionMainPanel() {
        guard let mainPanelWindow, mainPanelWindow.isVisible else { return }
        let mainSize = mainPanelWindowSize
        mainPanelWindow.setContentSize(mainSize)
        positionMainPanel(window: mainPanelWindow, size: mainSize)
    }

    // 把当前外观应用到窗口及其内容视图（可选做明暗过渡动画）
    private func applyPanelAppearance(to window: RedFundPanel) {
        applyPanelAppearance(to: window, animated: false)
    }

    private func applyPanelAppearance(to window: RedFundPanel, animated: Bool) {
        if animated {
            installAppearanceTransitionOverlay(on: window) // 先盖一层过渡遮罩
        }

        let appearance = panelAppearance
        window.appearance = appearance
        window.contentView?.appearance = appearance
        mainPanelHostingView?.appearance = appearance
        if let container = window.contentView as? PanelCardContainerView {
            container.applyAppearance(appearance)
        }

        if animated {
            fadeOutAppearanceTransitionOverlay(on: window) // 再淡出遮罩，形成平滑切换
        }
    }

    // 在窗口上叠加一层渐变遮罩（用于外观切换时不出现硬跳变）
    private func installAppearanceTransitionOverlay(on window: RedFundPanel) {
        guard let contentView = window.contentView else { return }
        // 先移除旧的遮罩，避免叠加
        contentView.subviews
            .filter { $0.identifier == appearanceTransitionOverlayIdentifier }
            .forEach { $0.removeFromSuperview() }

        let overlay = AppearanceTransitionOverlayView(appearance: window.effectiveAppearance)
        overlay.identifier = appearanceTransitionOverlayIdentifier
        overlay.frame = contentView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.alphaValue = 1
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    // 把遮罩淡出后移除
    private func fadeOutAppearanceTransitionOverlay(on window: RedFundPanel) {
        guard let contentView = window.contentView else { return }
        let overlays = contentView.subviews.filter { $0.identifier == appearanceTransitionOverlayIdentifier }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlays.forEach { overlay in
                overlay.animator().alphaValue = 0
            }
        } completionHandler: {
            Task { @MainActor in
                overlays.forEach { $0.removeFromSuperview() }
            }
        }
    }

    // 安装事件监听：本地（应用内点击/按键）、全局（屏外点击）、失活通知。只装一次。
    private func installEventMonitorsIfNeeded() {
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                self?.handleLocalPanelEvent(event) ?? event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                DispatchQueue.main.async {
                    self?.handlePanelEvent(event, screenLocation: event.locationInWindow)
                }
            }
        }

        if deactivateObserver == nil {
            deactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.closeAllPanels()
                }
            }
        }
    }

    // 移除所有事件监听与通知观察者
    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let deactivateObserver {
            NotificationCenter.default.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
    }

    // 应用内事件处理：Esc 关闭全部；鼠标按下时判断是否点在面板外需要收起
    private func handleLocalPanelEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { // 53 = Esc
            closeAllPanels()
            return nil
        }

        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              let location = event.window?.convertPoint(toScreen: event.locationInWindow)
        else {
            return event
        }

        handlePanelEvent(event, screenLocation: location)
        return event
    }

    // 点窗外/面板外时关闭所有面板（但点在面板内、状态栏按钮内或辅助浮层内则不关闭）
    private func handlePanelEvent(_ event: NSEvent, screenLocation: NSPoint) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if PanelAuxiliaryPopoverRegistry.handlePanelMouseDown(at: screenLocation) {
                return
            }
            guard !pointIsInsideManagedPanels(screenLocation), !pointIsInsideStatusButton(screenLocation) else { return }
            closeAllPanels()
        default:
            break
        }
    }

    // 判断屏幕坐标是否落在任一受管面板（主/子/京东）或其"走廊"区域内
    private func pointIsInsideManagedPanels(_ point: NSPoint) -> Bool {
        if let mainPanelWindow, mainPanelWindow.isVisible, mainPanelWindow.frame.contains(point) {
            return true
        }
        if let childPanelWindow, childPanelWindow.isVisible, childPanelWindow.frame.contains(point) {
            return true
        }
        if let jdFinanceLoginWindow, jdFinanceLoginWindow.isVisible, jdFinanceLoginWindow.frame.contains(point) {
            return true
        }
        // 主/子面板之间若形成一块重叠"走廊"，也算面板内部，避免点到缝隙关闭
        if let mainPanelWindow,
           let childPanelWindow,
           mainPanelWindow.isVisible,
           childPanelWindow.isVisible {
            let mainFrame = mainPanelWindow.frame
            let childFrame = childPanelWindow.frame
            let corridorMinX = min(mainFrame.maxX, childFrame.maxX)
            let corridorMaxX = max(mainFrame.minX, childFrame.minX)
            let corridorMinY = min(mainFrame.minY, childFrame.minY)
            let corridorMaxY = max(mainFrame.maxY, childFrame.maxY)

            if corridorMaxX > corridorMinX {
                let corridor = NSRect(
                    x: corridorMinX,
                    y: corridorMinY,
                    width: corridorMaxX - corridorMinX,
                    height: corridorMaxY - corridorMinY
                )
                if corridor.contains(point) {
                    return true
                }
            }
        }
        return false
    }

    // 判断坐标是否落在状态栏按钮附近（含 4pt 外扩点击区）
    private func pointIsInsideStatusButton(_ point: NSPoint) -> Bool {
        guard let frame = currentStatusButtonFrame() else { return false }
        return frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    // 把主面板定位到状态栏按钮下方（水平居中于按钮，并约束在可见屏幕内）；同时更新小三角位置
    private func positionMainPanel(window: NSWindow, size: NSSize) {
        guard let anchorFrame = mainPanelAnchorFrame ?? currentStatusButtonFrame() else { return }
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var originX = anchorFrame.midX - size.width / 2
        var originY = anchorFrame.minY - size.height - 5

        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        originY = max(visibleFrame.minY + 8, originY)

        popoverState.arrowX = anchorFrame.midX - originX // 让小三角指向按钮中心
        window.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
    }

    // 子面板定位到主面板右侧（若超出屏幕右边界则翻到左侧）
    private func positionChildPanel(window: NSWindow, size: NSSize) {
        guard let mainPanelWindow else { return }
        let visibleFrame = mainPanelWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var originX = mainPanelWindow.frame.maxX + PopoverLayout.panelGap
        if originX + size.width > visibleFrame.maxX - 8 {
            originX = mainPanelWindow.frame.minX - PopoverLayout.panelGap - size.width
        }

        var originY = mainPanelWindow.frame.maxY - PopoverLayout.arrowHeight - size.height
        originY = min(originY, visibleFrame.maxY - size.height - 8)
        originY = max(originY, visibleFrame.minY + 8)

        window.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
    }

    // 京东登录面板居中显示于屏幕
    private func positionJDFinanceLoginPanel(window: NSWindow, size: NSSize) {
        let visibleFrame = mainPanelWindow?.screen?.visibleFrame
            ?? statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero

        let originX = min(
            max(visibleFrame.midX - size.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let originY = min(
            max(visibleFrame.midY - size.height / 2, visibleFrame.minY + 8),
            visibleFrame.maxY - size.height - 8
        )
        window.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
    }

    // 取得状态栏按钮在屏幕坐标系下的矩形（用于定位与命中测试）
    private func currentStatusButtonFrame() -> NSRect? {
        guard let button = statusItem.button,
              let window = button.window
        else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // 设置状态栏图标是否高亮（面板展开时给一个半透明背景圆）
    private func setStatusItemHighlighted(_ isHighlighted: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = min(button.bounds.width, button.bounds.height) / 2
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = isHighlighted
            ? statusItemHighlightColor().cgColor
            : NSColor.clear.cgColor
        button.needsDisplay = true
    }

    private func statusItemHighlightColor() -> NSColor {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.08)
    }

    // 构建并弹出右键上下文菜单：版本信息、刷新、更新、设置、菜单栏显示配置、导入/导出、退出
    private func showContextMenu(relativeTo sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(disabledMenuItem("red-fund v\(appVersion)")) // 顶部版本号（禁用项）
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "刷新基金数据", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())

        addUpdateMenuItems(to: menu) // 动态更新的"检查更新/下载/安装"项

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        addMenuBarConfigurationMenuItems(to: menu) // "显示内容""涨跌颜色"两个子菜单
        menu.addItem(NSMenuItem(title: "导入基金配置", action: #selector(importFundConfigurationFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "导出基金配置", action: #selector(exportFundConfigurationFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self // 让菜单项把 action 发回本控制器
        }

        closeAllPanels() // 弹出菜单前先收起面板
        startContextMenuUpdateRefresh() // 开始轮询更新状态，让菜单项显示动画
        let startedUpdateCheck = checkForUpdatesFromContextMenu() // 菜单刚开时同步触发一次更新检查
        if startedUpdateCheck {
            // 若刚启动检查，稍等一帧再弹出，避免菜单初始渲染与状态刷新打架
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.popUpContextMenu(menu)
            }
            return
        }
        popUpContextMenu(menu)
    }

    // 通过未公开 API popUpStatusItemMenu: 在状态项上弹出菜单
    private func popUpContextMenu(_ menu: NSMenu) {
        let popUpMenuSelector = NSSelectorFromString("popUpStatusItemMenu:")
        _ = statusItem.perform(popUpMenuSelector, with: menu)
    }

    // 往菜单里添加"显示内容""涨跌颜色"两个带子菜单的项
    private func addMenuBarConfigurationMenuItems(to menu: NSMenu) {
        let contentItem = NSMenuItem(title: "显示内容", action: nil, keyEquivalent: "")
        contentItem.submenu = makeMenuBarContentModeMenu()
        contentItem.isEnabled = true
        menu.addItem(contentItem)

        let displayItem = NSMenuItem(title: "涨跌颜色", action: nil, keyEquivalent: "")
        displayItem.submenu = makeMenuBarDisplayModeMenu()
        displayItem.isEnabled = true
        menu.addItem(displayItem)
    }

    // 构造"显示内容"子菜单（今日收益/涨跌幅/金额等模式，带勾选状态）
    private func makeMenuBarContentModeMenu() -> NSMenu {
        let submenu = NSMenu(title: "显示内容")
        for mode in MenuBarContentMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectMenuBarContentModeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue // 把模式原始值带在菜单项上
            item.state = settingsStore.settings.menuBarContentMode == mode ? .on : .off
            item.toolTip = mode.detail
            submenu.addItem(item)
        }
        return submenu
    }

    // 构造"涨跌颜色"子菜单（随系统/红涨绿跌 等）
    private func makeMenuBarDisplayModeMenu() -> NSMenu {
        let submenu = NSMenu(title: "涨跌颜色")
        for mode in MenuBarDisplayMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectMenuBarDisplayModeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settingsStore.settings.menuBarDisplayMode == mode ? .on : .off
            item.toolTip = mode.detail
            submenu.addItem(item)
        }
        return submenu
    }

    // 添加一个动态更新的"检查更新"菜单项，并立即按当前状态渲染
    private func addUpdateMenuItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        applyUpdateMenuPresentation(to: item)
        contextMenuUpdateItem = item
        menu.addItem(item)
    }

    // 根据"更新状态/下载进度/动画帧"计算菜单项的标题、动作、可点状态
    private func applyUpdateMenuPresentation(to item: NSMenuItem) {
        let presentation = AppUpdateMenuItemPresentation(
            status: contextMenuUpdateStatusOverride ?? updateStore.presentationStatus,
            downloadProgress: updateStore.downloadProgress,
            activityFrame: contextMenuUpdateAnimationFrame
        )
        item.view = nil
        item.title = presentation.title
        item.action = updateMenuActionSelector(for: presentation.action)
        item.isEnabled = presentation.isEnabled
        item.toolTip = presentation.toolTip
        item.menu?.itemChanged(item) // 通知菜单该项已变更需重绘
    }

    // 菜单打开期间：启动一个 0.35s 的定时器，持续刷新"更新"菜单项的动画/状态；并立即刷新一次
    private func startContextMenuUpdateRefresh() {
        contextMenuUpdateRefreshTimer?.invalidate()
        contextMenuUpdateRefreshTimer = nil
        contextMenuUpdateStatusOverride = nil
        contextMenuUpdateAnimationFrame = 2
        refreshContextMenuUpdateItem()

        let timer = Timer(
            timeInterval: 0.35,
            target: self,
            selector: #selector(contextMenuUpdateRefreshTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        contextMenuUpdateRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking) // 菜单跟踪模式下也要触发
    }

    @objc private func contextMenuUpdateRefreshTimerFired(_ timer: Timer) {
        finishContextMenuUpdateCheckIfReady() // 先看看后台检查是否出结果了
        refreshContextMenuUpdateItem()
    }

    // 重新按当前状态渲染"更新"菜单项，并推进动画帧
    private func refreshContextMenuUpdateItem() {
        guard let contextMenuUpdateItem else {
            if contextMenuUpdateCheck == nil {
                stopContextMenuUpdateRefresh()
            }
            return
        }
        applyUpdateMenuPresentation(to: contextMenuUpdateItem)
        contextMenuUpdateAnimationFrame += 1
    }

    // 停止菜单更新轮询；cancelPendingCheck=true 时取消仍在进行中的检查任务
    private func stopContextMenuUpdateRefresh(cancelPendingCheck: Bool = false) {
        if cancelPendingCheck {
            contextMenuUpdateCheck?.task.cancel()
            contextMenuUpdateCheck = nil
        }
        if contextMenuUpdateCheck == nil {
            contextMenuUpdateRefreshTimer?.invalidate()
            contextMenuUpdateRefreshTimer = nil
        }
        contextMenuUpdateItem = nil
        contextMenuUpdateStatusOverride = nil
    }

    // 菜单打开时触发一次更新检查（若当前状态允许）。返回 true 表示已启动检查，调用方可延迟弹菜单。
    private func checkForUpdatesFromContextMenu() -> Bool {
        finishContextMenuUpdateCheckIfReady()
        if contextMenuUpdateCheck != nil {
            contextMenuUpdateStatusOverride = .checking
            refreshContextMenuUpdateItem()
            return true
        }
        updateStore.autoUpdateCheckEnabled = settingsStore.settings.autoUpdateCheckEnabled
        guard settingsStore.settings.autoUpdateCheckEnabled else { return false }
        guard updateStore.status.shouldCheckWhenOpeningContextMenu else { return false }
        guard let request = updateStore.startCheck(currentVersion: appVersion, mode: .interactive) else { return false }
        let checkID = UUID()
        let resultBox = ContextMenuUpdateCheckResultBox()
        // 在独立高优先级任务里真正去检查，结果写回 resultBox
        let task = Task.detached(priority: .userInitiated) { [request, resultBox] in
            let completion: AppUpdateCheckCompletion
            do {
                let status = try await request.service.check(
                    currentVersion: request.currentVersion,
                    mode: request.mode
                )
                completion = .success(status)
            } catch {
                completion = .failure(error.localizedDescription)
            }
            resultBox.set(completion)
        }
        contextMenuUpdateCheck = ContextMenuUpdateCheck(
            id: checkID,
            request: request,
            resultBox: resultBox,
            task: task
        )
        contextMenuUpdateStatusOverride = .checking
        refreshContextMenuUpdateItem()
        statusBarUpdateLogger.info("Start context menu update check generation=\(request.generation, privacy: .public)")
        return true
    }

    // 若检查已完成（resultBox 有结果），把它交给 updateStore 收尾，并返回 true
    @discardableResult
    private func finishContextMenuUpdateCheckIfReady(id: UUID? = nil) -> Bool {
        guard let check = contextMenuUpdateCheck,
              id == nil || id == check.id,
              let completion = check.resultBox.take()
        else { return false }

        contextMenuUpdateCheck = nil
        contextMenuUpdateStatusOverride = nil
        updateStore.finishCheck(check.request, completion: completion)
        statusBarUpdateLogger.info("Finish context menu update check generation=\(check.request.generation, privacy: .public)")
        return true
    }

    // 把"更新菜单项"的动作映射到对应的 @objc 处理方法
    private func updateMenuActionSelector(for action: AppUpdateMenuItemAction?) -> Selector? {
        switch action {
        case .checkForUpdates:
            #selector(checkUpdateFromMenu)
        case .openUpdate:
            #selector(openUpdateFromMenu)
        case nil:
            nil
        }
    }

    // 生成一个禁用（灰显）的菜单项，常用于标题/版本信息
    private func disabledMenuItem(_ title: String, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = toolTip
        return item
    }

    // 触发交互式检查更新（走 AppDelegate 注入的回调）
    private func checkForUpdates() {
        Task { [weak self] in
            await self?.onCheckUpdate(.interactive)
        }
    }

    @objc private func refreshFromMenu() {
        refreshQuotesAndStatusTitle()
    }

    @objc private func checkUpdateFromMenu() {
        checkForUpdates()
    }

    @objc private func openUpdateFromMenu() {
        onOpenUpdate()
    }

    // 右键菜单"设置"：先确保主面板开，再弹出设置子面板
    @objc private func openSettingsFromMenu() {
        showMainPanel()
        showChildPanel(.settings)
    }

    // 选中"显示内容"子菜单项：保存新模式并刷新
    @objc private func selectMenuBarContentModeFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = MenuBarContentMode(rawValue: rawValue)
        else { return }
        settingsStore.setMenuBarContentMode(mode)
        handleSettingsChanged()
    }

    // 选中"涨跌颜色"子菜单项
    @objc private func selectMenuBarDisplayModeFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = MenuBarDisplayMode(rawValue: rawValue)
        else { return }
        settingsStore.setMenuBarDisplayMode(mode)
        handleSettingsChanged()
    }

    @objc private func importFundConfigurationFromMenu() {
        _ = importFundConfiguration()
    }

    // 弹出文件选择框，将用户选中的 JSON 配置导入为当前持仓
    @discardableResult
    private func importFundConfiguration() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "导入基金配置"
        panel.prompt = "导入"
        panel.message = "选择 red-fund 导出的 JSON 配置文件。"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try store.importPortfolio(from: url)
            updateStatusTitle()
            sendFundThresholdRemindersIfNeeded()
            showMainPanel()
            return true
        } catch {
            presentConfigurationError(title: "导入基金配置失败", error: error)
            return false
        }
    }

    // 弹出保存面板，将当前组合（基金/持仓/待确认交易/交易记录）导出为 JSON
    @objc private func exportFundConfigurationFromMenu() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "导出基金配置"
        panel.prompt = "导出"
        panel.message = "导出当前录入的基金、持仓日期、待确认交易和交易记录。"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFundConfigurationFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportPortfolio(to: url)
        } catch {
            presentConfigurationError(title: "导出基金配置失败", error: error)
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    // 导出文件默认名：red-fund-portfolio-<日期>.json
    private func defaultFundConfigurationFileName() -> String {
        "red-fund-portfolio-\(DateOnlyFormatter.string(from: .now)).json"
    }

    // 通用错误弹窗（导入/导出失败等）
    private func presentConfigurationError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // 在主线程异步刷新行情并刷新菜单栏标题
    private func refreshQuotesAndStatusTitle() {
        Task { [weak self] in
            guard let self else { return }
            await refreshQuotesAndStatusTitleAsync()
        }
    }

    // 设置项变化后的统一处理：刷新标题、重绘面板、重配定时器与提醒、必要时刷新指数
    private func handleSettingsChanged() {
        updateStatusTitle()
        refreshVisiblePanels(animatedAppearance: true)
        configureAutoRefreshTimer()
        configureOperationReminder()
        sendFundThresholdRemindersIfNeeded()
        if settingsStore.settings.showsMarketIndexes {
            Task { [weak self] in
                await self?.refreshMarketIndexesIfNeeded(force: true)
            }
        }
    }

    // 拉取基金行情（及指数），刷新标题、发送阈值提醒，并通知面板数据已变
    private func refreshQuotesAndStatusTitleAsync(backfillTypes: Bool = false) async {
        await store.refreshQuotes(backfillTypes: backfillTypes)
        await refreshMarketIndexesIfNeeded()
        updateStatusTitle()
        sendFundThresholdRemindersIfNeeded()
        handleStoreSnapshotChanged()
    }

    // 若开启了"显示大盘指数"，则刷新指数（force=true 时忽略节流）
    private func refreshMarketIndexesIfNeeded(force: Bool = false) async {
        guard settingsStore.settings.showsMarketIndexes else { return }
        await marketIndexStore.refresh(force: force)
    }

    // 重新安排"一次性"自动刷新定时器：到点后刷新并自我重排（实现周期性刷新）
    private func configureAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        let interval = nextAutoRefreshInterval()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshQuotesAndStatusTitleAsync()
                self.configureAutoRefreshTimer() // 刷新完成后重新排期
            }
        }
        timer.tolerance = min(interval * 0.2, 5)
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    // 计算下一次自动刷新的间隔：取"用户设置间隔"与"距下一个交易时段边界"的较小值，确保开盘即刷新
    private func nextAutoRefreshInterval(now: Date = .now) -> TimeInterval {
        let interval = settingsStore.settings.effectiveAutoRefreshInterval(now: now).seconds

        guard let boundary = TradingCalendar.nextMarketSessionBoundary(after: now) else {
            return interval
        }

        let boundaryInterval = boundary.timeIntervalSince(now)
        guard boundaryInterval > 0 else { return interval }
        return min(interval, boundaryInterval)
    }

    // 根据设置重新配置"交易日开盘操作提醒"：生成未来若干天的提醒请求并交给调度器
    private func configureOperationReminder() {
        let isEnabled = settingsStore.settings.operationReminderEnabled
        let reminderMinutes = settingsStore.settings.operationReminderTimeMinutes
        let clampedMinutes = AppSettings.clampedReminderTimeMinutes(reminderMinutes)
        let requests = TradingCalendar.nextMarketOpenReminderDates(minutes: clampedMinutes).map { reminderDate in
            OperationReminderNotificationRequest(
                identifier: "\(operationReminderNotificationPrefix)\(DateOnlyFormatter.string(from: reminderDate))",
                title: OperationReminderNotificationContent.title,
                body: OperationReminderNotificationContent.body,
                fireDate: reminderDate
            )
        }
        operationReminderScheduler.configure(isEnabled: isEnabled, requests: requests)
    }

    // 给定一批通知标识符，返回其中属于"操作提醒"的那些（用于统一清除）
    nonisolated static func operationReminderNotificationIdentifiersToClear(from identifiers: [String]) -> [String] {
        Set(identifiers.filter(isOperationReminderNotificationID) + [operationReminderNotificationID]).sorted()
    }

    // 给定一批候选通知，按标识符前缀或标题/正文内容匹配，返回需清除的操作提醒标识符
    nonisolated static func operationReminderNotificationIdentifiersToClear(
        from candidates: [OperationReminderNotificationCandidate]
    ) -> [String] {
        Set(
            candidates.filter { candidate in
                isOperationReminderNotificationID(candidate.identifier)
                    || isOperationReminderNotificationContent(title: candidate.title, body: candidate.body)
            }.map(\.identifier) + [operationReminderNotificationID]
        ).sorted()
    }

    // 判断某个标识符是否为操作提醒（精确匹配或前缀匹配）
    nonisolated private static func isOperationReminderNotificationID(_ identifier: String) -> Bool {
        identifier == operationReminderNotificationID || identifier.hasPrefix(operationReminderNotificationPrefix)
    }

    // 判断某通知的标题/正文是否与操作提醒模板一致
    nonisolated private static func isOperationReminderNotificationContent(title: String, body: String) -> Bool {
        title == OperationReminderNotificationContent.title && body == OperationReminderNotificationContent.body
    }

    // 把系统通知请求转换为"操作提醒候选"结构
    nonisolated private static func operationReminderNotificationCandidate(
        from request: UNNotificationRequest
    ) -> OperationReminderNotificationCandidate {
        OperationReminderNotificationCandidate(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body
        )
    }

    // 评估并发送"基金阈值提醒"：当基金涨跌幅/收益达到用户设定阈值时推送本地通知（带去重）
    private func sendFundThresholdRemindersIfNeeded() {
        let now = Date()
        // 由评估器算出当前符合条件的提醒（并结合上次发送时间去重）
        let reminders = FundThresholdReminderEvaluator.eligibleReminders(
            in: store.snapshot,
            settings: settingsStore.settings,
            now: now,
            lastSentAt: fundThresholdReminderLastSentAt
        )
        let unsentReminders = reminders.filter {
            !pendingFundThresholdReminderKeys.contains($0.dedupeKey) // 排除正在发送中的
        }
        guard !unsentReminders.isEmpty else { return }

        pendingFundThresholdReminderKeys.formUnion(unsentReminders.map(\.dedupeKey))

        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            // 先请求通知授权；被拒则放弃并清理待发送状态
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                await MainActor.run {
                    unsentReminders.forEach { self?.markFundThresholdReminderFinished($0.dedupeKey) }
                }
                return
            }

            for reminder in unsentReminders {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default

                // trigger 为 nil 表示立即送达
                let request = UNNotificationRequest(
                    identifier: "\(reminder.notificationIdentifier).\(Int(now.timeIntervalSince1970))",
                    content: content,
                    trigger: nil
                )

                do {
                    try await center.add(request)
                    await MainActor.run {
                        self?.markFundThresholdReminderSent(reminder.dedupeKey, at: now)
                    }
                } catch {
                    await MainActor.run {
                        self?.markFundThresholdReminderFinished(reminder.dedupeKey)
                    }
                    continue
                }
            }
        }
    }

    // 提醒发送成功：记录最后发送时间并持久化，移出待发送集合
    private func markFundThresholdReminderSent(_ key: String, at date: Date) {
        fundThresholdReminderLastSentAt[key] = date
        pendingFundThresholdReminderKeys.remove(key)
        saveFundThresholdReminderLastSentAt()
    }

    // 提醒结束（失败/未授权）：仅从待发送集合移除，不记录发送时间
    private func markFundThresholdReminderFinished(_ key: String) {
        pendingFundThresholdReminderKeys.remove(key)
    }

    // 将"上次发送时间"字典（Date -> 时间戳）写入 UserDefaults
    private func saveFundThresholdReminderLastSentAt() {
        UserDefaults.standard.set(
            fundThresholdReminderLastSentAt.mapValues(\.timeIntervalSince1970),
            forKey: fundThresholdReminderLastSentDefaultsKey
        )
    }

    // 从 UserDefaults 恢复"上次发送时间"，并丢弃超过一天前的旧记录
    private static func loadFundThresholdReminderLastSentAt() -> [String: Date] {
        let rawValues = UserDefaults.standard.dictionary(forKey: fundThresholdReminderLastSentDefaultsKey) as? [String: Double] ?? [:]
        let earliestDate = Date().addingTimeInterval(-FundThresholdReminderInterval.oneDay.seconds)
        let values = rawValues.compactMapValues { timestamp -> Date? in
            let date = Date(timeIntervalSince1970: timestamp)
            return date >= earliestDate ? date : nil
        }
        UserDefaults.standard.set(
            values.mapValues(\.timeIntervalSince1970),
            forKey: fundThresholdReminderLastSentDefaultsKey
        )
        return values
    }

    // 删除某只基金：删成功后刷新标题；若当前子面板正展示它则收起，否则仅刷新快照状态
    private func deleteFund(_ fund: FundPosition) async {
        do {
            try await store.deleteFund(code: fund.code)
            updateStatusTitle()
            if activeChildPanel?.selectedFundCode == fund.code {
                hideChildPanel()
            } else {
                handleStoreSnapshotChanged()
            }
        } catch {
            // 保留现有数据；刷新失败会由 PortfolioStore.loadState 另行反馈。
        }
    }

    // 删除待确认活动：有记录 ID 则删记录，否则按代码删基金；随后刷新视图
    private func deletePendingActivity(_ activity: PendingTradeActivity) async {
        do {
            if let recordID = activity.recordID {
                try await store.deleteTradeRecord(id: recordID)
            } else {
                try await store.deleteFund(code: activity.code)
            }
            updateStatusTitle()
            handleStoreSnapshotChanged()
            updateMainPanelRootView()
        } catch {
            refreshVisiblePanels()
        }
    }

    // 删除一条交易记录，删完后回到该基金的"交易记录"面板
    private func deleteTradeRecord(_ record: FundTradeRecord, returningToFundCode fundCode: String) async {
        do {
            try await store.deleteTradeRecord(id: record.id)
            updateStatusTitle()
            showChildPanel(.tradeRecords(fundCode: fundCode))
            updateMainPanelRootView()
        } catch {
            refreshVisiblePanels()
        }
    }
}

// 右键菜单关闭时，停止菜单内更新状态的轮询定时器
extension StatusBarController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        stopContextMenuUpdateRefresh()
    }
}
