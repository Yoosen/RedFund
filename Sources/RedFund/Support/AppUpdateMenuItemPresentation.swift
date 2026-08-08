import Foundation

/// 菜单栏“检查更新”菜单项的点击动作。
enum AppUpdateMenuItemAction: Equatable {
    /// 触发检查更新。
    case checkForUpdates
    /// 打开（下载/安装）更新。
    case openUpdate
}

extension AppUpdateStatus {
    /// 打开右键菜单时是否应主动触发一次检查：下载/安装进行中不检查，其余状态允许。
    var shouldCheckWhenOpeningContextMenu: Bool {
        switch self {
        case .idle, .checking, .available, .upToDate, .failed:
            return true
        case .downloading, .downloaded, .installing:
            return false
        }
    }
}

/// 将更新状态映射为菜单栏“检查更新”菜单项的展示模型。
struct AppUpdateMenuItemPresentation: Equatable {
    /// 菜单项标题。
    var title: String
    /// 点击动作（nil 表示当前不可点击）。
    var action: AppUpdateMenuItemAction?
    /// 悬浮提示文案。
    var toolTip: String?
    /// 是否处于活动状态（用于展示动态文案，如“正在…”）。
    var isActiveStatus: Bool

    /// 是否有可触发的动作（即 action 非空）。
    var isEnabled: Bool {
        action != nil
    }

    /// 根据当前更新状态构造菜单项展示模型，并填充标题/动作/提示。
    init(status: AppUpdateStatus, downloadProgress: Double, activityFrame: Int = 2) {
        switch status {
        case .idle:
            title = "检查更新"
            action = .checkForUpdates
            toolTip = nil
            isActiveStatus = false
        case .checking:
            title = "正在检查更新\(Self.animatedEllipsis(activityFrame))"
            action = nil
            toolTip = nil
            isActiveStatus = true
        case .available(let info):
            title = "检测到新版本"
            action = .openUpdate
            toolTip = "v\(info.version) · 点击下载"
            isActiveStatus = false
        case .downloading(let info):
            title = "正在下载 v\(info.version) · \(Self.progressPercent(downloadProgress))%"
            action = nil
            toolTip = nil
            isActiveStatus = true
        case .downloaded(let info, _):
            title = "现在更新 v\(info.version)"
            action = .openUpdate
            toolTip = "更新已下载，点击安装"
            isActiveStatus = false
        case .installing:
            title = "正在更新，应用将自动重启"
            action = nil
            toolTip = nil
            isActiveStatus = true
        case .upToDate(let date):
            title = "已是最新版本"
            action = nil
            toolTip = "上次检查：\(date.formatted(date: .omitted, time: .shortened))"
            isActiveStatus = false
        case .failed(let reason):
            title = "重新检查更新"
            action = .checkForUpdates
            toolTip = reason
            isActiveStatus = false
        }
    }

    /// 将 0...1 的进度转换为整数百分比。
    private static func progressPercent(_ progress: Double) -> Int {
        Int(min(max(progress, 0), 1) * 100)
    }

    /// 根据动画帧数返回省略号，营造“正在…”的动效。
    private static func animatedEllipsis(_ frame: Int) -> String {
        String(repeating: ".", count: max(0, frame % 3) + 1)
    }
}
