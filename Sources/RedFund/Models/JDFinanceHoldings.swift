import Foundation

/// 京东金融持仓快照：包含总资产、各类收益、持仓产品与交易订单。
struct JDFinanceHoldingsSnapshot: Equatable {
    /// 京东账户总资产。
    var totalAssets: Double?
    /// 昨日收益。
    var yesterdayIncome: Double?
    /// 今日收益。
    var todayIncome: Double?
    /// 持有收益（累计）。
    var holdIncome: Double?
    /// 总收益（累计）。
    var totalIncome: Double?
    /// 持仓产品列表。
    var products: [JDFinanceHoldingProduct]
    /// 交易订单列表。
    var tradeOrders: [JDFinanceTradeOrderRecord] = []
    /// 交易订单抓取状态（是否完整）。
    var tradeOrderFetchState: JDFinanceTradeOrderFetchState = .notRequested
}

/// 交易订单抓取状态，记录是否完整及缺失告警。
enum JDFinanceTradeOrderFetchState: Equatable {
    case notRequested
    case complete
    case incomplete([String])

    /// 是否已完整抓取。
    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

    /// 不完整时的告警信息列表。
    var warnings: [String] {
        if case .incomplete(let warnings) = self {
            return warnings
        }
        return []
    }
}

/// 京东金融持仓产品，对应一只基金持仓。
struct JDFinanceHoldingProduct: Identifiable, Equatable {
    /// 稳定标识：已解析出代码则使用代码，否则用 skuID+名称。
    var id: String {
        if isCodeResolved {
            return code
        }
        return "unresolved-\(skuID)-\(name)"
    }

    /// 京东商品 SKU 标识。
    var skuID: String
    /// 基金代码。
    var code: String
    /// 基金代码解析来源。
    var codeResolution: JDFinanceFundCodeResolution = .explicit
    /// 基金名称。
    var name: String
    /// 持仓金额（含待确认买入时由京东返回）。
    var totalAmount: Double
    /// 昨日收益。
    var yesterdayIncome: Double?
    /// 昨日收益附注文案。
    var yesterdayIncomeNotice: String? = nil
    /// 今日收益。
    var todayIncome: Double?
    /// 持有收益（累计）。
    var holdIncome: Double?
    /// 持有收益率。
    var holdRate: Double?
    /// 交易提示信息（如待确认买入提示）。
    var transactionTip: JDFinanceTransactionTip? = nil
    /// 持仓明细请求参数（用于拉取详情）。
    var detailRequest: JDFinanceHoldingDetailRequest? = nil
    /// 待确认交易明细。
    var pendingDetail: JDFinancePendingTransactionDetail? = nil
    /// 已对账的待确认买入金额（用于扣减）。
    var reconciledPendingBuyAmount: Double? = nil

    /// 交易提示的可读文本。
    var transactionTipText: String? {
        transactionTip?.text
    }

    // The holding amount returned by JD includes this aggregate buy amount,
    // while the buy is still in confirmation and should not earn today's P/L.
    /// 待确认买入金额：京东返回的持仓金额中包含但仍在确认中的买入额，不应计入今日收益。
    var syncedPendingBuyAmount: Double? {
        if let reconciledPendingBuyAmount {
            return reconciledPendingBuyAmount > 0.01 ? reconciledPendingBuyAmount : nil
        }
        let action = pendingDetail?.action ?? transactionTip?.action
        guard action == .buy else { return nil }
        let pendingAmount = transactionTip?.totalAmount ?? pendingDetail?.amount
        guard let pendingAmount,
              pendingAmount > 0,
              totalAmount > pendingAmount + 0.01
        else {
            // A pure pending-order row is not an existing holding with an
            // embedded buy; importing it must not zero out the local holding.
            return nil
        }
        return pendingAmount
    }

    /// 可比较的持仓金额：扣减待确认买入后的净持仓金额。
    var comparableHoldingAmount: Double {
        max(totalAmount - (syncedPendingBuyAmount ?? 0), 0)
    }

    /// 是否已成功解析出基金代码。
    var isCodeResolved: Bool {
        codeResolution.isResolved && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 基金代码解析来源枚举。
enum JDFinanceFundCodeResolution: String, Equatable {
    case explicit
    case nameMatched
    case tradeOrderMatched
    case unresolved

    /// 是否已解析（unresolved 视为未解析）。
    var isResolved: Bool {
        self != .unresolved
    }
}

/// 京东待确认交易动作类型。
enum JDFinancePendingTradeAction: String, Equatable {
    case buy
    case sell
    case conversion
    case unknown

    /// 动作中文标题。
    var title: String {
        switch self {
        case .buy:
            "买入"
        case .sell:
            "卖出"
        case .conversion:
            "转换"
        case .unknown:
            "交易"
        }
    }

    /// 映射到本地交易动作（转换/未知无对应本地动作）。
    var fundTradeAction: FundTradeAction? {
        switch self {
        case .buy:
            .buy
        case .sell:
            .sell
        case .conversion:
            nil
        case .unknown:
            nil
        }
    }
}

/// 交易提示信息（展示待确认交易文案与金额）。
struct JDFinanceTransactionTip: Equatable {
    var text: String
    var action: JDFinancePendingTradeAction
    var tradeCount: Int?
    var totalAmount: Double?
}

/// 持仓明细请求参数（京东详情接口需要）。
struct JDFinanceHoldingDetailRequest: Equatable {
    var extJSON: String
}

/// 待确认交易明细：金额、份额、日期、状态等。
struct JDFinancePendingTransactionDetail: Equatable {
    var action: JDFinancePendingTradeAction?
    var amount: Double?
    var shares: Double?
    var tradeDate: String?
    var tradeTimeType: PositionTimeType?
    var statusText: String?
    var matchedTradeRecords: [JDFinanceTradeOrderRecord] = []
    var candidateTradeRecords: [JDFinanceTradeOrderRecord] = []
}

/// 京东金融交易订单记录（来自订单接口）。
struct JDFinanceTradeOrderRecord: Equatable {
    /// 稳定复合键（用于去重/对账）。
    var stableOrderKey: String? = nil
    /// 来源订单键列表（可对应多个子订单）。
    var sourceOrderKeys: [String] = []
    /// 基金代码。
    var code: String?
    /// 代码解析来源。
    var codeResolution: JDFinanceFundCodeResolution = .unresolved
    /// 产品名称。
    var productName: String?
    /// 转换目标基金代码。
    var conversionTargetCode: String? = nil
    /// 转换目标基金名称。
    var conversionTargetName: String? = nil
    /// 交易动作（买入/卖出/转换）。
    var action: JDFinancePendingTradeAction?
    /// 交易金额。
    var amount: Double?
    /// 交易份额。
    var shares: Double?
    /// 交易日期。
    var tradeDate: String?
    /// 交易时段（15:00 前/后）。
    var tradeTimeType: PositionTimeType?
    /// 提交时间文本。
    var submittedAt: String? = nil
    /// 订单状态码（枚举）。
    var status: JDFinanceTradeOrderStatus? = nil
    /// 订单状态码原文。
    var statusCode: String? = nil
    /// 订单状态文本。
    var statusText: String?

    /// 实际生效状态：优先用枚举，否则按状态码/文本归类。
    var effectiveStatus: JDFinanceTradeOrderStatus {
        status ?? JDFinanceTradeOrderStatus.classify(statusCode: statusCode, statusText: statusText)
    }

    /// 是否已成功解析出基金代码。
    var isCodeResolved: Bool {
        codeResolution.isResolved
            && !(code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// 京东交易订单状态枚举。
enum JDFinanceTradeOrderStatus: String, Equatable {
    case pending
    case succeeded
    case cancelled
    case failed
    case unknown

    /// 仅按状态文本归类。
    static func classify(_ statusText: String?) -> JDFinanceTradeOrderStatus {
        classify(statusCode: nil, statusText: statusText)
    }

    /// 综合状态码与文本归类订单状态，支持京东多种编码/中文文案。
    static func classify(statusCode: String?, statusText: String?) -> JDFinanceTradeOrderStatus {
        let normalizedCode = statusCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let normalizedText = statusText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard !normalizedCode.isEmpty || !normalizedText.isEmpty else { return .unknown }

        let exactCancelledCodes = ["REFUND_SUCC", "CANCELED", "CANCELLED", "REVOKED"]
        if exactCancelledCodes.contains(normalizedCode) {
            return .cancelled
        }

        let exactFailedCodes = ["FAIL", "FAILED", "ERROR", "REJECT", "REJECTED"]
        if exactFailedCodes.contains(normalizedCode) {
            return .failed
        }

        let exactPendingCodes = ["PAY_SUCC", "PAY_SUCCESS", "PROCESS", "PROCESSING", "REDEEM", "PENDING"]
        if exactPendingCodes.contains(normalizedCode) {
            return .pending
        }

        let exactSucceededCodes = ["COMPLETE", "COMPLETED", "CONFIRMED", "REDEEM_SUCC", "TRADE_SUCCESS"]
        if exactSucceededCodes.contains(normalizedCode) {
            return .succeeded
        }

        let cancelledTokens = ["取消", "撤单", "撤销", "退款", "CANCEL", "REFUND", "REVOKE"]
        if cancelledTokens.contains(where: normalizedText.contains) {
            return .cancelled
        }

        let failedTokens = ["失败", "FAIL", "ERROR", "REJECT"]
        if failedTokens.contains(where: normalizedText.contains) {
            return .failed
        }

        let pendingTokens = [
            "支付成功", "处理中", "确认中", "待确认", "受理", "申请", "转出中",
            "PENDING", "PROCESS", "PROCESSING", "ACCEPTED", "PAID",
            "PAY_SUCCESS", "PAYMENT_SUCCESS", "PAY_SUCCESSFUL"
        ]
        if pendingTokens.contains(where: normalizedText.contains) {
            return .pending
        }

        let succeededTokens = [
            "确认成功", "交易成功", "订单完成", "赎回成功", "转出完成", "转换成功", "已确认",
            "CONFIRMED", "COMPLETED", "TRADE_SUCCESS", "SUCCESS"
        ]
        if succeededTokens.contains(where: normalizedText.contains) {
            return .succeeded
        }

        return .unknown
    }
}

/// 待确认导入种类（新基金 / 普通交易 / 转换）。
enum JDFinancePendingImportKind: Equatable {
    case newFund
    case trade(FundTradeAction)
    case conversion(toCode: String, toName: String?)
}

/// 本地覆盖状态（用于判断待确认记录是否已被本地账本覆盖）。
enum JDFinancePendingLocalCoverage: Equatable {
    case none
    case pending
    case confirmed
    case positionOnly
}

/// 手动补全待确认交易所需要的日期/时段。
struct JDFinancePendingManualCompletion: Equatable {
    var tradeDate: String
    var tradeTimeType: PositionTimeType
}

/// 待导入的京东持仓候选（对应本地 FundPosition 草稿）。
struct JDFinanceHoldingImportCandidate: Identifiable, Equatable {
    var id: String { product.code }
    var product: JDFinanceHoldingProduct

    var code: String { product.code }
    var name: String { product.name }
    var amount: Double { product.totalAmount }
    var holdingIncome: Double { product.holdIncome ?? 0 }

    /// 生成本地持仓草稿（用于新建基金持仓）。
    func draft(positionDate: String) -> FundPositionDraft {
        return FundPositionDraft(
            code: code,
            name: name,
            positionMode: .amount,
            positionAmount: amount,
            positionProfit: holdingIncome,
            shares: nil,
            cost: nil,
            positionDate: positionDate,
            positionTimeType: .before15,
            memo: "京东金融同步导入",
            requiresTradeConfirmation: false
        )
    }
}

/// 京东与本地持仓差异（用于展示/覆盖决策）。
struct JDFinanceHoldingDifference: Identifiable, Equatable {
    var id: String { code }
    var code: String
    var name: String
    var jdAmount: Double
    var localAmount: Double?
    var jdHoldingIncome: Double?
    var localHoldingIncome: Double?
    var jdHoldingRate: Double?
    var localHoldingRate: Double?
    var jdPendingBuyAmount: Double? = nil

    /// 可比较的京东持仓金额（扣减待确认买入）。
    var comparableJDAmount: Double {
        max(jdAmount - (jdPendingBuyAmount ?? 0), 0)
    }

    /// 金额差异：京东可比较金额 - 本地金额。
    var amountDelta: Double {
        comparableJDAmount - (localAmount ?? 0)
    }
}

/// 京东有持仓但本地缺失的基金（可清空已清仓的本地记录）。
struct JDFinanceMissingLocalHolding: Identifiable, Equatable {
    var id: String { code }
    var code: String
    var name: String
    var localAmount: Double?
    var finalOutflowOrder: JDFinanceTradeOrderRecord? = nil

    /// 是否可清空：存在已成功的卖出/转换订单即可判定本地已清仓。
    var canClear: Bool {
        guard let finalOutflowOrder,
              finalOutflowOrder.effectiveStatus == .succeeded
        else { return false }
        return finalOutflowOrder.action == .sell || finalOutflowOrder.action == .conversion
    }
}

/// 无法解析基金代码的京东持仓（需用户手动处理）。
struct JDFinanceUnresolvedHolding: Identifiable, Equatable {
    var id: String { "\(skuID)-\(name)" }
    var skuID: String
    var name: String
    var amount: Double
    var holdingIncome: Double?
    var message: String
}

/// 单条差异的同步预览状态（本地/京东确认不一致、需覆盖或冲突）。
struct JDFinanceSyncDifference: Equatable {
    var amountDelta: Double?
    var sharesDelta: Double?
    var priceDelta: Double?

    /// 是否存在金额/份额/价格上的差异（超过阈值）。
    var hasDifference: Bool {
        (amountDelta.map { abs($0) >= 0.01 } ?? false)
            || (sharesDelta.map { abs($0) >= 0.000001 } ?? false)
            || (priceDelta.map { abs($0) >= 0.000001 } ?? false)
    }
}

/// 同步预览状态：本地已确认京东待确认 / 京东已确认需覆盖 / 冲突。
enum JDFinanceSyncPreviewState: Equatable {
    case localConfirmedJDPending(difference: JDFinanceSyncDifference)
    case jdConfirmedNeedsOverwrite(difference: JDFinanceSyncDifference)
    case conflict(String)
}

/// 对账种类（普通交易 / 转换）。
enum JDFinanceReconciliationKind: Equatable {
    case trade(recordID: String, action: FundTradeAction)
    case conversion(conversionID: String, outRecordID: String?, inRecordID: String?)
}

/// 对账值集合（金额/份额/价格及其转换端对应值）。
struct JDFinanceReconciliationValues: Equatable {
    var amount: Double? = nil
    var shares: Double? = nil
    var price: Double? = nil
    var inAmount: Double? = nil
    var inShares: Double? = nil
    var inPrice: Double? = nil
    var statusText: String? = nil
    var syncKey: String? = nil
}

/// 对账通知（针对某基金某日某笔交易的对账结果）。
struct JDFinanceReconciliationNotice: Identifiable, Equatable {
    var id: String
    var code: String
    var name: String
    var linkedCode: String?
    var linkedName: String?
    var tradeDate: String
    var tradeTimeType: PositionTimeType
    var kind: JDFinanceReconciliationKind
    var state: JDFinanceSyncPreviewState
    var localAmount: Double?
    var jdAmount: Double?
    var localShares: Double?
    var jdShares: Double?
    var values: JDFinanceReconciliationValues
    var matchedTradeRecords: [JDFinanceTradeOrderRecord]

    /// 是否可由京东侧覆盖本地（状态为 jdConfirmedNeedsOverwrite）。
    var isOverwritable: Bool {
        if case .jdConfirmedNeedsOverwrite = state {
            return true
        }
        return false
    }
}

/// 自动确认分组（一组订单可被自动确认导入）。
struct JDFinanceAutomaticConfirmation: Identifiable, Equatable {
    var id: String
    var recordIDs: [String]
    var syncKey: String?
    var statusText: String?
    var representedOrderKeys: [String] = []
}

/// 未记录的京东订单（需用户补全后才能导入）。
struct JDFinanceUnrecordedOrder: Identifiable, Equatable {
    var id: String
    var record: JDFinanceTradeOrderRecord
    var message: String
    var blockingReason: String? = nil

    var code: String { record.code ?? "" }
    var name: String { record.productName ?? "未命名基金" }
    /// 缺失的必填字段名列表（用于引导用户补全）。
    var missingFields: [String] {
        var fields: [String] = []
        if code.isEmpty { fields.append("基金代码") }
        if record.action == nil || record.action == .unknown { fields.append("交易方向") }
        if record.tradeDate == nil { fields.append("交易日期") }
        if record.tradeTimeType == nil { fields.append("交易时段") }
        switch record.action {
        case .buy:
            if (record.amount ?? 0) <= 0 { fields.append("交易金额") }
        case .sell:
            if (record.shares ?? 0) <= 0 { fields.append("交易份额") }
        case .conversion:
            if (record.shares ?? 0) <= 0 { fields.append("转出份额") }
            if (record.conversionTargetCode ?? "").isEmpty { fields.append("目标基金代码") }
        case .unknown, nil:
            break
        }
        return fields
    }

    /// 是否可直接导入（无阻塞原因、字段齐全、状态成功、有日期）。
    var isImportable: Bool {
        guard blockingReason == nil,
              missingFields.isEmpty,
              record.effectiveStatus == .succeeded,
              record.tradeDate != nil
        else {
            return false
        }

        switch record.action {
        case .buy:
            return (record.amount ?? 0) > 0
        case .sell:
            return (record.shares ?? 0) > 0
        case .conversion:
            return (record.shares ?? 0) > 0
                && !(record.conversionTargetCode ?? "").isEmpty
        case .unknown, nil:
            return false
        }
    }

    /// 生成本地普通交易草稿（买入/卖出）。
    func tradeDraft() -> FundTradeDraft? {
        guard let action = record.action?.fundTradeAction,
              let tradeDate = record.tradeDate,
              let tradeTimeType = record.tradeTimeType,
              !code.isEmpty
        else {
            return nil
        }

        switch action {
        case .buy:
            guard let amount = record.amount, amount > 0 else { return nil }
            return FundTradeDraft(
                action: .buy,
                code: code,
                mode: .amount,
                amount: amount,
                shares: nil,
                tradeDate: tradeDate,
                tradeTimeType: tradeTimeType
            )
        case .sell:
            guard let shares = record.shares, shares > 0 else { return nil }
            return FundTradeDraft(
                action: .sell,
                code: code,
                mode: .share,
                amount: nil,
                shares: shares,
                tradeDate: tradeDate,
                tradeTimeType: tradeTimeType
            )
        }
    }

    /// 生成本地转换草稿（转出/转入）。
    func conversionDraft() -> FundConversionDraft? {
        guard record.action == .conversion,
              let toCode = record.conversionTargetCode,
              !code.isEmpty,
              !toCode.isEmpty,
              let shares = record.shares,
              shares > 0,
              let tradeDate = record.tradeDate,
              let tradeTimeType = record.tradeTimeType
        else {
            return nil
        }
        return FundConversionDraft(
            fromCode: code,
            toCode: toCode,
            toName: record.conversionTargetName,
            shares: shares,
            tradeDate: tradeDate,
            tradeTimeType: tradeTimeType
        )
    }
}

/// 京东待确认持仓通知（含可导入的本地草稿构建）。
struct JDFinanceHoldingPendingNotice: Identifiable, Equatable {
    var id: String { code }
    var code: String
    var name: String
    var amount: Double
    var holdingIncome: Double?
    var message: String
    var transactionTip: JDFinanceTransactionTip? = nil
    var yesterdayIncomeNotice: String? = nil
    var pendingDetail: JDFinancePendingTransactionDetail? = nil
    var importKind: JDFinancePendingImportKind? = nil
    var syncState: JDFinanceSyncPreviewState? = nil
    var localCoverage: JDFinancePendingLocalCoverage = .none
    var representedOrderKeys: [String] = []
    var localConfirmedTradeCount: Int = 0
    var localPendingTradeCount: Int = 0
    var positionCoveredTradeCount: Int = 0

    /// 是否可构建本地草稿导入。
    var isImportable: Bool {
        canBuildLocalDraft(manualCompletion: nil)
    }

    /// 是否需用户手动补全（有导入种类但尚不可导入）。
    var requiresManualCompletion: Bool {
        importKind != nil && !isImportable
    }

    /// 待确认明细状态文本。
    var detailStatusText: String? {
        pendingDetail?.statusText
    }

    /// 匹配到的交易订单记录。
    var matchedTradeRecords: [JDFinanceTradeOrderRecord] {
        pendingDetail?.matchedTradeRecords ?? []
    }

    /// 逻辑交易记录（合并拆分订单后）。
    var logicalMatchedTradeRecords: [JDFinanceTradeOrderRecord] {
        JDFinanceTradeOrderBatcher.logicalRecords(matchedTradeRecords)
    }

    /// 候选交易订单记录。
    var candidateTradeRecords: [JDFinanceTradeOrderRecord] {
        pendingDetail?.candidateTradeRecords ?? []
    }

    /// 交易笔数展示文本。
    var tradeCountText: String? {
        "\(logicalTradeCount) 笔"
    }

    /// 逻辑交易笔数（优先用匹配记录，否则按提示笔数）。
    var logicalTradeCount: Int {
        if !logicalMatchedTradeRecords.isEmpty {
            return logicalMatchedTradeRecords.count
        }
        return max(transactionTip?.tradeCount ?? 1, 1)
    }

    /// 交易动作标题。
    var actionTitle: String {
        (pendingDetail?.action ?? transactionTip?.action ?? .unknown).title
    }

    /// 判断能否基于匹配订单或手动补全构建本地草稿。
    func canBuildLocalDraft(manualCompletion: JDFinancePendingManualCompletion?) -> Bool {
        switch importKind {
        case .newFund:
            if !matchedTradeDrafts().isEmpty { return true }
            return localTradeDate(manualCompletion: manualCompletion) != nil
                && localTradeTimeType(manualCompletion: manualCompletion) != nil
                && amount > 0
        case .trade(.buy):
            if !matchedTradeDrafts().isEmpty { return true }
            return localTradeDate(manualCompletion: manualCompletion) != nil
                && localTradeTimeType(manualCompletion: manualCompletion) != nil
                && amount > 0
        case .trade(.sell):
            if !matchedTradeDrafts().isEmpty { return true }
            return localTradeDate(manualCompletion: manualCompletion) != nil
                && localTradeTimeType(manualCompletion: manualCompletion) != nil
                && (pendingDetail?.shares ?? 0) > 0
        case .conversion:
            return !conversionDrafts(manualCompletion: manualCompletion).isEmpty
        case nil:
            return false
        }
    }

    /// 构建本地持仓草稿（仅新基金适用）。
    func fundPositionDraft(manualCompletion: JDFinancePendingManualCompletion? = nil) -> FundPositionDraft? {
        guard importKind == .newFund else {
            return nil
        }

        if let firstDraft = matchedTradeDrafts().first,
           let positionAmount = firstDraft.amount,
           positionAmount > 0
        {
            return FundPositionDraft(
                code: code,
                name: name,
                positionMode: .amount,
                positionAmount: positionAmount,
                positionProfit: holdingIncome ?? 0,
                shares: nil,
                cost: nil,
                positionDate: firstDraft.tradeDate,
                positionTimeType: firstDraft.tradeTimeType,
                memo: "京东金融同步待确认",
                requiresTradeConfirmation: true
            )
        }

        guard
              let tradeDate = localTradeDate(manualCompletion: manualCompletion),
              let tradeTimeType = localTradeTimeType(manualCompletion: manualCompletion)
        else {
            return nil
        }

        return FundPositionDraft(
            code: code,
            name: name,
            positionMode: .amount,
            positionAmount: amount,
            positionProfit: holdingIncome ?? 0,
            shares: nil,
            cost: nil,
            positionDate: tradeDate,
            positionTimeType: tradeTimeType,
            memo: "京东金融同步待确认",
            requiresTradeConfirmation: true
        )
    }

    /// 构建本地交易草稿（取首个）。
    func tradeDraft(manualCompletion: JDFinancePendingManualCompletion? = nil) -> FundTradeDraft? {
        if let firstDraft = tradeDrafts(manualCompletion: manualCompletion)?.first {
            return firstDraft
        }

        return nil
    }

    /// 构建本地交易草稿列表（买入/卖出）。
    func tradeDrafts(manualCompletion: JDFinancePendingManualCompletion? = nil) -> [FundTradeDraft]? {
        let matchedDrafts = matchedTradeDrafts()
        if !matchedDrafts.isEmpty {
            return matchedDrafts
        }

        guard case let .trade(action) = importKind,
              let tradeDate = localTradeDate(manualCompletion: manualCompletion),
              let tradeTimeType = localTradeTimeType(manualCompletion: manualCompletion)
        else {
            return nil
        }

        switch action {
        case .buy:
            guard amount > 0 else { return nil }
            return [FundTradeDraft(
                action: .buy,
                code: code,
                mode: .amount,
                amount: amount,
                shares: nil,
                tradeDate: tradeDate,
                tradeTimeType: tradeTimeType
            )]
        case .sell:
            guard let shares = pendingDetail?.shares, shares > 0 else { return nil }
            return [FundTradeDraft(
                action: .sell,
                code: code,
                mode: .share,
                amount: nil,
                shares: shares,
                tradeDate: tradeDate,
                tradeTimeType: tradeTimeType
            )]
        }
    }

    /// 构建本地转换草稿（取首个）。
    func conversionDraft(manualCompletion: JDFinancePendingManualCompletion? = nil) -> FundConversionDraft? {
        conversionDrafts(manualCompletion: manualCompletion).first
    }

    /// 构建本地转换草稿列表（转出/转入）。
    func conversionDrafts(manualCompletion: JDFinancePendingManualCompletion? = nil) -> [FundConversionDraft] {
        guard case let .conversion(toCode, toName) = importKind,
              let tradeDate = localTradeDate(manualCompletion: manualCompletion),
              let tradeTimeType = localTradeTimeType(manualCompletion: manualCompletion)
        else {
            return []
        }

        let conversionRecords = matchedTradeRecords.filter { $0.action == .conversion }
        if !conversionRecords.isEmpty {
            return conversionRecords.compactMap { record in
                guard let shares = record.shares,
                      shares > 0
                else {
                    return nil
                }
                return FundConversionDraft(
                    fromCode: code,
                    toCode: toCode,
                    toName: toName,
                    shares: shares,
                    tradeDate: record.tradeDate ?? tradeDate,
                    tradeTimeType: record.tradeTimeType ?? tradeTimeType
                )
            }
        }

        guard let shares = pendingDetail?.shares,
              shares > 0
        else {
            return []
        }

        return [FundConversionDraft(
            fromCode: code,
            toCode: toCode,
            toName: toName,
            shares: shares,
            tradeDate: tradeDate,
            tradeTimeType: tradeTimeType
        )]
    }

    /// 基于匹配订单构建本地交易草稿（买入/卖出）。
    private func matchedTradeDrafts() -> [FundTradeDraft] {
        let action: FundTradeAction
        switch importKind {
        case .newFund:
            action = .buy
        case .trade(let pendingAction):
            action = pendingAction
        case .conversion, nil:
            return []
        }
        let records = logicalMatchedTradeRecords.sorted(by: tradeRecordComesBefore)
        guard !records.isEmpty else { return [] }

        let drafts: [FundTradeDraft] = records.compactMap { record in
            guard let tradeDate = record.tradeDate,
                  let tradeTimeType = record.tradeTimeType
            else {
                return nil
            }

            switch action {
            case .buy:
                guard let amount = record.amount, amount > 0 else { return nil }
                return FundTradeDraft(
                    action: .buy,
                    code: normalizedRecordCode(record) ?? code,
                    mode: .amount,
                    amount: amount,
                    shares: nil,
                    tradeDate: tradeDate,
                    tradeTimeType: tradeTimeType
                )
            case .sell:
                guard let shares = record.shares, shares > 0 else { return nil }
                return FundTradeDraft(
                    action: .sell,
                    code: normalizedRecordCode(record) ?? code,
                    mode: .share,
                    amount: nil,
                    shares: shares,
                    tradeDate: tradeDate,
                    tradeTimeType: tradeTimeType
                )
            }
        }
        return drafts.count == records.count ? drafts : []
    }

    /// 比较两个交易记录的时间先后（先按日期，再按时段）。
    private func tradeRecordComesBefore(
        _ lhs: JDFinanceTradeOrderRecord,
        _ rhs: JDFinanceTradeOrderRecord
    ) -> Bool {
        let lhsDate = lhs.tradeDate ?? ""
        let rhsDate = rhs.tradeDate ?? ""
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return tradeTimeOrder(lhs.tradeTimeType) < tradeTimeOrder(rhs.tradeTimeType)
    }

    /// 交易时段的排序权重（15:00 前 < 15:00 后 < 未知）。
    private func tradeTimeOrder(_ timeType: PositionTimeType?) -> Int {
        switch timeType {
        case .before15:
            0
        case .after15:
            1
        case nil:
            2
        }
    }

    /// 规范化交易记录代码（去空格，空则 nil）。
    private func normalizedRecordCode(_ record: JDFinanceTradeOrderRecord) -> String? {
        let trimmed = record.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 取本地交易日期（优先明细，其次手动补全）。
    private func localTradeDate(manualCompletion: JDFinancePendingManualCompletion?) -> String? {
        pendingDetail?.tradeDate ?? manualCompletion?.tradeDate
    }

    /// 取本地交易时段（优先明细，其次手动补全）。
    private func localTradeTimeType(manualCompletion: JDFinancePendingManualCompletion?) -> PositionTimeType? {
        pendingDetail?.tradeTimeType ?? manualCompletion?.tradeTimeType
    }
}

/// 京东持仓同步预览：汇总所有待导入/变更/待确认/对账结果。
struct JDFinanceHoldingsSyncPreview: Equatable {
    var remoteSnapshot: JDFinanceHoldingsSnapshot
    var newHoldings: [JDFinanceHoldingImportCandidate]
    var changedHoldings: [JDFinanceHoldingDifference]
    var missingLocalHoldings: [JDFinanceMissingLocalHolding]
    var unresolvedHoldings: [JDFinanceUnresolvedHolding] = []
    var pendingNotices: [JDFinanceHoldingPendingNotice]
    var reconciliationNotices: [JDFinanceReconciliationNotice] = []
    var automaticConfirmations: [JDFinanceAutomaticConfirmation] = []
    var unrecordedOrders: [JDFinanceUnrecordedOrder] = []
    var informationalOrders: [JDFinanceTradeOrderRecord] = []
    var warnings: [String] = []
    var autoConfirmedCount: Int = 0
    var baselineRepresentedCount: Int = 0
    var baselineOrderKeys: [String] = []

    /// 是否有可导入的新持仓。
    var hasImportableChanges: Bool {
        !newHoldings.isEmpty
    }

    /// 是否存在需要用户处理的变更（新持仓/差异/待确认/可覆盖对账/可记录订单）。
    var hasActionableChanges: Bool {
        !newHoldings.isEmpty
            || !changedHoldings.isEmpty
            || !importablePendingNotices.isEmpty
            || !overwritableReconciliationNotices.isEmpty
            || !importableUnrecordedOrders.isEmpty
    }

    /// 可导入的待确认通知列表。
    var importablePendingNotices: [JDFinanceHoldingPendingNotice] {
        pendingNotices.filter(\.isImportable)
    }

    /// 全部待确认交易笔数合计。
    var pendingTradeCount: Int {
        pendingNotices.map(\.logicalTradeCount).reduce(0, +)
    }

    /// 可导入的待确认交易笔数合计。
    var importablePendingTradeCount: Int {
        importablePendingNotices.map(\.logicalTradeCount).reduce(0, +)
    }

    /// 本地已确认、京东待确认的待确认交易笔数合计。
    var localConfirmedJDPendingTradeCount: Int {
        pendingNotices.map(\.localConfirmedTradeCount).reduce(0, +)
    }

    /// 本地待确认的待确认交易笔数合计。
    var localPendingTradeCount: Int {
        pendingNotices.map(\.localPendingTradeCount).reduce(0, +)
    }

    /// 由持仓覆盖的缺失账本交易笔数合计。
    var positionCoveredMissingLedgerTradeCount: Int {
        pendingNotices.map(\.positionCoveredTradeCount).reduce(0, +)
    }

    /// 可覆盖的京东对账通知列表。
    var overwritableReconciliationNotices: [JDFinanceReconciliationNotice] {
        reconciliationNotices.filter(\.isOverwritable)
    }

    /// 可导入的未记录订单列表。
    var importableUnrecordedOrders: [JDFinanceUnrecordedOrder] {
        unrecordedOrders.filter(\.isImportable)
    }

    /// 预览是否为空（无任何内容/告警）。
    var isEmpty: Bool {
        newHoldings.isEmpty
            && changedHoldings.isEmpty
            && missingLocalHoldings.isEmpty
            && unresolvedHoldings.isEmpty
            && pendingNotices.isEmpty
            && reconciliationNotices.isEmpty
            && unrecordedOrders.isEmpty
            && informationalOrders.isEmpty
            && warnings.isEmpty
    }
}

/// 京东持仓同步错误类型。
enum JDFinanceHoldingsError: LocalizedError, Equatable {
    case notLoggedIn
    case emptyHoldings
    case invalidResponse
    case network(String)

    /// 错误的人类可读描述。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "请先登录京东账号"
        case .emptyHoldings:
            "没有读取到京东基金持仓"
        case .invalidResponse:
            "京东持仓接口结构变化，暂时无法解析"
        case .network(let message):
            message
        }
    }
}

/// 京东基金代码推断工具（从 SKU 中提取 6 位数字代码）。
enum JDFinanceFundCodeMapper {
    /// 从 SKU 中推断基金代码：要求恰好 6 位数字且不以 1 开头。
    static func inferCode(from skuID: String) -> String? {
        let digits = skuID.filter(\.isNumber)
        guard digits.count == 6, digits.first != "1" else { return nil }
        return digits
    }
}
