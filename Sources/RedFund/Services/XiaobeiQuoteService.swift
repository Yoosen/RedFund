import Foundation

/// 小倍养基估值数据源服务。
///
/// 仅负责「盘中估值」获取（官方净值仍由东方财富核心接口提供）。
/// 登录流程：先用手机号请求短信验证码，再用手机号+验证码登录换取 token。
/// 估值接口为批量查询（/yangji-api/api/get-optional-change-nav），一次拉全部持仓。
///
/// 接口与字段映射依据 github.com/Ye-Yu-Mo/FundVal-Live 的 xiaobeiyangji.py：
/// - 估值项字段：valuation=估值净值, valuationY=估值涨跌幅(小数，×100 为百分比),
///   nav=官方净值, navY=净值涨跌幅(小数)；接口不返回估值时间，本地取当前时间。
enum XiaobeiQuoteService {
    /// 小倍养基 API 基地址。
    static let baseURL = "https://api.xiaobeiyangji.com"
    /// 接口根路径前缀。
    static let apiPrefix = "/yangji-api/api"
    /// 客户端版本号（源码固定值）。
    static let version = "3.5.7.0"

    /// 通用 JSON POST 请求（带可选 Bearer 鉴权）。失败抛出错误交由调用方处理。
    private static func post<T: Decodable>(
        path: String,
        body: [String: Any],
        token: String? = nil,
        as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: baseURL + apiPrefix + path) else {
            throw NSError(domain: "XiaobeiQuoteService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效 URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        // 登录/发短信时后端要求显式带空 Bearer。
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await SharedURLSession.default.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "XiaobeiQuoteService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
        return try SharedJSONCoders.decoder.decode(T.self, from: data)
    }

    /// 顶层响应结构：code==200 为成功，data 为业务数据。
    private struct ApiResponse<T: Decodable>: Decodable {
        var code: Int?
        var msg: String?
        var data: T?
    }

    // MARK: - 登录流程

    /// 请求短信验证码。成功返回 true。
    static func sendSMSCode(phone: String) async throws -> Bool {
        struct Empty: Decodable {}
        let resp = try await post(
            path: "/send-sms",
            body: [
                "phoneNumber": phone,
                "isBind": false,
                "version": version,
                "clientType": "APP"
            ],
            as: ApiResponse<Empty>.self
        )
        guard resp.code == 200 else {
            throw NSError(
                domain: "XiaobeiQuoteService",
                code: resp.code ?? -1,
                userInfo: [NSLocalizedDescriptionKey: resp.msg ?? "发送验证码失败"]
            )
        }
        return true
    }

    /// 用手机号+验证码登录，返回登录会话（含 token / unionId）。失败抛出错误。
    static func login(phone: String, code: String) async throws -> XiaobeiSession {
        struct UserPayload: Decodable { var unionId: String? }
        struct DataPayload: Decodable { var accessToken: String?; var user: UserPayload? }
        let resp = try await post(
            path: "/login/phone",
            body: [
                "phone": phone,
                "code": code,
                "clientType": "PHONE",
                "version": version
            ],
            as: ApiResponse<DataPayload>.self
        )
        guard resp.code == 200,
              let token = resp.data?.accessToken, !token.isEmpty,
              let unionId = resp.data?.user?.unionId, !unionId.isEmpty
        else {
            throw NSError(
                domain: "XiaobeiQuoteService",
                code: resp.code ?? -1,
                userInfo: [NSLocalizedDescriptionKey: resp.msg ?? "登录失败：未返回 token"]
            )
        }
        return XiaobeiSession(phone: phone, token: token, unionId: unionId)
    }

    // MARK: - 估值获取

    /// 估值批量响应：data 为基金估值项数组。
    private struct NavItem: Decodable {
        var code: String?
        /// 估值净值（类似 GSZ）。
        var valuation: Double?
        /// 估值涨跌幅（小数，需 ×100）。
        var valuationY: Double?
        /// 官方净值（类似 DWJZ）。
        var nav: Double?
        /// 净值涨跌幅（小数）。
        var navY: Double?
    }

    /// 批量获取盘中估值，返回 code->估值载荷。未登录/失败返回空字典。
    static func fetchValuations(codes: [String]) async -> [String: FundValuationLastPayload] {
        let session = await MainActor.run { XiaobeiSessionStore.shared.session }
        guard let unionId = session?.unionId,
              let token = session?.token,
              !codes.isEmpty
        else { return [:] }

        let uniqueCodes = Array(Set(codes)).filter { !$0.isEmpty }
        guard !uniqueCodes.isEmpty else { return [:] }

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        struct NavList: Decodable { var data: [NavItem]? }
        let resp: ApiResponse<NavList>
        do {
            resp = try await post(
                path: "/get-optional-change-nav",
                body: [
                    "dataResources": "4",
                    "dataSourceSwitch": true,
                    "valuationDate": dateFormatter.string(from: today),
                    "navDate": dateFormatter.string(from: yesterday),
                    "isTD": true,
                    "codeArr": uniqueCodes,
                    "unionId": unionId,
                    "version": version,
                    "clientType": "APP"
                ],
                token: token,
                as: ApiResponse<NavList>.self
            )
        } catch {
            return [:]
        }
        guard resp.code == 200, let items = resp.data?.data else { return [:] }

        let estimateTime = DateFormatter.localizedString(
            from: today,
            dateStyle: .none,
            timeStyle: .short
        )
        var result: [String: FundValuationLastPayload] = [:]
        for item in items {
            guard let code = item.code, !code.isEmpty else { continue }
            // valuationY / navY 为小数，转百分比字符串（与东财 GSZZL 口径一致）。
            let estRate = item.valuationY.map { String(format: "%.2f", $0 * 100) }
            let payload = FundValuationLastPayload(
                code: code,
                name: nil,
                estimatedNetValue: item.valuation.map { LossyString(stringValue: String($0)) },
                estimatedGrowthRate: estRate.map { LossyString(stringValue: $0) },
                estimateTime: LossyString(stringValue: estimateTime),
                netValue: item.nav.map { LossyString(stringValue: String($0)) },
                netValueDate: nil
            )
            result[code] = payload
        }
        return result
    }
}
