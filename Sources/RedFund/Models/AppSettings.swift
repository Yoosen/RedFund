import Foundation

/// 应用设置模型（可编码、可比较），保存菜单栏显示、自动刷新、提醒、外观等用户偏好。
struct AppSettings: Codable, Equatable {
    /// 当前设置数据结构的 schema 版本号。
    static let currentSchemaVersion = 13
    /// 新手引导流程引入时对应的 schema 版本。
    static let currentOnboardingVersion = 1
    /// 主面板默认高度（pt）。
    static let defaultMainPanelHeight = 640
    /// 主面板最小高度。
    static let minMainPanelHeight = 560
    /// 主面板最大高度。
    static let maxMainPanelHeight = 900
    /// 默认操作提醒时间（14:30，单位：分钟）。
    static let defaultOperationReminderTimeMinutes = 14 * 60 + 30
    /// 默认阈值提醒触发间隔。
    static let defaultThresholdReminderInterval: FundThresholdReminderInterval = .thirtyMinutes
    /// 默认每日涨跌提醒是否开启。
    static let defaultDailyGrowthReminderEnabled = false
    /// 默认开盘时段自动刷新间隔。
    static let defaultAutoRefreshInterval: AutoRefreshInterval = .fiveSeconds
    /// 默认休市时段自动刷新间隔。
    static let defaultMarketClosedAutoRefreshInterval: AutoRefreshInterval = .tenMinutes
    /// 默认菜单栏展示的指数标识。
    static let defaultMarketIndexIdentifier: MarketIndexID = .shanghaiComposite

    /// 当前设置 schema 版本，用于迁移判断。
    var settingsSchemaVersion: Int? = Self.currentSchemaVersion
    /// 菜单栏涨跌配色模式（红绿 / 单色）。
    var menuBarDisplayMode: MenuBarDisplayMode = .color
    /// 菜单栏展示内容（金额 / 百分比 / 都显示 / 都不显示）。
    var menuBarContentMode: MenuBarContentMode = .amount
    /// 开盘时段的自动刷新间隔。
    var autoRefreshInterval: AutoRefreshInterval = Self.defaultAutoRefreshInterval
    /// 休市时段的自动刷新间隔。
    var marketClosedAutoRefreshInterval: AutoRefreshInterval = Self.defaultMarketClosedAutoRefreshInterval
    /// 主面板高度。
    var mainPanelHeight: Int = Self.defaultMainPanelHeight
    /// 是否开启盘中操作提醒。
    var operationReminderEnabled: Bool = true
    /// 操作提醒触发时间（分钟数，从 00:00 起算）。
    var operationReminderTimeMinutes: Int = Self.defaultOperationReminderTimeMinutes
    /// 阈值提醒的最小触发间隔。
    var thresholdReminderInterval: FundThresholdReminderInterval = Self.defaultThresholdReminderInterval
    /// 是否开启每日涨跌到档提醒。
    var dailyGrowthReminderEnabled: Bool = Self.defaultDailyGrowthReminderEnabled
    /// 上涨提醒阈值档位集合。
    var dailyGrowthRiseTiers: [FundGrowthReminderTier] = []
    /// 下跌提醒阈值档位集合。
    var dailyGrowthFallTiers: [FundGrowthReminderTier] = []
    /// 外观模式（跟随系统 / 浅色 / 深色）。
    var appearanceMode: AppAppearanceMode = .system
    /// 是否在菜单栏展示市场指数概览。
    var showsMarketIndexes: Bool = true
    /// 默认/首选展示的市场指数标识。
    var defaultMarketIndexID: MarketIndexID = Self.defaultMarketIndexIdentifier
    /// 是否开启 Beta 功能开关。
    var betaFeaturesEnabled: Bool = false
    /// 是否自动检查更新；关闭后启动与打开菜单时不再自动检查并提示（手动检查仍可用）。
    var autoUpdateCheckEnabled: Bool = true
    /// 已完成的新手引导版本；nil 表示尚未完成引导。
    var completedOnboardingVersion: Int? = nil

    /// 全量初始化器，对传入的各类间隔/高度/阈值做校验与归一化后再赋值。
    init(
        settingsSchemaVersion: Int? = Self.currentSchemaVersion,
        menuBarDisplayMode: MenuBarDisplayMode = .color,
        menuBarContentMode: MenuBarContentMode = .amount,
        autoRefreshInterval: AutoRefreshInterval = Self.defaultAutoRefreshInterval,
        marketClosedAutoRefreshInterval: AutoRefreshInterval = Self.defaultMarketClosedAutoRefreshInterval,
        mainPanelHeight: Int = Self.defaultMainPanelHeight,
        operationReminderEnabled: Bool = true,
        operationReminderTimeMinutes: Int = Self.defaultOperationReminderTimeMinutes,
        thresholdReminderInterval: FundThresholdReminderInterval = Self.defaultThresholdReminderInterval,
        dailyGrowthReminderEnabled: Bool = Self.defaultDailyGrowthReminderEnabled,
        dailyGrowthRiseTiers: [FundGrowthReminderTier] = [],
        dailyGrowthFallTiers: [FundGrowthReminderTier] = [],
        appearanceMode: AppAppearanceMode = .system,
        showsMarketIndexes: Bool = true,
        defaultMarketIndexID: MarketIndexID = Self.defaultMarketIndexIdentifier,
        betaFeaturesEnabled: Bool = false,
        autoUpdateCheckEnabled: Bool = true,
        completedOnboardingVersion: Int? = nil
    ) {
        self.settingsSchemaVersion = settingsSchemaVersion
        self.menuBarDisplayMode = menuBarDisplayMode
        self.menuBarContentMode = menuBarContentMode
        self.autoRefreshInterval = Self.validMarketOpenAutoRefreshInterval(autoRefreshInterval)
        self.marketClosedAutoRefreshInterval = Self.validMarketClosedAutoRefreshInterval(marketClosedAutoRefreshInterval)
        self.mainPanelHeight = Self.clampedMainPanelHeight(mainPanelHeight)
        self.operationReminderEnabled = operationReminderEnabled
        self.operationReminderTimeMinutes = Self.clampedReminderTimeMinutes(operationReminderTimeMinutes)
        self.thresholdReminderInterval = thresholdReminderInterval
        self.dailyGrowthReminderEnabled = dailyGrowthReminderEnabled
        self.dailyGrowthRiseTiers = Self.normalizedGrowthReminderTiers(dailyGrowthRiseTiers)
        self.dailyGrowthFallTiers = Self.normalizedGrowthReminderTiers(dailyGrowthFallTiers)
        self.appearanceMode = appearanceMode
        self.showsMarketIndexes = showsMarketIndexes
        self.defaultMarketIndexID = defaultMarketIndexID
        self.betaFeaturesEnabled = betaFeaturesEnabled
        self.autoUpdateCheckEnabled = autoUpdateCheckEnabled
        self.completedOnboardingVersion = completedOnboardingVersion
    }

    /// 编码键映射，对应持久化 JSON 的字段名。
    enum CodingKeys: String, CodingKey {
        case settingsSchemaVersion
        case menuBarDisplayMode
        case menuBarContentMode
        case autoRefreshInterval
        case marketClosedAutoRefreshInterval
        case mainPanelHeight
        case operationReminderEnabled
        case operationReminderTimeMinutes
        case thresholdReminderInterval
        case dailyGrowthReminderEnabled
        case dailyGrowthRiseTiers
        case dailyGrowthFallTiers
        case appearanceMode
        case showsMarketIndexes
        case defaultMarketIndexID
        case betaFeaturesEnabled
        case autoUpdateCheckEnabled
        case completedOnboardingVersion
    }

    /// 从持久化 JSON 解码设置；缺失字段回退默认值，并对间隔/高度/阈值做校验。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .settingsSchemaVersion)
        settingsSchemaVersion = decodedSchemaVersion
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .color
        menuBarContentMode = try container.decodeIfPresent(MenuBarContentMode.self, forKey: .menuBarContentMode) ?? .amount
        let decodedAutoRefreshInterval = try container.decodeIfPresent(
            AutoRefreshInterval.self,
            forKey: .autoRefreshInterval
        ) ?? Self.defaultAutoRefreshInterval
        autoRefreshInterval = Self.validMarketOpenAutoRefreshInterval(decodedAutoRefreshInterval)
        let decodedMarketClosedAutoRefreshInterval = try container.decodeIfPresent(
            AutoRefreshInterval.self,
            forKey: .marketClosedAutoRefreshInterval
        ) ?? Self.defaultMarketClosedAutoRefreshInterval
        marketClosedAutoRefreshInterval = Self.validMarketClosedAutoRefreshInterval(
            decodedMarketClosedAutoRefreshInterval
        )
        let decodedMainPanelHeight = try container.decodeIfPresent(Int.self, forKey: .mainPanelHeight)
            ?? Self.defaultMainPanelHeight
        mainPanelHeight = Self.clampedMainPanelHeight(decodedMainPanelHeight)
        operationReminderEnabled = try container.decodeIfPresent(Bool.self, forKey: .operationReminderEnabled) ?? true
        let decodedReminderMinutes = try container.decodeIfPresent(Int.self, forKey: .operationReminderTimeMinutes)
            ?? Self.defaultOperationReminderTimeMinutes
        operationReminderTimeMinutes = Self.clampedReminderTimeMinutes(decodedReminderMinutes)
        thresholdReminderInterval = try container.decodeIfPresent(
            FundThresholdReminderInterval.self,
            forKey: .thresholdReminderInterval
        ) ?? Self.defaultThresholdReminderInterval
        dailyGrowthReminderEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .dailyGrowthReminderEnabled
        ) ?? Self.defaultDailyGrowthReminderEnabled
        let decodedRiseTierValues = try container.decodeIfPresent([Int].self, forKey: .dailyGrowthRiseTiers) ?? []
        dailyGrowthRiseTiers = Self.normalizedGrowthReminderTiers(
            decodedRiseTierValues.compactMap(FundGrowthReminderTier.init(rawValue:))
        )
        let decodedFallTierValues = try container.decodeIfPresent([Int].self, forKey: .dailyGrowthFallTiers) ?? []
        dailyGrowthFallTiers = Self.normalizedGrowthReminderTiers(
            decodedFallTierValues.compactMap(FundGrowthReminderTier.init(rawValue:))
        )
        appearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .system
        showsMarketIndexes = try container.decodeIfPresent(Bool.self, forKey: .showsMarketIndexes) ?? true
        let decodedMarketIndexID = try container.decodeIfPresent(String.self, forKey: .defaultMarketIndexID)
        defaultMarketIndexID = decodedMarketIndexID
            .flatMap(MarketIndexID.init(rawValue:))
            ?? Self.defaultMarketIndexIdentifier
        betaFeaturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .betaFeaturesEnabled) ?? false
        autoUpdateCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateCheckEnabled) ?? true
        if container.contains(.completedOnboardingVersion) {
            completedOnboardingVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .completedOnboardingVersion
            )
        } else if (decodedSchemaVersion ?? 0) < Self.currentSchemaVersion {
            // Onboarding was introduced in schema 13. Existing installs must never
            // be mistaken for a new install merely because the field is absent.
            completedOnboardingVersion = Self.currentOnboardingVersion
        } else {
            completedOnboardingVersion = nil
        }
    }

    /// 将主面板高度限制在 [最小值, 最大值] 区间内。
    static func clampedMainPanelHeight(_ height: Int) -> Int {
        min(max(height, minMainPanelHeight), maxMainPanelHeight)
    }

    /// 将操作提醒时间（分钟）限制在 0..(23*60+59) 区间内。
    static func clampedReminderTimeMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 0), 23 * 60 + 59)
    }

    /// 对涨跌提醒阈值档位去重并按数值升序排序。
    static func normalizedGrowthReminderTiers(_ tiers: [FundGrowthReminderTier]) -> [FundGrowthReminderTier] {
        Array(Set(tiers)).sorted { $0.rawValue < $1.rawValue }
    }

    /// 校验给定的开盘自动刷新间隔是否合法，非法则回退到默认开盘间隔。
    static func validMarketOpenAutoRefreshInterval(_ interval: AutoRefreshInterval) -> AutoRefreshInterval {
        AutoRefreshInterval.marketOpenIntervals.contains(interval) ? interval : defaultAutoRefreshInterval
    }

    /// 校验给定的休市自动刷新间隔是否合法，非法则回退到默认休市间隔。
    static func validMarketClosedAutoRefreshInterval(_ interval: AutoRefreshInterval) -> AutoRefreshInterval {
        AutoRefreshInterval.marketClosedIntervals.contains(interval) ? interval : defaultMarketClosedAutoRefreshInterval
    }

    /// 根据当前时间对应的市场会话状态，返回实际应使用的自动刷新间隔。
    func effectiveAutoRefreshInterval(now: Date = .now) -> AutoRefreshInterval {
        effectiveAutoRefreshInterval(for: TradingCalendar.marketSessionState(now: now))
    }

    /// 按给定的市场会话状态（开盘 / 午休 / 休市）返回对应的自动刷新间隔。
    func effectiveAutoRefreshInterval(for state: MarketSessionState) -> AutoRefreshInterval {
        switch state {
        case .open:
            autoRefreshInterval
        case .middayBreak, .closed:
            marketClosedAutoRefreshInterval
        }
    }

    /// 将操作提醒时间（分钟数）格式化为 "HH:mm" 文本。
    var operationReminderTimeText: String {
        let hours = operationReminderTimeMinutes / 60
        let minutes = operationReminderTimeMinutes % 60
        return String(format: "%02d:%02d", hours, minutes)
    }
}

/// 每日涨跌提醒阈值档位（百分比），用于触发涨/跌到档通知。
enum FundGrowthReminderTier: Int, Codable, CaseIterable, Identifiable, Equatable {
    case two = 2
    case three = 3
    case five = 5
    case seven = 7
    case ten = 10

    /// 用作 Identifiable 的稳定标识。
    var id: Int { rawValue }

    /// 档位对应的百分比数值。
    var value: Double { Double(rawValue) }

    /// 档位展示文本，如 "5%"。
    var title: String {
        "\(rawValue)%"
    }
}

/// 应用外观模式。
enum AppAppearanceMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case system
    case light
    case dark

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 模式中文标题。
    var title: String {
        switch self {
        case .system:
            "跟随系统"
        case .light:
            "浅色"
        case .dark:
            "深色"
        }
    }

    /// 模式对应的系统图标名。
    var systemImage: String {
        switch self {
        case .system:
            "display"
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }
}

/// 阈值提醒最小触发间隔（同一基金同类提醒命中后，间隔内不再重复提醒）。
enum FundThresholdReminderInterval: String, Codable, CaseIterable, Identifiable, Equatable {
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHours = "2h"
    case fourHours = "4h"
    case oneDay = "1d"

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 间隔对应的秒数。
    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes:
            15 * 60
        case .thirtyMinutes:
            30 * 60
        case .oneHour:
            60 * 60
        case .twoHours:
            2 * 60 * 60
        case .fourHours:
            4 * 60 * 60
        case .oneDay:
            24 * 60 * 60
        }
    }

    /// 间隔中文标题。
    var title: String {
        switch self {
        case .fifteenMinutes:
            "15分钟"
        case .thirtyMinutes:
            "30分钟"
        case .oneHour:
            "1小时"
        case .twoHours:
            "2小时"
        case .fourHours:
            "4小时"
        case .oneDay:
            "每天一次"
        }
    }

    /// 间隔说明文案，提示重复提醒抑制规则。
    var detail: String {
        let intervalText = self == .oneDay ? "24小时" : title
        return "同一只基金同一类提醒命中后，\(intervalText)内不再重复提醒。"
    }
}

/// 菜单栏涨跌配色模式。
enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case color
    case sign

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 模式中文标题。
    var title: String {
        switch self {
        case .color:
            "红绿"
        case .sign:
            "单色"
        }
    }

    /// 模式详细说明文案。
    var detail: String {
        switch self {
        case .color:
            "未隐藏时文字按涨跌红/绿；隐藏金额时仅图标按涨跌红/绿。"
        case .sign:
            "未隐藏时文字使用系统颜色；隐藏金额时图标也使用系统单色。"
        }
    }

    /// 是否使用涨跌红绿配色。
    var usesGrowthColor: Bool {
        self == .color
    }
}

/// 菜单栏展示内容模式。
enum MenuBarContentMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case amount
    case rate
    case both
    case hidden

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 模式中文标题。
    var title: String {
        switch self {
        case .amount:
            "金额"
        case .rate:
            "百分比"
        case .both:
            "都显示"
        case .hidden:
            "都不显示"
        }
    }

    /// 模式详细说明文案。
    var detail: String {
        switch self {
        case .amount:
            "菜单栏只显示实时收益金额。"
        case .rate:
            "菜单栏只显示实时收益率。"
        case .both:
            "菜单栏显示金额和百分比，中间用竖线分隔。"
        case .hidden:
            "菜单栏只显示图标，不显示金额和百分比。"
        }
    }
}

/// 自动刷新可选间隔；分开盘与休市两套合法集合。
enum AutoRefreshInterval: String, Codable, CaseIterable, Identifiable, Equatable {
    case twoSeconds = "2s"
    case fiveSeconds = "5s"
    case tenSeconds = "10s"
    case thirtySeconds = "30s"
    case oneMinute = "1m"
    case threeMinutes = "3m"
    case fiveMinutes = "5m"
    case tenMinutes = "10m"
    case thirtyMinutes = "30m"

    /// 开盘时段允许使用的刷新间隔集合。
    static let marketOpenIntervals: [AutoRefreshInterval] = [
        .twoSeconds,
        .fiveSeconds,
        .tenSeconds,
        .thirtySeconds,
        .oneMinute,
        .threeMinutes,
        .fiveMinutes
    ]

    /// 休市时段允许使用的刷新间隔集合。
    static let marketClosedIntervals: [AutoRefreshInterval] = [
        .oneMinute,
        .threeMinutes,
        .fiveMinutes,
        .tenMinutes,
        .thirtyMinutes
    ]

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 在滑块候选列表中的序号。
    var sliderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// 按滑块序号取对应间隔（用于滑块整体候选）。
    static func interval(atSliderIndex index: Int) -> AutoRefreshInterval {
        interval(atSliderIndex: index, in: allCases)
    }

    /// 按滑块序号在指定间隔集合中取对应间隔，越界时回退。
    static func interval(atSliderIndex index: Int, in intervals: [AutoRefreshInterval]) -> AutoRefreshInterval {
        guard !intervals.isEmpty else { return .fiveSeconds }
        let clampedIndex = min(max(index, 0), allCases.count - 1)
        return intervals[min(clampedIndex, intervals.count - 1)]
    }

    /// 间隔对应的秒数。
    var seconds: TimeInterval {
        switch self {
        case .twoSeconds:
            2
        case .fiveSeconds:
            5
        case .tenSeconds:
            10
        case .thirtySeconds:
            30
        case .oneMinute:
            60
        case .threeMinutes:
            180
        case .fiveMinutes:
            300
        case .tenMinutes:
            600
        case .thirtyMinutes:
            1_800
        }
    }

    /// 间隔中文标题。
    var title: String {
        switch self {
        case .twoSeconds:
            "2秒"
        case .fiveSeconds:
            "5秒"
        case .tenSeconds:
            "10秒"
        case .thirtySeconds:
            "30秒"
        case .oneMinute:
            "1分"
        case .threeMinutes:
            "3分"
        case .fiveMinutes:
            "5分"
        case .tenMinutes:
            "10分"
        case .thirtyMinutes:
            "30分"
        }
    }

    /// 间隔说明文案。
    var detail: String {
        "每 \(title) 自动刷新基金数据，并同步更新菜单栏收益。"
    }
}
