import Foundation

/// 决定首次引导（Onboarding）是否应当展示给用户的判定逻辑。
enum OnboardingEligibility {
    /// 综合设置版本、设置加载来源与组合加载状态，判断是否应展示引导页。
    /// 已恢复过的损坏数据、已完成引导版本、或存在旧版/已有账本时不展示。
    static func shouldPresent(
        settings: AppSettings,
        settingsLoadOrigin: AppSettingsStore.LoadOrigin,
        portfolioLoadState: PortfolioStore.LoadState
    ) -> Bool {
        guard settingsLoadOrigin != .recoveredInvalid else { return false }
        guard (settings.completedOnboardingVersion ?? 0) < AppSettings.currentOnboardingVersion else {
            return false
        }

        guard case let .missingPlainData(hasLegacyStore) = portfolioLoadState else {
            return false
        }
        return !hasLegacyStore
    }
}
