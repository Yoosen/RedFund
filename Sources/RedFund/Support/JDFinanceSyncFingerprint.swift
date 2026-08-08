import Foundation
import CryptoKit

/// 京东金融同步指纹工具：将交易/订单/持仓等实体归一化为稳定哈希键，用于去重与对账。
enum JDFinanceSyncFingerprint {
    /// 为本地交易草稿生成用于去重的指纹字符串。
    static func tradeDraft(_ draft: FundTradeDraft) -> String {
        return [
            "trade",
            draft.action.rawValue,
            normalizedCode(draft.code),
            draft.tradeDate,
            draft.tradeTimeType.rawValue,
            moneyPart(draft.amount),
            sharesPart(draft.shares)
        ].joined(separator: "|")
    }

    /// 为基金转换草稿生成去重指纹字符串。
    static func conversionDraft(_ draft: FundConversionDraft) -> String {
        [
            "conversion",
            normalizedCode(draft.fromCode),
            normalizedCode(draft.toCode),
            draft.tradeDate,
            draft.tradeTimeType.rawValue,
            sharesPart(draft.shares)
        ].joined(separator: "|")
    }

    /// 为京东金融订单记录生成稳定指纹；优先使用服务端稳定键，否则基于字段组合生成哈希。
    static func tradeOrderRecord(_ record: JDFinanceTradeOrderRecord, fallbackCode: String? = nil) -> String {
        if let stableOrderKey = record.stableOrderKey, !stableOrderKey.isEmpty {
            return stableOrderKey
        }
        let composite = [
            "order",
            record.action?.rawValue ?? "unknown",
            normalizedCode(record.code ?? fallbackCode ?? ""),
            normalizedName(record.productName ?? ""),
            normalizedCode(record.conversionTargetCode ?? ""),
            normalizedName(record.conversionTargetName ?? ""),
            record.tradeDate ?? "",
            record.tradeTimeType?.rawValue ?? "",
            record.submittedAt ?? "",
            moneyPart(record.amount),
            sharesPart(record.shares)
        ].joined(separator: "|")
        return "jd-flow-" + sha256(composite)
    }

    /// 从原始订单 ID 提取并生成稳定订单键，空值返回 nil。
    static func stableOrderKey(rawOrderID: String?) -> String? {
        guard let rawOrderID = rawOrderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOrderID.isEmpty
        else {
            return nil
        }
        return "jd-order-" + sha256(rawOrderID)
    }

    /// 将一组源订单键合并生成逻辑订单组键，用于聚合拆分订单。
    static func logicalTradeOrderGroup(sourceOrderKeys: [String]) -> String {
        let keys = Array(Set(sourceOrderKeys.filter { !$0.isEmpty })).sorted()
        return "jd-order-group-" + sha256(keys.joined(separator: "|"))
    }

    /// 从 Cookie 头中提取京东账号标识并生成账号键。
    static func accountKey(cookieHeader: String?) -> String? {
        guard let cookieHeader else { return nil }
        var valuesByName: [String: String] = [:]
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            let name = parts[0].lowercased()
            if valuesByName[name] == nil {
                valuesByName[name] = parts[1]
            }
        }
        for name in ["pt_pin", "pin", "pwdt_id"] {
            guard let value = valuesByName[name] else { continue }
            return "jd-account-" + sha256(value)
        }
        return nil
    }

    /// 生成持仓基线键，标记某代码在特定同步时刻的基线。
    static func positionBaseline(code: String, syncedAt: Date) -> String {
        let value = [
            "position-baseline",
            normalizedCode(code),
            ISO8601DateFormatter().string(from: syncedAt)
        ].joined(separator: "|")
        return "jd-position-" + sha256(value)
    }

    /// 去除首尾空白，归一化基金代码。
    private static func normalizedCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化产品名称（去空白、去转换/转入/转出前缀、转小写）。
    private static func normalizedName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "转换-", with: "")
            .replacingOccurrences(of: "转入-", with: "")
            .replacingOccurrences(of: "转出-", with: "")
            .lowercased()
    }

    /// 对字符串计算 SHA-256 十六进制摘要。
    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 将金额格式化为两位小数的字符串。
    private static func moneyPart(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.2f", (value * 100).rounded() / 100)
    }

    /// 将份额格式化为六位小数的字符串。
    private static func sharesPart(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", (value * 1_000_000).rounded() / 1_000_000)
    }
}
