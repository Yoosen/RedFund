import Foundation

/// 集中管理「代码已实现、但暂不对用户开放」的功能开关。
///
/// 关闭某个开关后需要同时生效三处，避免入口关了但逻辑还在跑：
/// 1. 设置页不再展示对应入口；
/// 2. 历史设置中的残留值在加载时回落为可用默认值；
/// 3. 运行时的取用点做兜底，防止任何绕过设置页的路径走进未开放分支。
enum FeatureAvailability {
    /// 小倍养基盘中估值源。
    ///
    /// 接口尚未稳定（登录失效/失败时估值整体缺失，且未覆盖完整回归测试），
    /// 暂时关闭入口，统一使用东方财富作为盘中估值源。
    /// 稳定后把这里改回 `true` 即可恢复，其余代码无需改动。
    static let xiaobeiValuationSource = false

    /// 当前对用户开放的盘中估值数据源（按展示顺序）。
    static var availableValuationSources: [QuoteValuationSource] {
        QuoteValuationSource.allCases.filter(isAvailable)
    }

    /// 指定盘中估值数据源当前是否可用。
    static func isAvailable(_ source: QuoteValuationSource) -> Bool {
        switch source {
        case .eastmoney:
            true
        case .xiaobei:
            xiaobeiValuationSource
        }
    }

    /// 把不可用的数据源回落为东方财富，用于读写两侧的统一兜底。
    static func resolved(_ source: QuoteValuationSource) -> QuoteValuationSource {
        isAvailable(source) ? source : .eastmoney
    }

    // MARK: - 盘中走势数据源

    /// 新浪盘中走势数据源（数据源2）。
    ///
    /// 暂时关闭入口：详情页的切换下拉与设置页的分区都不再展示，统一使用东财的盘中走势。
    /// 需要恢复时把这里改回 `true` 即可，其余代码无需改动。
    static let sinaIntradayDataSource = false

    /// 当前对用户开放的盘中走势数据源（按展示顺序）。
    static var availableIntradayDataSources: [IntradayDataSource] {
        IntradayDataSource.allCases.filter(isAvailableIntradayDataSource)
    }

    /// 指定盘中走势数据源当前是否可用。
    static func isAvailableIntradayDataSource(_ source: IntradayDataSource) -> Bool {
        switch source {
        case .eastmoney:
            true
        case .sina:
            sinaIntradayDataSource
        }
    }

    /// 把不可用的盘中走势数据源回落为东财，用于读写两侧的统一兜底。
    static func resolvedIntradayDataSource(_ source: IntradayDataSource) -> IntradayDataSource {
        isAvailableIntradayDataSource(source) ? source : .eastmoney
    }
}
