import Foundation

/// 可展示的市场指数标识，枚举值即东方财富的 secid 前缀分类。
enum MarketIndexID: String, Codable, CaseIterable, Identifiable, Equatable {
    case shanghaiComposite
    case shenzhenComponent
    case chinext
    case csi300
    case sciTech50
    case shanghaiTotalReturn
    case shanghai50
    case csi500
    case beijing50
    case hangSengIndex
    case nikkei225
    case dowJones
    case nasdaq
    case sp500

    var id: String { rawValue }

    /// 指数的中文展示名。
    var title: String {
        switch self {
        case .shanghaiComposite:
            "上证指数"
        case .shenzhenComponent:
            "深证成指"
        case .chinext:
            "创业板指"
        case .csi300:
            "沪深300"
        case .sciTech50:
            "科创50"
        case .shanghaiTotalReturn:
            "上证收益"
        case .shanghai50:
            "上证50"
        case .csi500:
            "中证500"
        case .beijing50:
            "北证50"
        case .hangSengIndex:
            "恒生指数"
        case .nikkei225:
            "日经225"
        case .dowJones:
            "道琼斯指数"
        case .nasdaq:
            "纳斯达克"
        case .sp500:
            "标普500"
        }
    }

    /// 东方财富接口使用的 secid（如 "1.000001"）。
    var eastmoneySecID: String {
        switch self {
        case .shanghaiComposite:
            "1.000001"
        case .shenzhenComponent:
            "0.399001"
        case .chinext:
            "0.399006"
        case .csi300:
            "1.000300"
        case .sciTech50:
            "1.000688"
        case .shanghaiTotalReturn:
            "1.000888"
        case .shanghai50:
            "1.000016"
        case .csi500:
            "1.000905"
        case .beijing50:
            "0.899050"
        case .hangSengIndex:
            "100.HSI"
        case .nikkei225:
            "100.N225"
        case .dowJones:
            "100.DJIA"
        case .nasdaq:
            "100.NDX"
        case .sp500:
            "100.SPX"
        }
    }

    /// 从 secid 中提取的纯数字代码（用于匹配行情返回）。
    var eastmoneyQuoteCode: String {
        eastmoneySecID.split(separator: ".").last.map(String.init) ?? eastmoneySecID
    }
}

/// 单个市场指数的实时行情快照。
struct MarketIndexQuote: Codable, Equatable, Identifiable {
    /// 指数标识。
    var id: MarketIndexID
    /// 指数名称。
    var name: String
    /// 最新点位。
    var value: Double
    /// 涨跌点数。
    var change: Double
    /// 涨跌幅（百分比数值，如 1.23 表示 +1.23%）。
    var changeRate: Double
    /// 行情更新时间。
    var updateTime: Date

    init(
        id: MarketIndexID,
        name: String,
        value: Double,
        change: Double,
        changeRate: Double,
        updateTime: Date = .now
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.change = change
        self.changeRate = changeRate
        self.updateTime = updateTime
    }
}

/// 全市场涨跌家数概览（用于菜单栏“市场概览”）。
struct MarketBreadth: Codable, Equatable {
    /// 上涨家数。
    var risingCount: Int
    /// 下跌家数。
    var fallingCount: Int
    /// 各涨跌幅区间的个股数量分布。
    var distribution: [Int]
    /// 涨停家数。
    var limitUpCount: Int?
    /// 跌停家数。
    var limitDownCount: Int?
    /// 数据更新时间。
    var updateTime: Date

    init(
        risingCount: Int,
        fallingCount: Int,
        distribution: [Int] = [],
        limitUpCount: Int? = nil,
        limitDownCount: Int? = nil,
        updateTime: Date = .now
    ) {
        self.risingCount = risingCount
        self.fallingCount = fallingCount
        self.distribution = distribution
        self.limitUpCount = limitUpCount
        self.limitDownCount = limitDownCount
        self.updateTime = updateTime
    }

    /// 涨跌家数合计。
    var activeCount: Int {
        risingCount + fallingCount
    }

    /// 是否存在有效数据（用于判断是否展示）。
    var hasData: Bool {
        risingCount > 0 || fallingCount > 0
    }
}
