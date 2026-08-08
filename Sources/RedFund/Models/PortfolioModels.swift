import Foundation

/// 组合（账本）快照：组合整体指标与全部基金持仓、交易记录等。
struct PortfolioSnapshot: Codable, Equatable {
    /// 快照更新时间。
    var updateTime: Date
    /// 总资产金额。
    var totalAmount: Double
    /// 持有收益（累计）。
    var holdingIncome: Double
    /// 持有收益率。
    var holdingIncomeRate: Double
    /// 今日收益。
    var todayIncome: Double
    /// 今日收益率。
    var todayIncomeRate: Double
    /// 待确认数量。
    var pendingCount: Int
    /// 基金持仓列表。
    var funds: [FundPosition]
    /// 迁移信息（旧版数据迁移标记）。
    var migration: MigrationInfo?
    /// 待确认交易列表。
    var pendingTrades: [FundPendingTrade]? = nil
    /// 待确认转换列表。
    var pendingConversions: [FundPendingConversion]? = nil
    /// 已确认交易记录列表。
    var tradeRecords: [FundTradeRecord]? = nil
    /// 同步账户的总资产（如京东金融）。
    var syncedAccountTotal: PortfolioSyncedAccountTotal? = nil
    /// 京东金融同步状态。
    var jdFinanceSyncState: JDFinanceSyncState? = nil
    // Only populated in exported backups. Runtime history lives in
    // portfolio-performance.json so high-frequency quote refreshes do not
    // repeatedly rewrite a growing history array.
    /// 收益历史快照，仅在导出的备份中填充；运行时历史存于独立文件。
    var portfolioPerformanceHistory: PortfolioPerformanceSnapshot? = nil

    /// 空快照（用于首次启动/无数据场景）。
    static let empty = PortfolioSnapshot(
        updateTime: .now,
        totalAmount: 0,
        holdingIncome: 0,
        holdingIncomeRate: 0,
        todayIncome: 0,
        todayIncomeRate: 0,
        pendingCount: 0,
        funds: [],
        migration: nil
    )

}

/// 京东金融同步状态（基线建立时间、已覆盖订单键等）。
struct JDFinanceSyncState: Codable, Equatable {
    var schemaVersion: Int = 1
    /// 京东账户键（用于识别账号）。
    var accountKey: String?
    /// 基线建立时间。
    var baselineEstablishedAt: Date
    /// 最近一次完整交易订单同步时间。
    var lastCompleteTradeOrderSyncAt: Date? = nil
    /// 已纳入代表的订单键。
    var representedOrderKeys: [String] = []
    /// 用户已忽略的订单键。
    var dismissedOrderKeys: [String] = []
    /// 跟踪中的待确认订单键。
    var trackedPendingOrderKeys: [String] = []
    /// 跟踪待确认订单的起始日期。
    var trackedPendingStartDate: String? = nil
}

/// 同步账户总资产记录（来源 + 金额 + 同步时间）。
struct PortfolioSyncedAccountTotal: Codable, Equatable {
    var source: PortfolioAccountTotalSource
    var amount: Double
    var syncedAt: Date
}

/// 同步账户总资产来源。
enum PortfolioAccountTotalSource: String, Codable, Equatable {
    case jdFinance
}

/// 基金持仓（单只基金在组合中的状态）。
struct FundPosition: Codable, Identifiable, Equatable {
    /// 稳定标识，即基金代码。
    var id: String { code }
    /// 基金代码。
    var code: String
    /// 基金名称。
    var name: String
    /// 持仓日期文本。
    var dateText: String
    /// 今日收益。
    var todayIncome: Double
    /// 今日收益率。
    var todayRate: Double
    /// 持有收益（累计）。
    var holdingIncome: Double? = nil
    /// 持有收益率。
    var holdingRate: Double?
    /// 已确认持仓收益。
    var confirmedHoldingIncome: Double? = nil
    /// 已确认持仓收益率。
    var confirmedHoldingRate: Double? = nil
    /// 当前金额（持仓市值）。
    var currentAmount: Double? = nil
    /// 持仓状态（持有/待确认/观察）。
    var status: FundHoldingStatus
    /// 是否已更新行情。
    var isUpdated: Bool
    /// 收益是否处于活动计算状态。
    var isIncomeActive: Bool? = nil
    /// 迁移得到的份额。
    var migratedShares: Double? = nil
    /// 迁移得到的成本。
    var migratedCost: Double? = nil
    /// 迁移得到的总本金。
    var migratedPrincipal: Double? = nil
    /// 收益计算起始日期。
    var incomeStartDate: String? = nil
    /// 持仓计价模式（金额/份额）。
    var positionMode: PositionMode? = nil
    /// 持仓建立日期。
    var positionDate: String? = nil
    /// 持仓建立时段（15:00 前/后）。
    var positionTimeType: PositionTimeType? = nil
    /// 待确认金额。
    var pendingAmount: Double? = nil
    /// 待确认收益。
    var pendingProfit: Double? = nil
    // JD's synced holding amount may include today's buy orders before shares are confirmed.
    /// 京东同步持仓中尚未确认份额的买入金额（需扣减）。
    var syncedPendingBuyAmount: Double? = nil
    /// 该待确认买入对应的日期。
    var syncedPendingBuyDate: String? = nil
    // JD's reported daily income is retained as sync metadata; realtime income is calculated locally.
    /// 京东上报的今日收益，保留为同步元数据；实时收益由本地计算。
    var syncedTodayIncome: Double? = nil
    /// 京东今日收益对应日期。
    var syncedTodayIncomeDate: String? = nil
    /// 涨跌幅区间（%）。
    var zdfRange: Double? = nil
    /// 净值提示值。
    var jzNotice: Double? = nil
    /// 备注。
    var memo: String? = nil
    /// 持仓批次（按批次记录份额/成本）。
    var lots: [FundPositionLot]? = nil
    /// 盘中收益率采样日期。
    var intradayRateDate: String? = nil
    /// 盘中收益率历史采样点。
    var intradayRateHistory: [FundIntradayRatePoint]? = nil
}

/// 持仓批次：单笔建仓的份额、成本与日期。
struct FundPositionLot: Codable, Identifiable, Equatable {
    var id: String
    var shares: Double
    var cost: Double
    var principal: Double? = nil
    var incomeStartDate: String
    var positionDate: String
    var positionTimeType: PositionTimeType
}

/// 盘中收益率采样点。
struct FundIntradayRatePoint: Codable, Identifiable, Equatable {
    var id: Int64 { timestamp }
    var timestamp: Int64
    var rate: Double
    var estimateTime: String
}

/// 交易种类（新增基金/加仓/减仓/转换转出/转入）。
enum FundTradeKind: String, Codable, Equatable {
    case newFund
    case buy
    case sell
    case conversionOut
    case conversionIn

    /// 交易种类中文标题。
    var title: String {
        switch self {
        case .newFund:
            "新增基金"
        case .buy:
            "加仓"
        case .sell:
            "减仓"
        case .conversionOut:
            "转换转出"
        case .conversionIn:
            "转换转入"
        }
    }
}

/// 交易记录状态（待确认/已确认/失败）。
enum FundTradeRecordStatus: String, Codable, Equatable {
    case pending
    case confirmed
    case failed

    /// 状态中文标题。
    var title: String {
        switch self {
        case .pending:
            "待确认"
        case .confirmed:
            "已确认"
        case .failed:
            "失败"
        }
    }
}

/// 交易同步来源。
enum FundTradeSyncSource: String, Codable, Equatable {
    case jdFinance
}

/// 交易外部确认状态（等待外部确认/已确认/冲突）。
enum FundTradeExternalStatus: String, Codable, Equatable {
    case waitingExternalConfirmation
    case externalConfirmed
    case conflict
}

/// 交易同步元数据（来源、同步键、外部状态等）。
struct FundTradeSyncMetadata: Codable, Equatable {
    var source: FundTradeSyncSource
    var syncKey: String?
    var externalStatus: FundTradeExternalStatus?
    var externalStatusText: String?
    var waitsForExternalConfirmation: Bool? = nil
}

/// 交易记录（已确认的建仓/交易流水）。
struct FundTradeRecord: Codable, Identifiable, Equatable {
    var id: String
    var kind: FundTradeKind
    var status: FundTradeRecordStatus
    var code: String
    var name: String
    var mode: PositionMode
    var amount: Double?
    var shares: Double?
    var confirmedShares: Double?
    var price: Double?
    var profit: Double? = nil
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var acceptedDate: String
    var createdAt: Date
    var confirmedAt: Date?
    var failureReason: String?
    var buyFeeRate: Double? = nil
    var sellFeeMode: TradeFeeMode? = nil
    var sellFeeValue: Double? = nil
    var conversionID: String? = nil
    var linkedCode: String? = nil
    var linkedName: String? = nil
    var feeAmount: Double? = nil
    var syncSource: FundTradeSyncSource? = nil
    var syncKey: String? = nil
    var externalStatus: FundTradeExternalStatus? = nil
    var externalStatusText: String? = nil
    var waitsForExternalConfirmation: Bool? = nil
    var isReconciliationBaseline: Bool? = nil
}

/// 交易动作（加仓/减仓）。
enum FundTradeAction: String, Codable, CaseIterable, Identifiable, Equatable {
    case buy
    case sell

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 动作中文标题。
    var title: String {
        switch self {
        case .buy:
            "加仓"
        case .sell:
            "减仓"
        }
    }
}

/// 卖出费用计算模式（费率/金额）。
enum TradeFeeMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case rate
    case amount

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 模式中文标题。
    var title: String {
        switch self {
        case .rate:
            "费率"
        case .amount:
            "金额"
        }
    }
}

/// 交易草稿（尚未落库的买入/卖出编辑态）。
struct FundTradeDraft: Equatable {
    var action: FundTradeAction
    var code: String
    var mode: PositionMode
    var amount: Double?
    var shares: Double?
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var buyFeeRate: Double? = nil
    var sellFeeMode: TradeFeeMode? = nil
    var sellFeeValue: Double? = nil
}

/// 待确认交易（挂起的买入/卖出，待确认后转为记录）。
struct FundPendingTrade: Codable, Identifiable, Equatable {
    var id: String
    var recordID: String? = nil
    var action: FundTradeAction
    var code: String
    var mode: PositionMode
    var amount: Double?
    var shares: Double?
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var createdAt: Date
    var buyFeeRate: Double? = nil
    var sellFeeMode: TradeFeeMode? = nil
    var sellFeeValue: Double? = nil
    var syncSource: FundTradeSyncSource? = nil
    var syncKey: String? = nil
    var externalStatus: FundTradeExternalStatus? = nil
    var externalStatusText: String? = nil
    var waitsForExternalConfirmation: Bool? = nil

    /// 转换为可落库的 FundTradeDraft。
    var draft: FundTradeDraft {
        FundTradeDraft(
            action: action,
            code: code,
            mode: mode,
            amount: amount,
            shares: shares,
            tradeDate: tradeDate,
            tradeTimeType: tradeTimeType,
            buyFeeRate: buyFeeRate,
            sellFeeMode: sellFeeMode,
            sellFeeValue: sellFeeValue
        )
    }
}

/// 转换草稿（基金间转换的编辑态）。
struct FundConversionDraft: Equatable {
    var fromCode: String
    var toCode: String
    var toName: String? = nil
    var shares: Double
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var sellFeeMode: TradeFeeMode = .rate
    var sellFeeValue: Double = 0
    var buyFeeRate: Double = 0
}

/// 待确认转换（挂起的基金转换，待确认后转为两条记录）。
struct FundPendingConversion: Codable, Identifiable, Equatable {
    var id: String
    var outRecordID: String? = nil
    var inRecordID: String? = nil
    var fromCode: String
    var toCode: String
    var toName: String?
    var shares: Double
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var acceptedDate: String
    var createdAt: Date
    var sellFeeMode: TradeFeeMode = .rate
    var sellFeeValue: Double = 0
    var buyFeeRate: Double = 0
    var failureReason: String? = nil
    var syncSource: FundTradeSyncSource? = nil
    var syncKey: String? = nil
    var externalStatus: FundTradeExternalStatus? = nil
    var externalStatusText: String? = nil
    var waitsForExternalConfirmation: Bool? = nil

    /// 转换为可落库的 FundConversionDraft。
    var draft: FundConversionDraft {
        FundConversionDraft(
            fromCode: fromCode,
            toCode: toCode,
            toName: toName,
            shares: shares,
            tradeDate: tradeDate,
            tradeTimeType: tradeTimeType,
            sellFeeMode: sellFeeMode,
            sellFeeValue: sellFeeValue,
            buyFeeRate: buyFeeRate
        )
    }
}

/// 持仓草稿（新建持仓的编辑态）。
struct FundPositionDraft: Equatable {
    var code: String
    var name: String
    var positionMode: PositionMode
    var positionAmount: Double?
    var positionProfit: Double
    var shares: Double?
    var cost: Double?
    var positionDate: String
    var positionTimeType: PositionTimeType
    var memo: String
    var requiresTradeConfirmation: Bool = true

    /// 全量初始化器。
    init(
        code: String,
        name: String,
        positionMode: PositionMode,
        positionAmount: Double? = nil,
        positionProfit: Double,
        shares: Double? = nil,
        cost: Double? = nil,
        positionDate: String,
        positionTimeType: PositionTimeType,
        memo: String,
        requiresTradeConfirmation: Bool = true
    ) {
        self.code = code
        self.name = name
        self.positionMode = positionMode
        self.positionAmount = positionAmount
        self.positionProfit = positionProfit
        self.shares = shares
        self.cost = cost
        self.positionDate = positionDate
        self.positionTimeType = positionTimeType
        self.memo = memo
        self.requiresTradeConfirmation = requiresTradeConfirmation
    }
}

/// 按金额同步持仓更新（代码/金额/收益/待确认买入）。
struct FundAmountPositionSyncUpdate: Equatable {
    var code: String
    var amount: Double
    var holdingIncome: Double?
    var syncedPendingBuyAmount: Double? = nil
    var syncedAt: Date? = nil
}

/// 迁移信息（旧版钱包数据迁移标记）。
struct MigrationInfo: Codable, Equatable {
    var source: String
    var currentWalletCode: String
    var walletName: String
    var eyeStatus: Bool
}

/// 持仓状态（持有/待确认/观察）。
enum FundHoldingStatus: String, Codable, Equatable {
    case holding
    case pending
    case watch

    /// 状态中文标题。
    var title: String {
        switch self {
        case .holding:
            "持有"
        case .pending:
            "待确认"
        case .watch:
            "待确认"
        }
    }

    /// 是否为待确认展示态。
    var isPendingDisplay: Bool {
        self == .pending || self == .watch
    }
}

/// 已清仓零持仓的展示判定规则。
enum PendingFundDisplayRules {
    /// 判断某基金是否为已清仓的零持仓（需配合已确认交易记录）。
    static func isClosedZeroPosition(
        _ fund: FundPosition,
        tradeRecords: [FundTradeRecord]
    ) -> Bool {
        let shares = fund.migratedShares ?? 0
        let principal = fund.migratedPrincipal ?? 0
        let currentAmount = fund.currentAmount ?? 0
        let pendingAmount = fund.pendingAmount ?? 0
        let hasLots = fund.lots?.isEmpty == false

        guard shares <= 0.0001,
              principal <= 0.0001,
              currentAmount <= 0.0001,
              pendingAmount <= 0.0001,
              !hasLots
        else {
            return false
        }

        return tradeRecords.contains {
            $0.code == fund.code && $0.status == .confirmed
        }
    }
}

/// 基金列表展示规则。
enum FundListDisplayRules {
    /// 是否作为「持有」展示（持有状态，或已清仓零持仓）。
    static func isDisplayedHolding(
        _ fund: FundPosition,
        tradeRecords: [FundTradeRecord]
    ) -> Bool {
        fund.status == .holding
            || PendingFundDisplayRules.isClosedZeroPosition(fund, tradeRecords: tradeRecords)
    }

    /// 是否作为「待确认」展示（待确认态且非已清仓零持仓）。
    static func isDisplayedPending(
        _ fund: FundPosition,
        tradeRecords: [FundTradeRecord]
    ) -> Bool {
        fund.status.isPendingDisplay
            && !PendingFundDisplayRules.isClosedZeroPosition(fund, tradeRecords: tradeRecords)
    }
}

/// 持仓计价模式（金额/份额）。
enum PositionMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case share
    case amount

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 模式中文标题。
    var title: String {
        switch self {
        case .amount:
            "按金额"
        case .share:
            "按份额"
        }
    }
}

/// 交易时段（15:00 前/后）。
enum PositionTimeType: String, Codable, CaseIterable, Identifiable, Equatable {
    case before15
    case after15

    /// 用作 Identifiable 的稳定标识。
    var id: String { rawValue }

    /// 时段中文标题。
    var title: String {
        switch self {
        case .before15:
            "15:00前"
        case .after15:
            "15:00后"
        }
    }
}
