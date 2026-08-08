import Foundation

/// 组合计算中各类数值的保留精度与容差常量，集中管理以避免散落的魔法数字。
enum PortfolioPrecision {
    /// 份额在本地存储时保留的小数位数。
    static let storedSharePlaces = 6
    /// 份额在界面展示时保留的小数位数。
    static let displayedSharePlaces = 2
    /// 判断份额是否“可用/非零”的容差（基于展示精度推得）。
    static let shareAvailabilityTolerance = 0.5 / pow(10, Double(displayedSharePlaces))
    /// 成本价保留的小数位数。
    static let costPlaces = 4
    /// 金额保留的小数位数。
    static let moneyPlaces = 2
}
