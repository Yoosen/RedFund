import Foundation

/// 基金实时行情（来自东方财富接口的核心报价字段）。
struct FundQuote: Codable, Equatable {
    /// 基金代码。
    var code: String
    /// 基金名称。
    var name: String
    /// 最新官方单位净值。
    var netValue: Double
    /// 盘中估算净值。
    var estimatedNetValue: Double
    /// 估算涨跌幅（百分比数值）。
    var growthRate: Double
    /// 估值时间文本。
    var estimateTime: String
    /// 官方净值日期（yyyy-MM-dd）。
    var netValueDate: String
}

/// 净值走势上的单个数据点。
struct FundNetValuePoint: Identifiable, Equatable, Codable {
    var id: Int64 { timestamp }
    /// 时间戳（毫秒）。
    var timestamp: Int64
    /// 单位净值。
    var value: Double
    /// 当日净值回报率（可选）。
    var equityReturn: Double?
}

/// 基金十大重仓股。
struct FundStockHolding: Identifiable, Equatable, Codable {
    var id: String { code.isEmpty ? name : code }
    /// 股票代码。
    var code: String
    /// 股票名称。
    var name: String
    /// 占净值比例（文本形式）。
    var weight: String
    /// 涨跌幅（可选）。
    var changeRate: Double?
    /// 所属行业代码。
    var industryCode: String?
    /// 所属行业名称。
    var industryName: String?
    /// 持仓变动类型（增持/减持等）。
    var positionChangeType: String?
    /// 持仓变动幅度。
    var positionChangeRate: Double?
    /// 交易市场。
    var market: String?

    init(
        code: String,
        name: String,
        weight: String,
        changeRate: Double?,
        industryCode: String? = nil,
        industryName: String? = nil,
        positionChangeType: String? = nil,
        positionChangeRate: Double? = nil,
        market: String? = nil
    ) {
        self.code = code
        self.name = name
        self.weight = weight
        self.changeRate = changeRate
        self.industryCode = industryCode
        self.industryName = industryName
        self.positionChangeType = positionChangeType
        self.positionChangeRate = positionChangeRate
        self.market = market
    }
}

/// 基金的行业/板块暴露。
struct FundSectorExposure: Identifiable, Equatable, Codable {
    /// 暴露数据来源。
    enum Source: String, Equatable, Codable {
        /// 来自十大重仓股映射。
        case topHoldings
        /// 来自披露的行业配置。
        case disclosedIndustry
    }

    var id: String { "\(source.rawValue)-\(code ?? name)" }
    /// 行业/板块代码。
    var code: String?
    /// 行业/板块名称。
    var name: String
    /// 权重（百分比）。
    var weight: Double
    /// 数据日期。
    var date: String?
    /// 数据来源。
    var source: Source
}

/// 基金的资产配置项（如股票/债券/现金占比）。
struct FundAssetAllocationItem: Identifiable, Equatable, Codable {
    var id: String { name }
    /// 资产类别名称。
    var name: String
    /// 权重（百分比）。
    var weight: Double
    /// 数据日期。
    var date: String?
}

/// 基金详情的补充数据（走势、持仓、行业、资产配置等）。
struct FundDetailSupplement: Equatable, Codable {
    /// 历史净值点（净值走势的唯一存储）。
    var history: [FundNetValuePoint]

    /// 净值走势点。
    ///
    /// 历史实现里 `trend` 与 `history` 是两份**完全相同**的数组（写入侧各赋一次同
    /// 一批点），占了缓存文件约 96% 体积。改为计算属性后磁盘占用减半，读取侧
    /// `supplement.history.isEmpty ? supplement.trend : supplement.history` 的
    /// 语义完全不变，仅解码时不再重复持有同一份数据。
    var trend: [FundNetValuePoint] { history }
    /// 十大重仓股。
    var topHoldings: [FundStockHolding]
    /// 关联板块。
    var relatedSectors: [FundSectorExposure]
    /// 行业配置。
    var industryAllocation: [FundSectorExposure]
    /// 资产配置。
    var assetAllocation: [FundAssetAllocationItem]
    /// 持仓披露日期。
    var holdingDisclosureDate: String?
    /// 行业配置披露日期。
    var industryDisclosureDate: String?
    /// 资产配置披露日期。
    var assetAllocationDate: String?
    /// 昨日净值点（用于对比）。
    var yesterdayPoint: FundNetValuePoint?
    /// 跟踪指数代码（仅指数/ETF/ETF联接类基金有，如 000688）。
    var indexCode: String?
    /// 跟踪指数名称（如 科创50）。
    var indexName: String?
    /// 跟踪指数当日涨跌幅（盘内为实时值，收盘后为当日收盘涨跌幅）。
    var indexChangeRate: Double?
    /// 关联场内 ETF 代码（ETF 联接基金才有，如 518880）。
    var linkedETFCode: String? = nil
    /// 关联场内 ETF 简称（如 黄金ETF华安）。
    var linkedETFName: String? = nil
    /// 关联标的种类："etf" = 场内 ETF（市价口径），"index" = 跟踪指数；nil 视为指数。
    var relatedKind: String? = nil
    /// 重仓股涨跌幅对应的交易日（格式 `yyyy-MM-dd`）。盘后保留涨跌幅时据此判断
    /// 缓存是否为「今天」的值；若为更早交易日则视为过期，需重新拉一次当日涨跌幅，
    /// 避免盘后一直展示上一交易日的重仓股涨跌（见 PopoverContentView.loadSupplement）。
    var topHoldingsChangeDate: String?

    /// 空补充数据（用于加载失败/无数据兜底）。
    static let empty = FundDetailSupplement(
        history: [],
        topHoldings: [],
        relatedSectors: [],
        industryAllocation: [],
        assetAllocation: [],
        holdingDisclosureDate: nil,
        industryDisclosureDate: nil,
        assetAllocationDate: nil,
        yesterdayPoint: nil,
        indexCode: nil,
        indexName: nil,
        indexChangeRate: nil,
        topHoldingsChangeDate: nil
    )

    /// 合并一次补充拉取的结果。网络端的某一模块短暂失败时会返回空数组，
    /// 不应覆盖已展示的有效重仓数据，避免详情页核心信息闪回“暂无数据”。
    func mergingAvailableData(from next: FundDetailSupplement) -> FundDetailSupplement {
        FundDetailSupplement(
            history: next.history.isEmpty ? history : next.history,
            topHoldings: next.topHoldings.isEmpty ? topHoldings : next.topHoldings,
            relatedSectors: next.relatedSectors.isEmpty ? relatedSectors : next.relatedSectors,
            industryAllocation: next.industryAllocation.isEmpty ? industryAllocation : next.industryAllocation,
            assetAllocation: next.assetAllocation.isEmpty ? assetAllocation : next.assetAllocation,
            holdingDisclosureDate: next.holdingDisclosureDate ?? holdingDisclosureDate,
            industryDisclosureDate: next.industryDisclosureDate ?? industryDisclosureDate,
            assetAllocationDate: next.assetAllocationDate ?? assetAllocationDate,
            yesterdayPoint: next.yesterdayPoint ?? yesterdayPoint,
            indexCode: next.indexCode ?? indexCode,
            indexName: next.indexName ?? indexName,
            indexChangeRate: next.indexChangeRate ?? indexChangeRate,
            linkedETFCode: next.linkedETFCode ?? linkedETFCode,
            linkedETFName: next.linkedETFName ?? linkedETFName,
            relatedKind: next.relatedKind ?? relatedKind
        )
    }
}
