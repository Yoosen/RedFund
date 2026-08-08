import Foundation
import Observation

enum JDFinanceDebugArtifacts {
    static let fileNames = [
        "jd-sync-preview-debug.json",
        "jd-network-probe.log"
    ]

    /// 删除持久化的调试产物（同步预览 JSON 与网络探测日志），用于排错后清理。
    static func removePersistedFiles(
        in directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "red-fund", directoryHint: .isDirectory)
    ) {
        for fileName in fileNames {
            try? FileManager.default.removeItem(at: directory.appending(path: fileName))
        }
    }
}

enum JDFinanceNetworkProbeSource: String, Equatable {
    case urlSession = "URLSession"
    case webView = "WebView"
}

struct JDFinanceNetworkProbeEntry: Identifiable, Equatable {
    let id = UUID()
    var source: JDFinanceNetworkProbeSource
    var method: String
    var path: String
    var statusCode: Int?
    var topLevelKeys: [String]
    var fieldSummaries: [String]
    var createdAt: Date

    var isVisibleInCapturePanel: Bool {
        !fieldSummaries.isEmpty || isTradeOrderEndpoint
    }

    var isTradeOrderEndpoint: Bool {
        let normalized = path.lowercased()
        return normalized.contains("querytradeorderlist")
            || normalized.contains("querytradeorderbybusinesscodemenu")
    }
}

struct JDFinanceNetworkProbeTarget: Equatable {
    var code: String
    var name: String
    var amount: Double?
}

@MainActor
@Observable
final class JDFinanceNetworkProbe: @unchecked Sendable {
    private(set) var entries: [JDFinanceNetworkProbeEntry] = []
    private var targets: [JDFinanceNetworkProbeTarget] = []
    private let persistsEntriesToDisk: Bool

    init(persistsEntriesToDisk: Bool = false) {
        self.persistsEntriesToDisk = persistsEntriesToDisk
    }

    /// 清空当前捕捉到的所有网络记录，用于重新开始捕捉或退出捕捉面板时复位。
    func clear() {
        entries = []
    }

    /// 设置本次探测的关注目标（基金代码 + 名称 + 金额），用于优先匹配交易订单行。
    func setTargets(_ targets: [JDFinanceNetworkProbeTarget]) {
        self.targets = targets
    }

    /// 记录一次 URLSession 网络响应：解析 JSON 摘要（脱敏）并写入捕捉面板，可持久化到磁盘日志。
    func recordURLSession(
        endpoint: String,
        url: URL,
        method: String = "GET",
        statusCode: Int?,
        data: Data,
        now: Date = .now
    ) {
        let summary = Self.summary(from: data, targets: targets)
        appendEntry(
            source: .urlSession,
            method: method,
            path: "\(Self.sanitizedPath(from: url)) · \(endpoint)",
            statusCode: statusCode,
            topLevelKeys: summary.topLevelKeys,
            fieldSummaries: summary.fieldSummaries,
            now: now
        )
    }

    /// 记录 WebView 注入脚本回报的请求/响应负载：解析请求体与响应体摘要并写入捕捉面板。
    func recordWebViewPayload(_ payload: Any, now: Date = .now) {
        guard let dictionary = payload as? [String: Any] else { return }
        let url = (dictionary["url"] as? String).flatMap(URL.init(string:))
        let method = (dictionary["method"] as? String)?.uppercased() ?? "GET"
        let statusCode = dictionary["status"] as? Int
        let bodyText = dictionary["body"] as? String
        let requestBodyText = dictionary["requestBody"] as? String
        let responseSummary = Self.summary(fromBodyText: bodyText, targets: targets)
        let requestSummaries = Self.requestSummaries(fromBodyText: requestBodyText)

        appendEntry(
            source: .webView,
            method: method,
            path: Self.sanitizedPath(from: url),
            statusCode: statusCode,
            topLevelKeys: responseSummary.topLevelKeys,
            fieldSummaries: Self.mergedSummaries(requestSummaries + responseSummary.fieldSummaries),
            now: now
        )
    }

    /// 把一条解析后的网络摘要追加到捕捉列表：仅保留可见条目，超出 24 条时丢弃最旧，并按需写磁盘日志。
    private func appendEntry(
        source: JDFinanceNetworkProbeSource,
        method: String,
        path: String,
        statusCode: Int?,
        topLevelKeys: [String],
        fieldSummaries: [String],
        now: Date
    ) {
        let candidate = JDFinanceNetworkProbeEntry(
            source: source,
            method: method,
            path: path,
            statusCode: statusCode,
            topLevelKeys: topLevelKeys,
            fieldSummaries: fieldSummaries,
            createdAt: now
        )
        guard candidate.isVisibleInCapturePanel else { return }

        entries.append(candidate)
        if entries.count > 24 {
            entries.removeFirst(entries.count - 24)
        }
        if persistsEntriesToDisk {
            Self.appendDebugLog(candidate)
        }
    }

    /// 从原始响应 Data 解析出顶层键与字段摘要。
    private static func summary(
        from data: Data,
        targets: [JDFinanceNetworkProbeTarget]
    ) -> (topLevelKeys: [String], fieldSummaries: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ([], [])
        }
        return summary(fromJSONObject: object, targets: targets)
    }

    /// 从响应体文本（截断至 250K）解析出顶层键与字段摘要。
    private static func summary(
        fromBodyText bodyText: String?,
        targets: [JDFinanceNetworkProbeTarget]
    ) -> (topLevelKeys: [String], fieldSummaries: [String]) {
        guard let bodyText,
              let data = bodyText.prefix(250_000).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return ([], [])
        }
        return summary(fromJSONObject: object, targets: targets)
    }

    /// 从已解析对象抽取摘要：优先交易订单行，否则账户资产字段，最后递归叶子值（脱敏后）。
    private static func summary(
        fromJSONObject object: Any,
        targets: [JDFinanceNetworkProbeTarget]
    ) -> (topLevelKeys: [String], fieldSummaries: [String]) {
        let topLevelKeys: [String]
        if let dictionary = object as? [String: Any] {
            let keys = dictionary.keys
                .filter { !isSensitivePath($0) }
                .sorted()
            topLevelKeys = Array(keys.prefix(8))
        } else {
            topLevelKeys = []
        }

        var summaries = tradeOrderSummaries(in: object, targets: targets)
        if !summaries.isEmpty {
            return (topLevelKeys, summaries)
        }

        var seen = Set<String>()
        for summary in summaries {
            seen.insert(summary)
        }

        for summary in accountAssetSummaries(in: object) where seen.insert(summary).inserted {
            summaries.append(summary)
            if summaries.count >= 12 { break }
        }

        for leaf in leafValues(in: object) {
            guard !isSensitivePath(leaf.path),
                  let summary = safeSummary(for: leaf)
            else { continue }

            if seen.insert(summary).inserted {
                summaries.append(summary)
            }
            if summaries.count >= 12 { break }
        }

        return (topLevelKeys, summaries)
    }

    /// 提取账户资产类字段摘要：总资产/持仓收益/今日收益/昨日收益/累计收益等（按路径优先级取值）。
    private static func accountAssetSummaries(in object: Any) -> [String] {
        let leaves = leafValues(in: object).filter { !isSensitivePath($0.path) }
        let targets: [(path: String, label: String)] = [
            ("headassetsdata.totalassets", "账户总金额"),
            ("headassetsdata.holdincome", "账户持仓收益"),
            ("headassetsdata.todayincome", "账户今日收益"),
            ("headassetsdata.yesterdayincome", "账户昨日收益"),
            ("headassetsdata.totalincome", "账户累计收益")
        ]

        return targets.compactMap { target in
            let candidates = leaves
                .filter { accountLeaf($0, matches: target.path) }
                .sorted(by: accountLeafPrecedes)
            guard let leaf = candidates.first else { return nil }

            if let amount = numericValue(leaf.value) {
                return "\(target.label): \(MoneyFormatter.plainMoney(amount))"
            }
            return "\(target.label): \(abbreviated(leaf.value))"
        }
    }

    /// 判断一个叶子值路径是否匹配目标账户资产路径（精确/前缀/后缀/包含）。
    private static func accountLeaf(_ leaf: Leaf, matches targetPath: String) -> Bool {
        let path = leaf.path.lowercased()
        return path == targetPath
            || path.hasPrefix("\(targetPath).")
            || path.hasSuffix(".\(targetPath)")
            || path.contains(".\(targetPath).")
    }

    /// 账户叶子排序：金额(amt)优先于文本(text)，文本优先于其他。
    private static func accountLeafPrecedes(_ lhs: Leaf, _ rhs: Leaf) -> Bool {
        accountLeafPriority(lhs.path) < accountLeafPriority(rhs.path)
    }

    /// 返回账户叶子路径的优先级数值（.amt=0、.text=1、其他=2）。
    private static func accountLeafPriority(_ path: String) -> Int {
        let path = path.lowercased()
        if path.hasSuffix(".amt") { return 0 }
        if path.hasSuffix(".text") { return 1 }
        return 2
    }

    /// 从请求体文本中提取关键请求字段摘要（业务代码/产品代码/基金代码/日期范围等）。
    private static func requestSummaries(fromBodyText bodyText: String?) -> [String] {
        guard let object = requestJSONObject(fromBodyText: bodyText) else {
            return []
        }

        let importantKeys: Set<String> = [
            "businesscode",
            "pageshowtype",
            "pageno",
            "pagetype",
            "title",
            "busproductid",
            "productid",
            "productcode",
            "fundcode",
            "ordercreatestartdate",
            "ordercreateenddate"
        ]
        var summaries: [String] = []
        var seen = Set<String>()

        for leaf in leafValues(in: object) {
            let normalizedKey = leaf.key.lowercased()
            guard importantKeys.contains(normalizedKey),
                  !isSensitivePath(leaf.path)
            else { continue }

            let value = leaf.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let summary: String
            if normalizedKey == "busproductid" || normalizedKey == "productid" {
                summary = "请求.\(shortFieldName(leaf.path)): \(abbreviated(value))"
            } else if normalizedKey == "productcode" || normalizedKey == "fundcode" {
                summary = "请求.\(shortFieldName(leaf.path)): \(fundCode(from: value) ?? abbreviated(value))"
            } else if let date = normalizedDate(from: value),
                      normalizedKey == "ordercreatestartdate" || normalizedKey == "ordercreateenddate"
            {
                summary = "请求.\(shortFieldName(leaf.path)): \(date)"
            } else {
                summary = "请求.\(shortFieldName(leaf.path)): \(abbreviated(value))"
            }

            if seen.insert(summary).inserted {
                summaries.append(summary)
            }
            if summaries.count >= 10 { break }
        }

        return summaries
    }

    /// 把请求体文本解析为对象：支持纯 JSON 或 query 字符串中的 reqData 字段。
    private static func requestJSONObject(fromBodyText bodyText: String?) -> Any? {
        guard let bodyText else { return nil }
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let object = jsonObject(from: trimmed) {
            return object
        }

        if let components = URLComponents(string: "?\(trimmed)"),
           let reqData = components.queryItems?.first(where: { $0.name == "reqData" })?.value
        {
            return jsonObject(from: reqData)
        }

        return nil
    }

    /// 对摘要去重并限长（最多 12 条），用于合并请求与响应摘要。
    private static func mergedSummaries(_ summaries: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for summary in summaries where seen.insert(summary).inserted {
            result.append(summary)
            if result.count >= 12 { break }
        }
        return result
    }

    /// 提取交易订单行摘要：命中目标（代码/名称）优先，逐行生成“交易记录…状态…类型”摘要并附带交易字段。
    private static func tradeOrderSummaries(
        in object: Any,
        targets: [JDFinanceNetworkProbeTarget]
    ) -> [String] {
        var rows = tradeOrderRows(in: object)
        if !targets.isEmpty {
            let matchedRows = rows.filter { row in
                targets.contains { target in
                    tradeOrderRow(row, matches: target)
                }
            }
            if !matchedRows.isEmpty {
                rows = matchedRows
            }
        }

        var summaries: [String] = []
        var seen = Set<String>()
        for row in rows.prefix(12) {
            guard let summary = tradeOrderSummary(row),
                  seen.insert(summary).inserted
            else { continue }
            summaries.append(summary)
            for leaf in leafValues(in: row) {
                guard !isSensitivePath(leaf.path),
                      let fieldSummary = safeSummary(for: leaf)
                else { continue }
                let detail = "交易字段.\(fieldSummary)"
                if seen.insert(detail).inserted {
                    summaries.append(detail)
                }
                if summaries.count >= 12 { break }
            }
            if summaries.count >= 12 { break }
        }
        return summaries
    }

    /// 递归在响应对象中查找交易订单行：识别 tradeOrderVoList 或单条订单字典，并展开嵌套数组/字符串。
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

    /// 启发式判断一个字典是否为交易订单行：含基金代码或名称，且至少带金额/时间/类型/状态之一。
    private static func isTradeOrderRow(_ dictionary: [String: Any]) -> Bool {
        let hasIdentity = explicitFundCode(in: dictionary) != nil
            || firstStringValue(
                in: dictionary,
                keys: ["productName", "sellProductName", "fundName", "productFullName", "productTitle", "skuName", "name"]
            ) != nil
        let hasAmount = firstNumericValue(in: dictionary, keys: tradeAmountKeys) != nil
        let hasTiming = firstTradeTiming(in: dictionary) != nil
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

    /// 判断一条交易订单行是否匹配探测目标（代码相等，或规范名称互相包含）。
    private static func tradeOrderRow(
        _ row: [String: Any],
        matches target: JDFinanceNetworkProbeTarget
    ) -> Bool {
        if let code = explicitFundCode(in: row), code == target.code {
            return true
        }

        guard let productName = firstStringValue(
            in: row,
            keys: ["productName", "sellProductName", "fundName", "productFullName", "productTitle", "skuName", "name"]
        ) else {
            return false
        }

        let rowName = canonicalName(productName)
        let targetName = canonicalName(target.name)
        return rowName.count >= 6
            && targetName.count >= 6
            && (rowName.contains(targetName) || targetName.contains(rowName))
    }

    /// 把一条交易订单行格式化为摘要文本：代码·名称·金额·时间·状态·类型。
    private static func tradeOrderSummary(_ row: [String: Any]) -> String? {
        let code = explicitFundCode(in: row)
        let productName = firstStringValue(
            in: row,
            keys: ["productName", "sellProductName", "fundName", "productFullName", "productTitle", "skuName", "name"]
        )
        let amount = firstNumericValue(
            in: row,
            keys: tradeAmountKeys
        )
        let timing = firstTradeTiming(in: row)
        let status = firstStringValue(
            in: row,
            keys: ["statusName", "statusDesc", "statusText", "statusCode", "orderStatus", "orderStatusName"]
        )
        let type = firstStringValue(
            in: row,
            keys: ["tradeTypeName", "tradeTypeCode", "tradeType", "tradeTypeDesc", "orderTypeName"]
        )

        guard code != nil || productName != nil || amount != nil || timing != nil else {
            return nil
        }

        var parts: [String] = ["交易记录"]
        if let code { parts.append(code) }
        if let productName { parts.append(abbreviated(productName)) }
        if let amount { parts.append(MoneyFormatter.plainMoney(amount)) }
        if let timing {
            if let timeType = timing.timeType {
                parts.append("\(timing.date) \(timeType.title)")
            } else {
                parts.append(timing.date)
            }
        }
        if let status { parts.append(abbreviated(status)) }
        if let type { parts.append(abbreviated(type)) }
        return parts.joined(separator: " · ")
    }

    private struct Leaf {
        var path: String
        var key: String
        var value: String
    }

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

    /// 递归遍历对象，把所有叶子值（字典键/数组下标路径 + 字符串值）收集为扁平列表。
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
        return [Leaf(path: path, key: path.components(separatedBy: ".").last ?? path, value: text)]
    }

    /// 根据叶子值的路径与内容类型生成脱敏摘要：基金代码/日期时间/金额/状态/产品名称等。
    private static func safeSummary(for leaf: Leaf) -> String? {
        let path = leaf.path.lowercased()
        let value = leaf.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let code = fundCode(from: value),
           path.contains("code") || path.contains("fund") || value.range(of: #"^\d{6}$"#, options: .regularExpression) != nil
        {
            return "\(shortFieldName(leaf.path)): \(code)"
        }

        if let date = normalizedDate(from: value),
           isTradeTimingPath(path) || value.contains("交易日") || value.contains("下单时间") || value.contains("申请时间")
        {
            if let timeType = explicitTimeType(from: value) ?? clockTimeType(from: value) {
                return "\(shortFieldName(leaf.path)): \(date) \(timeType.title)"
            }
            return "\(shortFieldName(leaf.path)): \(date)"
        }

        if let timestampDate = normalizedTimestampDate(from: value),
           isTradeTimingPath(path)
        {
            if let timeType = clockTimeType(from: timestampDate.rawText) {
                return "\(shortFieldName(leaf.path)): \(timestampDate.date) \(timeType.title)"
            }
            return "\(shortFieldName(leaf.path)): \(timestampDate.date)"
        }

        if let timeType = explicitTimeType(from: value) ?? clockTimeType(from: value),
           isTradeTimingPath(path) || value.contains("15:00")
        {
            return "\(shortFieldName(leaf.path)): \(timeType.title)"
        }

        if isProductNamePath(path) {
            return "\(shortFieldName(leaf.path)): \(abbreviated(value))"
        }

        if isAmountPath(path) || value.contains("元") || value.contains("合计") {
            if let amount = numericValue(value) {
                return "\(shortFieldName(leaf.path)): \(MoneyFormatter.plainMoney(amount))"
            }
        }

        if isStatusPath(path) || containsTradeStatus(value) {
            return "\(shortFieldName(leaf.path)): \(abbreviated(value))"
        }

        return nil
    }

    /// 从字典的多个常见代码键（fundCode/productCode/jjdm 等）中提取 6 位基金代码。
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
            if let code = fundCode(from: stringValue(dictionary[key]) ?? "") {
                return code
            }
        }

        return nil
    }

    /// 按候选键顺序从字典取第一个非空字符串值。
    private static func firstStringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    /// 按候选键顺序从字典取第一个数值（字符串或 NSNumber 均可）。
    private static func firstNumericValue(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let text = stringValue(dictionary[key]),
               let value = numericValue(text)
            {
                return value
            }
            if let number = dictionary[key] as? NSNumber {
                return number.doubleValue
            }
        }
        return nil
    }

    /// 从字典中找第一个交易时间叶子，并归一化为“日期 + 时段（15:00 前后）”。
    private static func firstTradeTiming(in dictionary: [String: Any]) -> (date: String, timeType: PositionTimeType?)? {
        let preferredLeaves = leafValues(in: dictionary).filter { leaf in
            isTradeTimingPath(leaf.path.lowercased())
        }

        for leaf in preferredLeaves {
            if let timing = normalizedDateAndTime(from: leaf.value) {
                return timing
            }
        }
        return nil
    }

    /// 把混合文本中的时间戳/日期归一化为“日期 + 时段”。
    private static func normalizedDateAndTime(from value: String) -> (date: String, timeType: PositionTimeType?)? {
        let normalizedText = normalizedTimestampDate(from: value)?.rawText ?? value
        guard let date = normalizedDate(from: normalizedText) else {
            return nil
        }
        return (date, explicitTimeType(from: normalizedText) ?? clockTimeType(from: normalizedText))
    }

    /// 规范化基金名称用于匹配：去空白、去“中证”、转小写。
    private static func canonicalName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "中证", with: "")
            .lowercased()
    }

    /// 把 URL 简化为“host + path”，用于面板展示接口路径。
    private static func sanitizedPath(from url: URL?) -> String {
        guard let url else { return "--" }
        let host = url.host() ?? ""
        return host.isEmpty ? url.path : "\(host)\(url.path)"
    }

    /// 取路径最后两段作为简短字段名（去掉数组下标），便于阅读。
    private static func shortFieldName(_ path: String) -> String {
        path
            .split(separator: ".")
            .suffix(2)
            .joined(separator: ".")
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
    }

    /// 把过长文本截断到 80 字符并加省略号。
    private static func abbreviated(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return "\(trimmed.prefix(80))..."
    }

    /// 判断路径是否包含敏感字段（cookie/token/订单号/账号标识等），用于脱敏过滤。
    private static func isSensitivePath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        let sensitiveTokens = [
            "cookie",
            "token",
            "orderid",
            "orderno",
            "order_id",
            "order_no",
            "extjson",
            "pt_key",
            "pt_pin",
            "pin",
            "wskey",
            "thor",
            "eid",
            "fp",
            "uuid",
            "encrypt",
            "sign"
        ]
        return sensitiveTokens.contains { normalized.contains($0) }
    }

    /// 判断路径是否表示金额字段（含 amount/amt/money/balance，排除收益/费率/份额）。
    private static func isAmountPath(_ path: String) -> Bool {
        (path.contains("amount") || path.contains("amt") || path.contains("money") || path.contains("balance"))
            && !path.contains("income")
            && !path.contains("profit")
            && !path.contains("rate")
            && !path.contains("share")
    }

    /// 判断路径是否表示基金/产品名称字段（productName/fundName 等）。
    private static func isProductNamePath(_ path: String) -> Bool {
        path.contains("productname")
            || path.contains("fundname")
            || path.contains("sellproductname")
            || path.contains("buyproductname")
    }

    /// 判断路径是否表示状态/类型字段（status/state/type/desc/tip 等）。
    private static func isStatusPath(_ path: String) -> Bool {
        path.contains("status") || path.contains("state") || path.contains("type") || path.contains("desc") || path.contains("tip")
    }

    /// 判断路径是否表示交易时间字段：含 trade/apply/create 等正向词，且不含 update/income 等负向词。
    private static func isTradeTimingPath(_ path: String) -> Bool {
        let positive = ["trade", "apply", "accept", "create", "deal", "entrust", "submit", "business", "biz", "time", "date"]
        let negative = ["update", "expect", "estimate", "income", "profit", "nav", "netvalue", "notice", "tip"]
        return positive.contains { path.contains($0) }
            && !negative.contains { path.contains($0) }
    }

    /// 判断文本是否包含交易状态语义（买入/卖出/申购/赎回/确认/处理中等）。
    private static func containsTradeStatus(_ value: String) -> Bool {
        value.contains("买入")
            || value.contains("卖出")
            || value.contains("申购")
            || value.contains("赎回")
            || value.contains("交易中")
            || value.contains("确认")
            || value.contains("处理中")
    }

    /// 从任意文本中过滤出纯数字部分；若恰好为 6 位则视为基金代码并返回，否则返回 nil。
    private static func fundCode(from value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }

    /// 从文本中识别日期并归一化为 `yyyy-MM-dd`；支持中文/斜杠/点分隔以及 8 位纯数字、月日+时分等格式，并校验为合法日期。
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

    /// 把 10 位（秒）或 13 位（毫秒）时间戳归一化为日期与完整时间文本，并校验时间范围合理性。
    private static func normalizedTimestampDate(from text: String) -> (date: String, rawText: String)? {
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
        let rawText = formatter.string(from: date)
        return (String(rawText.prefix(10)), rawText)
    }

    /// 从文本中识别明确的 15:00 前后语义（如“15:00前/三点后”），返回交易时段类型。
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

    /// 从文本中识别具体时刻（如 `14:30` 或“14点”），按小时判定为 15:00 前/后，返回交易时段类型。
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

    /// 从文本提取首个数值（支持正负号、千分位、百分号），去掉符号与单位后解析为 Double；无法解析或为空返回 nil。
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

    /// 把任意值规整为字符串：字符串去空白、NSNumber 转字符串、字典则回退取 text/subTitle/title/amt 字段；空值返回 nil。
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

    /// 把以 `{` 或 `[` 开头的文本解析为 JSON 对象/数组；非法或非 JSON 文本返回 nil。
    private static func jsonObject(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// 用正则匹配文本并返回捕获组（不含整串），无匹配或正则非法时返回 nil。
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

    /// 把一条网络记录追加写入磁盘调试日志：确保目录存在、按需滚动日志，并以“时间 来源 方法 路径 状态 字段”格式逐行写入。
    private static func appendDebugLog(_ entry: JDFinanceNetworkProbeEntry) {
        do {
            let url = debugLogURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateDebugLogIfNeeded(at: url)

            let status = entry.statusCode.map(String.init) ?? "--"
            let keys = entry.topLevelKeys.isEmpty ? "" : " keys=\(entry.topLevelKeys.joined(separator: ","))"
            let fields = entry.fieldSummaries.isEmpty ? "" : " | \(entry.fieldSummaries.joined(separator: " | "))"
            let line = "\(debugTimestamp(entry.createdAt)) \(entry.source.rawValue) \(entry.method) \(entry.path) \(status)\(keys)\(fields)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Debug capture should never affect syncing.
        }
    }

    /// 当调试日志超过 1MB 时删除旧日志，限制磁盘占用。
    private static func rotateDebugLogIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 1_000_000
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 返回调试日志文件在 Application Support 中的完整路径（red-fund/jd-network-probe.log）。
    private static func debugLogURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "red-fund", directoryHint: .isDirectory)
            .appending(path: "jd-network-probe.log")
    }

    /// 把日期格式化为 ISO8601（含毫秒）时间戳字符串，用于调试日志前缀。
    private static func debugTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
