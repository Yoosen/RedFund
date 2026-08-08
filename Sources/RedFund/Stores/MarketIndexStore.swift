import Foundation
import Observation

/// 市场指数行情的运行时存储。
/// 负责按最小刷新间隔拉取指数报价与涨跌家数，并向 UI 暴露有序行情。
@Observable
@MainActor
final class MarketIndexStore {
    private(set) var quotes: [MarketIndexID: MarketIndexQuote] = [:]
    private(set) var marketBreadth: MarketBreadth?
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    private let service: MarketIndexService
    private let minimumRefreshInterval: TimeInterval
    private let nowProvider: () -> Date

    /// 初始化：注入行情服务、最小刷新间隔与时间提供者。
    init(
        service: MarketIndexService = MarketIndexService(),
        minimumRefreshInterval: TimeInterval = 20,
        now: @escaping () -> Date = { .now }
    ) {
        self.service = service
        self.minimumRefreshInterval = minimumRefreshInterval
        self.nowProvider = now
    }

    /// 刷新指数行情与涨跌家数（受最小刷新间隔与是否强制刷新约束）。
    func refresh(ids: [MarketIndexID] = MarketIndexID.allCases, force: Bool = false) async {
        guard !isRefreshing else { return }

        let now = nowProvider()
        if !force,
           let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < minimumRefreshInterval,
           !quotes.isEmpty,
           marketBreadth != nil {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        async let nextQuotesTask = service.fetchQuotes(for: ids)
        async let nextBreadthTask = service.fetchMarketBreadth()
        let (nextQuotes, nextBreadth) = await (nextQuotesTask, nextBreadthTask)
        if !nextQuotes.isEmpty {
            quotes.merge(nextQuotes) { _, new in new }
        }
        if let nextBreadth, nextBreadth.hasData {
            marketBreadth = nextBreadth
        }
        lastRefreshAt = now
    }

    /// 按给定 ID 顺序返回已加载的指数报价。
    func orderedQuotes(ids: [MarketIndexID] = MarketIndexID.allCases) -> [MarketIndexQuote] {
        ids.compactMap { quotes[$0] }
    }

    /// 返回默认指数对应的报价（用于菜单栏主展示）。
    func primaryQuote(defaultID: MarketIndexID) -> MarketIndexQuote? {
        quotes[defaultID]
    }
}
