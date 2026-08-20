import Foundation

/// 估值误差闭环录制器。
///
/// 在每次行情刷新后调用：当某基金已公布当日实际净值（官方净值日期等于盘中估值所在交易日）时，
/// 把该基金「当日最后一次盘中估值涨跌幅」与「当日实际涨跌幅（东财官方值）」配对，
/// 计算绝对偏差（百分点）并写入 `FundPosition.estimationDeviationHistory`，保留最近 30 天。
///
/// 盘中交易时段当天净值尚未公布，官方净值日期仍停留在上一交易日，不会配对；
/// 晚上基金净值更新后（官方净值日期等于盘中估值日）即可记录，无需等到下一个交易日。
///
/// QDII 等盘中无估值的基金，`intradayRateHistory` 为空，自然跳过（预期行为）。
enum EstimationDeviationRecorder {
    /// 最多保留的历史天数。
    private static let maxDays = 30

    /// 迁移旧版「相对误差」数据。
    ///
    /// 早期版本把 `|实际-预估| / max(|实际|, 0.01) * 100` 作为误差写入 `relativeError` 字段；
    /// 现改为绝对偏差字段 `absoluteDeviation`，且旧存档解码时把 `relativeError` 值映射到该字段。
    /// 新写入的记录恒满足 `absoluteDeviation == |actualRate - estimatedRate|`（单位：百分点）。
    /// 凡是不满足该恒等式的历史记录，都是旧算法残留且无法还原真实偏差，直接清空该基金
    /// 整段误差历史重新统计。此校验精确、不依赖阈值，不会误伤新算法数据。
    static func migratingLegacyRelativeErrorHistory(_ snapshot: PortfolioSnapshot) -> PortfolioSnapshot {
        var next = snapshot
        next.funds = snapshot.funds.map { fund in
            guard let history = fund.estimationDeviationHistory,
                  history.contains(where: { deviation in
                      abs(deviation.absoluteDeviation - abs(deviation.actualRate - deviation.estimatedRate)) > 1e-9
                  })
            else {
                return fund
            }
            var updated = fund
            updated.estimationDeviationHistory = nil
            return updated
        }
        return next
    }

    static func applyingConfirmedDeviation(
        to snapshot: PortfolioSnapshot,
        quotes: [String: FundQuote]
    ) -> PortfolioSnapshot {
        var next = snapshot
        next.funds = snapshot.funds.map { fund in
            guard let intradayDate = fund.intradayRateDate,
                  let points = fund.intradayRateHistory,
                  let lastPoint = points.sorted(by: { $0.timestamp < $1.timestamp }).last
            else {
                return fund
            }

            guard let quote = quotes[fund.code],
                  quote.netValueDate == intradayDate,
                  quote.growthRate.isFinite
            else {
                return fund
            }

            let estimatedRate = lastPoint.rate
            let actualRate = quote.growthRate
            // 绝对偏差（百分点）：|实际-预估|。例如实际 -0.72%、预估 -1.10%，偏差 0.38。
            let absoluteDeviation = abs(actualRate - estimatedRate)

            var history = fund.estimationDeviationHistory ?? []
            guard !history.contains(where: { $0.date == intradayDate }) else {
                return fund
            }

            let deviation = EstimationDeviation(
                date: intradayDate,
                estimatedRate: estimatedRate,
                actualRate: actualRate,
                absoluteDeviation: absoluteDeviation
            )
            history.append(deviation)
            history.sort { $0.date > $1.date }
            if history.count > maxDays {
                history.removeLast(history.count - maxDays)
            }

            var updated = fund
            updated.estimationDeviationHistory = history
            return updated
        }

        return next
    }
}
