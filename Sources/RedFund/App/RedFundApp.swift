import AppKit          // macOS 原生 UI 框架，提供 NSApp、菜单栏等能力
import Foundation      // 基础库：Bundle、ProcessInfo 等
import SwiftUI         // 声明式 UI 框架，提供 App / Scene 协议
import UserNotifications // 系统通知框架，用于操作提醒推送

// @main 标记程序入口；RedFundApp 遵循 SwiftUI 的 App 协议
@main
struct RedFundApp: App {
    // 将传统的 AppKit 生命周期委托（AppDelegate）桥接进 SwiftUI 生命周期
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App 的场景描述
    var body: some Scene {
        // 本应用是菜单栏常驻程序，没有主窗口；
        // 这里仅提供一个空的设置场景占位，避免显示真实窗口
        Settings {
            EmptyView()
                .frame(width: 0, height: 0) // 尺寸设为 0，使其不可见
        }
    }
}

// 应用委托类：承担真正的启动、刷新、通知等逻辑
// @MainActor 保证类内成员默认在主线程执行（UI 相关操作要求）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let portfolioStore = PortfolioStore()       // 持仓数据仓库：管理基金持仓与行情
    let settingsStore = AppSettingsStore()      // 应用设置仓库：读写用户偏好
    let marketIndexStore = MarketIndexStore()   // 大盘指数仓库：管理指数数据
    let updateStore = AppUpdateStore()          // 更新仓库：负责检查/下载新版本
    // 操作提醒通知的"展示闸门"，用于去重/过滤重复通知；nonisolated 表示不受 MainActor 约束，可在任意线程访问
    nonisolated private let operationReminderPresentationGate = OperationReminderNotificationPresentationGate()
    private var statusBarController: StatusBarController?          // 菜单栏控制器：管理状态栏图标与菜单
    private var backgroundRefreshActivity: (any NSObjectProtocol)? // 后台活动令牌：用于抑制 App Nap

    // 从 Info.plist 读取当前应用版本号，读不到时回退为 "0.0.0"
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // 应用启动完成时调用（核心初始化入口）
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 设为 accessory：不在 Dock 显示图标，只驻留菜单栏
        // 菜单栏常驻应用需在后台定时刷新行情，抑制 App Nap 避免刷新定时器被系统挂起。
        backgroundRefreshActivity = ProcessInfo.processInfo.beginActivity(
            options: .background,               // 声明为后台活动
            reason: "保持基金行情定时刷新"        // 系统展示/日志用的原因说明
        )
        UNUserNotificationCenter.current().delegate = self // 设置自己为通知中心代理，接管通知展示
#if DEBUG
        // Debug 构建：保留调试产物，不做清理
#else
        JDFinanceDebugArtifacts.removePersistedFiles() // Release 构建：清理落盘的京东金融调试文件
#endif
        portfolioStore.load() // 加载本地已保存的持仓数据
        // 创建菜单栏控制器，注入各数据仓库与版本号，并传入更新相关的回调
        statusBarController = StatusBarController(
            store: portfolioStore,
            settingsStore: settingsStore,
            marketIndexStore: marketIndexStore,
            updateStore: updateStore,
            appVersion: appVersion,
            onCheckUpdate: { [weak self] mode in       // 手动检查更新的回调（弱引用防循环持有）
                await self?.checkForUpdates(mode: mode)
            },
            onOpenUpdate: { [weak self] in             // 打开/前往更新的回调
                self?.updateStore.openUpdate()
            }
        )
        statusBarController?.presentInitialExperienceIfNeeded() // 首次启动时展示引导/初始体验
#if DEBUG
        statusBarController?.presentDebugPanelIfRequested()     // Debug 下按需弹出调试面板
#endif
        Task {
            // 仅在开启自动检查更新时，启动后异步进行一次后台更新检查
            guard settingsStore.settings.autoUpdateCheckEnabled else { return }
            await checkForUpdates() // 启动后异步进行一次后台更新检查
        }
    }

    // 应用即将退出时调用，做资源清理
    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.invalidate() // 让菜单栏控制器停止定时器等资源
        statusBarController = nil          // 释放控制器
        if let backgroundRefreshActivity {
            ProcessInfo.processInfo.endActivity(backgroundRefreshActivity) // 结束后台活动，恢复 App Nap
            self.backgroundRefreshActivity = nil
        }
    }

    // 仅刷新菜单栏标题（不重新拉取数据）
    func refreshStatusTitle() {
        statusBarController?.updateStatusTitle()
    }

    // 刷新持仓行情（必要时同时刷新大盘指数），然后更新菜单栏标题
    func refreshPortfolioAndStatusTitle() async {
        await portfolioStore.refreshQuotes()            // 拉取最新基金净值/行情
        if settingsStore.settings.showsMarketIndexes {  // 若用户设置显示大盘指数
            await marketIndexStore.refresh()            // 则刷新指数数据
        }
        refreshStatusTitle()                            // 最后刷新菜单栏文字
    }

    // 检查更新，默认以后台模式执行
    func checkForUpdates(mode: AppUpdateCheckMode = .background) async {
        await updateStore.check(currentVersion: appVersion, mode: mode)
    }

    // 通知中心代理方法：决定应用在前台时通知如何展示
    // nonisolated：不在 MainActor 上执行，允许系统在任意线程回调
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let request = notification.request
        // 将通知内容包装成"操作提醒候选对象"，用于闸门判断
        let candidate = OperationReminderNotificationCandidate(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body
        )
        // 若闸门判定不应展示（如重复通知），返回空数组即不弹出
        guard await operationReminderPresentationGate.shouldPresent(candidate) else {
            return []
        }
        return [.banner, .sound] // 允许展示：以横幅 + 声音的形式呈现
    }
}
