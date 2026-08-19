import CoreFoundation
import Foundation

/// 基金行情服务：从东方财富抓取实时行情、历史净值、持仓/行业/资产配置等补充数据。
struct FundQuoteService {
    /// 行情请求错误类型。
    enum QuoteError: LocalizedError {
        case invalidResponse

        /// 错误的人类可读描述。
        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "行情接口返回异常"
            }
        }
    }

    /// 网络会话。
    private let session: URLSession

    /// 初始化，可注入会话。
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 获取单只基金的实时行情。
    func fetchQuote(code: String) async throws -> FundQuote {
        try await fetchEastmoneyCoreQuote(code: code)
    }

    /// 批量获取多只基金实时行情（去重、排序、容错）。
    func fetchQuotes(codes: [String]) async -> [String: FundQuote] {
        let uniqueCodes = Array(Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        guard !uniqueCodes.isEmpty else { return [:] }

        let quotes = await fetchCoreQuotesWithFallback(uniqueCodes)
        // 天天基金估值接口（FundValuationLast）的盘中估值优先于核心行情接口；
        // 该接口常返回空估值（null），此时保留核心行情原值。
        let valuations = await fetchValuationLastQuotes(codes: uniqueCodes)
        return Self.mergingValuations(valuations, into: quotes)
    }

    /// 核心行情接口（FundCoreDiyNew）：批量失败时分块重试，再对仍缺失的基金逐只补拉。
    private func fetchCoreQuotesWithFallback(_ uniqueCodes: [String]) async -> [String: FundQuote] {
        if let quotes = try? await fetchEastmoneyCoreQuotes(codes: uniqueCodes) {
            return await backfillingMissingQuotes(in: quotes, for: uniqueCodes)
        }

        // 整体批量请求失败（网络抖动/接口限流）时先按小块重试，再对仍缺失的基金逐只补拉，
        // 避免行情长期停留在上一次成功值。
        let chunkedQuotes = await fetchQuotesInChunks(uniqueCodes)
        return await backfillingMissingQuotes(in: chunkedQuotes, for: uniqueCodes)
    }

    /// 从天天基金估值接口批量获取最新估值（任何失败都返回空，由调用方回退）。
    private func fetchValuationLastQuotes(codes: [String]) async -> [String: FundValuationLastPayload] {
        let codes = codes.filter { !$0.isEmpty }
        guard !codes.isEmpty else { return [:] }

        var components = URLComponents(string: "https://fundcomapi.tiantianfunds.com/mm/newCore/FundValuationLast")!
        components.queryItems = [
            URLQueryItem(name: "FCODES", value: codes.joined(separator: ",")),
            URLQueryItem(name: "FIELDS", value: "FCODE,SHORTNAME,GSZZL,GZTIME,GSZ,NAV,PDATE")
        ]
        guard let url = components.url else { return [:] }

        var request = realtimeQuoteRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(FundValuationLastResponse.self, from: data),
              response.success != false,
              let rows = response.data
        else {
            return [:]
        }

        var valuations: [String: FundValuationLastPayload] = [:]
        for row in rows {
            guard let code = row.code?.nilIfBlank else { continue }
            valuations[code] = row
        }
        return valuations
    }

    /// 将天天基金估值（优先）合并进核心行情：估值字段以新接口为准，官方净值取日期较新者；
    /// 核心行情缺失的基金用估值接口数据兜底合成。
    private static func mergingValuations(
        _ valuations: [String: FundValuationLastPayload],
        into quotes: [String: FundQuote]
    ) -> [String: FundQuote] {
        guard !valuations.isEmpty else { return quotes }

        var merged = quotes
        for (code, valuation) in valuations {
            if let quote = merged[code] {
                merged[code] = applyingValuation(valuation, to: quote)
            } else if let synthesized = synthesizedQuote(from: valuation) {
                merged[code] = synthesized
            }
        }
        return merged
    }

    /// 用天天基金估值覆盖行情中的估值字段（估值时间/估算净值/估算涨跌幅），并按需更新官方净值。
    private static func applyingValuation(
        _ valuation: FundValuationLastPayload,
        to quote: FundQuote
    ) -> FundQuote {
        var next = quote

        let valuationNetValue = valuation.netValue.doubleValue
        if valuationNetValue > 0,
           let valuationNetValueDate = valuation.netValueDate.stringValue?.nilIfDash,
           valuationNetValueDate >= quote.netValueDate {
            next.netValue = valuationNetValue
            next.netValueDate = valuationNetValueDate
        }

        // 仅在估值时间不落后于现有行情时覆盖，避免旧估值回写。
        guard let estimateTime = normalizedEstimateTime(valuation.estimateTime.stringValue),
              estimateTime >= quote.estimateTime
        else {
            return next
        }

        let estimatedNetValue = valuation.estimatedNetValue.doubleValue
        if estimatedNetValue > 0 {
            next.estimatedNetValue = estimatedNetValue
        }
        next.estimateTime = estimateTime

        // 官方净值日期未追上估值时间时，涨跌幅以估值接口为准；已追上则保留官方日涨幅。
        let officialCaughtUp = next.netValueDate >= String(estimateTime.prefix(10))
        if !officialCaughtUp, valuation.estimatedGrowthRate.stringValue?.nilIfDash != nil {
            next.growthRate = valuation.estimatedGrowthRate.doubleValue
        }
        return next
    }

    /// 核心行情缺失时，用天天基金估值数据合成行情（官方净值 + 估值）。
    private static func synthesizedQuote(from valuation: FundValuationLastPayload) -> FundQuote? {
        guard let code = valuation.code?.nilIfBlank else { return nil }
        let netValue = valuation.netValue.doubleValue
        let estimatedNetValue = valuation.estimatedNetValue.doubleValue
        let resolvedNetValue = netValue > 0 ? netValue : estimatedNetValue
        guard resolvedNetValue > 0 else { return nil }

        return FundQuote(
            code: code,
            name: valuation.name?.nilIfBlank ?? code,
            netValue: resolvedNetValue,
            estimatedNetValue: estimatedNetValue > 0 ? estimatedNetValue : resolvedNetValue,
            growthRate: valuation.estimatedGrowthRate.doubleValue,
            estimateTime: normalizedEstimateTime(valuation.estimateTime.stringValue) ?? "",
            netValueDate: valuation.netValueDate.stringValue?.nilIfDash ?? ""
        )
    }

    /// 将估值时间归一化为 "yyyy-MM-dd HH:mm"（去掉可能的秒数），空值/破折号返回 nil。
    private static func normalizedEstimateTime(_ value: String?) -> String? {
        guard let text = value?.nilIfDash else { return nil }
        if text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            return String(text.prefix(16))
        }
        return text
    }

    /// 对批量结果中缺失的基金逐只补拉行情。
    private func backfillingMissingQuotes(
        in quotes: [String: FundQuote],
        for codes: [String]
    ) async -> [String: FundQuote] {
        let missingCodes = codes.filter { quotes[$0] == nil }
        guard !missingCodes.isEmpty else { return quotes }

        var merged = quotes
        for code in missingCodes {
            if let quote = try? await fetchEastmoneyCoreQuote(code: code) {
                merged[code] = quote
            }
        }
        return merged
    }

    /// 按小块分批请求行情（基金数量超过单块大小时才有意义）。
    private func fetchQuotesInChunks(_ codes: [String]) async -> [String: FundQuote] {
        let chunkSize = 20
        guard codes.count > chunkSize else { return [:] }

        var merged: [String: FundQuote] = [:]
        for start in stride(from: 0, to: codes.count, by: chunkSize) {
            let chunk = Array(codes[start..<min(start + chunkSize, codes.count)])
            if let quotes = try? await fetchEastmoneyCoreQuotes(codes: chunk) {
                merged.merge(quotes) { _, new in new }
            }
        }
        return merged
    }

    /// 从 startDate 起逐日向前查找首个有历史净值的日期（最多 30 天）。
    func fetchSmartNetValue(code: String, startDate: String) async -> (date: String, value: Double)? {
        guard let start = DateOnlyFormatter.parse(startDate) else { return nil }
        let today = Calendar.current.startOfDay(for: .now)
        var current = Calendar.current.startOfDay(for: start)

        for _ in 0..<30 {
            if current > today { return nil }
            let dateText = DateOnlyFormatter.string(from: current)
            if let value = try? await fetchHistoricalNetValue(code: code, date: dateText) {
                return (dateText, value)
            }
            current = Calendar.current.date(byAdding: .day, value: 1, to: current) ?? current
        }
        return nil
    }

    /// 获取某确认日（acceptedDate）的确认净值，优先用最新行情里的当日净值。
    func fetchConfirmedNetValue(
        code: String,
        acceptedDate: String,
        latestQuote: FundQuote? = nil
    ) async -> Double? {
        if latestQuote?.netValueDate == acceptedDate,
           let netValue = latestQuote?.netValue,
           netValue > 0 {
            return netValue
        }

        guard let value = try? await fetchHistoricalNetValue(code: code, date: acceptedDate),
              value > 0
        else {
            return nil
        }
        return value
    }

    /// 按基金代码查询名称（搜索服务优先，回退行情接口）。
    func lookupFundName(code: String) async -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }

        if let name = try? await searchFundName(code: code), !name.isEmpty {
            return name
        }

        if let quote = try? await fetchQuote(code: code),
           quote.name != code {
            return quote.name
        }

        return nil
    }

    /// 按基金名称查询代码（含 ETF 联接别名兜底）。
    func lookupFundCode(name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let matchKeys = Self.fundCodeSearchKeys(for: name)
        var searchKeys = matchKeys
        for key in matchKeys {
            guard let baseName = Self.qdiiBaseSearchName(for: key),
                  !searchKeys.contains(baseName)
            else {
                continue
            }
            searchKeys.append(baseName)
        }
        for key in searchKeys {
            guard let items = try? await searchFunds(key: key), !items.isEmpty else {
                continue
            }
            if let matchedCode = Self.matchedFundCode(in: items, queryNames: matchKeys) {
                return matchedCode
            }
        }

        // Some JD ETF-link holdings use a longer display name than the fund
        // search service. Keep this behind every existing lookup and require an
        // exact, unique fund-name match for the conservative alias.
        for alias in Self.conservativeETFLinkAliases(for: name) where !searchKeys.contains(alias) {
            guard let items = try? await searchFunds(key: alias), !items.isEmpty else {
                continue
            }
            if let matchedCode = Self.matchedFundCode(in: items, queryNames: [alias]) {
                return matchedCode
            }
        }
        return nil
    }

    /// 获取基金官方类型（天天基金 FundMNNBasicInformation 接口返回 FTYPE）。
    func fetchFundType(code: String) async -> FundType? {
        var components = URLComponents(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNNBasicInformation")!
        components.queryItems = [
            URLQueryItem(name: "FCODE", value: code),
            URLQueryItem(name: "deviceid", value: "app"),
            URLQueryItem(name: "version", value: "6.3.5"),
            URLQueryItem(name: "plat", value: "Iphone"),
            URLQueryItem(name: "appType", value: "ttjj"),
            URLQueryItem(name: "product", value: "EFund")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(FundBasicInfoResponse.self, from: data)
            guard let info = decoded.datas else { return nil }
            let isQDII = Self.qdiiBaseSearchName(for: info.shortName ?? "") != nil
            return FundType.from(ftype: info.ftype, isQDII: isQDII)
        } catch {
            return nil
        }
    }

    /// 获取基金详情补充数据：净值走势、重仓股、相关行业、行业/资产配置。
    func fetchFundDetailSupplement(code: String, now: Date = .now) async -> FundDetailSupplement {
        async let history = fetchNetValueHistorySafely(code: code)
        async let position = fetchPositionSupplementSafely(code: code)
        async let assetAllocation = fetchAssetAllocationSafely(code: code)
        let (historyPoints, positionSupplement, assetItems) = await (history, position, assetAllocation)
        let industryAllocation = await fetchSectorAllocationSafely(
            code: code,
            date: positionSupplement.holdingDisclosureDate
        )
        let yesterdayPoint = Self.yesterdayNetValuePoint(from: historyPoints, now: now)
        return FundDetailSupplement(
            trend: historyPoints,
            history: historyPoints,
            topHoldings: positionSupplement.topHoldings,
            relatedSectors: positionSupplement.relatedSectors,
            industryAllocation: industryAllocation,
            assetAllocation: assetItems,
            holdingDisclosureDate: positionSupplement.holdingDisclosureDate,
            industryDisclosureDate: industryAllocation.first?.date,
            assetAllocationDate: assetItems.first?.date,
            yesterdayPoint: yesterdayPoint
        )
    }

    /// 从净值点列表中取早于“今天”的最后一个点（昨日净值）。
    private static func yesterdayNetValuePoint(from points: [FundNetValuePoint], now: Date) -> FundNetValuePoint? {
        let today = DateOnlyFormatter.string(from: now)
        return points.last { point in
            let date = Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000)
            return DateOnlyFormatter.string(from: date) < today
        }
    }

    /// 获取单只基金实时行情的内部入口（走批量接口）。
    private func fetchEastmoneyCoreQuote(code: String) async throws -> FundQuote {
        guard let quote = try await fetchEastmoneyCoreQuotes(codes: [code])[code] else {
            throw QuoteError.invalidResponse
        }
        return quote
    }

    /// 调用东方财富核心行情接口批量获取基金实时行情。
    private func fetchEastmoneyCoreQuotes(codes: [String]) async throws -> [String: FundQuote] {
        let codes = codes.filter { !$0.isEmpty }
        guard !codes.isEmpty else { return [:] }

        var components = URLComponents(string: "https://fundcomapi.eastmoney.com/mm/newCore/FundCoreDiyNew")!
        components.queryItems = [
            URLQueryItem(name: "FCODES", value: codes.joined(separator: ",")),
            URLQueryItem(name: "FIELDS", value: "SHORTNAME,RZDF,DWJZ,JZRQ,FSRQ,NAV,GSZZL,GZTIME,GSZ,FCODE,QDCODE,PTYPE"),
            URLQueryItem(name: "deviceid", value: "1234567.py.service"),
            URLQueryItem(name: "version", value: "6.5.5"),
            URLQueryItem(name: "product", value: "EFund"),
            URLQueryItem(name: "plat", value: "web")
        ]
        guard let url = components.url else { throw QuoteError.invalidResponse }

        var request = realtimeQuoteRequest(url: url)
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(EastmoneyCoreQuoteResponse.self, from: data)
        guard response.success != false,
              let rows = response.data,
              !rows.isEmpty
        else {
            throw QuoteError.invalidResponse
        }

        var quotes: [String: FundQuote] = [:]
        for row in rows {
            guard let quote = row.quote else { continue }
            quotes[quote.code] = quote
        }
        if quotes.isEmpty {
            throw QuoteError.invalidResponse
        }
        return quotes
    }

    /// 获取某日期的历史净值，按交易日期严格匹配。
    /// 旧版 HTML 端点（fundf10.eastmoney.com/F10DataApi.aspx）已失效、常返回 404，
    /// 会导致依赖历史净值的旧交易长期无法确认。故优先使用东财 JSON F10 接口，
    /// 失败再回退净值走势 JS，最后才用旧版 HTML 接口做兼容兜底。
    private func fetchHistoricalNetValue(code: String, date: String) async throws -> Double? {
        if let value = try? await fetchCurrentHistoricalNetValue(code: code, date: date),
           value > 0 {
            return value
        }

        if let value = try? await fetchTrendHistoricalNetValue(code: code, date: date),
           value > 0 {
            return value
        }

        // Keep the legacy HTML route as a final compatibility fallback. It is
        // no longer the primary source because the public endpoint currently
        // returns HTTP 404, but some mirrored environments may still serve it.
        return try await fetchLegacyHistoricalNetValue(code: code, date: date)
    }

    private func fetchCurrentHistoricalNetValue(code: String, date: String) async throws -> Double? {
        var components = URLComponents(string: "https://api.fund.eastmoney.com/f10/lsjz")!
        components.queryItems = [
            URLQueryItem(name: "fundCode", value: code),
            URLQueryItem(name: "pageIndex", value: "1"),
            URLQueryItem(name: "pageSize", value: "20"),
            URLQueryItem(name: "startDate", value: date),
            URLQueryItem(name: "endDate", value: date)
        ]
        guard let url = components.url else {
            throw QuoteError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("https://fundf10.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw QuoteError.invalidResponse
        }

        let payload = try JSONDecoder().decode(EastmoneyHistoricalNetValueResponse.self, from: data)
        guard payload.errorCode == 0 else {
            throw QuoteError.invalidResponse
        }
        guard let row = payload.data?.rows?.first(where: { $0.date?.value == date }) else {
            return nil
        }
        let value = Double(row.netValue?.value ?? "") ?? 0
        return value > 0 && value.isFinite ? value : nil
    }

    private func fetchTrendHistoricalNetValue(code: String, date: String) async throws -> Double? {
        let points = try await fetchNetValueHistory(code: code)
        return points.first { point in
            let pointDate = Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000)
            return DateOnlyFormatter.string(from: pointDate) == date
        }?.value
    }

    private func fetchLegacyHistoricalNetValue(code: String, date: String) async throws -> Double? {
        let url = URL(string: "https://fundf10.eastmoney.com/F10DataApi.aspx?type=lsjz&code=\(code)&page=1&per=1&sdate=\(date)&edate=\(date)")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw QuoteError.invalidResponse
        }
        guard let text = decodedText(data) else {
            throw QuoteError.invalidResponse
        }
        if text.contains("暂无数据") {
            return nil
        }
        return parseHistoricalNetValue(text, date: date)
    }

    /// 安全获取净值历史（失败返回空）。
    private func fetchNetValueHistorySafely(code: String) async -> [FundNetValuePoint] {
        (try? await fetchNetValueHistory(code: code)) ?? []
    }

    /// 安全获取十大重仓股（失败返回空）。
    private func fetchTopStockHoldingsSafely(code: String) async -> [FundStockHolding] {
        (try? await fetchTopStockHoldings(code: code)) ?? []
    }

    /// 安全获取持仓补充：优先移动端，失败回退重仓股接口。
    private func fetchPositionSupplementSafely(code: String) async -> FundPositionSupplement {
        if let supplement = try? await fetchMobileInvestmentPosition(code: code),
           !supplement.topHoldings.isEmpty || !supplement.relatedSectors.isEmpty {
            return supplement
        }
        let holdings = await fetchTopStockHoldingsSafely(code: code)
        return FundPositionSupplement(
            topHoldings: holdings,
            relatedSectors: [],
            holdingDisclosureDate: nil
        )
    }

    /// 安全获取行业配置（失败返回空）。
    private func fetchSectorAllocationSafely(code: String, date: String?) async -> [FundSectorExposure] {
        (try? await fetchSectorAllocation(code: code, date: date)) ?? []
    }

    /// 安全获取资产配置（失败返回空）。
    private func fetchAssetAllocationSafely(code: String) async -> [FundAssetAllocationItem] {
        (try? await fetchAssetAllocation(code: code)) ?? []
    }

    /// 获取基金净值历史走势（东方财富 pingzhongdata.js）。
    private func fetchNetValueHistory(code: String) async throws -> [FundNetValuePoint] {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(code).js?v=\(timestamp)")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await session.data(for: request)
        guard let text = decodedText(data),
              let payload = extractJSONArray(named: "Data_netWorthTrend", from: text)
        else {
            throw QuoteError.invalidResponse
        }
        let rows = try JSONDecoder().decode([NetWorthTrendPayload].self, from: payload)
        return rows.map {
            FundNetValuePoint(
                timestamp: Int64($0.x),
                value: $0.y,
                equityReturn: $0.equityReturn
            )
        }
    }

    /// 获取基金十大重仓股（东方财富 F10 接口）。
    private func fetchTopStockHoldings(code: String) async throws -> [FundStockHolding] {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=\(code)&topline=10&year=&month=&_=\(timestamp)")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await session.data(for: request)
        guard let text = decodedText(data) else {
            throw QuoteError.invalidResponse
        }
        var holdings = parseTopStockHoldings(text)
        if holdings.isEmpty {
            return []
        }

        let changes = try? await fetchStockChanges(for: holdings.map(\.code))
        if let changes {
            holdings = holdings.map { holding in
                var next = holding
                next.changeRate = changes[holding.code]
                return next
            }
        }
        return holdings
    }

    /// 从移动端接口获取持仓（重仓股 + 相关行业）。
    private func fetchMobileInvestmentPosition(code: String) async throws -> FundPositionSupplement {
        var components = URLComponents(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNInverstPosition")!
        components.queryItems = eastmoneyMobileQueryItems(code: code)
        guard let url = components.url else { throw QuoteError.invalidResponse }

        let (data, _) = try await session.data(for: eastmoneyMobileRequest(url: url))
        let response = try JSONDecoder().decode(MobileInvestmentPositionResponse.self, from: data)
        guard response.success == true,
              let stocks = response.datas?.fundStocks
        else {
            throw QuoteError.invalidResponse
        }

        var holdings = stocks.prefix(10).compactMap { row -> FundStockHolding? in
            let code = row.code?.nilIfBlank ?? ""
            let name = row.name?.nilIfBlank ?? ""
            let weight = row.weight.doubleValue
            guard !code.isEmpty || !name.isEmpty || weight > 0 else { return nil }
            return FundStockHolding(
                code: code,
                name: name,
                weight: weight > 0 ? MoneyFormatter.percent(weight, signed: false) : "",
                changeRate: nil,
                industryCode: row.industryCode?.nilIfBlank,
                industryName: row.industryName?.nilIfBlank,
                positionChangeType: row.positionChangeType?.nilIfBlank,
                positionChangeRate: row.positionChangeRate.doubleValue,
                market: row.market?.nilIfBlank
            )
        }

        if !holdings.isEmpty,
           let changes = try? await fetchStockChanges(for: holdings.map(\.code)) {
            holdings = holdings.map { holding in
                var next = holding
                next.changeRate = changes[holding.code]
                return next
            }
        }

        let relatedSectors = aggregateRelatedSectors(
            from: stocks,
            date: response.expansion?.nilIfBlank
        )
        return FundPositionSupplement(
            topHoldings: holdings,
            relatedSectors: relatedSectors,
            holdingDisclosureDate: response.expansion?.nilIfBlank
        )
    }

    /// 获取行业配置（移动端接口）。
    private func fetchSectorAllocation(code: String, date: String?) async throws -> [FundSectorExposure] {
        var components = URLComponents(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNSectorAllocation")!
        var queryItems = eastmoneyMobileQueryItems(code: code)
        queryItems.append(URLQueryItem(name: "DATE", value: date ?? ""))
        components.queryItems = queryItems
        guard let url = components.url else { throw QuoteError.invalidResponse }

        let (data, _) = try await session.data(for: eastmoneyMobileRequest(url: url))
        let response = try JSONDecoder().decode(MobileSectorAllocationResponse.self, from: data)
        guard response.success == true,
              let rows = response.datas
        else {
            throw QuoteError.invalidResponse
        }

        return rows.compactMap { row -> FundSectorExposure? in
            guard let name = row.name?.nilIfBlank,
                  name != "合计"
            else { return nil }
            let weight = row.weight.doubleValue
            guard weight > 0 else { return nil }
            return FundSectorExposure(
                code: nil,
                name: name,
                weight: weight,
                date: row.date?.nilIfBlank ?? response.expansion?.nilIfBlank,
                source: .disclosedIndustry
            )
        }
        .sorted { $0.weight > $1.weight }
    }

    /// 获取资产配置（移动端接口，股票/债券/现金/基金/其他）。
    private func fetchAssetAllocation(code: String) async throws -> [FundAssetAllocationItem] {
        var components = URLComponents(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNAssetAllocationNew")!
        components.queryItems = eastmoneyMobileQueryItems(code: code)
        guard let url = components.url else { throw QuoteError.invalidResponse }

        let (data, _) = try await session.data(for: eastmoneyMobileRequest(url: url))
        let response = try JSONDecoder().decode(MobileAssetAllocationResponse.self, from: data)
        guard response.success == true,
              let row = response.datas?.first
        else {
            throw QuoteError.invalidResponse
        }

        let date = row.date?.nilIfBlank ?? response.expansion?.nilIfBlank
        let items: [(String, Double)] = [
            ("股票", row.stock.doubleValue),
            ("债券", row.bond.doubleValue),
            ("现金", row.cash.doubleValue),
            ("基金", row.fund.doubleValue),
            ("其他", row.other.doubleValue)
        ]
        return items.compactMap { name, weight in
            guard weight > 0 else { return nil }
            return FundAssetAllocationItem(name: name, weight: weight, date: date)
        }
    }

    /// 获取重仓股当日涨跌（腾讯行情接口，GB18030 编码）。
    private func fetchStockChanges(for codes: [String]) async throws -> [String: Double] {
        let symbols = codes.compactMap(tencentStockSymbol(for:))
        guard !symbols.isEmpty else { return [:] }
        let url = URL(string: "https://qt.gtimg.cn/q=\(symbols.joined(separator: ","))")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await session.data(for: request)
        guard let text = decodedText(data, preferredEncoding: Self.gb18030Encoding) else {
            throw QuoteError.invalidResponse
        }

        var changes: [String: Double] = [:]
        for code in codes {
            guard let symbol = tencentStockSymbol(for: code),
                  let payload = parseTencentStockPayload(text, symbol: symbol)
            else {
                continue
            }
            changes[code] = payload
        }
        return changes
    }

    /// 按代码搜索基金名称。
    private func searchFundName(code: String) async throws -> String? {
        let response = try await searchFunds(key: code)
        let matchedFund = response.first { $0.code == code }
        return matchedFund?.name?.nilIfBlank ?? matchedFund?.shortName?.nilIfBlank
    }

    /// 搜索基金（东方财富搜索建议接口，JSONP 响应）。
    private func searchFunds(key: String) async throws -> [FundSearchItem] {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let callback = "RedFundSuggest_\(timestamp)"
        var components = URLComponents(string: "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx")!
        components.queryItems = [
            URLQueryItem(name: "m", value: "1"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "callback", value: callback),
            URLQueryItem(name: "_", value: "\(timestamp)")
        ]
        guard let url = components.url else { throw QuoteError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await session.data(for: request)
        guard let text = decodedText(data),
              let payload = parseJSONP(text)
        else {
            throw QuoteError.invalidResponse
        }

        let response = try JSONDecoder().decode(FundSearchResponse.self, from: payload)
        return response.datas ?? []
    }

    /// 基金搜索名称归一化（去空格/括号/"板"）。
    private static func canonicalFundSearchName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "板", with: "")
            .lowercased()
    }

    /// 构造基金代码搜索键集合（含去除 ETF/交易前缀等变体）。
    private static func fundCodeSearchKeys(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tradeName = fundSearchNameWithoutTradePrefix(trimmed)
        var keys: [String] = []
        func append(_ value: String) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !keys.contains(normalized) else { return }
            keys.append(normalized)
        }

        append(trimmed)
        append(tradeName)
        for value in [trimmed, tradeName] {
            append(value.replacingOccurrences(of: "ETF", with: ""))
            append(value.replacingOccurrences(of: "交易型开放式指数证券投资基金", with: ""))
            append(value.replacingOccurrences(of: "板", with: ""))
            append(value.replacingOccurrences(of: "板", with: "").replacingOccurrences(of: "ETF", with: ""))
        }
        return keys
    }

    /// 提取 QDII 基金的基础名（去除末尾 "(QDII)A" 后缀）。
    /// 若名称以 `(QDII)X` 形式结尾，返回去除 QDII 后缀的基础名，否则 nil。
    static func qdiiBaseSearchName(for value: String) -> String? {
        let pattern = #"(?i)\s*[\(（]\s*QDII\s*[\)）]\s*[A-Z]\s*$"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let baseName = value[..<range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? nil : baseName
    }

    /// 去除名称中的转换/转入/转出前缀。
    private static func fundSearchNameWithoutTradePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "转换-", with: "")
            .replacingOccurrences(of: "转入-", with: "")
            .replacingOccurrences(of: "转出-", with: "")
    }

    /// 构造 ETF 联接基金的保守别名（用于兜底匹配）。
    private static func conservativeETFLinkAliases(for value: String) -> [String] {
        let name = fundSearchNameWithoutTradePrefix(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.localizedCaseInsensitiveContains("ETF"), name.contains("联接") else {
            return []
        }

        let alias = name
            .replacingOccurrences(of: "中证全指", with: "")
            .replacingOccurrences(of: "发起式", with: "")
        guard alias != name, !alias.isEmpty else { return [] }
        return [alias]
    }

    /// 从搜索结果中匹配唯一基金代码（名称规范一致且为 6 位数字）。
    private static func matchedFundCode(in items: [FundSearchItem], queryNames: [String]) -> String? {
        let canonicalQueries = Set(queryNames.map(canonicalFundSearchName))
        let codes = Set(items.compactMap { item -> String? in
            guard item.isFund else { return nil }
            let itemNames = [item.name, item.shortName].compactMap { $0 }
            guard itemNames
                .map(canonicalFundSearchName)
                .contains(where: canonicalQueries.contains)
            else {
                return nil
            }
            let code = item.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return code.count == 6 && code.allSatisfy(\.isNumber) ? code : nil
        })
        return codes.count == 1 ? codes.first : nil
    }

    /// 从 JSONP 文本中提取 JSON 负载（去除回调包裹）。
    private func parseJSONP(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "("),
              let end = text.lastIndex(of: ")"),
              start < end
        else {
            return nil
        }
        let json = text[text.index(after: start)..<end]
        return String(json).data(using: .utf8)
    }

    /// 解析历史净值行（F10 表格），返回指定日期的净值。
    private func parseHistoricalNetValue(_ text: String, date: String) -> Double? {
        let rows = text.components(separatedBy: "<tr")
        guard let row = rows.first(where: { $0.contains("<td>\(date)</td>") }),
              let parsed = parseOfficialNetValueRow(row)
        else {
            return nil
        }
        return parsed.value
    }

    /// 从脚本文本中提取命名 JSON 数组（按括号深度匹配）。
    private func extractJSONArray(named variableName: String, from text: String) -> Data? {
        guard let nameRange = text.range(of: variableName),
              let start = text[nameRange.upperBound...].firstIndex(of: "[")
        else {
            return nil
        }

        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    return String(text[start..<end]).data(using: .utf8)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 解析十大重仓股表格（按表头定位代码/名称/占比列）。
    private func parseTopStockHoldings(_ text: String) -> [FundStockHolding] {
        let headerRow = firstMatch(
            pattern: #"<thead[\s\S]*?<tr[\s\S]*?</tr>[\s\S]*?</thead>"#,
            in: text
        ) ?? ""
        let headerCells = matches(
            pattern: #"<th[\s\S]*?>([\s\S]*?)</th>"#,
            in: headerRow
        ).map { stripHTML($0).replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }

        var codeIndex = -1
        var nameIndex = -1
        var weightIndex = -1
        for (index, title) in headerCells.enumerated() {
            if codeIndex < 0, title.contains("股票代码") || title.contains("证券代码") {
                codeIndex = index
            }
            if nameIndex < 0, title.contains("股票名称") || title.contains("证券名称") {
                nameIndex = index
            }
            if weightIndex < 0, title.contains("占净值比例") || title.contains("占比") {
                weightIndex = index
            }
        }

        let body = firstMatch(pattern: #"<tbody[\s\S]*?</tbody>"#, in: text) ?? text
        return matches(pattern: #"<tr[\s\S]*?</tr>"#, in: body).compactMap { row in
            let cells = matches(pattern: #"<td[\s\S]*?>([\s\S]*?)</td>"#, in: row).map(stripHTML)
            guard !cells.isEmpty else { return nil }

            let code = cell(at: codeIndex, in: cells).flatMap(stockCode(in:))
                ?? cells.compactMap(stockCode(in:)).first
                ?? ""
            let name = cell(at: nameIndex, in: cells)
                ?? cells.first(where: {
                    !$0.isEmpty
                        && $0 != code
                        && !$0.contains("%")
                        && Double($0.replacingOccurrences(of: ",", with: "")) == nil
                })
                ?? ""
            let weight = cell(at: weightIndex, in: cells).flatMap(weightText(in:))
                ?? cells.compactMap(weightText(in:)).first
                ?? ""

            guard !code.isEmpty || !name.isEmpty || !weight.isEmpty else { return nil }
            return FundStockHolding(code: code, name: name, weight: weight, changeRate: nil)
        }
        .prefix(10)
        .map { $0 }
    }

    /// 解析腾讯股票行情负载，提取当日涨跌幅（~ 分隔的第 6 字段）。
    private func parseTencentStockPayload(_ text: String, symbol: String) -> Double? {
        let variable = "v_\(symbol)"
        guard let variableRange = text.range(of: "\(variable)=\""),
              let endQuote = text[variableRange.upperBound...].firstIndex(of: "\"")
        else {
            return nil
        }
        let payload = String(text[variableRange.upperBound..<endQuote])
        let parts = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 5 else { return nil }
        return Double(parts[5])
    }

    /// 将 6/5 位股票代码转换为腾讯行情符号（区分沪/深/京/港）。
    private func tencentStockSymbol(for code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\d{6}$"#, options: .regularExpression) != nil {
            if trimmed.hasPrefix("6") || trimmed.hasPrefix("9") {
                return "s_sh\(trimmed)"
            }
            if trimmed.hasPrefix("4") || trimmed.hasPrefix("8") {
                return "s_bj\(trimmed)"
            }
            return "s_sz\(trimmed)"
        }
        if trimmed.range(of: #"^\d{5}$"#, options: .regularExpression) != nil {
            return "s_hk\(trimmed)"
        }
        return nil
    }

    /// 聚合重仓股所属行业，按权重汇总为行业暴露。
    private func aggregateRelatedSectors(
        from stocks: [MobileFundStockPayload],
        date: String?
    ) -> [FundSectorExposure] {
        var sectors: [String: (code: String?, name: String, weight: Double)] = [:]
        for stock in stocks {
            guard let name = stock.industryName?.nilIfBlank else { continue }
            let code = stock.industryCode?.nilIfBlank
            let key = code ?? name
            let current = sectors[key] ?? (code: code, name: name, weight: 0)
            sectors[key] = (code: code, name: name, weight: current.weight + stock.weight.doubleValue)
        }

        return sectors.values
            .filter { $0.weight > 0 }
            .map {
                FundSectorExposure(
                    code: $0.code,
                    name: $0.name,
                    weight: $0.weight,
                    date: date,
                    source: .topHoldings
                )
            }
            .sorted { $0.weight > $1.weight }
    }

    /// 构造东方财富移动端接口通用查询参数。
    private func eastmoneyMobileQueryItems(code: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "FCODE", value: code),
            URLQueryItem(name: "deviceid", value: "Wap"),
            URLQueryItem(name: "plat", value: "Wap"),
            URLQueryItem(name: "product", value: "EFund"),
            URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "Uid", value: "")
        ]
    }

    /// 构造东方财富移动端请求（iPhone UA + Referer）。
    private func eastmoneyMobileRequest(url: URL) -> URLRequest {
        var request = realtimeQuoteRequest(url: url)
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// 构造实时行情请求（禁用缓存）。
    private func realtimeQuoteRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    /// 返回首个正则匹配。
    private func firstMatch(pattern: String, in text: String) -> String? {
        matches(pattern: pattern, in: text).first
    }

    /// 返回所有正则捕获组匹配（取第一个捕获组）。
    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: captureIndex), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    /// 取单元格（按索引，越界返回 nil）。
    private func cell(at index: Int, in cells: [String]) -> String? {
        guard index >= 0, cells.indices.contains(index) else {
            return nil
        }
        return cells[index]
    }

    /// 东财 JSON F10 历史净值接口（`/f10/lsjz`）响应。
    private struct EastmoneyHistoricalNetValueResponse: Decodable {
        let errorCode: Int
        let errorMessage: String?
        let data: EastmoneyHistoricalNetValueData?

        enum CodingKeys: String, CodingKey {
            case errorCode = "ErrCode"
            case errorMessage = "ErrMsg"
            case data = "Data"
        }

        struct EastmoneyHistoricalNetValueData: Decodable {
            let rows: [EastmoneyHistoricalNetValueRow]?
            let totalCount: Int?

            enum CodingKeys: String, CodingKey {
                case rows = "LSJZList"
                case totalCount = "TotalCount"
            }
        }

        struct EastmoneyHistoricalNetValueRow: Decodable {
            let date: LossyString?
            let netValue: LossyString?
            let accumulatedNetValue: LossyString?
            let rate: LossyString?

            enum CodingKeys: String, CodingKey {
                case date = "FSRQ"
                case netValue = "DWJZ"
                case accumulatedNetValue = "LJJZ"
                case rate = "JZZZL"
            }
        }
    }

    /// 从文本中提取 5~6 位数字作为股票代码。
    private func stockCode(in text: String) -> String? {
        firstMatch(pattern: #"(\d{5,6})"#, in: text)
    }

    /// 从文本中提取百分比数值（附加 "%"）。
    private func weightText(in text: String) -> String? {
        firstMatch(pattern: #"(\d+(?:\.\d+)?)\s*%"#, in: text).map { "\($0)%" }
    }

    /// 解析官方净值行（F10 表格），返回日期/净值/增长率。
    private func parseOfficialNetValueRow(_ row: String) -> (date: String, value: Double, growthRate: Double?)? {
        let pattern = #"<td[^>]*>(.*?)</td>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(row.startIndex..<row.endIndex, in: row)
        let cells = regex.matches(in: row, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let cellRange = Range(match.range(at: 1), in: row)
            else {
                return nil
            }
            return stripHTML(String(row[cellRange]))
        }
        guard cells.count >= 2 else { return nil }
        let date = cells[0]
        guard DateOnlyFormatter.parse(date) != nil,
              let value = Double(cells[1])
        else {
            return nil
        }
        let growthRate = cells.count >= 4 ? Double(cells[3].replacingOccurrences(of: "%", with: "")) : nil
        return (date, value, growthRate)
    }

    /// 去除 HTML 标签并裁剪空白。
    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按优先编码解码文本（UTF-8 优先，回退 GB18030）。
    private func decodedText(_ data: Data, preferredEncoding: String.Encoding = .utf8) -> String? {
        String(data: data, encoding: preferredEncoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: Self.gb18030Encoding)
    }

    /// GB18030 编码（用于处理腾讯行情中文）。
    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}

/// 东方财富核心行情响应。
private struct EastmoneyCoreQuoteResponse: Decodable {
    var data: [EastmoneyCoreQuotePayload]?
    var success: Bool?
}

/// 东方财富核心行情单条载荷（字段对应 FCODE/SHORTNAME/DWJZ 等）。
private struct EastmoneyCoreQuotePayload: Decodable {
    var code: String?
    var quoteCode: String?
    var name: String?
    var netValue: LossyString?
    var netValueDate: LossyString?
    var fallbackNetValueDate: LossyString?
    var estimatedNetValue: LossyString?
    var estimatedGrowthRate: LossyString?
    var estimateTime: LossyString?
    var latestGrowthRate: LossyString?

    /// 将原始字段转换为领域模型 FundQuote（处理实时估值/官方净值/增长率）。
    var quote: FundQuote? {
        let resolvedCode = code?.nilIfBlank ?? quoteCode?.nilIfBlank ?? ""
        guard !resolvedCode.isEmpty else { return nil }

        let netValue = netValue.doubleValue
        let estimatedNetValue = estimatedNetValue.doubleValue
        let estimateTimeText = estimateTime.stringValue?.nilIfDash
        let netValueDateText = netValueDate.stringValue?.nilIfDash
            ?? fallbackNetValueDate.stringValue?.nilIfDash
        let hasRealtimeEstimate = estimatedNetValue > 0 || estimateTimeText != nil
        let officialDateHasCaughtUp = Self.officialDateHasCaughtUp(
            netValueDate: netValueDateText,
            estimateTime: estimateTimeText
        )
        let latestGrowthRateText = latestGrowthRate.stringValue?.nilIfDash
        let growthRate = officialDateHasCaughtUp
            ? (latestGrowthRateText != nil ? latestGrowthRateText.doubleValue : estimatedGrowthRate.doubleValue)
            : estimatedGrowthRate.doubleValue
        let resolvedNetValue = netValue > 0 ? netValue : estimatedNetValue
        guard resolvedNetValue > 0 else { return nil }

        return FundQuote(
            code: resolvedCode,
            name: name?.nilIfDash ?? resolvedCode,
            netValue: resolvedNetValue,
            estimatedNetValue: estimatedNetValue > 0 ? estimatedNetValue : resolvedNetValue,
            growthRate: growthRate,
            estimateTime: hasRealtimeEstimate ? (estimateTimeText ?? "") : "",
            netValueDate: netValueDateText ?? ""
        )
    }

    /// 判断官方净值日期是否已追上估值时间（决定使用哪类增长率）。
    private static func officialDateHasCaughtUp(netValueDate: String?, estimateTime: String?) -> Bool {
        guard let netValueDate else { return false }
        guard let estimateTime, estimateTime.count >= 10 else { return true }
        return netValueDate >= String(estimateTime.prefix(10))
    }

    private enum CodingKeys: String, CodingKey {
        case code = "FCODE"
        case quoteCode = "QDCODE"
        case name = "SHORTNAME"
        case netValue = "DWJZ"
        case netValueDate = "FSRQ"
        case fallbackNetValueDate = "JZRQ"
        case estimatedNetValue = "GSZ"
        case estimatedGrowthRate = "GSZZL"
        case estimateTime = "GZTIME"
        case latestGrowthRate = "RZDF"
    }
}

/// 天天基金估值接口（FundValuationLast）响应。
private struct FundValuationLastResponse: Decodable {
    var data: [FundValuationLastPayload]?
    var success: Bool?
}

/// 天天基金估值单条载荷（字段对应 FCODE/SHORTNAME/GSZ/GSZZL/GZTIME/NAV/PDATE）。
private struct FundValuationLastPayload: Decodable {
    var code: String?
    var name: String?
    var estimatedNetValue: LossyString?
    var estimatedGrowthRate: LossyString?
    var estimateTime: LossyString?
    var netValue: LossyString?
    var netValueDate: LossyString?

    private enum CodingKeys: String, CodingKey {
        case code = "FCODE"
        case name = "SHORTNAME"
        case estimatedNetValue = "GSZ"
        case estimatedGrowthRate = "GSZZL"
        case estimateTime = "GZTIME"
        case netValue = "NAV"
        case netValueDate = "PDATE"
    }
}

/// 基金持仓补充数据（重仓股 + 相关行业 + 披露日期）。
private struct FundPositionSupplement: Equatable {
    var topHoldings: [FundStockHolding]
    var relatedSectors: [FundSectorExposure]
    var holdingDisclosureDate: String?
}

/// 移动端持仓响应。
private struct MobileInvestmentPositionResponse: Decodable {
    var datas: MobileInvestmentPositionData?
    var success: Bool?
    var expansion: String?

    private enum CodingKeys: String, CodingKey {
        case datas = "Datas"
        case success = "Success"
        case expansion = "Expansion"
    }
}

/// 移动端持仓数据（重仓股列表）。
private struct MobileInvestmentPositionData: Decodable {
    var fundStocks: [MobileFundStockPayload]?
}

/// 移动端重仓股负载（字段对应 GPDM/GPJC/JZBL 等）。
private struct MobileFundStockPayload: Decodable {
    var code: String?
    var name: String?
    var weight: String?
    var industryCode: String?
    var industryName: String?
    var positionChangeType: String?
    var positionChangeRate: String?
    var market: String?

    private enum CodingKeys: String, CodingKey {
        case code = "GPDM"
        case name = "GPJC"
        case weight = "JZBL"
        case industryCode = "INDEXCODE"
        case industryName = "INDEXNAME"
        case positionChangeType = "PCTNVCHGTYPE"
        case positionChangeRate = "PCTNVCHG"
        case market = "NEWTEXCH"
    }
}

/// 移动端行业配置响应。
private struct MobileSectorAllocationResponse: Decodable {
    var datas: [MobileSectorAllocationPayload]?
    var success: Bool?
    var expansion: String?

    private enum CodingKeys: String, CodingKey {
        case datas = "Datas"
        case success = "Success"
        case expansion = "Expansion"
    }
}

/// 移动端行业配置单条（字段对应 HYMC/ZJZBL/FSRQ）。
private struct MobileSectorAllocationPayload: Decodable {
    var name: String?
    var weight: String?
    var date: String?

    private enum CodingKeys: String, CodingKey {
        case name = "HYMC"
        case weight = "ZJZBL"
        case date = "FSRQ"
    }
}

/// 移动端资产配置响应。
private struct MobileAssetAllocationResponse: Decodable {
    var datas: [MobileAssetAllocationPayload]?
    var success: Bool?
    var expansion: String?

    private enum CodingKeys: String, CodingKey {
        case datas = "Datas"
        case success = "Success"
        case expansion = "Expansion"
    }
}

/// 移动端资产配置单条（字段对应 GP/ZQ/HB/JJ/QT）。
private struct MobileAssetAllocationPayload: Decodable {
    var date: String?
    var stock: String?
    var bond: String?
    var cash: String?
    var fund: String?
    var other: String?

    private enum CodingKeys: String, CodingKey {
        case date = "FSRQ"
        case stock = "GP"
        case bond = "ZQ"
        case cash = "HB"
        case fund = "JJ"
        case other = "QT"
    }
}

/// 净值走势点（时间戳 + 净值 + 当日回报）。
private struct NetWorthTrendPayload: Decodable {
    var x: Double
    var y: Double
    var equityReturn: Double?
}

/// 基金搜索响应。
private struct FundSearchResponse: Decodable {
    var datas: [FundSearchItem]?

    private enum CodingKeys: String, CodingKey {
        case datas = "Datas"
    }
}

/// 基金搜索结果项（字段对应 CODE/NAME/SHORTNAME/CATEGORYDESC）。
private struct FundSearchItem: Decodable {
    var code: String?
    var name: String?
    var shortName: String?
    var categoryDescription: String?

    /// 是否为基金类别。
    var isFund: Bool {
        categoryDescription == "基金"
    }

    private enum CodingKeys: String, CodingKey {
        case code = "CODE"
        case name = "NAME"
        case shortName = "SHORTNAME"
        case categoryDescription = "CATEGORYDESC"
    }
}

/// 天天基金基金基本信息接口响应（Datas 为单条字典而非数组）。
private struct FundBasicInfoResponse: Decodable {
var datas: FundBasicInfoItem?

private enum CodingKeys: String, CodingKey {
    case datas = "Datas"
}
}

/// 天天基金基金基本信息单条（字段对应 FTYPE/SHORTNAME 等）。
private struct FundBasicInfoItem: Decodable {
var ftype: String?
var shortName: String?

private enum CodingKeys: String, CodingKey {
    case ftype = "FTYPE"
    case shortName = "SHORTNAME"
}
}

/// 宽松字符串解析（兼容 null/字符串/数字）。
private struct LossyString: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            value = ""
        }
    }
}

/// 可选字符串的 doubleValue 便捷属性。
private extension Optional where Wrapped == String {
    var doubleValue: Double {
        guard let self else { return 0 }
        let normalized = self
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized) ?? 0
    }
}

/// 可选 LossyString 的便捷访问属性。
private extension Optional where Wrapped == LossyString {
    var stringValue: String? {
        self?.value
    }

    var doubleValue: Double {
        stringValue.doubleValue
    }
}

/// 字符串便捷扩展（空串转 nil、破折号转 nil）。
private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfDash: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "--" ? nil : trimmed
    }
}
