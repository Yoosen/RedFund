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
    /// 涨跌家数独立时间戳，频率低于指数报价，避免该接口抖动拖累整体刷新。
    private(set) var lastBreadthRefreshAt: Date?

    private let service: MarketIndexService
    private let minimumRefreshInterval: TimeInterval
    /// 涨跌家数刷新间隔（默认 60s，单独降频）。
    private let breadthRefreshInterval: TimeInterval
    private let nowProvider: () -> Date

    /// 初始化：注入行情服务、最小刷新间隔与时间提供者。
    init(
        service: MarketIndexService = MarketIndexService(),
        minimumRefreshInterval: TimeInterval = 20,
        breadthRefreshInterval: TimeInterval = 60,
        now: @escaping () -> Date = { .now }
    ) {
        self.service = service
        self.minimumRefreshInterval = minimumRefreshInterval
        self.breadthRefreshInterval = breadthRefreshInterval
        self.nowProvider = now
    }

    /// 刷新指数行情与涨跌家数。
    /// 指数报价与涨跌家数各自独立降频：报价 20s、涨跌家数 60s，
    /// 两者失败互不影响（涨跌家数超时不会阻断报价，反之亦然）。
    func refresh(ids: [MarketIndexID] = MarketIndexID.allCases, force: Bool = false) async {
        guard !isRefreshing else { return }

        let now = nowProvider()

        let quotesDue: Bool
        if force {
            quotesDue = true
        } else if quotes.isEmpty {
            quotesDue = true
        } else if let lastRefreshAt {
            quotesDue = now.timeIntervalSince(lastRefreshAt) >= minimumRefreshInterval
        } else {
            quotesDue = true
        }

        let breadthDue: Bool
        if force {
            breadthDue = true
        } else if marketBreadth == nil {
            breadthDue = true
        } else if let lastBreadthRefreshAt {
            breadthDue = now.timeIntervalSince(lastBreadthRefreshAt) >= breadthRefreshInterval
        } else {
            breadthDue = true
        }

        isRefreshing = true
        defer { isRefreshing = false }

        async let nextQuotesTask: [MarketIndexID: MarketIndexQuote] = quotesDue
            ? service.fetchQuotes(for: ids)
            : [:]
        async let nextBreadthTask: MarketBreadth? = breadthDue
            ? service.fetchMarketBreadth()
            : nil
        let (nextQuotes, nextBreadth) = await (nextQuotesTask, nextBreadthTask)

        if quotesDue, !nextQuotes.isEmpty {
            quotes.merge(nextQuotes) { _, new in new }
            lastRefreshAt = now
        }
        if breadthDue, let nextBreadth, nextBreadth.hasData {
            marketBreadth = nextBreadth
            lastBreadthRefreshAt = now
        }
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
