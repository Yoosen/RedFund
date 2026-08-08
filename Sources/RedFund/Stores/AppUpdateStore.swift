import AppKit
import Foundation
import Observation
import OSLog

/// 更新模块的日志记录器。
private let appUpdateStoreLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.yoosen.red-fund.swift",
    category: "AppUpdate"
)

/// 一次更新检查的请求描述（含代际编号、当前版本、模式与所属服务）。
struct AppUpdateCheckRequest: Sendable, Equatable {
    var generation: Int
    var currentVersion: String
    var mode: AppUpdateCheckMode
    var service: AppUpdateService

    static func == (lhs: AppUpdateCheckRequest, rhs: AppUpdateCheckRequest) -> Bool {
        lhs.generation == rhs.generation &&
            lhs.currentVersion == rhs.currentVersion &&
            lhs.mode == rhs.mode
    }
}

/// 更新检查结果：成功（带状态）或失败（带原因）。
enum AppUpdateCheckCompletion: Sendable, Equatable {
    case success(AppUpdateStatus)
    case failure(String)
}

/// 更新检查/下载/安装的状态机。
/// 管理检查代际、UI 状态、下载进度，并在完成后触发安装。
@Observable
@MainActor
final class AppUpdateStore {
    private(set) var status: AppUpdateStatus = .idle
    private(set) var lastCheckedAt: Date?
    private(set) var downloadProgress: Double = 0

    /// 是否开启自动检查更新（由外部同步 AppSettings 的值）。
    /// 关闭时，UI 展示状态会抑制「被动」的自动检查结果（发现新版本/已是最新/失败），
    /// 仅保留用户手动操作链中的状态（检查中/下载中/已下载/安装中）。
    var autoUpdateCheckEnabled: Bool = true

    private let service: AppUpdateService
    private var checkGeneration = 0
    private var currentCheckMode: AppUpdateCheckMode?

    /// 供 UI 使用的展示状态：会结合 `autoUpdateCheckEnabled` 抑制更新提示。
    /// 关闭自动检查时，完全不提示更新相关信息——已检查到的新版本、已是最新、失败、检查中、
    /// 空闲一律视为 `.idle`；仅保留用户已在进行的主动安装操作链（下载中/已下载/安装中），
    /// 从而主界面不再展示「发现新版本/需要下载」，右键菜单也回到静默状态。
    var presentationStatus: AppUpdateStatus {
        guard !autoUpdateCheckEnabled else { return status }
        switch status {
        case .downloading, .downloaded, .installing:
            return status
        case .available, .upToDate, .failed, .checking, .idle:
            return .idle
        }
    }

    init(service: AppUpdateService = AppUpdateService()) {
        self.service = service
    }

    /// 执行一次更新检查：先开启检查，再调用服务，最后收尾更新状态。
    func check(currentVersion: String, mode: AppUpdateCheckMode = .background) async {
        guard let request = startCheck(currentVersion: currentVersion, mode: mode) else { return }
        let completion: AppUpdateCheckCompletion
        do {
            let nextStatus = try await request.service.check(currentVersion: request.currentVersion, mode: request.mode)
            completion = .success(nextStatus)
        } catch {
            completion = .failure(error.localizedDescription)
        }
        finishCheck(request, completion: completion)
    }

    /// 开启一次检查：校验当前状态是否允许检查，递增代际并返回请求描述。
    func startCheck(currentVersion: String, mode: AppUpdateCheckMode = .background) -> AppUpdateCheckRequest? {
        guard canCheckForUpdates(mode: mode) else {
            appUpdateStoreLogger.info("Skip update check mode=\(String(describing: mode), privacy: .public) status=\(String(describing: self.status), privacy: .public) currentMode=\(String(describing: self.currentCheckMode), privacy: .public)")
            return nil
        }
        checkGeneration += 1
        let generation = checkGeneration
        currentCheckMode = mode
        status = .checking
        appUpdateStoreLogger.info("Start update check mode=\(String(describing: mode), privacy: .public) generation=\(generation, privacy: .public) currentVersion=\(currentVersion, privacy: .public)")
        return AppUpdateCheckRequest(
            generation: generation,
            currentVersion: currentVersion,
            mode: mode,
            service: service
        )
    }

    /// 收尾一次检查：忽略过期代际，按结果更新状态并记录检查时间。
    func finishCheck(_ request: AppUpdateCheckRequest, completion: AppUpdateCheckCompletion) {
        guard isCurrentCheck(request.generation) else {
            appUpdateStoreLogger.info("Ignore stale update check mode=\(String(describing: request.mode), privacy: .public) generation=\(request.generation, privacy: .public)")
            return
        }

        switch completion {
        case .success(let nextStatus):
            status = nextStatus
        case .failure(let message):
            status = .failed(message)
        }
        currentCheckMode = nil
        lastCheckedAt = .now
        appUpdateStoreLogger.info("Finish update check mode=\(String(describing: request.mode), privacy: .public) generation=\(request.generation, privacy: .public) status=\(String(describing: self.status), privacy: .public)")
    }

    /// 判断当前状态是否允许发起更新检查（交互式可打断后台检查）。
    private func canCheckForUpdates(mode: AppUpdateCheckMode) -> Bool {
        switch status {
        case .checking:
            return mode == .interactive && currentCheckMode == .background
        case .downloading, .downloaded, .installing:
            return false
        case .idle, .available, .upToDate, .failed:
            return true
        }
    }

    /// 判断给定代际是否为当前最新的检查（用于丢弃过期结果）。
    private func isCurrentCheck(_ generation: Int) -> Bool {
        generation == checkGeneration
    }

    /// 根据当前状态执行主操作：有更新则开始下载，已下载则安装。
    func openUpdate() {
        switch status {
        case .available(let info):
            Task {
                await downloadUpdate(info)
            }
        case .downloaded(let info, let package):
            installUpdate(info: info, package: package)
        case .downloading, .installing, .checking, .idle, .upToDate, .failed:
            break
        }
    }

    /// 下载更新包：实时更新下载进度，完成后进入「已下载」状态。
    private func downloadUpdate(_ info: AppUpdateInfo) async {
        downloadProgress = 0
        status = .downloading(info)
        do {
            let package = try await service.downloadPackage(for: info) { [weak self] progress in
                self?.downloadProgress = min(max(progress, 0), 1)
            }
            downloadProgress = 1
            status = .downloaded(info, package)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// 安装更新包：调用服务替换应用并终止当前进程以完成重启。
    private func installUpdate(info: AppUpdateInfo, package: AppUpdatePackage) {
        status = .installing(info)
        do {
            try service.installPackage(
                package,
                currentAppURL: Bundle.main.bundleURL,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// 主操作按钮标题（随更新状态变化）。
    var primaryActionTitle: String? {
        switch status {
        case .available:
            "下载更新"
        case .downloading:
            "正在下载 \(Int(downloadProgress * 100))%"
        case .downloaded:
            "现在更新"
        case .installing:
            "正在更新"
        case .idle, .checking, .upToDate, .failed:
            nil
        }
    }

    /// 主操作按钮图标（随更新状态变化）。
    var primaryActionSystemImage: String {
        switch status {
        case .available:
            "arrow.down.circle"
        case .downloading:
            "arrow.down.circle.fill"
        case .downloaded:
            "arrow.triangle.2.circlepath.circle"
        case .installing:
            "arrow.triangle.2.circlepath"
        case .idle, .checking, .upToDate, .failed:
            "arrow.clockwise"
        }
    }

    /// 主操作按钮是否禁用（下载/安装中禁用）。
    var isPrimaryActionDisabled: Bool {
        switch status {
        case .downloading, .installing:
            true
        case .idle, .checking, .available, .downloaded, .upToDate, .failed:
            false
        }
    }

    /// 菜单栏/通知区域展示的状态文案（随更新状态变化）。
    var badgeTitle: String? {
        switch status {
        case .available(let info):
            "发现新版本 v\(info.version)，点击下载"
        case .downloading(let info):
            "正在下载 v\(info.version) · \(Int(downloadProgress * 100))%"
        case .downloaded(let info, _):
            "更新已下载，点击安装 v\(info.version)"
        case .installing:
            "正在更新，应用将自动重启"
        case .checking:
            "检查更新中"
        case .failed(let message):
            "更新检查失败：\(message)"
        case .upToDate:
            "已是最新版本"
        case .idle:
            nil
        }
    }

}
