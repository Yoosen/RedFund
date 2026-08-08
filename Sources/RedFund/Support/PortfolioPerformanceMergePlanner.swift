import Foundation

/// 京东历史收益合并错误类型。
enum PortfolioPerformanceMergeError: LocalizedError, Equatable {
    case invalidAccount
    case accountMismatch
    case concurrentModification

    /// 错误的人类可读描述。
    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            "无法确认当前京东账号，请重新登录后再试"
        case .accountMismatch:
            "当前京东账号与已有京东同步数据来源不一致，请切回原账号；如需换号，请先清除旧账号的收益记录和持仓同步基线"
        case .concurrentModification:
            "组合收益在预览后发生变化，请重新同步"
        }
    }
}

/// 收益合并冲突（同一天本地与京东取值不同）。
struct PortfolioPerformanceMergeConflict: Identifiable, Equatable, Sendable {
    var id: String { date }
    var date: String
    var existing: PortfolioPerformanceDay
    var incoming: PortfolioPerformanceDay
}

/// 收益合并计划：汇总需自动插入/升级/更新/冲突的天数及元数据。
struct PortfolioPerformanceMergePlan: Equatable, Sendable {
    fileprivate var baseSnapshot: PortfolioPerformanceSnapshot
    fileprivate var automaticDays: [PortfolioPerformanceDay]
    fileprivate var metadata: JDFinancePerformanceSyncMetadata

    var conflicts: [PortfolioPerformanceMergeConflict]
    var insertedCount: Int
    var upgradedCount: Int
    var updatedCount: Int
    var unchangedCount: Int
    var zeroValueSkippedCount: Int
    var invalidValueSkippedCount: Int

    /// 是否存在可落盘的天数变更或冲突。
    var hasDayChanges: Bool {
        !automaticDays.isEmpty || !conflicts.isEmpty
    }

    /// 选中变更的天数计数（是否覆盖冲突）。
    func selectedDayChangeCount(overwriteConflicts: Bool) -> Int {
        insertedCount + upgradedCount + updatedCount
            + (overwriteConflicts ? conflicts.count : 0)
    }

    /// 判断计划是否可应用（有选中变更或元数据变化）。
    func canApply(overwriteConflicts: Bool) -> Bool {
        selectedDayChangeCount(overwriteConflicts: overwriteConflicts) > 0 || metadataChanged
    }

    /// 元数据是否相对基线发生变化。
    var metadataChanged: Bool {
        baseSnapshot.jdFinanceSync != metadata
    }

    /// 覆盖起始日期。
    var coveredFrom: String { metadata.coveredFrom }
    /// 覆盖截止日期。
    var coveredThrough: String { metadata.coveredThrough }
    /// 是否完整覆盖。
    var isComplete: Bool { metadata.isComplete }
    /// 来源账号键。
    var accountKey: String { metadata.accountKey }
}

/// 收益合并规划器：比对京东历史收益与本地收益，产出可应用的合并计划。
enum PortfolioPerformanceMergePlanner {
    /// 生成本地收益快照与京东历史的合并计划；账号不匹配或无效时抛错。
    static func plan(
        history: JDFinancePerformanceHistory,
        accountKey: String,
        in snapshot: PortfolioPerformanceSnapshot,
        syncedAt: Date
    ) throws -> PortfolioPerformanceMergePlan {
        let normalizedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccountKey.isEmpty else {
            throw PortfolioPerformanceMergeError.invalidAccount
        }

        let base = PortfolioPerformanceRecorder.normalized(snapshot)
        if let establishedKey = base.jdFinanceSync?.accountKey,
           establishedKey != normalizedAccountKey {
            throw PortfolioPerformanceMergeError.accountMismatch
        }
        if base.days.contains(where: {
            $0.source == .jdFinance
                && $0.sourceAccountKey != nil
                && $0.sourceAccountKey != normalizedAccountKey
        }) {
            throw PortfolioPerformanceMergeError.accountMismatch
        }

        var automaticDays: [PortfolioPerformanceDay] = []
        var conflicts: [PortfolioPerformanceMergeConflict] = []
        var insertedCount = 0
        var upgradedCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        var zeroValueSkippedCount = 0
        var invalidValueSkippedCount = 0
        let existingByDate = Dictionary(uniqueKeysWithValues: base.days.map { ($0.date, $0) })

        for remote in history.days.sorted(by: { $0.date < $1.date }) {
            guard DateOnlyFormatter.parse(remote.date) != nil,
                  remote.incomeAmount.isFinite,
                  remote.incomeRate?.isFinite ?? true
            else {
                invalidValueSkippedCount += 1
                continue
            }
            let existing = existingByDate[remote.date]
            if existing == nil, isZeroValue(remote) {
                zeroValueSkippedCount += 1
                continue
            }

            let incoming = PortfolioPerformanceDay(
                date: remote.date,
                profit: remote.incomeAmount,
                returnRate: remote.incomeRate,
                status: .confirmed,
                source: .jdFinance,
                sourceAccountKey: normalizedAccountKey,
                updatedAt: syncedAt
            )
            guard let existing else {
                automaticDays.append(incoming)
                insertedCount += 1
                continue
            }

            if existing.source == .jdFinance {
                let existingAccountKey = existing.sourceAccountKey ?? base.jdFinanceSync?.accountKey
                guard existingAccountKey == nil || existingAccountKey == normalizedAccountKey else {
                    throw PortfolioPerformanceMergeError.accountMismatch
                }
                if sameOfficialValue(existing, incoming) {
                    unchangedCount += 1
                } else {
                    automaticDays.append(incoming)
                    updatedCount += 1
                }
                continue
            }

            if existing.status == .estimated {
                automaticDays.append(incoming)
                upgradedCount += 1
            } else if sameProfit(existing.profit, incoming.profit) {
                unchangedCount += 1
            } else {
                conflicts.append(.init(date: remote.date, existing: existing, incoming: incoming))
            }
        }

        let metadata = mergedMetadata(
            existing: base.jdFinanceSync,
            accountKey: normalizedAccountKey,
            history: history,
            syncedAt: syncedAt,
            hasAutomaticDayChanges: !automaticDays.isEmpty
        )
        return PortfolioPerformanceMergePlan(
            baseSnapshot: base,
            automaticDays: automaticDays,
            metadata: metadata,
            conflicts: conflicts.sorted { $0.date < $1.date },
            insertedCount: insertedCount,
            upgradedCount: upgradedCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount,
            zeroValueSkippedCount: zeroValueSkippedCount,
            invalidValueSkippedCount: invalidValueSkippedCount
        )
    }

    /// 将合并计划应用到本地收益快照；若快照已被并发修改则抛错。
    static func applying(
        _ plan: PortfolioPerformanceMergePlan,
        to snapshot: PortfolioPerformanceSnapshot,
        overwriteConflicts: Bool = false
    ) throws -> PortfolioPerformanceSnapshot {
        let base = PortfolioPerformanceRecorder.normalized(snapshot)
        guard base == plan.baseSnapshot else {
            throw PortfolioPerformanceMergeError.concurrentModification
        }

        var next = base
        let selectedDays = plan.automaticDays + (overwriteConflicts ? plan.conflicts.map(\.incoming) : [])
        for day in selectedDays {
            if let index = next.days.firstIndex(where: { $0.date == day.date }) {
                next.days[index] = day
            } else {
                next.days.append(day)
            }
        }
        next.jdFinanceSync = plan.metadata
        return PortfolioPerformanceRecorder.normalized(next)
    }

    /// 判断京东日收益是否为零值（金额与收益率均接近 0）。
    private static func isZeroValue(_ day: JDFinancePerformanceDay) -> Bool {
        abs(day.incomeAmount) < 0.000_000_1
            && abs(day.incomeRate ?? 0) < 0.000_000_1
    }

    /// 比较两天官方取值是否一致（金额 + 收益率）。
    private static func sameOfficialValue(
        _ lhs: PortfolioPerformanceDay,
        _ rhs: PortfolioPerformanceDay
    ) -> Bool {
        sameProfit(lhs.profit, rhs.profit)
            && sameOptionalRate(lhs.returnRate, rhs.returnRate)
    }

    /// 比较收益金额是否一致（容差 0.005）。
    private static func sameProfit(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.005
    }

    /// 比较可选收益率是否一致（容差 1e-6）。
    private static func sameOptionalRate(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            abs(lhs - rhs) < 0.000_001
        case (nil, _), (_, nil):
            false
        }
    }

    /// 合并京东同步元数据：扩展覆盖区间、判定完成度，无变化时复用旧值。
    private static func mergedMetadata(
        existing: JDFinancePerformanceSyncMetadata?,
        accountKey: String,
        history: JDFinancePerformanceHistory,
        syncedAt: Date,
        hasAutomaticDayChanges: Bool
    ) -> JDFinancePerformanceSyncMetadata {
        let coveredFrom = min(existing?.coveredFrom ?? history.coveredFrom, history.coveredFrom)
        let coveredThrough = max(existing?.coveredThrough ?? history.coveredThrough, history.coveredThrough)
        let isComplete: Bool
        if let existing,
           existing.isComplete,
           existing.coveredFrom <= history.coveredFrom,
           existing.coveredThrough >= history.coveredThrough {
            isComplete = true
        } else {
            isComplete = history.isComplete
        }

        if let existing,
           existing.accountKey == accountKey,
           existing.coveredFrom == coveredFrom,
           existing.coveredThrough == coveredThrough,
           existing.isComplete == isComplete,
           !hasAutomaticDayChanges {
            return existing
        }
        return JDFinancePerformanceSyncMetadata(
            accountKey: accountKey,
            coveredFrom: coveredFrom,
            coveredThrough: coveredThrough,
            lastSyncedAt: syncedAt,
            isComplete: isComplete
        )
    }
}
