import Foundation

/// 一次可更新版本的信息（来自 GitHub Release）。
struct AppUpdateInfo: Codable, Equatable, Sendable {
    /// 版本号字符串。
    var version: String
    /// Release 标题。
    var releaseName: String
    /// Release 说明文本。
    var releaseNotes: String
    /// 发布时间。
    var publishedAt: Date?
    /// Release 网页地址。
    var htmlURL: URL
    /// 更新包下载地址（可能为空，表示不支持自动下载）。
    var downloadURL: URL?
}

/// 已下载到本地的更新包临时信息。
struct AppUpdatePackage: Equatable, Sendable {
    /// 本地临时文件路径。
    var localURL: URL
    /// 解包后得到的 .app 路径。
    var stagedAppURL: URL
    /// 下载完成时间。
    var downloadedAt: Date
}

/// 更新检查的触发模式。
enum AppUpdateCheckMode: Equatable, Sendable {
    /// 后台静默检查。
    case background
    /// 用户主动触发的交互式检查。
    case interactive
}

/// 应用更新状态机，驱动菜单栏与设置中的更新展示与操作。
enum AppUpdateStatus: Equatable, Sendable {
    /// 空闲。
    case idle
    /// 正在检查。
    case checking
    /// 检测到新版本。
    case available(AppUpdateInfo)
    /// 正在下载。
    case downloading(AppUpdateInfo)
    /// 已下载完成，待安装。
    case downloaded(AppUpdateInfo, AppUpdatePackage)
    /// 正在安装。
    case installing(AppUpdateInfo)
    /// 已是最新（携带上次检查时间）。
    case upToDate(Date)
    /// 检查/更新失败（携带原因）。
    case failed(String)

    /// 提取与状态关联的可更新版本信息；无关联版本时返回 nil。
    var updateInfo: AppUpdateInfo? {
        switch self {
        case .available(let info),
             .downloading(let info),
             .downloaded(let info, _),
             .installing(let info):
            return info
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}
