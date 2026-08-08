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
struct FundNetValuePoint: Identifiable, Equatable {
    var id: Int64 { timestamp }
    /// 时间戳（毫秒）。
    var timestamp: Int64
    /// 单位净值。
    var value: Double
    /// 当日净值回报率（可选）。
    var equityReturn: Double?
}

/// 基金十大重仓股。
struct FundStockHolding: Identifiable, Equatable {
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
struct FundSectorExposure: Identifiable, Equatable {
    /// 暴露数据来源。
    enum Source: String, Equatable {
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
struct FundAssetAllocationItem: Identifiable, Equatable {
    var id: String { name }
    /// 资产类别名称。
    var name: String
    /// 权重（百分比）。
    var weight: Double
    /// 数据日期。
    var date: String?
}

/// 基金详情的补充数据（走势、持仓、行业、资产配置等）。
struct FundDetailSupplement: Equatable {
    /// 净值走势点。
    var trend: [FundNetValuePoint]
    /// 历史净值点。
    var history: [FundNetValuePoint]
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

    /// 空补充数据（用于加载失败/无数据兜底）。
    static let empty = FundDetailSupplement(
        trend: [],
        history: [],
        topHoldings: [],
        relatedSectors: [],
        industryAllocation: [],
        assetAllocation: [],
        holdingDisclosureDate: nil,
        industryDisclosureDate: nil,
        assetAllocationDate: nil,
        yesterdayPoint: nil
    )
}
