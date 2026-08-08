import Foundation

/// 收益记录状态（估值/已确认）。
enum PortfolioPerformanceRecordStatus: String, Codable, Equatable, Sendable {
    case estimated
    case confirmed

    /// 状态中文标题。
    var title: String {
        switch self {
        case .estimated:
            "估值"
        case .confirmed:
            "已确认"
        }
    }
}

/// 收益数据来源（本地行情记录/京东金融补全）。
enum PortfolioPerformanceSource: String, Codable, Equatable, Sendable {
    case localQuote
    case jdFinance

    /// 来源中文标题。
    var title: String {
        switch self {
        case .localQuote:
            "本地记录"
        case .jdFinance:
            "京东补全"
        }
    }
}

/// 单日组合收益记录。
struct PortfolioPerformanceDay: Codable, Identifiable, Equatable, Sendable {
    /// 稳定标识，即日期。
    var id: String { date }
    /// 日期（yyyy-MM-dd）。
    var date: String
    /// 当日收益金额。
    var profit: Double
    /// 当日收益率。
    var returnRate: Double?
    /// 记录状态（估值/已确认）。
    var status: PortfolioPerformanceRecordStatus
    /// 数据来源。
    var source: PortfolioPerformanceSource
    /// 来源账户键（区分本地/不同京东账号）。
    var sourceAccountKey: String?
    /// 记录更新时间。
    var updatedAt: Date

    /// 全量初始化器。
    init(
        date: String,
        profit: Double,
        returnRate: Double?,
        status: PortfolioPerformanceRecordStatus,
        source: PortfolioPerformanceSource = .localQuote,
        sourceAccountKey: String? = nil,
        updatedAt: Date
    ) {
        self.date = date
        self.profit = profit
        self.returnRate = returnRate
        self.status = status
        self.source = source
        self.sourceAccountKey = sourceAccountKey
        self.updatedAt = updatedAt
    }

    /// 编码键映射。
    private enum CodingKeys: String, CodingKey {
        case date
        case profit
        case returnRate
        case status
        case source
        case sourceAccountKey
        case updatedAt
    }

    /// 自定义解码，缺省字段回退默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        profit = try container.decode(Double.self, forKey: .profit)
        returnRate = try container.decodeIfPresent(Double.self, forKey: .returnRate)
        status = try container.decode(PortfolioPerformanceRecordStatus.self, forKey: .status)
        source = try container.decodeIfPresent(PortfolioPerformanceSource.self, forKey: .source)
            ?? .localQuote
        sourceAccountKey = try container.decodeIfPresent(String.self, forKey: .sourceAccountKey)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// 京东金融收益同步元数据（覆盖区间、账号、完成度）。
struct JDFinancePerformanceSyncMetadata: Codable, Equatable, Sendable {
    var accountKey: String
    var coveredFrom: String
    var coveredThrough: String
    var lastSyncedAt: Date
    var isComplete: Bool
}

/// 组合收益快照（图表数据核心，独立持久化）。
struct PortfolioPerformanceSnapshot: Codable, Equatable, Sendable {
    /// 当前数据结构 schema 版本。
    static let currentSchemaVersion = 2
    /// 空快照。
    static let empty = PortfolioPerformanceSnapshot()

    /// schema 版本。
    var schemaVersion: Int
    /// 收益追踪起始日期。
    var trackingStartDate: String?
    /// 本地记录起始日期。
    var localRecordingStartDate: String?
    /// 每日收益记录列表。
    var days: [PortfolioPerformanceDay]
    /// 京东金融同步元数据。
    var jdFinanceSync: JDFinancePerformanceSyncMetadata?

    /// 全量初始化器。
    init(
        schemaVersion: Int = currentSchemaVersion,
        trackingStartDate: String? = nil,
        localRecordingStartDate: String? = nil,
        days: [PortfolioPerformanceDay] = [],
        jdFinanceSync: JDFinancePerformanceSyncMetadata? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.trackingStartDate = trackingStartDate
        self.localRecordingStartDate = localRecordingStartDate
        self.days = days
        self.jdFinanceSync = jdFinanceSync
    }

    /// 编码键映射。
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case trackingStartDate
        case localRecordingStartDate
        case days
        case jdFinanceSync
    }

    /// 自定义解码，处理旧版本 schema 缺省字段的迁移。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = decodedSchemaVersion
        trackingStartDate = try container.decodeIfPresent(String.self, forKey: .trackingStartDate)
        localRecordingStartDate = try container.decodeIfPresent(String.self, forKey: .localRecordingStartDate)
        if decodedSchemaVersion < 2, localRecordingStartDate == nil {
            localRecordingStartDate = trackingStartDate
        }
        days = try container.decodeIfPresent([PortfolioPerformanceDay].self, forKey: .days) ?? []
        jdFinanceSync = try container.decodeIfPresent(
            JDFinancePerformanceSyncMetadata.self,
            forKey: .jdFinanceSync
        )
    }
}

/// 组合收益数据点（含累计收益），用于图表。
struct PortfolioPerformancePoint: Identifiable, Equatable, Sendable {
    /// 稳定标识。
    var id: String { day.id }
    /// 当日收益记录。
    var day: PortfolioPerformanceDay
    /// 截至该日的累计收益。
    var cumulativeProfit: Double
}

/// 收益图表纵轴比例尺（最小/最大值）。
struct PortfolioPerformanceChartScale: Equatable, Sendable {
    let minimum: Double
    let maximum: Double

    /// 由一组数值构造比例尺，全为 0 时回退到 [-1, 1]。
    init(values: [Double]) {
        let rawMinimum = min(values.min() ?? 0, 0)
        let rawMaximum = max(values.max() ?? 0, 0)
        if rawMinimum == rawMaximum {
            minimum = -1
            maximum = 1
        } else {
            minimum = rawMinimum
            maximum = rawMaximum
        }
    }

    /// 将数值归一化到 [0, 1] 的 Y 坐标（1 表示顶部）。
    func normalizedY(for value: Double) -> Double {
        1 - ((value - minimum) / (maximum - minimum))
    }
}

/// 收益图表色调（正/负/中性）。
enum PortfolioPerformanceChartTone: Equatable, Sendable {
    case positive
    case negative
    case neutral

    /// 由数值正负判定色调。
    init(value: Double) {
        if value > 0 {
            self = .positive
        } else if value < 0 {
            self = .negative
        } else {
            self = .neutral
        }
    }
}

/// 收益图表坐标轴标签（最大值/最小值）。
struct PortfolioPerformanceChartAxisLabels: Equatable, Sendable {
    var maximum: Double?
    var minimum: Double?

    /// 由具体值构造。
    init(maximum: Double?, minimum: Double?) {
        self.maximum = maximum
        self.minimum = minimum
    }

    /// 由数值与比例尺构造；全 0 时不展示刻度。
    init(values: [Double], scale: PortfolioPerformanceChartScale) {
        guard values.contains(where: { $0 != 0 }) else {
            maximum = nil
            minimum = nil
            return
        }

        maximum = scale.maximum == 0 ? nil : scale.maximum
        minimum = scale.minimum == 0 ? nil : scale.minimum
    }
}

/// 图表分段（起点/终点比例 + 色调），用于绘制正负区间。
struct PortfolioPerformanceChartSegmentPortion: Equatable, Sendable {
    var startFraction: Double
    var endFraction: Double
    var tone: PortfolioPerformanceChartTone
}

/// 收益图表配色工具：计算相邻值之间的分段色调。
enum PortfolioPerformanceChartColor {
    /// 由起点值到终点值计算分段色调列表（处理正负穿越情形）。
    static func segmentPortions(
        from startValue: Double,
        to endValue: Double
    ) -> [PortfolioPerformanceChartSegmentPortion] {
        if startValue > 0, endValue < 0 {
            let crossing = startValue / (startValue - endValue)
            return [
                .init(startFraction: 0, endFraction: crossing, tone: .positive),
                .init(startFraction: crossing, endFraction: 1, tone: .negative)
            ]
        }
        if startValue < 0, endValue > 0 {
            let crossing = startValue / (startValue - endValue)
            return [
                .init(startFraction: 0, endFraction: crossing, tone: .negative),
                .init(startFraction: crossing, endFraction: 1, tone: .positive)
            ]
        }
        if startValue == 0, endValue == 0 {
            return [.init(startFraction: 0, endFraction: 1, tone: .neutral)]
        }
        let tone: PortfolioPerformanceChartTone = startValue < 0 || endValue < 0
            ? .negative
            : .positive
        return [.init(startFraction: 0, endFraction: 1, tone: tone)]
    }
}

/// 收益图表可选择的日期范围（1 周/1 月/3 月/6 月/1 年/全部）。
enum PortfolioPerformanceRange: String, CaseIterable, Identifiable, Sendable {
    case oneWeek
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case all

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 范围中文标题。
    var title: String {
        switch self {
        case .oneWeek:
            "1周"
        case .oneMonth:
            "1月"
        case .threeMonths:
            "3月"
        case .sixMonths:
            "6月"
        case .oneYear:
            "1年"
        case .all:
            "全部"
        }
    }
}

/// 收益月历网格（某月的每日收益格子）。
struct PortfolioPerformanceMonthGrid: Equatable, Sendable {
    var monthKey: String
    var cells: [String?]
}

/// 收益月度汇总（每日记录、总收益、涨跌天数等）。
struct PortfolioPerformanceMonthSummary: Equatable, Sendable {
    var days: [PortfolioPerformanceDay]
    var totalProfit: Double
    var riseDays: Int
    var fallDays: Int
    /// 估值天数：当天未获取到完整官方净值的天数（当晚官方净值更新后即转为已确认，不再计为估值）。
    var estimatedDays: Int
    /// 本地记录天数：未同步京东金融、由本机行情刷新写入的天数。
    var localQuoteDays: Int
}
