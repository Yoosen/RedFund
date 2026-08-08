import Foundation

/// 应用偏好设置在 UserDefaults 中的键名集合。
enum AppPreferenceKey {
    /// 是否隐藏头部资产金额（金额隐私模式开关）。
    static let hideHeaderAmounts = "redFund.hideHeaderAmounts"
    /// 已被用户忽略的“待处理活动”通知 ID 集合。
    static let dismissedPendingActivityNoticeIDs = "redFund.dismissedPendingActivityNoticeIDs"
}

extension Notification.Name {
    /// 金额隐私显示状态发生变化时广播的通知。
    static let redFundAmountPrivacyDidChange = Notification.Name("redFundAmountPrivacyDidChange")
}
