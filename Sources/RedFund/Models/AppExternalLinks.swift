import Foundation

/// 应用内跳转的外部链接地址集合（隐私政策、问题反馈等）。
enum AppExternalLinks {
    /// 隐私政策与免责声明页面。
    static let privacyPolicyURL = URL(
        string: "https://github.com/yoosen/red-fund/blob/main/PRIVACY.md"
    )!
    /// GitHub Issues 选择模板入口。
    static let issueChooserURL = URL(
        string: "https://github.com/yoosen/red-fund/issues/new/choose"
    )!
    /// 提交 Bug 报告的模板链接。
    static let bugReportURL = URL(
        string: "https://github.com/yoosen/red-fund/issues/new?template=issue_template_bug"
    )!
    /// 提交功能建议的模板链接。
    static let featureRequestURL = URL(
        string: "https://github.com/yoosen/red-fund/issues/new?template=issue_template_feature"
    )!
}

/// 外部链接的打开动作及其结果，支持“打开失败则复制文本”的兜底策略。
enum AppExternalLinkAction {
    /// 动作执行结果：已打开，或已复制文本（携带提示信息）。
    enum Outcome: Equatable {
        case opened
        case copied(message: String)
    }

    /// 尝试用 `open` 打开链接；若打开失败，则用 `copy` 复制兜底文本并返回 copied 结果。
    static func perform(
        url: URL,
        fallbackText: String,
        failureMessage: String,
        open: (URL) -> Bool,
        copy: (String) -> Void
    ) -> Outcome {
        guard !open(url) else { return .opened }
        copy(fallbackText)
        return .copied(message: failureMessage)
    }
}
