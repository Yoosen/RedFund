import Foundation

/// 京东金融持仓数据同步服务。
/// 负责拉取持仓快照（`fundHoldGroup`）、待确认交易明细（`getNewFundPositionDetail`）
/// 与交易流水（`queryTradeOrderList`），并将流水与持仓中的「待确认/交易提示」进行
/// 匹配、去重与合并，产出可用于本地对账的 `JDFinanceHoldingsSnapshot`。
struct JDFinanceHoldingsService: Sendable {
    /// 单次交易流水拉取的批次结果：记录集合 + 拉取状态（是否完整）。
    private struct TradeOrderFetchBatch {
        var records: [JDFinanceTradeOrderRecord]
        var state: JDFinanceTradeOrderFetchState
    }

    /// 单页交易流水拉取结果：记录集合 + 是否到达末页。
    private struct TradeOrderPageBatch {
        var records: [JDFinanceTradeOrderRecord]
        var reachedEnd: Bool
    }

    /// 持仓分组接口地址（京东金融网关，用于拉取持仓快照）。
    static let endpoint = URL(string: "https://ms.jr.jd.com/gw/generic/base/h5/m/fundHoldGroup")!
    /// 持仓待确认明细接口地址（用于补全交易中的份额/金额/时间）。
    static let detailEndpoint = URL(string: "https://ms.jr.jd.com/gw/generic/jj/newna/m/getNewFundPositionDetail")!
    /// 交易流水接口地址（新版网关，优先使用）。
    static let tradeOrderListEndpoint = URL(
        string: "https://ms.jr.jd.com/gw2/generic/cfGateway/newna/m/queryTradeOrderList"
    )!
    /// 交易流水接口地址（旧版 h5 网关，作为新版失败时的兜底）。
    static let legacyTradeOrderListEndpoint = URL(
        string: "https://ms.jr.jd.com/gw2/generic/cfGateway/h5/m/queryTradeOrderList"
    )!

    /// 底层网络会话。
    private let session: URLSession
    /// 可选的网络探测记录器，用于记录每次请求的端点/状态码/响应。
    private let networkProbe: JDFinanceNetworkProbe?

    /// 初始化：可注入自定义 `URLSession` 与网络探测器。
    init(session: URLSession = .shared, networkProbe: JDFinanceNetworkProbe? = nil) {
        self.session = session
        self.networkProbe = networkProbe
    }

    /// 拉取京东持仓快照。
    /// - Parameters:
    ///   - cookieHeader: 京东登录 Cookie；为空时只返回持仓基础信息。
    ///   - needsTradeOrderRecords: 是否需要把交易流水用于「对账候选」。
    ///   - tradeOrderStartDate: 交易流水查询的起始日期（默认近 90 天）。
    /// 返回解析后的持仓快照，并视情况补全待确认明细与交易流水。
    func fetchSnapshot(
        cookieHeader: String?,
        needsTradeOrderRecords: Bool = false,
        tradeOrderStartDate: String? = nil
    ) async throws -> JDFinanceHoldingsSnapshot {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "reqData", value: Self.requestPayload)
        ]
        guard let url = components?.url else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://jdjr.jd.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            await networkProbe?.recordURLSession(
                endpoint: "fundHoldGroup",
                url: url,
                statusCode: statusCode,
                data: data
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw JDFinanceHoldingsError.network("京东持仓接口请求失败")
            }
            var snapshot = try JDFinanceHoldingsParser.parse(data: data)
            if let cookieHeader, !cookieHeader.isEmpty {
                let tradeOrderBatch = await tradeOrderRecords(
                    for: snapshot.products,
                    cookieHeader: cookieHeader,
                    startDate: tradeOrderStartDate
                )
                snapshot.tradeOrders = tradeOrderBatch.records
                snapshot.tradeOrderFetchState = tradeOrderBatch.state
                snapshot.products = await productsByFillingPendingDetails(
                    for: snapshot.products,
                    cookieHeader: cookieHeader,
                    tradeOrderRecords: tradeOrderBatch.records,
                    includeReconciliationCandidates: needsTradeOrderRecords
                )
            }
            return snapshot
        } catch let error as JDFinanceHoldingsError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw JDFinanceHoldingsError.network(error.localizedDescription)
        }
    }

    /// 为持仓产品补全「待确认交易明细」。
    /// 优先用产品自带的 `detailRequest` 拉取明细；若产品存在交易提示，
    /// 则进一步用匹配到的交易流水合并出更完整的待确认信息。
    private func productsByFillingPendingDetails(
        for products: [JDFinanceHoldingProduct],
        cookieHeader: String,
        tradeOrderRecords: [JDFinanceTradeOrderRecord],
        includeReconciliationCandidates _: Bool
    ) async -> [JDFinanceHoldingProduct] {
        var enrichedProducts: [JDFinanceHoldingProduct] = []
        enrichedProducts.reserveCapacity(products.count)

        for var product in products {
            if let detailRequest = product.detailRequest,
               let detail = try? await fetchPendingDetail(detailRequest, cookieHeader: cookieHeader)
            {
                product.pendingDetail = detail
            }
            if product.transactionTip != nil,
               let matchedRecords = Self.matchingTradeOrderRecords(for: product, in: tradeOrderRecords)
            {
                product.pendingDetail = Self.mergedPendingDetail(
                    product.pendingDetail,
                    with: matchedRecords,
                    for: product
                )
            } else if product.transactionTip != nil,
                      let unmatchedStatus = Self.unmatchedTradeOrderStatus(
                for: product,
                in: tradeOrderRecords
            ) {
                let candidateRecords = Self.candidateTradeOrderRecords(for: product, in: tradeOrderRecords)
                product.pendingDetail = Self.pendingDetail(
                    product.pendingDetail,
                    product: product,
                    statusText: unmatchedStatus,
                    candidateTradeRecords: candidateRecords
                )
            }
            enrichedProducts.append(product)
        }

        return enrichedProducts
    }

    /// 拉取交易流水：先拉全局流水，再为存在交易提示的持仓产品补充拉取，
    /// 最后解析转换目标基金代码（按名称在线查询补全）。
    private func tradeOrderRecords(
        for products: [JDFinanceHoldingProduct],
        cookieHeader: String,
        startDate: String?
    ) async -> TradeOrderFetchBatch {
        guard !Task.isCancelled else {
            return TradeOrderFetchBatch(records: [], state: .incomplete(["同步已取消"]))
        }
        let pendingProducts = products.filter { $0.transactionTip != nil }
        var warnings: [String] = []
        var records: [JDFinanceTradeOrderRecord] = []

        do {
            let globalBatch = try await fetchTradeOrderRecords(
                cookieHeader: cookieHeader,
                startDate: startDate
            )
            Self.mergeTradeOrderRecords(globalBatch.records, into: &records)
            warnings.append(contentsOf: globalBatch.state.warnings)
        } catch {
            warnings.append("京东全局交易流水拉取失败：\(error.localizedDescription)")
        }

        guard !Task.isCancelled else {
            return TradeOrderFetchBatch(records: [], state: .incomplete(["同步已取消"]))
        }

        for product in pendingProducts {
            guard !Task.isCancelled else { break }
            do {
                let productBatch = try await fetchTradeOrderRecords(
                    for: product,
                    cookieHeader: cookieHeader,
                    startDate: startDate
                )
                Self.mergeTradeOrderRecords(productBatch.records, into: &records)
                warnings.append(contentsOf: productBatch.state.warnings)
            } catch {
                warnings.append("\(product.name)交易流水补充拉取失败：\(error.localizedDescription)")
            }
        }

        let resolvedRecords = await recordsByResolvingConversionTargets(
            records
        )
        return TradeOrderFetchBatch(
            records: resolvedRecords,
            state: warnings.isEmpty ? .complete : .incomplete(Array(Set(warnings)).sorted())
        )
    }

    /// 为「转换」类流水补全目标基金代码：当流水只有目标基金名称时，
    /// 通过行情服务按名称查询基金代码并回填（带缓存以避免重复请求）。
    private func recordsByResolvingConversionTargets(_ records: [JDFinanceTradeOrderRecord]) async -> [JDFinanceTradeOrderRecord] {
        let quoteService = FundQuoteService(session: session)
        var cache: [String: String?] = [:]
        var result: [JDFinanceTradeOrderRecord] = []
        result.reserveCapacity(records.count)

        for var record in records {
            guard !Task.isCancelled else { break }
            if record.action == .conversion,
               record.conversionTargetCode == nil,
               let targetName = record.conversionTargetName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !targetName.isEmpty
            {
                let code: String?
                if let cached = cache[targetName] {
                    code = cached
                } else {
                    code = await quoteService.lookupFundCode(name: targetName)
                    cache[targetName] = code
                }
                record.conversionTargetCode = code
            }
            result.append(record)
        }

        return result
    }

    /// 拉取单个产品的待确认交易明细（持仓详情接口）。
    private func fetchPendingDetail(
        _ detailRequest: JDFinanceHoldingDetailRequest,
        cookieHeader: String
    ) async throws -> JDFinancePendingTransactionDetail {
        let payloadObject: [String: Any] = [
            "extJson": detailRequest.extJSON,
            "version": 202
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        var components = URLComponents(url: Self.detailEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "reqData", value: payload)
        ]
        guard let url = components?.url else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://roma.jd.com/fund/hold/list/pc/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        await networkProbe?.recordURLSession(
            endpoint: "getNewFundPositionDetail",
            url: url,
            statusCode: statusCode,
            data: data
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw JDFinanceHoldingsError.network("京东持仓详情接口请求失败")
        }

        return try JDFinanceHoldingDetailParser.parse(data: data)
    }

    /// 拉取交易流水（按产品可选）。
    /// 依次尝试新版/旧版两个网关端点，任一成功即采用；
    /// 兼容「原生别名登录失败但旧版成功」的场景，避免误报告警。
    private func fetchTradeOrderRecords(
        for product: JDFinanceHoldingProduct? = nil,
        cookieHeader: String,
        startDate: String?,
        pageLimit: Int = 20
    ) async throws -> TradeOrderFetchBatch {
        var firstError: Error?
        var hasSuccessfulRequest = false
        var legacyEndpointSucceeded = false
        var allRecords: [JDFinanceTradeOrderRecord] = []
        var warnings: [String] = []
        var endpointFailures: [(endpoint: URL, error: Error)] = []
        for endpoint in [Self.tradeOrderListEndpoint, Self.legacyTradeOrderListEndpoint] {
            do {
                let batch = try await fetchTradeOrderRecords(
                    from: endpoint,
                    product: product,
                    cookieHeader: cookieHeader,
                    startDate: startDate,
                    pageLimit: pageLimit
                )
                hasSuccessfulRequest = true
                if endpoint == Self.legacyTradeOrderListEndpoint {
                    legacyEndpointSucceeded = true
                }
                if !batch.records.isEmpty {
                    Self.mergeTradeOrderRecords(batch.records, into: &allRecords)
                }
                if !batch.reachedEnd {
                    warnings.append("京东交易流水达到 \(pageLimit) 页上限，结果可能不完整")
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if firstError == nil {
                    firstError = error
                }
                endpointFailures.append((endpoint, error))
            }
        }

        for failure in endpointFailures {
            let isExpectedNativeAliasLoginFailure = failure.endpoint == Self.tradeOrderListEndpoint
                && legacyEndpointSucceeded
                && (failure.error as? JDFinanceHoldingsError) == .notLoggedIn
            if !isExpectedNativeAliasLoginFailure {
                warnings.append("京东交易流水接口部分失败：\(failure.error.localizedDescription)")
            }
        }

        if !allRecords.isEmpty {
            return TradeOrderFetchBatch(
                records: allRecords,
                state: warnings.isEmpty ? .complete : .incomplete(Array(Set(warnings)).sorted())
            )
        }

        if hasSuccessfulRequest {
            return TradeOrderFetchBatch(
                records: [],
                state: warnings.isEmpty ? .complete : .incomplete(Array(Set(warnings)).sorted())
            )
        }
        throw firstError ?? JDFinanceHoldingsError.network("京东交易记录接口请求失败")
    }

    /// 从指定端点分页拉取交易流水，直到某页为空或达到页上限。
    private func fetchTradeOrderRecords(
        from endpoint: URL,
        product: JDFinanceHoldingProduct?,
        cookieHeader: String,
        startDate: String?,
        pageLimit: Int
    ) async throws -> TradeOrderPageBatch {
        var records: [JDFinanceTradeOrderRecord] = []
        for page in 1...pageLimit {
            let pageRecords = try await fetchTradeOrderRecords(
                from: endpoint,
                page: page,
                product: product,
                cookieHeader: cookieHeader,
                startDate: startDate
            )
            if pageRecords.isEmpty {
                return TradeOrderPageBatch(records: records, reachedEnd: true)
            }
            Self.mergeTradeOrderRecords(pageRecords, into: &records)
        }
        return TradeOrderPageBatch(records: records, reachedEnd: false)
    }

    /// 拉取交易流水单页：POST 表单请求，解析响应为交易记录数组。
    private func fetchTradeOrderRecords(
        from endpoint: URL,
        page: Int,
        product: JDFinanceHoldingProduct?,
        cookieHeader: String,
        startDate: String?
    ) async throws -> [JDFinanceTradeOrderRecord] {
        let payload = try Self.tradeOrderRequestPayload(
            page: page,
            product: product,
            startDate: startDate
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Self.formEncodedBody(name: "reqData", value: payload)
        request.setValue(Self.tradeOrderReferer(for: product), forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        await networkProbe?.recordURLSession(
            endpoint: "queryTradeOrderList",
            url: endpoint,
            method: "POST",
            statusCode: statusCode,
            data: data
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw JDFinanceHoldingsError.network("京东交易记录接口请求失败")
        }

        return try JDFinanceTradeOrderParser.parse(data: data)
    }

    /// 按「稳定订单键」去重交易流水；无稳定键的记录直接保留。
    private static func deduplicatedTradeOrderRecords(_ records: [JDFinanceTradeOrderRecord]) -> [JDFinanceTradeOrderRecord] {
        var seenStableKeys = Set<String>()
        var result: [JDFinanceTradeOrderRecord] = []
        result.reserveCapacity(records.count)

        for record in records {
            guard let stableOrderKey = record.stableOrderKey, !stableOrderKey.isEmpty else {
                result.append(record)
                continue
            }
            if seenStableKeys.insert(stableOrderKey).inserted {
                result.append(record)
            }
        }

        return result
    }

    /// Merge overlapping API sources without collapsing two real legacy orders that
    /// happen to share the same visible fields. Stable order keys are unique. For
    /// records without an order ID, retain the largest occurrence count returned by
    /// any one source instead of summing copies from new/legacy or global/product APIs.
    /// 将新来源流水合并进已有记录：有稳定键的按键去重，
    /// 无稳定键的按多字段指纹去重，并对同款「无订单号」的流水取最大出现次数，
    /// 避免新旧/全局/产品接口重复计数。
    private static func mergeTradeOrderRecords(
        _ incomingRecords: [JDFinanceTradeOrderRecord],
        into records: inout [JDFinanceTradeOrderRecord]
    ) {
        let incoming = deduplicatedTradeOrderRecords(incomingRecords)
        var seenStableKeys = Set(records.compactMap(\.stableOrderKey))
        let existingCounts = Dictionary(
            grouping: records.filter { $0.stableOrderKey == nil },
            by: tradeOrderRecordDedupeKey
        ).mapValues(\.count)
        let incomingCounts = Dictionary(
            grouping: incoming.filter { $0.stableOrderKey == nil },
            by: tradeOrderRecordDedupeKey
        ).mapValues(\.count)
        var remainingCounts = incomingCounts.mapValues { count in count }
        for (key, existingCount) in existingCounts {
            remainingCounts[key] = max(0, (remainingCounts[key] ?? 0) - existingCount)
        }

        for record in incoming {
            if let stableOrderKey = record.stableOrderKey {
                if seenStableKeys.insert(stableOrderKey).inserted {
                    records.append(record)
                }
                continue
            }

            let key = tradeOrderRecordDedupeKey(record)
            guard let remaining = remainingCounts[key], remaining > 0 else {
                continue
            }
            records.append(record)
            remainingCounts[key] = remaining - 1
        }
    }

    /// 生成交易流水去重指纹：优先用稳定订单键，否则用多字段拼接。
    private static func tradeOrderRecordDedupeKey(_ record: JDFinanceTradeOrderRecord) -> String {
        if let stableOrderKey = record.stableOrderKey, !stableOrderKey.isEmpty {
            return stableOrderKey
        }
        let keyComponents: [String] = [
            record.code ?? "",
            record.productName ?? "",
            record.conversionTargetCode ?? "",
            record.conversionTargetName ?? "",
            record.action?.rawValue ?? "",
            record.amount.map { String(format: "%.2f", $0) } ?? "",
            record.shares.map { String(format: "%.4f", $0) } ?? "",
            record.tradeDate ?? "",
            record.tradeTimeType?.rawValue ?? "",
            record.submittedAt ?? "",
            record.effectiveStatus.rawValue,
            record.statusText ?? ""
        ]
        return keyComponents.joined(separator: "|")
    }

    /// 将单键值序列化为 `application/x-www-form-urlencoded` 的请求体。
    private static func formEncodedBody(name: String, value: String) -> Data? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: name, value: value)
        ]
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    /// 构造交易流水查询请求体（JSON 字符串）。
    /// 含分页、业务类型、查询时间范围；指定产品时附带产品/SKU/基金代码。
    static func tradeOrderRequestPayload(
        page: Int,
        now: Date = .now,
        product: JDFinanceHoldingProduct? = nil,
        startDate: String? = nil
    ) throws -> String {
        let dateRange = tradeOrderDateRange(now: now, startDate: startDate)
        var payloadObject: [String: Any] = [
            "businessCode": "FUND",
            "tradeTypeCodeList": [],
            "pageNo": page,
            "pageType": "na",
            "title": "基金交易",
            "clientType": "h5",
            "clientVersion": "999.999.999",
            "orderCreateStartDate": "\(dateRange.start) 00:00:00",
            "orderCreateEndDate": "\(dateRange.end) 23:59:59"
        ]

        if let product {
            payloadObject["busProductId"] = product.skuID
            payloadObject["productId"] = product.skuID
            if product.isCodeResolved {
                payloadObject["productCode"] = product.code
                payloadObject["fundCode"] = product.code
            }
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw JDFinanceHoldingsError.invalidResponse
        }
        return payload
    }

    /// 构造交易流水接口所需的 `Referer` 头（全局列表页或产品详情页）。
    private static func tradeOrderReferer(for product: JDFinanceHoldingProduct?) -> String {
        guard let product else {
            return "https://roma.jd.com/wealth/tradeorder/list?pageShowType=1&businessCode=FUND&pageShowTitle=%E5%9F%BA%E9%87%91%E4%BA%A4%E6%98%93"
        }

        var baseParam: [String: Any] = [
            "productId": product.skuID
        ]
        if product.isCodeResolved {
            baseParam["productCode"] = product.code
            baseParam["fundCode"] = product.code
        }
        let baseParamData = (try? JSONSerialization.data(withJSONObject: baseParam)) ?? Data()
        let baseParamText = String(data: baseParamData, encoding: .utf8) ?? "{}"

        var components = URLComponents(string: "https://roma.jd.com/wealth/tradeorder/list")
        components?.queryItems = [
            URLQueryItem(name: "pageShowType", value: "1"),
            URLQueryItem(name: "businessCode", value: "FUND"),
            URLQueryItem(name: "pageShowTitle", value: "基金交易"),
            URLQueryItem(name: "base_paramExtend", value: baseParamText)
        ]
        return components?.url?.absoluteString
            ?? "https://roma.jd.com/wealth/tradeorder/list?pageShowType=1&businessCode=FUND"
    }

    /// 计算交易流水查询的起止日期：优先用传入起始日期，否则回退到近 90 天。
    private static func tradeOrderDateRange(now: Date, startDate: String?) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let fallbackStartDate = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let resolvedStart = startDate.flatMap(DateOnlyFormatter.parse) ?? fallbackStartDate
        return (
            DateOnlyFormatter.string(from: min(resolvedStart, now)),
            DateOnlyFormatter.string(from: now)
        )
    }

    /// 为持仓产品的交易提示寻找匹配的交易流水。
    /// 按「金额+笔数」多种组合策略逐层尝试，返回能唯一确定的一批记录。
    private static func matchingTradeOrderRecords(
        for product: JDFinanceHoldingProduct,
        in records: [JDFinanceTradeOrderRecord]
    ) -> [JDFinanceTradeOrderRecord]? {
        let candidates = records.filter { record in
            record.tradeDate != nil
                && record.tradeTimeType != nil
                && matchesIdentity(record, product: product)
                && matchesAction(record, product: product)
                && matchesUsableStatus(record)
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           let expectedAmount = product.transactionTip?.totalAmount,
           let pendingRecords = matchingAmountSubset(
                in: candidates.filter { $0.effectiveStatus == .pending },
                expectedAmount: expectedAmount,
                expectedCount: expectedCount
           )
        {
            return pendingRecords
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           let expectedAmount = product.transactionTip?.totalAmount,
           let groupedRecords = matchingTradeOrderRecordGroup(
                in: candidates,
                expectedAmount: expectedAmount,
                expectedCount: expectedCount
           )
        {
            return groupedRecords
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           let expectedAmount = product.transactionTip?.totalAmount,
           let aggregateRecord = matchingAggregateTradeOrderRecord(
                in: candidates,
                expectedAmount: expectedAmount
           )
        {
            return [aggregateRecord]
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           let expectedAmount = product.transactionTip?.totalAmount,
           let ungroupedRecords = matchingUngroupedTradeOrderRecords(
                in: candidates,
                expectedAmount: expectedAmount,
                expectedCount: expectedCount
           )
        {
            return ungroupedRecords
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           product.transactionTip?.totalAmount == nil,
           let countedRecords = matchingTradeOrderRecordsByCount(
                in: candidates,
                expectedCount: expectedCount
           )
        {
            return countedRecords
        }

        let amountMatches = candidates.filter { matchesAmount($0, product: product) }
        if let matchedRecord = uniqueAmountMatchedTradeOrder(in: amountMatches) {
            return [matchedRecord]
        }

        return nil
    }

    /// 取与产品同基金同方向、作为「对账候选」的前若干条流水。
    private static func candidateTradeOrderRecords(
        for product: JDFinanceHoldingProduct,
        in records: [JDFinanceTradeOrderRecord]
    ) -> [JDFinanceTradeOrderRecord] {
        let candidates = records.filter { record in
            matchesIdentity(record, product: product)
                && matchesAction(record, product: product)
        }
        return Array(candidates.prefix(6))
    }

    /// 当交易提示无匹配流水时，生成一段可读的状态说明，描述已查到/未查到的原因。
    private static func unmatchedTradeOrderStatus(
        for product: JDFinanceHoldingProduct,
        in records: [JDFinanceTradeOrderRecord]
    ) -> String? {
        guard product.transactionTip != nil,
              product.pendingDetail?.tradeDate == nil || product.pendingDetail?.tradeTimeType == nil
        else {
            return nil
        }

        guard !records.isEmpty else {
            return "已查交易记录，接口未返回可解析的基金交易记录"
        }

        let sameFundRecords = records.filter { record in
            matchesIdentity(record, product: product)
                && matchesAction(record, product: product)
                && matchesUsableStatus(record)
        }
        guard !sameFundRecords.isEmpty else {
            return "已查交易记录，未找到同基金同方向的有效记录"
        }

        let timedRecords = sameFundRecords.filter { record in
            record.tradeDate != nil && record.tradeTimeType != nil
        }
        guard !timedRecords.isEmpty else {
            return "已查交易记录，找到同基金记录，但未返回交易时间"
        }

        if let expectedCount = product.transactionTip?.tradeCount,
           expectedCount > 1,
           let expectedAmount = product.transactionTip?.totalAmount
        {
            return "已查交易记录，找到 \(timedRecords.count) 笔同基金记录，但未匹配到 \(expectedCount) 笔同日同时段合计 \(MoneyFormatter.plainMoney(expectedAmount))"
        }

        if let expectedAmount = product.transactionTip?.totalAmount ?? product.pendingDetail?.amount {
            return "已查交易记录，找到同基金记录，但未匹配到金额 \(MoneyFormatter.plainMoney(expectedAmount))"
        }

        return "已查交易记录，未匹配到可用交易时间"
    }

    /// 判断流水与持仓产品是否同一基金：优先比对基金代码，否则按规范化名称（含包含关系）匹配。
    private static func matchesIdentity(_ record: JDFinanceTradeOrderRecord, product: JDFinanceHoldingProduct) -> Bool {
        if product.isCodeResolved, let code = record.code, code == product.code {
            return true
        }
        guard let productName = record.productName else {
            return false
        }
        let normalizedRecordName = normalizedFundName(productName)
        let normalizedProductName = normalizedFundName(product.name)
        let canonicalRecordName = canonicalFundName(productName)
        let canonicalProductName = canonicalFundName(product.name)

        if normalizedRecordName == normalizedProductName || canonicalRecordName == canonicalProductName {
            return true
        }

        return canonicalRecordName.count >= 6
            && canonicalProductName.count >= 6
            && (canonicalRecordName.contains(canonicalProductName) || canonicalProductName.contains(canonicalRecordName))
    }

    /// 判断流水交易方向与产品期望方向是否一致（未知方向视为兼容）。
    private static func matchesAction(_ record: JDFinanceTradeOrderRecord, product: JDFinanceHoldingProduct) -> Bool {
        let expectedAction = product.pendingDetail?.action ?? product.transactionTip?.action
        guard let expectedAction, expectedAction != .unknown else {
            return true
        }
        guard let recordAction = record.action, recordAction != .unknown else {
            return true
        }
        return recordAction == expectedAction
    }

    /// 判断流水金额与产品期望金额是否一致（误差 < 0.01）。
    private static func matchesAmount(_ record: JDFinanceTradeOrderRecord, product: JDFinanceHoldingProduct) -> Bool {
        let expectedAmount = product.transactionTip?.totalAmount ?? product.pendingDetail?.amount
        guard let expectedAmount else { return true }
        guard let amount = record.amount else { return false }
        return abs(amount - expectedAmount) < 0.01
    }

    /// 判断流水是否为可用状态（排除已取消/失败）。
    private static func matchesUsableStatus(_ record: JDFinanceTradeOrderRecord) -> Bool {
        record.effectiveStatus != .cancelled && record.effectiveStatus != .failed
    }

    /// 在按交易日+时段分组的流水中，寻找金额/笔数唯一匹配的一组。
    private static func matchingTradeOrderRecordGroup(
        in records: [JDFinanceTradeOrderRecord],
        expectedAmount: Double,
        expectedCount: Int
    ) -> [JDFinanceTradeOrderRecord]? {
        guard expectedCount > 1 else { return nil }
        let matches = recordsGroupedByTradeTiming(records).compactMap { group in
            matchingAmountSubset(
                in: group.records,
                expectedAmount: expectedAmount,
                expectedCount: expectedCount
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 在流水中寻找金额唯一匹配的单条聚合记录。
    private static func matchingAggregateTradeOrderRecord(
        in records: [JDFinanceTradeOrderRecord],
        expectedAmount: Double
    ) -> JDFinanceTradeOrderRecord? {
        let amountMatches = records.filter { record in
            guard let amount = record.amount else { return false }
            return abs(amount - expectedAmount) < 0.01
        }
        return uniqueAmountMatchedTradeOrder(in: amountMatches)
    }

    /// 从金额匹配的流水中挑出唯一一条；若存在「处理中」订单则优先它而非历史已完成订单。
    private static func uniqueAmountMatchedTradeOrder(
        in records: [JDFinanceTradeOrderRecord]
    ) -> JDFinanceTradeOrderRecord? {
        if records.count == 1 {
            return records.first
        }

        // A recent payment-success order is still waiting for fund confirmation.
        // Prefer that record over an older completed order with the same amount;
        // the latter is historical evidence, not the current pending trade.
        let pendingRecords = records.filter { $0.effectiveStatus == .pending }
        return pendingRecords.count == 1 ? pendingRecords.first : nil
    }

    /// 在未按时间分组的流水中，按金额/笔数寻找唯一匹配的若干条。
    private static func matchingUngroupedTradeOrderRecords(
        in records: [JDFinanceTradeOrderRecord],
        expectedAmount: Double,
        expectedCount: Int
    ) -> [JDFinanceTradeOrderRecord]? {
        matchingAmountSubset(
            in: records,
            expectedAmount: expectedAmount,
            expectedCount: expectedCount
        )
    }

    /// 仅按笔数匹配：寻找同时间分组恰好等于期望笔数、或整体等于期望笔数的一批记录。
    private static func matchingTradeOrderRecordsByCount(
        in records: [JDFinanceTradeOrderRecord],
        expectedCount: Int
    ) -> [JDFinanceTradeOrderRecord]? {
        guard expectedCount > 1 else { return nil }

        let groupedMatches = recordsGroupedByTradeTiming(records)
            .filter { $0.records.count == expectedCount }
            .map(\.records)
        if groupedMatches.count == 1 {
            return groupedMatches[0]
        }
        return groupedMatches.isEmpty && records.count == expectedCount ? records : nil
    }

    private struct TradeTimingGroup {
        var date: String
        var timeType: PositionTimeType
        var records: [JDFinanceTradeOrderRecord]
    }

    /// 将流水按「交易日 + 交易时段」分组，便于同组匹配。
    private static func recordsGroupedByTradeTiming(_ records: [JDFinanceTradeOrderRecord]) -> [TradeTimingGroup] {
        var groups: [TradeTimingGroup] = []

        for record in records {
            guard let date = record.tradeDate,
                  let timeType = record.tradeTimeType
            else {
                continue
            }

            if let index = groups.firstIndex(where: { $0.date == date && $0.timeType == timeType }) {
                groups[index].records.append(record)
            } else {
                groups.append(TradeTimingGroup(date: date, timeType: timeType, records: [record]))
            }
        }

        return groups
    }

    /// 在流水中寻找金额组合数唯一等于期望金额+笔数的一组（用于多笔合计匹配）。
    private static func matchingAmountSubset(
        in records: [JDFinanceTradeOrderRecord],
        expectedAmount: Double,
        expectedCount: Int
    ) -> [JDFinanceTradeOrderRecord]? {
        let candidates = records.filter { record in
            guard let amount = record.amount else { return false }
            return amount > 0 && amount <= expectedAmount + 0.01
        }
        guard candidates.count >= expectedCount else {
            return nil
        }

        var selected: [JDFinanceTradeOrderRecord] = []
        var matches: [[JDFinanceTradeOrderRecord]] = []
        collectAmountSubsets(
            in: candidates,
            startIndex: 0,
            expectedAmount: expectedAmount,
            expectedCount: expectedCount,
            selectedAmount: 0,
            selected: &selected,
            matches: &matches
        )
        return matches.count == 1 ? matches[0] : nil
    }

    /// 回溯枚举流水的金额组合，收集所有金额/笔数均符合期望的子集（最多保留 2 组用于判定唯一性）。
    private static func collectAmountSubsets(
        in records: [JDFinanceTradeOrderRecord],
        startIndex: Int,
        expectedAmount: Double,
        expectedCount: Int,
        selectedAmount: Double,
        selected: inout [JDFinanceTradeOrderRecord],
        matches: inout [[JDFinanceTradeOrderRecord]]
    ) {
        guard matches.count < 2 else { return }
        if selected.count == expectedCount {
            if abs(selectedAmount - expectedAmount) < 0.01 {
                matches.append(selected)
            }
            return
        }

        guard startIndex < records.count else { return }

        let remainingSlots = expectedCount - selected.count
        guard records.count - startIndex >= remainingSlots else { return }

        for index in startIndex..<records.count {
            guard let amount = records[index].amount else { continue }
            let nextAmount = selectedAmount + amount
            if nextAmount > expectedAmount + 0.01 { continue }

            selected.append(records[index])
            collectAmountSubsets(
                in: records,
                startIndex: index + 1,
                expectedAmount: expectedAmount,
                expectedCount: expectedCount,
                selectedAmount: nextAmount,
                selected: &selected,
                matches: &matches
            )
            selected.removeLast()
            if matches.count >= 2 { return }
        }
    }

    /// 将匹配到的多条交易流水合并进待确认明细：汇总金额/份额、统一交易日与时段、生成状态文案。
    private static func mergedPendingDetail(
        _ detail: JDFinancePendingTransactionDetail?,
        with records: [JDFinanceTradeOrderRecord],
        for product: JDFinanceHoldingProduct
    ) -> JDFinancePendingTransactionDetail {
        let firstKnownAction = records.compactMap(\.action).first { $0 != .unknown }
        let totalRecordAmount = summedAmount(records)
        let totalShares = summedShares(records)
        let commonDate = commonValue(records.compactMap(\.tradeDate))
        let commonTimeType = commonValue(records.compactMap(\.tradeTimeType))

        return JDFinancePendingTransactionDetail(
            action: detail?.action ?? product.transactionTip?.action ?? firstKnownAction,
            amount: detailAmount(detail, product: product, records: records, totalRecordAmount: totalRecordAmount),
            shares: detail?.shares ?? totalShares,
            tradeDate: detail?.tradeDate ?? commonDate,
            tradeTimeType: detail?.tradeTimeType ?? commonTimeType,
            statusText: records.count > 1 ? (aggregateStatusText(for: records) ?? detail?.statusText) : (detail?.statusText ?? aggregateStatusText(for: records)),
            matchedTradeRecords: records
        )
    }

    /// 在无法匹配流水时，基于产品交易提示与状态文案构造占位待确认明细（附带候选流水）。
    private static func pendingDetail(
        _ detail: JDFinancePendingTransactionDetail?,
        product: JDFinanceHoldingProduct,
        statusText: String,
        candidateTradeRecords: [JDFinanceTradeOrderRecord] = []
    ) -> JDFinancePendingTransactionDetail {
        let existingCandidates = detail?.candidateTradeRecords ?? []
        return JDFinancePendingTransactionDetail(
            action: detail?.action ?? product.transactionTip?.action,
            amount: detail?.amount ?? product.transactionTip?.totalAmount,
            shares: detail?.shares,
            tradeDate: detail?.tradeDate,
            tradeTimeType: detail?.tradeTimeType,
            statusText: statusText,
            matchedTradeRecords: detail?.matchedTradeRecords ?? [],
            candidateTradeRecords: existingCandidates.isEmpty ? candidateTradeRecords : existingCandidates
        )
    }

    /// 计算待确认明细金额：多笔流水取提示总额/汇总值，单笔取明细/流水/提示优先级。
    private static func detailAmount(
        _ detail: JDFinancePendingTransactionDetail?,
        product: JDFinanceHoldingProduct,
        records: [JDFinanceTradeOrderRecord],
        totalRecordAmount: Double?
    ) -> Double? {
        if records.count > 1 {
            return product.transactionTip?.totalAmount ?? totalRecordAmount ?? detail?.amount
        }
        return detail?.amount ?? records.first?.amount ?? product.transactionTip?.totalAmount
    }

    /// 汇总流水金额（任一缺失则返回 nil）。
    private static func summedAmount(_ records: [JDFinanceTradeOrderRecord]) -> Double? {
        let amounts = records.compactMap(\.amount)
        guard amounts.count == records.count else { return nil }
        return amounts.reduce(0, +)
    }

    /// 汇总流水份额（任一缺失则返回 nil）。
    private static func summedShares(_ records: [JDFinanceTradeOrderRecord]) -> Double? {
        let shares = records.compactMap(\.shares)
        guard !shares.isEmpty, shares.count == records.count else { return nil }
        return shares.reduce(0, +)
    }

    /// 若数组中所有值一致则返回该值，否则返回 nil。
    private static func commonValue<Value: Hashable>(_ values: [Value]) -> Value? {
        guard let first = values.first,
              values.allSatisfy({ $0 == first })
        else {
            return nil
        }
        return first
    }

    /// 为多笔匹配流水生成聚合状态文案（含笔数、交易日与时段）。
    private static func aggregateStatusText(for records: [JDFinanceTradeOrderRecord]) -> String? {
        guard records.count > 1 else {
            return records.first?.statusText
        }

        if let date = commonValue(records.compactMap(\.tradeDate)),
           let timeType = commonValue(records.compactMap(\.tradeTimeType))
        {
            return "匹配交易记录：\(records.count) 笔，\(date) \(timeType.title)"
        }

        return "匹配交易记录：\(records.count) 笔"
    }

    /// 规范化基金名称：去空格、转小写，便于模糊匹配。
    private static func normalizedFundName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    /// 规范化基金名称（去除「中证/转换/转入/转出」等前缀），用于较长名称的包含匹配。
    private static func canonicalFundName(_ value: String) -> String {
        normalizedFundName(value)
            .replacingOccurrences(of: "中证", with: "")
            .replacingOccurrences(of: "转换-", with: "")
            .replacingOccurrences(of: "转入-", with: "")
            .replacingOccurrences(of: "转出-", with: "")
    }

    /// 持仓分组接口的固定请求体（JSON 字符串）。
    private static let requestPayload = """
    {"clientVersion":"","clientType":"android","apiVersion":1,"appChannel":"fund_jjcc","sortKey":"1","sortDirection":"DESC","extParams":{"channelCode":"outside"}}
    """
}

/// 解析京东持仓快照接口（`fundHoldGroup`）的 JSON 响应，产出 `JDFinanceHoldingsSnapshot`。
enum JDFinanceHoldingsParser {
    /// 解析整个持仓快照：校验登录态、提取总资产/收益、遍历产品列表。
    static func parse(data: Data) throws -> JDFinanceHoldingsSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JDFinanceHoldingsError.invalidResponse
        }

        guard let envelope = object as? [String: Any] else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        try validateLoginState(in: envelope)

        let outerResultData = envelope["resultData"] as? [String: Any]
        if let outerResultData {
            try validateLoginState(in: outerResultData)
        }

        let payload = (outerResultData?["resultData"] as? [String: Any]) ?? outerResultData
        guard let payload else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        let headAssetsData = payload["headAssetsData"] as? [String: Any]
        let fundData = payload["fundData"] as? [String: Any]
        guard let fundData,
              let fundList = fundData["fundList"] as? [[String: Any]]
        else {
            throw JDFinanceHoldingsError.invalidResponse
        }
        let productRows = fundList.flatMap { row in
            row["productList"] as? [[String: Any]] ?? []
        }
        let products = productRows.compactMap(parseProduct)

        return JDFinanceHoldingsSnapshot(
            totalAssets: numericValue(headAssetsData?["totalAssets"]),
            yesterdayIncome: numericValue(headAssetsData?["yesterdayIncome"]),
            todayIncome: numericValue(headAssetsData?["todayIncome"]),
            holdIncome: numericValue(headAssetsData?["holdIncome"]),
            totalIncome: numericValue(headAssetsData?["totalIncome"]),
            products: products
        )
    }

    /// 检测响应中的登录失效标记（resultCode=3 或提示请先登录），抛出 `notLoggedIn`。
    private static func validateLoginState(in dictionary: [String: Any]) throws {
        let resultCode = stringValue(dictionary["resultCode"])
        let resultMessage = stringValue(dictionary["resultMsg"]) ?? ""
        if resultCode == "3" || resultMessage.contains("请先登录") || resultMessage.contains("登录京东") {
            throw JDFinanceHoldingsError.notLoggedIn
        }
    }

    /// 解析单个持仓产品：提取 SKU、名称、金额、收益、交易提示与详情请求。
    private static func parseProduct(_ dictionary: [String: Any]) -> JDFinanceHoldingProduct? {
        guard let skuID = stringValue(dictionary["skuId"] ?? dictionary["skuID"] ?? dictionary["sku"]),
              let name = stringValue(dictionary["productName"] ?? dictionary["name"]),
              let totalAmount = numericValue(dictionary["totalAmount"])
        else {
            return nil
        }
        let explicitCode = explicitFundCode(in: dictionary)

        return JDFinanceHoldingProduct(
            skuID: skuID,
            code: explicitCode ?? "",
            codeResolution: explicitCode == nil ? .unresolved : .explicit,
            name: name,
            totalAmount: totalAmount,
            yesterdayIncome: numericValue(dictionary["yesterdayIncome"]),
            yesterdayIncomeNotice: noticeTextValue(dictionary["yesterdayIncome"]),
            todayIncome: numericValue(dictionary["todayIncome"]),
            holdIncome: numericValue(dictionary["holdIncome"]),
            holdRate: numericValue(dictionary["holdRate"]),
            transactionTip: parseTransactionTip(dictionary["transactionTip"]),
            detailRequest: parseDetailRequest(in: dictionary),
            pendingDetail: nil
        )
    }

    /// 解析「交易提示」文本，提取交易方向、笔数、合计金额。
    private static func parseTransactionTip(_ value: Any?) -> JDFinanceTransactionTip? {
        guard let text = stringValue(value) else { return nil }
        return JDFinanceTransactionTip(
            text: text,
            action: pendingTradeAction(from: text),
            tradeCount: regexInt(pattern: #"(\d+)\s*笔"#, in: text),
            totalAmount: transactionTotalAmount(from: text)
        )
    }

    /// 从字典中提取持仓详情请求所需的 `extJson`。
    private static func parseDetailRequest(in dictionary: [String: Any]) -> JDFinanceHoldingDetailRequest? {
        guard let extJSON = nestedStringValue(forKey: "extJson", in: dictionary) else {
            return nil
        }
        return JDFinanceHoldingDetailRequest(extJSON: extJSON)
    }

    /// 在嵌套字典/数组中递归查找指定键（不区分大小写）对应的字符串值。
    private static func nestedStringValue(forKey targetKey: String, in value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, value) in dictionary where key.caseInsensitiveCompare(targetKey) == .orderedSame {
                if let text = stringValue(value) {
                    return text
                }
            }
            for value in dictionary.values {
                if let text = nestedStringValue(forKey: targetKey, in: value) {
                    return text
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let text = nestedStringValue(forKey: targetKey, in: item) {
                    return text
                }
            }
        }

        return nil
    }

    /// 从多个可能的字段名（含嵌套）中提取显式基金代码（6 位数字）。
    private static func explicitFundCode(in dictionary: [String: Any]) -> String? {
        let explicitCodeKeys = [
            "fundCode",
            "fundcode",
            "fund_code",
            "fundCd",
            "fundcd",
            "fundNo",
            "fundno",
            "productCode",
            "productcode",
            "jjdm"
        ]

        for key in explicitCodeKeys {
            if let code = normalizedFundCode(from: dictionary[key]) {
                return code
            }
        }

        // 按键名排序后递归，保证同一份数据每次提取结果一致（字典遍历顺序本身不稳定）。
        for key in dictionary.keys.sorted() {
            if let nested = dictionary[key] as? [String: Any],
               let code = explicitFundCode(in: nested)
            {
                return code
            }
        }

        return nil
    }

    /// 将任意值规范化为 6 位纯数字基金代码，否则返回 nil。
    private static func normalizedFundCode(from value: Any?) -> String? {
        guard let rawValue = stringValue(value) else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }

    /// 将 JSON 中的任意值（字符串/数字/嵌套字典）尽力转换为字符串。
    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as [String: Any]:
            return stringValue(value["text"])
                ?? stringValue(value["subTitle"])
                ?? stringValue(value["title"])
                ?? stringValue(value["amt"])
        default:
            return nil
        }
    }

    /// 当字段非数值时返回其文本（用于收益提示语等）。
    private static func noticeTextValue(_ value: Any?) -> String? {
        guard numericValue(value) == nil else { return nil }
        return stringValue(value)
    }

    /// 将 JSON 中的任意值（数字/字符串/嵌套字典）尽力转换为 `Double`。
    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            guard value.isFinite else { return nil }
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return parseNumber(value)
        case let value as [String: Any]:
            return numericValue(value["amt"])
                ?? numericValue(value["text"])
                ?? numericValue(value["subTitle"])
                ?? numericValue(value["title"])
        default:
            return nil
        }
    }

    /// 清洗字符串（去逗号/百分号/加号）后解析为 `Double`，空或 `--` 返回 nil。
    private static func parseNumber(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != "--",
              normalized != "-"
        else {
            return nil
        }
        return Double(normalized)
    }

    /// 从交易提示文本推断交易方向（转换/买入/卖出/未知）。
    private static func pendingTradeAction(from text: String) -> JDFinancePendingTradeAction {
        if text.contains("转换") || text.contains("转入") || text.contains("转出") {
            return .conversion
        }
        if text.contains("买入") || text.contains("申购") || text.contains("加仓") {
            return .buy
        }
        if text.contains("卖出") || text.contains("赎回") || text.contains("减仓") {
            return .sell
        }
        return .unknown
    }

    /// 从交易提示文本中正则提取「合计 X 元」或「X 元」形式的金额。
    private static func transactionTotalAmount(from text: String) -> Double? {
        if let value = regexString(pattern: #"合计\s*([+-]?[0-9][0-9,]*(?:\.[0-9]+)?)\s*元"#, in: text) {
            return parseNumber(value)
        }
        if let value = regexString(pattern: #"([+-]?[0-9][0-9,]*(?:\.[0-9]+)?)\s*元"#, in: text) {
            return parseNumber(value)
        }
        return nil
    }

    /// 正则提取第一个捕获组并转为 `Int`。
    private static func regexInt(pattern: String, in text: String) -> Int? {
        regexString(pattern: pattern, in: text).flatMap(Int.init)
    }

    /// 正则提取第一个捕获组的子串。
    private static func regexString(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[matchRange])
    }
}

/// 解析京东持仓「待确认交易明细」接口（`getNewFundPositionDetail`）的 JSON 响应。
/// 采用「叶子节点遍历」策略：把任意嵌套 JSON 拍平为 (路径, 文本) 列表，再按路径关键词与文本特征提取字段。
private enum JDFinanceHoldingDetailParser {
    /// 拍平后的叶子节点：记录字段路径与文本值。
    private struct Leaf {
        var path: String
        var value: String
    }

    /// 解析待确认交易明细：校验登录态后，从叶子节点提取方向/金额/份额/交易日/时段/状态。
    static func parse(data: Data) throws -> JDFinancePendingTransactionDetail {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JDFinanceHoldingsError.invalidResponse
        }

        guard let envelope = object as? [String: Any] else {
            throw JDFinanceHoldingsError.invalidResponse
        }
        try validateLoginState(in: envelope)

        let leaves = leafValues(in: envelope)
        guard !leaves.isEmpty else {
            throw JDFinanceHoldingsError.invalidResponse
        }

        return JDFinancePendingTransactionDetail(
            action: parseAction(from: leaves),
            amount: parseAmount(from: leaves),
            shares: parseShares(from: leaves),
            tradeDate: parseTradeDate(from: leaves),
            tradeTimeType: parseTradeTimeType(from: leaves),
            statusText: parseStatusText(from: leaves)
        )
    }

    /// 检测响应中的登录失效标记（resultCode=3 或提示请先登录），抛出 `notLoggedIn`。
    private static func validateLoginState(in dictionary: [String: Any]) throws {
        let resultCode = stringValue(dictionary["resultCode"])
        let resultMessage = stringValue(dictionary["resultMsg"]) ?? ""
        if resultCode == "3" || resultMessage.contains("请先登录") || resultMessage.contains("登录京东") {
            throw JDFinanceHoldingsError.notLoggedIn
        }
    }

    /// 从叶子节点中按路径关键词优先级推断交易方向（转换/买入/卖出）。
    private static func parseAction(from leaves: [Leaf]) -> JDFinancePendingTradeAction? {
        let preferredLeaves = leaves.sorted { lhs, rhs in
            score(lhs.path, keywords: ["action", "type", "trade", "order", "status", "state"]) >
                score(rhs.path, keywords: ["action", "type", "trade", "order", "status", "state"])
        }

        for leaf in preferredLeaves {
            if leaf.value.contains("转换") || leaf.value.contains("转入") || leaf.value.contains("转出") {
                return .conversion
            }
            if leaf.value.contains("买入") || leaf.value.contains("申购") || leaf.value.contains("加仓") {
                return .buy
            }
            if leaf.value.contains("卖出") || leaf.value.contains("赎回") || leaf.value.contains("减仓") {
                return .sell
            }
        }

        return nil
    }

    /// 从叶子节点提取交易金额：优先匹配金额相关路径，否则匹配含「金额/合计/元」的文本。
    private static func parseAmount(from leaves: [Leaf]) -> Double? {
        let preferred = leaves
            .filter { leaf in
                let path = leaf.path.lowercased()
                return (path.contains("amount") || path.contains("amt") || path.contains("money") || path.contains("balance"))
                    && !path.contains("share")
                    && !path.contains("income")
                    && !path.contains("profit")
                    && !path.contains("rate")
            }

        for leaf in preferred {
            if let value = numericValue(leaf.value), value > 0 {
                return value
            }
        }

        for leaf in leaves where leaf.value.contains("金额") || leaf.value.contains("合计") || leaf.value.contains("元") {
            if let value = numericValue(leaf.value), value > 0 {
                return value
            }
        }

        return nil
    }

    /// 从叶子节点提取交易份额（匹配 share/份额 相关路径或文本）。
    private static func parseShares(from leaves: [Leaf]) -> Double? {
        let preferred = leaves.filter { leaf in
            let path = leaf.path.lowercased()
            return path.contains("share") || path.contains("份额")
        }

        for leaf in preferred {
            if let value = numericValue(leaf.value), value > 0 {
                return value
            }
        }

        for leaf in leaves where leaf.value.contains("份") {
            if let value = numericValue(leaf.value), value > 0 {
                return value
            }
        }

        return nil
    }

    /// 从叶子节点提取交易日（排除「预计」类文案，按路径关键词排序挑选）。
    private static func parseTradeDate(from leaves: [Leaf]) -> String? {
        let preferred = leaves.filter(isTradeTimingCandidate).sorted { lhs, rhs in
            score(lhs.path, keywords: ["trade", "apply", "order", "date", "time"]) >
                score(rhs.path, keywords: ["trade", "apply", "order", "date", "time"])
        }

        for leaf in preferred {
            guard !leaf.value.contains("预计"),
                  let date = normalizedDate(from: leaf.value)
            else { continue }
            return date
        }

        return nil
    }

    /// 从叶子节点提取交易时段（15:00 前/后），按路径关键词排序挑选。
    private static func parseTradeTimeType(from leaves: [Leaf]) -> PositionTimeType? {
        let preferred = leaves.filter(isTradeTimingCandidate).sorted { lhs, rhs in
            score(lhs.path, keywords: ["trade", "apply", "order", "time", "date"]) >
                score(rhs.path, keywords: ["trade", "apply", "order", "time", "date"])
        }

        for leaf in preferred {
            if let timeType = explicitTimeType(from: leaf.value) ?? clockTimeType(from: leaf.value) {
                return timeType
            }
        }

        return nil
    }

    /// 判断某个叶子节点是否为「交易时间」相关字段（按路径/文本关键词过滤）。
    /// 判断某个叶子节点是否为「交易时间」相关字段（按路径/文本关键词过滤）。
    private static func isTradeTimingCandidate(_ leaf: Leaf) -> Bool {
        let path = leaf.path.lowercased()
        let positivePathTokens = ["trade", "apply", "order", "accept", "create", "deal", "entrust", "submit", "business"]
        let negativePathTokens = ["update", "expect", "estimate", "income", "profit", "nav", "netvalue", "notice", "tip"]
        let hasPositivePath = positivePathTokens.contains { path.contains($0) }
        let hasNegativePath = negativePathTokens.contains { path.contains($0) }
        let hasTradeTimingText = leaf.value.contains("交易日")
            || leaf.value.contains("下单时间")
            || leaf.value.contains("申请时间")
            || leaf.value.contains("受理时间")
            || leaf.value.contains("委托时间")
            || leaf.value.contains("成交时间")

        return (hasPositivePath || hasTradeTimingText) && !hasNegativePath && !leaf.value.contains("预计")
    }

    /// 从叶子节点提取交易状态文案（确认中/交易中/处理中等）。
    private static func parseStatusText(from leaves: [Leaf]) -> String? {
        let statusLeaves = leaves.filter { leaf in
            let path = leaf.path.lowercased()
            return path.contains("status") || path.contains("state") || path.contains("tip") || path.contains("desc")
        }
        let candidates = statusLeaves + leaves
        return candidates.first { leaf in
            leaf.value.contains("确认")
                || leaf.value.contains("交易中")
                || leaf.value.contains("处理中")
                || leaf.value.contains("买入中")
                || leaf.value.contains("卖出中")
        }?.value
    }

    /// 将任意嵌套 JSON 递归拍平为 (路径, 文本) 叶子节点列表，便于后续按路径提取。
    /// 将任意嵌套 JSON 递归拍平为 (路径, 文本) 叶子节点列表，便于后续按路径提取。
    private static func leafValues(in value: Any, path: String = "") -> [Leaf] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in
                leafValues(in: value, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }

        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, value in
                leafValues(in: value, path: "\(path)[\(index)]")
            }
        }

        guard let text = stringValue(value) else { return [] }
        return [Leaf(path: path, value: text)]
    }

    /// 从文本中按多种日期格式归一化为 `yyyy-MM-dd` 字符串。
    /// 从文本中按多种日期格式归一化为 `yyyy-MM-dd` 字符串。
    private static func normalizedDate(from text: String) -> String? {
        let patterns = [
            #"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#,
            #"(\d{4})\.(\d{1,2})\.(\d{1,2})"#,
            #"\b(\d{4})(\d{2})(\d{2})\b"#
        ]

        for pattern in patterns {
            guard let captures = regexCaptures(pattern: pattern, in: text),
                  captures.count == 3,
                  let year = Int(captures[0]),
                  let month = Int(captures[1]),
                  let day = Int(captures[2])
            else { continue }

            let normalized = String(format: "%04d-%02d-%02d", year, month, day)
            if DateOnlyFormatter.parse(normalized) != nil {
                return normalized
            }
        }

        if let captures = regexCaptures(pattern: #"(?:^|[^0-9])(\d{1,2})[-/.月](\d{1,2})(?:日)?(?:\s+[0-2]?\d[:：][0-5]\d)"#, in: text),
           captures.count == 2,
           let month = Int(captures[0]),
           let day = Int(captures[1])
        {
            let year = Calendar.current.component(.year, from: .now)
            let normalized = String(format: "%04d-%02d-%02d", year, month, day)
            if DateOnlyFormatter.parse(normalized) != nil {
                return normalized
            }
        }

        return nil
    }

    /// 从文本中按「15:00 前/后」等表述识别交易时段。
    private static func explicitTimeType(from text: String) -> PositionTimeType? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        if normalized.contains("15:00前")
            || normalized.contains("15点前")
            || normalized.contains("三点前")
            || normalized.contains("下午3点前")
        {
            return .before15
        }

        if normalized.contains("15:00后")
            || normalized.contains("15点后")
            || normalized.contains("三点后")
            || normalized.contains("下午3点后")
        {
            return .after15
        }

        return nil
    }

    /// 从文本中的时钟时间（如 14:30）推断交易时段（15:00 前/后）。
    private static func clockTimeType(from text: String) -> PositionTimeType? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        let hourText = regexCaptures(pattern: #"\b([01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?\b"#, in: normalized)?.first
            ?? regexCaptures(pattern: #"(^|[^0-9])([01]?\d|2[0-3])点(?:[0-5]\d分?)?"#, in: normalized)?.last
        guard let hourText,
              let hour = Int(hourText)
        else {
            return nil
        }
        return hour < 15 ? .before15 : .after15
    }

    /// 计算文本对给定关键词的命中数（用于字段路径优先级排序）。
    private static func score(_ value: String, keywords: [String]) -> Int {
        let lowercased = value.lowercased()
        return keywords.reduce(0) { total, keyword in
            total + (lowercased.contains(keyword) ? 1 : 0)
        }
    }

    /// 将 JSON 中的任意值（字符串/数字/嵌套字典）尽力转换为字符串。
    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as [String: Any]:
            return stringValue(value["text"])
                ?? stringValue(value["subTitle"])
                ?? stringValue(value["title"])
                ?? stringValue(value["amt"])
        default:
            return nil
        }
    }

    /// 将金额文本清洗后解析为 `Double`（用于持仓明细中的数值字段）。
    private static func numericValue(_ value: String) -> Double? {
        let match = regexCaptures(pattern: #"([+-]?[0-9][0-9,]*(?:\.[0-9]+)?)"#, in: value)?.first ?? value
        let normalized = match
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != "--",
              normalized != "-"
        else {
            return nil
        }
        return Double(normalized)
    }

    /// 正则提取所有捕获组（跳过第 0 组整体匹配），返回子串数组。
    private static func regexCaptures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }

        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            captures.append(String(text[range]))
        }
        return captures
    }
}

/// 解析京东交易流水接口（`queryTradeOrderList`）的 JSON 响应，产出 `JDFinanceTradeOrderRecord` 数组。
enum JDFinanceTradeOrderParser {
    /// 拍平后的叶子节点：字段路径与文本值。
    private struct Leaf {
        var path: String
        var value: String
    }

    /// 交易金额字段候选键名（用于从流水字典中提取金额）。
    private static let tradeAmountKeys = [
        "allAmount",
        "amount",
        "orderAmount",
        "tradeAmount",
        "payAmount",
        "actualAmount",
        "applyAmount",
        "applyAmt",
        "orderPayAmount",
        "transactionAmount",
        "businessAmount",
        "allAmountText",
        "amountText",
        "tradeAmountText"
    ]

    /// 解析交易流水响应：校验登录态后，遍历所有流水行并解析为记录数组。
    static func parse(data: Data) throws -> [JDFinanceTradeOrderRecord] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JDFinanceHoldingsError.invalidResponse
        }

        if let dictionary = object as? [String: Any] {
            try validateLoginState(in: dictionary)
        }

        return tradeOrderRows(in: object).compactMap(parseRecord)
    }

    /// 检测响应中的登录失效标记（resultCode=3 或提示请先登录），抛出 `notLoggedIn`。
    private static func validateLoginState(in dictionary: [String: Any]) throws {
        let resultCode = stringValue(dictionary["resultCode"])
        let resultMessage = stringValue(dictionary["resultMsg"]) ?? ""
        if resultCode == "3" || resultMessage.contains("请先登录") || resultMessage.contains("登录京东") {
            throw JDFinanceHoldingsError.notLoggedIn
        }
    }

    /// 在任意嵌套 JSON 中递归查找交易流水行（支持 `tradeOrderVoList`/对象/数组/字符串包装）。
    private static func tradeOrderRows(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            if let rows = dictionary["tradeOrderVoList"] as? [[String: Any]] {
                return rows
            }
            if isTradeOrderRow(dictionary) {
                return [dictionary]
            }
            return dictionary.values.flatMap(tradeOrderRows)
        }

        if let array = value as? [Any] {
            return array.flatMap(tradeOrderRows)
        }

        if let text = value as? String,
           let object = jsonObject(from: text)
        {
            return tradeOrderRows(in: object)
        }

        return []
    }

    /// 判断一个字典是否为交易流水行（具备基金身份且金额/时间/类型/状态之一）。
    private static func isTradeOrderRow(_ dictionary: [String: Any]) -> Bool {
        let hasIdentity = explicitFundCode(in: dictionary) != nil
            || firstStringValue(
                in: dictionary,
                keys: ["productName", "sellProductName", "fundName", "productFullName", "productTitle", "skuName", "name"]
            ) != nil
        let hasAmount = firstNumericValue(in: dictionary, keys: tradeAmountKeys) != nil
        let hasTiming = parseTradeTiming(in: dictionary) != nil
        let hasTradeType = firstStringValue(
            in: dictionary,
            keys: ["tradeTypeName", "tradeTypeCode", "tradeType", "tradeTypeDesc", "orderTypeName"]
        ) != nil
        let hasStatus = firstStringValue(
            in: dictionary,
            keys: ["statusName", "statusDesc", "statusText", "statusCode", "orderStatus", "orderStatusName"]
        ) != nil

        return hasIdentity && (hasAmount || hasTiming || hasTradeType || hasStatus)
    }

    /// 解析单条交易流水行：提取基金代码/名称/方向/金额/份额/时间/状态并构造记录。
    private static func parseRecord(_ dictionary: [String: Any]) -> JDFinanceTradeOrderRecord? {
        let timing = parseTradeTiming(in: dictionary)
        let submittedAt = parseSubmittedAt(in: dictionary)
        let productName = firstStringValue(
            in: dictionary,
            keys: ["productName", "sellProductName", "fundName", "productFullName", "productTitle", "skuName", "name"]
        )
        let conversionTargetName = firstStringValue(
            in: dictionary,
            keys: ["sellProductName", "targetProductName", "targetFundName", "toProductName", "toFundName"]
        )
        let conversionTargetCode = conversionTargetFundCode(in: dictionary)
        let statusCode = firstStringValue(
            in: dictionary,
            keys: ["statusCode", "orderStatus"]
        )
        let statusText = firstStringValue(
            in: dictionary,
            keys: ["statusName", "statusDesc", "statusText", "orderStatusName"]
        )

        guard productName != nil || explicitFundCode(in: dictionary) != nil else {
            return nil
        }

        let code = explicitFundCode(in: dictionary)
        let action = parseAction(in: dictionary)
        let amount = firstNumericValue(in: dictionary, keys: tradeAmountKeys)
        let shares = firstNumericValue(
            in: dictionary,
            keys: [
                "share", "shares", "tradeShare", "tradeShares", "confirmShare",
                "confirmedShare", "applyShare", "redeemShare", "shareAmount"
            ]
        )
        let rawOrderID = firstStringValue(
            in: dictionary,
            keys: [
                "orderId", "orderID", "order_id", "tradeOrderId", "tradeOrderID",
                "businessOrderId", "businessOrderID", "bizOrderId", "bizOrderID"
            ]
        )

        return JDFinanceTradeOrderRecord(
            stableOrderKey: JDFinanceSyncFingerprint.stableOrderKey(rawOrderID: rawOrderID),
            code: code,
            codeResolution: code == nil ? .unresolved : .explicit,
            productName: productName,
            conversionTargetCode: action == .conversion ? conversionTargetCode : nil,
            conversionTargetName: action == .conversion ? conversionTargetName : nil,
            action: action,
            amount: amount,
            shares: shares,
            tradeDate: timing?.date,
            tradeTimeType: timing?.timeType,
            submittedAt: submittedAt,
            status: JDFinanceTradeOrderStatus.classify(statusCode: statusCode, statusText: statusText),
            statusCode: statusCode,
            statusText: statusText
        )
    }

    /// 从流水字典的多个类型/状态字段中推断交易方向（转换/买入/卖出/未知）。
    private static func parseAction(in dictionary: [String: Any]) -> JDFinancePendingTradeAction? {
        let candidates = [
            stringValue(dictionary["tradeTypeName"]),
            stringValue(dictionary["tradeTypeCode"]),
            stringValue(dictionary["tradeType"]),
            stringValue(dictionary["tradeTypeDesc"]),
            stringValue(dictionary["orderTypeName"]),
            stringValue(dictionary["statusName"]),
            stringValue(dictionary["statusDesc"])
        ].compactMap { $0 }

        for candidate in candidates {
            let normalized = candidate.uppercased()
            if candidate.contains("转换")
                || normalized.contains("TRANSFORM")
                || normalized.contains("CONVERT")
                || normalized.contains("CONVERSION")
            {
                return .conversion
            }
            if candidate.contains("买入")
                || candidate.contains("申购")
                || candidate.contains("加仓")
                || normalized.contains("BUY")
                || normalized.contains("APPLY")
                || normalized.contains("PURCHASE")
                || normalized.contains("SUBSCRIBE")
                || normalized.contains("TRANSFER_IN")
            {
                return .buy
            }
            if candidate.contains("卖出")
                || candidate.contains("赎回")
                || candidate.contains("减仓")
                || normalized.contains("SELL")
                || normalized.contains("REDEEM")
                || normalized.contains("REDEMPTION")
                || normalized.contains("TRANSFER_OUT")
            {
                return .sell
            }
        }

        return .unknown
    }

    /// 从流水字典中提取交易日与交易时段：优先完整时间戳，否则回退日期或时段。
    private static func parseTradeTiming(in dictionary: [String: Any]) -> (date: String, timeType: PositionTimeType?)? {
        let preferredLeaves = leafValues(in: dictionary).filter(isTradeTimingCandidate).sorted { lhs, rhs in
            score(lhs.path, keywords: ["biztime", "trade", "apply", "order", "create", "time"]) >
                score(rhs.path, keywords: ["biztime", "trade", "apply", "order", "create", "time"])
        }

        var fallbackDate: String?
        var fallbackTimeType: PositionTimeType?
        for leaf in preferredLeaves {
            if let timing = normalizedDateAndTime(from: leaf.value) {
                if timing.timeType != nil {
                    return timing
                }
                fallbackDate = fallbackDate ?? timing.date
            }
            fallbackTimeType = fallbackTimeType ?? explicitTimeType(from: leaf.value) ?? clockTimeType(from: leaf.value)
            if let fallbackDate, let fallbackTimeType {
                return (fallbackDate, fallbackTimeType)
            }
        }

        if let fallbackDate {
            return (fallbackDate, fallbackTimeType)
        }
        return nil
    }

    /// 从流水字典中提取提交时间（下单/受理时间），归一化为标准时间戳文本。
    private static func parseSubmittedAt(in dictionary: [String: Any]) -> String? {
        let preferredLeaves = leafValues(in: dictionary).filter(isTradeTimingCandidate).sorted { lhs, rhs in
            score(lhs.path, keywords: ["biztime", "trade", "apply", "order", "create", "submit", "time"]) >
                score(rhs.path, keywords: ["biztime", "trade", "apply", "order", "create", "submit", "time"])
        }
        return preferredLeaves.lazy.compactMap { normalizedFullTimestamp(from: $0.value) }.first
    }

    /// 判断某个叶子节点是否为「交易时间」相关字段（按路径/文本关键词过滤）。
    private static func isTradeTimingCandidate(_ leaf: Leaf) -> Bool {
        let path = leaf.path.lowercased()
        let positivePathTokens = [
            "biztime",
            "tradetime",
            "tradedate",
            "applytime",
            "applydate",
            "ordertime",
            "ordercreatetime",
            "ordercreatedate",
            "createtime",
            "createdate",
            "accepttime",
            "acceptdate",
            "dealtime",
            "dealdate",
            "submittime",
            "submitdate",
            "businesstime",
            "businessdate",
            "currenttime",
            "paytime",
            "paydate",
            "requesttime",
            "requestdate",
            "time",
            "date"
        ]
        let negativePathTokens = ["update", "expect", "estimate", "income", "profit", "nav", "netvalue", "notice", "tip"]
        return positivePathTokens.contains { path.contains($0) }
            && !negativePathTokens.contains { path.contains($0) }
            && !leaf.value.contains("预计")
    }

    /// 从多个可能的字段名（含嵌套）中提取显式基金代码（6 位数字）。
    private static func explicitFundCode(in dictionary: [String: Any]) -> String? {
        let explicitCodeKeys = [
            "fundCode",
            "fundcode",
            "fund_code",
            "fundCd",
            "fundNo",
            "productCode",
            "productcode",
            "jjdm"
        ]
        for key in explicitCodeKeys {
            if let code = normalizedFundCode(from: dictionary[key]) {
                return code
            }
        }

        return nil
    }

    /// 从流水字典中提取「转换目标」基金代码（卖出/目标基金相关键名）。
    private static func conversionTargetFundCode(in dictionary: [String: Any]) -> String? {
        let explicitCodeKeys = [
            "sellFundCode",
            "sellProductCode",
            "targetFundCode",
            "targetProductCode",
            "toFundCode",
            "toProductCode"
        ]
        for key in explicitCodeKeys {
            if let code = normalizedFundCode(from: dictionary[key]) {
                return code
            }
        }
        return nil
    }

    /// 将任意值规范化为 6 位纯数字基金代码，否则返回 nil。
    private static func normalizedFundCode(from value: Any?) -> String? {
        guard let rawValue = stringValue(value) else { return nil }
        let digits = rawValue.filter(\.isNumber)
        guard digits.count == 6 else { return nil }
        return digits
    }

    /// 将任意嵌套 JSON 递归拍平为 (路径, 文本) 叶子节点列表，便于后续按路径提取。
    private static func leafValues(in value: Any, path: String = "") -> [Leaf] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in
                leafValues(in: value, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }

        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, value in
                leafValues(in: value, path: "\(path)[\(index)]")
            }
        }

        guard let text = stringValue(value) else { return [] }
        return [Leaf(path: path, value: text)]
    }

    /// 归一化时间戳/日期文本为 (日期, 时段) 组合：优先完整时间，否则仅日期。
    private static func normalizedDateAndTime(from value: String) -> (date: String, timeType: PositionTimeType?)? {
        let normalizedText: String
        if let timestampText = normalizedTimestampText(from: value) {
            normalizedText = timestampText
        } else {
            normalizedText = value
        }

        guard let date = normalizedDate(from: normalizedText) else {
            return nil
        }
        return (date, explicitTimeType(from: normalizedText) ?? clockTimeType(from: normalizedText))
    }

    /// 将 10/13 位 Unix 时间戳文本归一化为标准日期时间字符串。
    private static func normalizedTimestampText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{10}(\d{3})?$"#, options: .regularExpression) != nil,
              let rawValue = Double(trimmed)
        else {
            return nil
        }

        let seconds = trimmed.count == 13 ? rawValue / 1_000 : rawValue
        guard seconds > 946_684_800,
              seconds < 4_102_444_800
        else {
            return nil
        }

        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 从文本中解析完整日期时间（时间戳或「年月日 时分秒」形式）并归一化。
    private static func normalizedFullTimestamp(from text: String) -> String? {
        if let timestamp = normalizedTimestampText(from: text) {
            return timestamp
        }

        let patterns = [
            #"(\d{4})[-/年.](\d{1,2})[-/月.](\d{1,2})(?:日)?\s+([0-2]?\d)[:：]([0-5]\d)[:：]([0-5]\d)"#,
            #"(\d{4})[-/年.](\d{1,2})[-/月.](\d{1,2})(?:日)?\s+([0-2]?\d)[:：]([0-5]\d)"#
        ]
        for pattern in patterns {
            guard let captures = regexCaptures(pattern: pattern, in: text),
                  captures.count >= 5,
                  let year = Int(captures[0]),
                  let month = Int(captures[1]),
                  let day = Int(captures[2]),
                  let hour = Int(captures[3]),
                  let minute = Int(captures[4])
            else {
                continue
            }
            let second = captures.count > 5 ? (Int(captures[5]) ?? 0) : 0
            let dateText = String(format: "%04d-%02d-%02d", year, month, day)
            guard DateOnlyFormatter.parse(dateText) != nil,
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (0...59).contains(second)
            else {
                continue
            }
            return String(format: "%@ %02d:%02d:%02d", dateText, hour, minute, second)
        }
        return nil
    }

    /// 从文本中按多种日期格式归一化为 `yyyy-MM-dd` 字符串。
    private static func normalizedDate(from text: String) -> String? {
        let patterns = [
            #"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#,
            #"(\d{4})\.(\d{1,2})\.(\d{1,2})"#,
            #"\b(\d{4})(\d{2})(\d{2})\b"#
        ]

        for pattern in patterns {
            guard let captures = regexCaptures(pattern: pattern, in: text),
                  captures.count == 3,
                  let year = Int(captures[0]),
                  let month = Int(captures[1]),
                  let day = Int(captures[2])
            else { continue }

            let normalized = String(format: "%04d-%02d-%02d", year, month, day)
            if DateOnlyFormatter.parse(normalized) != nil {
                return normalized
            }
        }

        if let captures = regexCaptures(pattern: #"(?:^|[^0-9])(\d{1,2})[-/.月](\d{1,2})(?:日)?(?:\s+[0-2]?\d[:：][0-5]\d)"#, in: text),
           captures.count == 2,
           let month = Int(captures[0]),
           let day = Int(captures[1])
        {
            let year = Calendar.current.component(.year, from: .now)
            let normalized = String(format: "%04d-%02d-%02d", year, month, day)
            if DateOnlyFormatter.parse(normalized) != nil {
                return normalized
            }
        }

        return nil
    }

    /// 从文本中按「15:00 前/后」等表述识别交易时段。
    private static func explicitTimeType(from text: String) -> PositionTimeType? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        if normalized.contains("15:00前")
            || normalized.contains("15点前")
            || normalized.contains("三点前")
            || normalized.contains("下午3点前")
        {
            return .before15
        }

        if normalized.contains("15:00后")
            || normalized.contains("15点后")
            || normalized.contains("三点后")
            || normalized.contains("下午3点后")
        {
            return .after15
        }

        return nil
    }

    /// 从文本中的时钟时间（如 14:30）推断交易时段（15:00 前/后）。
    private static func clockTimeType(from text: String) -> PositionTimeType? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        let hourText = regexCaptures(pattern: #"\b([01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?\b"#, in: normalized)?.first
            ?? regexCaptures(pattern: #"(^|[^0-9])([01]?\d|2[0-3])点(?:[0-5]\d分?)?"#, in: normalized)?.last
        guard let hourText,
              let hour = Int(hourText)
        else {
            return nil
        }
        return hour < 15 ? .before15 : .after15
    }

    /// 计算文本对给定关键词的命中数（用于字段路径优先级排序）。
    private static func score(_ value: String, keywords: [String]) -> Int {
        let lowercased = value.lowercased()
        return keywords.reduce(0) { total, keyword in
            total + (lowercased.contains(keyword) ? 1 : 0)
        }
    }

    /// 将 JSON 中的任意值（字符串/数字/嵌套字典）尽力转换为字符串。
    /// 将 JSON 中的任意值（字符串/数字/嵌套字典）尽力转换为字符串。
    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as [String: Any]:
            return stringValue(value["text"])
                ?? stringValue(value["subTitle"])
                ?? stringValue(value["title"])
                ?? stringValue(value["amt"])
        default:
            return nil
        }
    }

    /// 按候选键名顺序从字典中提取第一个非空字符串值。
    private static func firstStringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    /// 按候选键名顺序从字典中提取第一个数值。
    private static func firstNumericValue(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = numericValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    /// 将 JSON 中的任意值（数字/字符串/嵌套字典）尽力转换为 `Double`。
    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            guard value.isFinite else { return nil }
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return parseNumber(value)
        case let value as [String: Any]:
            return numericValue(value["amt"])
                ?? numericValue(value["text"])
                ?? numericValue(value["subTitle"])
                ?? numericValue(value["title"])
        default:
            return nil
        }
    }

    /// 清洗字符串（去逗号/百分号/加号）后解析为 `Double`，空或 `--` 返回 nil。
    private static func parseNumber(_ value: String) -> Double? {
        let match = regexCaptures(pattern: #"([+-]?[0-9][0-9,]*(?:\.[0-9]+)?)"#, in: value)?.first ?? value
        let normalized = match
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != "--",
              normalized != "-"
        else {
            return nil
        }
        return Double(normalized)
    }

    /// 将可能是 JSON 字符串的文本解析为对象（用于接口返回的字符串包裹 JSON）。
    private static func jsonObject(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// 正则提取所有捕获组（跳过第 0 组整体匹配），返回子串数组。
    private static func regexCaptures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }

        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            captures.append(String(text[range]))
        }
        return captures
    }
}
