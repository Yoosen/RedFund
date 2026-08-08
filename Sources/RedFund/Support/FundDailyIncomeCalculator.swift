import Foundation

/// 单日收益明细行（用于图表/列表展示）。
struct FundDailyIncomeRow: Identifiable, Equatable {
    var id: String { dateText }

    /// 日期文本。
    let dateText: String
    /// 当日单位净值。
    let netValue: Double
    /// 当日浮动收益。
    let dailyIncome: Double
    /// 当日因入金（申购）产生的账面收益。
    let entryIncome: Double
    /// 累计收益金额。
    let cumulativeIncome: Double
    /// 累计收益率（百分比，可选）。
    let cumulativeRate: Double?
}

/// 从持仓份额与净值点计算每日收益历史。
enum FundDailyIncomeCalculator {
    /// 计算所有持仓按日聚合的收益明细行（按日期升序返回）。
    static func rows(
        lots: [FundPositionLot],
        points: [FundNetValuePoint]
    ) -> [FundDailyIncomeRow] {
        let dailyPoints = uniqueDailyPoints(from: points)
        guard !dailyPoints.isEmpty else { return [] }

        var previousCumulativeIncome = 0.0
        var rows: [FundDailyIncomeRow] = []

        for (index, point) in dailyPoints.enumerated() {
            let activeLots = lots.filter { isActive($0, on: point.dateText) }
            guard !activeLots.isEmpty else { continue }

            let previousPoint = index > 0 ? dailyPoints[index - 1] : nil
            let dailyLots = lots.filter { participatesInDailyIncome($0, on: point.dateText) }
            let dailyIncome = calculatedDailyIncome(
                lots: dailyLots,
                point: point,
                previousPoint: previousPoint
            )
            let cumulativeIncome = activeLots.reduce(0) { total, lot in
                total + lot.shares * (point.value - lot.cost)
            }
            let principal = activeLots.reduce(0) { total, lot in
                total + lot.shares * lot.cost
            }
            let cumulativeRate = principal > 0 ? cumulativeIncome / principal * 100 : nil
            let entryIncome = cumulativeIncome - previousCumulativeIncome - dailyIncome

            rows.append(FundDailyIncomeRow(
                dateText: point.dateText,
                netValue: point.value,
                dailyIncome: dailyIncome,
                entryIncome: entryIncome,
                cumulativeIncome: cumulativeIncome,
                cumulativeRate: cumulativeRate
            ))
            previousCumulativeIncome = cumulativeIncome
        }

        return rows.reversed()
    }

    /// 计算指定净值点相对前一日的当日浮动收益。
    private static func calculatedDailyIncome(
        lots: [FundPositionLot],
        point: DailyNetValuePoint,
        previousPoint: DailyNetValuePoint?
    ) -> Double {
        guard let previousPoint else { return 0 }

        return lots.reduce(0) { total, lot in
            let baseline = baselineNetValue(for: lot, previousPoint: previousPoint)
            return total + lot.shares * (point.value - baseline)
        }
    }

    /// 取收益起始日之后的净值作为基准，否则用持仓成本。
    private static func baselineNetValue(
        for lot: FundPositionLot,
        previousPoint: DailyNetValuePoint
    ) -> Double {
        guard DateOnlyFormatter.parse(lot.incomeStartDate) != nil else {
            return previousPoint.value
        }
        return previousPoint.dateText >= lot.incomeStartDate ? previousPoint.value : lot.cost
    }

    /// 判断份额在指定日期是否已生效（参与累计收益）。
    private static func isActive(_ lot: FundPositionLot, on dateText: String) -> Bool {
        guard lot.shares > 0 else { return false }
        guard DateOnlyFormatter.parse(lot.incomeStartDate) != nil else { return true }
        return lot.incomeStartDate <= dateText
    }

    /// 判断份额在指定日期是否参与当日收益计算（严格晚于起始日）。
    private static func participatesInDailyIncome(_ lot: FundPositionLot, on dateText: String) -> Bool {
        guard lot.shares > 0 else { return false }
        guard DateOnlyFormatter.parse(lot.incomeStartDate) != nil else { return true }
        return lot.incomeStartDate < dateText
    }

    /// 按自然日去重净值点，生成用于按日计算的序列。
    private static func uniqueDailyPoints(from points: [FundNetValuePoint]) -> [DailyNetValuePoint] {
        var pointsByDate: [String: DailyNetValuePoint] = [:]
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) where point.value > 0 {
            let dateText = DateOnlyFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000)
            )
            pointsByDate[dateText] = DailyNetValuePoint(
                dateText: dateText,
                timestamp: point.timestamp,
                value: point.value
            )
        }
        return pointsByDate.values.sorted {
            if $0.dateText != $1.dateText {
                return $0.dateText < $1.dateText
            }
            return $0.timestamp < $1.timestamp
        }
    }
}

/// 内部用：按日聚合后的净值点（含日期与毫秒时间戳）。
private struct DailyNetValuePoint: Equatable {
    let dateText: String
    let timestamp: Int64
    let value: Double
}
