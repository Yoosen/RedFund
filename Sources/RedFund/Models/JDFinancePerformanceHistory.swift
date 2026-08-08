import Foundation

/// 京东金融同步得到的单日收益记录。
struct JDFinancePerformanceDay: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { date }

    /// 日期（yyyy-MM-dd）。
    var date: String
    /// 当日收益金额。
    var incomeAmount: Double
    /// 当日收益率（可选）。
    var incomeRate: Double?

    init(date: String, incomeAmount: Double, incomeRate: Double?) {
        self.date = date
        self.incomeAmount = incomeAmount
        self.incomeRate = incomeRate
    }
}

/// 京东金融历史每日收益集合，并标注覆盖区间与完整性。
struct JDFinancePerformanceHistory: Codable, Equatable, Sendable {
    /// 逐日收益记录。
    var days: [JDFinancePerformanceDay]
    /// 覆盖起始日期。
    var coveredFrom: String
    /// 覆盖结束日期。
    var coveredThrough: String
    /// 是否完整覆盖（无缺失区间）。
    var isComplete: Bool

    init(
        days: [JDFinancePerformanceDay],
        coveredFrom: String,
        coveredThrough: String,
        isComplete: Bool
    ) {
        self.days = days
        self.coveredFrom = coveredFrom
        self.coveredThrough = coveredThrough
        self.isComplete = isComplete
    }

    /// 空历史（加载失败/未同步兜底）。
    static let empty = JDFinancePerformanceHistory(
        days: [],
        coveredFrom: "",
        coveredThrough: "",
        isComplete: false
    )
}

/// 京东历史收益同步的日期区间。
struct JDFinancePerformanceHistoryRange: Equatable, Sendable {
    /// 起始日期。
    var from: String
    /// 结束日期。
    var through: String

    init(from: String, through: String) {
        self.from = from
        self.through = through
    }
}

/// 京东历史收益同步的错误类型。
enum JDFinancePerformanceHistoryError: LocalizedError, Equatable {
    case notLoggedIn
    case invalidDateRange
    case invalidResponse
    case server(String)
    case network(String)

    /// 各错误对应的中文提示。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "请先登录京东账号"
        case .invalidDateRange:
            "京东历史收益同步日期范围无效"
        case .invalidResponse:
            "京东历史收益接口结构变化，暂时无法解析"
        case .server(let message):
            message
        case .network(let message):
            message
        }
    }
}
