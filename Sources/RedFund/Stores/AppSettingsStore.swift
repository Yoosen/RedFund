import Foundation
import Observation

/// App 设置的持久化存储。
/// 负责将 `AppSettings` 以 JSON 形式读写到应用数据目录（settings.json），并提供各项设置的更新入口。
@Observable
@MainActor
final class AppSettingsStore {
    /// 设置加载来源：新建 / 读取已有 / 从损坏数据恢复。
    enum LoadOrigin: Equatable {
        case createdNew
        case loadedExisting
        case recoveredInvalid
    }

    private(set) var settings: AppSettings = AppSettings()
    private(set) var dataDirectory: URL
    private(set) var loadOrigin: LoadOrigin = .createdNew

    init(dataDirectory: URL = AppDataPaths.sharedDataDirectory) {
        self.dataDirectory = dataDirectory
        load()
    }

    /// 从磁盘加载设置：文件不存在则新建，版本不一致则升级后保存，损坏则回退默认值。
    func load() {
        do {
            let url = settingsFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                loadOrigin = .createdNew
                settings = AppSettings()
                try save()
                return
            }
            loadOrigin = .loadedExisting
            let data = try Data(contentsOf: url)
            var decodedSettings = try JSONDecoder().decode(AppSettings.self, from: data)
            if decodedSettings.settingsSchemaVersion != AppSettings.currentSchemaVersion {
                decodedSettings.settingsSchemaVersion = AppSettings.currentSchemaVersion
                settings = decodedSettings
                try save()
            } else {
                settings = decodedSettings
            }
        } catch {
            loadOrigin = .recoveredInvalid
            settings = AppSettings()
        }
    }

    /// 标记新手引导已完成，并记录对应的引导版本号。
    func completeOnboarding(version: Int = AppSettings.currentOnboardingVersion) throws {
        settings.completedOnboardingVersion = version
        try save()
    }

    /// 设置菜单栏展示模式（如只显示图标/显示文字等）。
    func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
        settings.menuBarDisplayMode = mode
        try? save()
    }

    /// 设置菜单栏显示内容模式（如收益/涨跌额等不同维度）。
    func setMenuBarContentMode(_ mode: MenuBarContentMode) {
        settings.menuBarContentMode = mode
        try? save()
    }

    /// 设置开盘时自动刷新间隔（会自动校验为合法区间）。
    func setAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        settings.autoRefreshInterval = AppSettings.validMarketOpenAutoRefreshInterval(interval)
        try? save()
    }

    /// 设置休市时自动刷新间隔（会自动校验为合法区间）。
    func setMarketClosedAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        settings.marketClosedAutoRefreshInterval = AppSettings.validMarketClosedAutoRefreshInterval(interval)
        try? save()
    }

    /// 设置主面板高度（会自动限制在合法范围）。
    func setMainPanelHeight(_ height: Int) {
        settings.mainPanelHeight = AppSettings.clampedMainPanelHeight(height)
        try? save()
    }

    /// 设置是否开启「交易操作提醒」。
    func setOperationReminderEnabled(_ isEnabled: Bool) {
        settings.operationReminderEnabled = isEnabled
        try? save()
    }

    /// 设置交易操作提醒的触发时间（分钟，自动限制范围）。
    func setOperationReminderTimeMinutes(_ minutes: Int) {
        settings.operationReminderTimeMinutes = AppSettings.clampedReminderTimeMinutes(minutes)
        try? save()
    }

    /// 设置收益阈值提醒的检查间隔。
    func setThresholdReminderInterval(_ interval: FundThresholdReminderInterval) {
        settings.thresholdReminderInterval = interval
        try? save()
    }

    /// 设置是否开启每日涨跌提醒。
    func setDailyGrowthReminderEnabled(_ isEnabled: Bool) {
        settings.dailyGrowthReminderEnabled = isEnabled
        try? save()
    }

    /// 设置每日上涨提醒的分档阈值（自动归一化）。
    func setDailyGrowthRiseTiers(_ tiers: [FundGrowthReminderTier]) {
        settings.dailyGrowthRiseTiers = AppSettings.normalizedGrowthReminderTiers(tiers)
        try? save()
    }

    /// 设置每日下跌提醒的分档阈值（自动归一化）。
    func setDailyGrowthFallTiers(_ tiers: [FundGrowthReminderTier]) {
        settings.dailyGrowthFallTiers = AppSettings.normalizedGrowthReminderTiers(tiers)
        try? save()
    }

    /// 设置外观模式（跟随系统/浅色/深色）。
    func setAppearanceMode(_ mode: AppAppearanceMode) {
        settings.appearanceMode = mode
        try? save()
    }

    /// 设置是否在面板中展示市场指数。
    func setShowsMarketIndexes(_ isShown: Bool) {
        settings.showsMarketIndexes = isShown
        try? save()
    }

    /// 设置默认展示的市场指数。
    func setDefaultMarketIndexID(_ id: MarketIndexID) {
        settings.defaultMarketIndexID = id
        try? save()
    }

    /// 设置是否开启 Beta 实验功能。
    func setBetaFeaturesEnabled(_ isEnabled: Bool) {
        settings.betaFeaturesEnabled = isEnabled
        try? save()
    }

    /// 设置是否自动检查更新（关闭后不再自动检查并提示，手动检查不受影响）。
    func setAutoUpdateCheckEnabled(_ isEnabled: Bool) {
        settings.autoUpdateCheckEnabled = isEnabled
        try? save()
    }

    /// 设置文件在应用数据目录中的路径（settings.json）。
    var settingsFileURL: URL {
        dataDirectory.appending(path: "settings.json")
    }

    /// 将当前设置编码为格式化 JSON 并原子写入磁盘。
    private func save() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
    }
}
