import Foundation

/// 待匹配的通知候选项（标识、标题、正文）。
struct OperationReminderNotificationCandidate: Equatable, Sendable {
    /// 通知标识。
    let identifier: String
    /// 通知标题。
    let title: String
    /// 通知正文。
    let body: String
}

/// 一条待调度的操作提醒通知请求，含触发时间。
struct OperationReminderNotificationRequest: Equatable, Sendable {
    /// 通知标识。
    let identifier: String
    /// 通知标题。
    let title: String
    /// 通知正文。
    let body: String
    /// 触发时间。
    let fireDate: Date
}

/// 操作提醒通知的固定文案与标识常量。
enum OperationReminderNotificationContent {
    /// 旧版单条通知标识。
    static let legacyIdentifier = "red-fund.operation-reminder"
    /// 新版按日期拆分通知的标识前缀。
    static let identifierPrefix = "\(legacyIdentifier)."
    /// 通知标题。
    static let title = "基金操作提醒"
    /// 通知正文。
    static let body = "现在可以检查基金估值，按计划处理加仓、减仓或继续持仓。"
}

/// 识别并收集需要清理的京东操作提醒通知。
enum OperationReminderNotificationCleanup {
    /// 判断候选通知是否为本应用的操作提醒（按标识或标题+正文匹配）。
    static func isOperationReminder(_ candidate: OperationReminderNotificationCandidate) -> Bool {
        candidate.identifier == OperationReminderNotificationContent.legacyIdentifier
            || candidate.identifier.hasPrefix(OperationReminderNotificationContent.identifierPrefix)
            || (
                candidate.title == OperationReminderNotificationContent.title
                    && candidate.body == OperationReminderNotificationContent.body
            )
    }

    /// 返回所有匹配操作提醒的标识（去重排序）。
    static func matchingIdentifiers(
        in candidates: [OperationReminderNotificationCandidate]
    ) -> [String] {
        Set(
            candidates.filter(isOperationReminder).map(\.identifier)
        ).sorted()
    }
}

/// 基于时间窗口的展示去重闸门，防止短时间内重复弹出操作提醒。
actor OperationReminderNotificationPresentationGate {
    /// 判定为重复的展示间隔。
    private let duplicateWindow: TimeInterval
    /// 上次展示时间。
    private var lastPresentedAt: Date?

    /// 初始化闸门，间隔下限钳制为 0。
    init(duplicateWindow: TimeInterval = 60) {
        self.duplicateWindow = max(duplicateWindow, 0)
    }

    /// 判断候选通知此刻是否允许展示；非本应用通知一律放行，本应用通知在窗口内去重。
    func shouldPresent(
        _ candidate: OperationReminderNotificationCandidate,
        at date: Date = .now
    ) -> Bool {
        guard OperationReminderNotificationCleanup.isOperationReminder(candidate) else {
            return true
        }

        if let lastPresentedAt,
           date.timeIntervalSince(lastPresentedAt) < duplicateWindow {
            return false
        }

        lastPresentedAt = date
        return true
    }
}

/// 在主线程调度操作提醒通知的增删与权限申请。
@MainActor
final class OperationReminderNotificationScheduler {
    /// 清除待发送通知的最大尝试次数。
    private let maximumRemovalAttempts: Int
    /// 读取待发送通知的注入回调。
    private let pendingRequests: @MainActor () async -> [OperationReminderNotificationCandidate]
    /// 移除待发送通知的注入回调。
    private let removePendingRequests: @MainActor ([String]) -> Void
    /// 读取已送达通知的注入回调。
    private let deliveredNotifications: @MainActor () async -> [OperationReminderNotificationCandidate]
    /// 移除已送达通知的注入回调。
    private let removeDeliveredNotifications: @MainActor ([String]) -> Void
    /// 申请通知授权的注入回调。
    private let requestAuthorization: @MainActor () async throws -> Bool
    /// 添加单条通知的注入回调。
    private let addRequest: @MainActor (OperationReminderNotificationRequest) async throws -> Void
    /// 每次清除尝试后的等待回调。
    private let waitAfterRemovalAttempt: @MainActor () async -> Void

    /// 当前重建配置的后台任务。
    private var configurationTask: Task<Void, Never>?

    /// 注入全部依赖回调并钳制最大移除尝试次数（至少 1）。
    init(
        maximumRemovalAttempts: Int,
        pendingRequests: @escaping @MainActor () async -> [OperationReminderNotificationCandidate],
        removePendingRequests: @escaping @MainActor ([String]) -> Void,
        deliveredNotifications: @escaping @MainActor () async -> [OperationReminderNotificationCandidate],
        removeDeliveredNotifications: @escaping @MainActor ([String]) -> Void,
        requestAuthorization: @escaping @MainActor () async throws -> Bool,
        addRequest: @escaping @MainActor (OperationReminderNotificationRequest) async throws -> Void,
        waitAfterRemovalAttempt: @escaping @MainActor () async -> Void
    ) {
        self.maximumRemovalAttempts = max(maximumRemovalAttempts, 1)
        self.pendingRequests = pendingRequests
        self.removePendingRequests = removePendingRequests
        self.deliveredNotifications = deliveredNotifications
        self.removeDeliveredNotifications = removeDeliveredNotifications
        self.requestAuthorization = requestAuthorization
        self.addRequest = addRequest
        self.waitAfterRemovalAttempt = waitAfterRemovalAttempt
    }

    /// 取消旧任务并异步重建通知配置（启用状态 + 待调度请求）。
    func configure(isEnabled: Bool, requests: [OperationReminderNotificationRequest]) {
        let previousTask = configurationTask
        previousTask?.cancel()

        configurationTask = Task { [weak self, previousTask] in
            if let previousTask {
                await previousTask.value
            }
            guard let self, !Task.isCancelled else { return }
            await rebuild(isEnabled: isEnabled, requests: requests)
        }
    }

    /// 取消并清空配置任务。
    func invalidate() {
        configurationTask?.cancel()
        configurationTask = nil
    }

    /// 等待当前配置任务完成。
    func waitUntilIdle() async {
        let task = configurationTask
        await task?.value
    }

    /// 先清理旧提醒，再按启用状态与权限添加新提醒。
    private func rebuild(
        isEnabled: Bool,
        requests: [OperationReminderNotificationRequest]
    ) async {
        guard await removePendingOperationReminders(), !Task.isCancelled else { return }

        let deliveredCandidates = await deliveredNotifications()
        guard !Task.isCancelled else { return }
        let deliveredIdentifiers = OperationReminderNotificationCleanup.matchingIdentifiers(
            in: deliveredCandidates
        )
        if !deliveredIdentifiers.isEmpty {
            removeDeliveredNotifications(deliveredIdentifiers)
        }

        guard isEnabled, !requests.isEmpty, !Task.isCancelled else { return }
        guard (try? await requestAuthorization()) == true, !Task.isCancelled else { return }

        var addedIdentifiers: Set<String> = []
        for request in requests where addedIdentifiers.insert(request.identifier).inserted {
            guard !Task.isCancelled else { return }
            try? await addRequest(request)
        }
    }

    /// 按最大次数尝试清除待发送的操作提醒，返回是否清理干净。
    private func removePendingOperationReminders() async -> Bool {
        for _ in 0..<maximumRemovalAttempts {
            guard !Task.isCancelled else { return false }

            let candidates = await pendingRequests()
            guard !Task.isCancelled else { return false }
            let identifiers = OperationReminderNotificationCleanup.matchingIdentifiers(in: candidates)
            guard !identifiers.isEmpty else { return true }

            removePendingRequests(identifiers)
            await waitAfterRemovalAttempt()
        }

        guard !Task.isCancelled else { return false }
        let remainingCandidates = await pendingRequests()
        return OperationReminderNotificationCleanup.matchingIdentifiers(in: remainingCandidates).isEmpty
    }
}
