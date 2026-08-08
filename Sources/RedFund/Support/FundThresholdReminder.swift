import Foundation

/// 单条基金涨跌幅档位提醒的配置与展示模型。
struct FundThresholdReminder: Equatable {
    /// 提醒类型。
    enum Kind: String, Equatable {
        /// 每日涨跌幅提醒。
        case dailyGrowth = "daily-growth"
    }

    /// 提醒方向（涨 / 跌）。
    enum Direction: String, Equatable {
        case rise
        case fall

        /// 方向中文名。
        var title: String {
            switch self {
            case .rise:
                "涨幅"
            case .fall:
                "跌幅"
            }
        }
    }

    /// 基金代码。
    let code: String
    /// 基金名称。
    let name: String
    /// 提醒类型。
    let kind: Kind
    /// 提醒方向。
    let direction: Direction
    /// 触发的档位阈值（涨跌幅百分比）。
    let threshold: Double
    /// 当前实际涨跌幅。
    let currentValue: Double
    /// 触发日期键（yyyy-MM-dd）。
    let dateKey: String

    /// 去重键（同类型/同日/同代码/同方向/同档位视为同一条）。
    var dedupeKey: String {
        "\(kind.rawValue).\(dateKey).\(displayCode).\(direction.rawValue).\(thresholdKey)"
    }

    /// 同日同方向的去重前缀，用于判断已发过的同方向更高档位。
    var sameDayDirectionDedupePrefix: String {
        "\(kind.rawValue).\(dateKey).\(displayCode).\(direction.rawValue)."
    }

    /// 通知的唯一标识。
    var notificationIdentifier: String {
        "red-fund.threshold.\(kind.rawValue).\(dateKey).\(displayCode).\(direction.rawValue).\(thresholdKey)"
    }

    /// 通知标题。
    var title: String {
        displayName
    }

    /// 通知正文文案。
    var body: String {
        switch kind {
        case .dailyGrowth:
            return "涨跌幅提醒：当前\(direction.title) \(MoneyFormatter.percent(currentValue, signed: true))，已达 \(MoneyFormatter.percent(threshold, signed: false))档。"
        }
    }

    /// 展示用基金代码。
    private var displayCode: String {
        FundCodeFormatter.display(code)
    }

    /// 展示用基金名称（空名称时回退为代码）。
    private var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? displayCode : name
    }

    /// 档位阈值作为去重键（小数点转下划线）。
    private var thresholdKey: String {
        Self.numberText(threshold, places: 2)
            .replacingOccurrences(of: ".", with: "_")
    }

    /// 按指定位数格式化数字。
    private static func numberText(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

/// 从组合快照中评估应发出的涨跌幅档位提醒。
enum FundThresholdReminderEvaluator {
    /// 返回当前所有基金达到档位的提醒（不校验是否已发送过）。
    static func reminders(
        in snapshot: PortfolioSnapshot,
        settings: AppSettings,
        date: Date = .now
    ) -> [FundThresholdReminder] {
        let dateKey = DateOnlyFormatter.string(from: date)
        return snapshot.funds.flatMap { reminders(for: $0, settings: settings, dateKey: dateKey) }
    }

    /// 返回当前应发送（已剔除同日同向更高档位已发记录）的提醒；非开市时段返回空。
    static func eligibleReminders(
        in snapshot: PortfolioSnapshot,
        settings: AppSettings,
        now: Date = .now,
        lastSentAt: [String: Date]
    ) -> [FundThresholdReminder] {
        guard TradingCalendar.isMarketOpen(now: now) else {
            return []
        }

        return reminders(in: snapshot, settings: settings, date: now).filter { reminder in
            let sentSameDirectionThresholds = lastSentAt.keys.compactMap {
                reminder.sentThresholdFromSameDayDirectionKey($0)
            }
            return !sentSameDirectionThresholds.contains { $0 >= reminder.threshold }
        }
    }

    /// 为单只基金生成提醒数组（每日涨跌幅最多一条）。
    static func reminders(for fund: FundPosition, settings: AppSettings, dateKey: String) -> [FundThresholdReminder] {
        guard let dailyGrowthReminder = dailyGrowthReminder(for: fund, settings: settings, dateKey: dateKey) else {
            return []
        }
        return [dailyGrowthReminder]
    }

    /// 计算单只基金当前应触发的每日涨跌幅提醒（取已达到的最高档位）。
    private static func dailyGrowthReminder(
        for fund: FundPosition,
        settings: AppSettings,
        dateKey: String
    ) -> FundThresholdReminder? {
        guard settings.dailyGrowthReminderEnabled,
              fund.todayRate != 0
        else {
            return nil
        }

        let direction: FundThresholdReminder.Direction = fund.todayRate > 0 ? .rise : .fall
        let tiers = direction == .rise ? settings.dailyGrowthRiseTiers : settings.dailyGrowthFallTiers
        let absoluteRate = abs(fund.todayRate)
        guard let threshold = tiers.map(\.value).filter({ absoluteRate >= $0 }).max() else {
            return nil
        }

        return FundThresholdReminder(
            code: fund.code,
            name: fund.name,
            kind: .dailyGrowth,
            direction: direction,
            threshold: threshold,
            currentValue: fund.todayRate,
            dateKey: dateKey
        )
    }
}

private extension FundThresholdReminder {
    /// 从已发送记录键中解析出同日同方向已发过的档位阈值。
    func sentThresholdFromSameDayDirectionKey(_ key: String) -> Double? {
        guard key.hasPrefix(sameDayDirectionDedupePrefix) else {
            return nil
        }
        let rawThreshold = key.dropFirst(sameDayDirectionDedupePrefix.count)
            .replacingOccurrences(of: "_", with: ".")
        return Double(rawThreshold)
    }
}
