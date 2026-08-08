import Foundation
import WebKit

/// 京东 Cookie 存储协议（用于抽象 HTTPCookieStorage）。
protocol JDFinanceCookieStorage: AnyObject {
    var cookies: [HTTPCookie]? { get }

    func deleteCookie(_ cookie: HTTPCookie)
}

extension HTTPCookieStorage: JDFinanceCookieStorage {}

/// 京东 Cookie 头过滤器：提取与校验可用于同步的认证 Cookie。
enum JDFinanceCookieHeaderFilter {
    /// 需要转发的 Cookie 名称集合。
    private static let forwardedNames: Set<String> = [
        "pt_key",
        "pt_pin",
        "pin",
        "pwdt_id",
        "thor",
        "wskey"
    ]
    /// 认证类 Cookie（缺失则无法同步）。
    private static let authenticationNames: Set<String> = [
        "pt_key",
        "thor",
        "wskey"
    ]
    /// 稳定身份类 Cookie（缺失则无法同步）。
    private static let stableIdentityNames: Set<String> = [
        "pt_pin",
        "pin",
        "pwdt_id"
    ]

    /// 从原始 Cookie 头中过滤出可转发的认证 Cookie 头。
    static func scopedHeader(from cookieHeader: String?) -> String? {
        guard let cookieHeader else { return nil }
        var seenNames = Set<String>()
        let pairs = cookieHeader.split(separator: ";").compactMap { segment -> String? in
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = name.lowercased()
            guard forwardedNames.contains(normalizedName),
                  !value.isEmpty,
                  seenNames.insert(normalizedName).inserted
            else {
                return nil
            }
            return "\(name)=\(value)"
        }
        let header = pairs.joined(separator: "; ")
        return hasAuthenticationCookie(header) ? header : nil
    }

    /// 从 Cookie 数组（jd.com 根域、未过期）中过滤出可转发 Cookie 头。
    static func scopedHeader(from cookies: [HTTPCookie], now: Date = .now) -> String? {
        let rootDomainCookies = cookies.filter { cookie in
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard domain == "jd.com" else { return false }
            guard cookie.path == "/" else { return false }
            if let expiresDate = cookie.expiresDate, expiresDate <= now { return false }
            return true
        }
        let rawHeader = rootDomainCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return scopedHeader(from: rawHeader)
    }

    /// 在 WebKit Cookie 与共享 Cookie 中取首个可同步的 Cookie 头。
    static func preferredScopedHeader(
        webKitCookies: [HTTPCookie],
        sharedCookies: [HTTPCookie],
        now: Date = .now
    ) -> String? {
        for cookies in [webKitCookies, sharedCookies] {
            guard let header = scopedHeader(from: cookies, now: now),
                  isSynchronizableHeader(header)
            else {
                continue
            }
            return header
        }
        return nil
    }

    /// 判断 Cookie 头是否含认证 Cookie。
    static func hasAuthenticationCookie(_ cookieHeader: String?) -> Bool {
        !cookieNamesWithValues(in: cookieHeader).isDisjoint(with: authenticationNames)
    }

    /// 判断 Cookie 头是否含稳定身份 Cookie。
    static func hasStableIdentityCookie(_ cookieHeader: String?) -> Bool {
        !cookieNamesWithValues(in: cookieHeader).isDisjoint(with: stableIdentityNames)
    }

    /// 判断 Cookie 头是否同时含认证与稳定身份 Cookie（可同步）。
    static func isSynchronizableHeader(_ cookieHeader: String?) -> Bool {
        hasAuthenticationCookie(cookieHeader) && hasStableIdentityCookie(cookieHeader)
    }

    /// 提取 Cookie 头中包含值的 Cookie 名称集合。
    private static func cookieNamesWithValues(in cookieHeader: String?) -> Set<String> {
        guard let cookieHeader else { return [] }
        let names = Set(cookieHeader.split(separator: ";").compactMap { segment -> String? in
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return names
    }
}

/// 京东金融 Web 登录会话管理（Cookie 缓存、登录判定、清理）。
@MainActor
enum JDFinanceWebSession {
    /// 内存中缓存的 Cookie 头。
    private static var cachedCookieHeader: String?
    /// 认证类 Cookie 名称集合。
    private static let authenticationCookieNames: Set<String> = [
        "pt_key",
        "thor",
        "wskey"
    ]

    /// 京东登录页地址。
    static let loginURL = URL(
        string: "https://plogin.m.jd.com/login/login?qqlogin=false&wxlogin=false&appid=2508&source=JDJR_PC&returnurl=https%3A%2F%2Fjdjr.jd.com%2F"
    )!
    /// 京东金融回跳地址。
    static let holdingsURL = URL(string: "https://jdjr.jd.com/")!
    /// 京东持仓页（PC）。
    static let holdingsPCURL = URL(string: "https://roma.jd.com/fund/hold/list/pc/")!
    /// 京东交易订单页。
    static let tradeOrderURL = URL(
        string: "https://roma.jd.com/wealth/tradeorder/list?pageShowType=1&businessCode=FUND&pageShowTitle=%E5%9F%BA%E9%87%91%E4%BA%A4%E6%98%93"
    )!

    /// 判断 URL 是否为京东金融登录回跳地址。
    static func isLoginReturnURL(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "jdjr.jd.com"
    }

    /// 判断登录导航是否完成（回跳地址且含可用 Cookie）。
    static func didCompleteLoginNavigation(url: URL?, cookieHeader: String?) -> Bool {
        guard isLoginReturnURL(url) else { return false }
        return hasUsableCookieHeader(cookieHeader)
    }

    /// 判断 Cookie 头是否含认证 Cookie（可用于同步）。
    static func hasUsableCookieHeader(_ cookieHeader: String?) -> Bool {
        let cookieNames = cookieNamesWithValues(in: cookieHeader)
        return !cookieNames.isDisjoint(with: authenticationCookieNames)
    }

    /// 从 WebKit/共享 Cookie 中解析出可同步的 Cookie 头并缓存。
    static func cookieHeader() async -> String? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let header = JDFinanceCookieHeaderFilter.preferredScopedHeader(
                    webKitCookies: cookies,
                    sharedCookies: HTTPCookieStorage.shared.cookies ?? []
                )
                let resolvedHeader = header ?? cachedCookieHeader
                if JDFinanceCookieHeaderFilter.isSynchronizableHeader(resolvedHeader) {
                    cachedCookieHeader = resolvedHeader
                    continuation.resume(returning: resolvedHeader)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 记录（缓存）可用的 Cookie 头。
    static func rememberCookieHeader(_ cookieHeader: String?) {
        guard let scopedHeader = JDFinanceCookieHeaderFilter.scopedHeader(from: cookieHeader),
              JDFinanceCookieHeaderFilter.isSynchronizableHeader(scopedHeader)
        else { return }
        cachedCookieHeader = scopedHeader
    }

    /// 清空会话：清除缓存、共享 Cookie 与 WebKit 站点数据。
    static func clearSession() async {
        cachedCookieHeader = nil
        clearJDCookies(in: HTTPCookieStorage.shared)
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                let jdRecords = records.filter { isJDRecordName($0.displayName) }
                guard !jdRecords.isEmpty else {
                    continuation.resume()
                    return
                }
                dataStore.removeData(ofTypes: dataTypes, for: jdRecords) {
                    continuation.resume()
                }
            }
        }
    }

    /// 清理指定 Cookie 存储中京东域名的 Cookie。
    static func clearJDCookies(in cookieStorage: any JDFinanceCookieStorage) {
        for cookie in cookieStorage.cookies ?? [] where isJDDomain(cookie.domain) {
            cookieStorage.deleteCookie(cookie)
        }
    }

    /// 提取 Cookie 头中包含值的 Cookie 名称集合（私有）。
    private static func cookieNamesWithValues(in cookieHeader: String?) -> Set<String> {
        guard let cookieHeader else { return [] }

        let pairs = cookieHeader.split(separator: ";").compactMap { segment -> (String, String)? in
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value)
        }

        return Set(pairs.map(\.0))
    }

    /// 判断站点数据记录名是否为京东相关。
    private static func isJDRecordName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("jd")
            || normalized.contains("360buy")
            || normalized.contains("jdpay")
    }

    /// 判断域名是否为京东域名（含子域）。
    static func isJDDomain(_ domain: String) -> Bool {
        let normalized = domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalized == "jd.com"
            || normalized.hasSuffix(".jd.com")
            || normalized == "360buy.com"
            || normalized.hasSuffix(".360buy.com")
            || normalized == "jdpay.com"
            || normalized.hasSuffix(".jdpay.com")
    }
}
