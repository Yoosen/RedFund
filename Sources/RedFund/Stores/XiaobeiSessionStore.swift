import Foundation

/// 小倍养基登录会话（手机号 + 登录态）。
/// 登录后由 `XiaobeiSessionStore` 持久化到应用数据目录（red-fund/xiaobei_session.json）。
struct XiaobeiSession: Codable, Equatable {
    /// 登录手机号（脱敏仅保留后四位无必要，这里存完整号以便后续接口使用）。
    var phone: String
    /// 登录令牌（Bearer 鉴权用）。
    var token: String
    /// 用户唯一标识（小倍养基接口 userId 字段）。
    var unionId: String
    /// 登录时间（用于展示/排查）。
    var loginAt: Date

    init(phone: String, token: String, unionId: String, loginAt: Date = .now) {
        self.phone = phone
        self.token = token
        self.unionId = unionId
        self.loginAt = loginAt
    }
}

/// 小倍养基会话的持久化存储（明文存盘，同京东 cookie 范式）。
/// 标 @MainActor：登录态由设置 UI（MainActor）写入，行情刷新链（PortfolioStore 亦 MainActor）
/// 同步读取，所有访问均在主线程，避免跨 actor 共享可变状态。
@MainActor
final class XiaobeiSessionStore {
    /// 单例（与 AppSettingsStore 一致，主线程单例）。
    static let shared = XiaobeiSessionStore()

    /// 会话文件路径（red-fund/xiaobei_session.json）。
    private let fileURL: URL

    /// 内存中的当前会话（nil 表示未登录）。
    private(set) var session: XiaobeiSession?

    private init(dataDirectory: URL = AppDataPaths.sharedDataDirectory) {
        self.fileURL = dataDirectory.appending(path: "xiaobei_session.json")
        load()
    }

    /// 从磁盘加载会话；文件不存在或损坏则视为未登录。
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? SharedJSONCoders.decoder.decode(XiaobeiSession.self, from: data)
        else {
            session = nil
            return
        }
        session = decoded
    }

    /// 保存会话到磁盘（明文）。
    func save(_ session: XiaobeiSession) {
        self.session = session
        do {
            let data = try SharedJSONCoders.encoder.encode(session)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不影响本次运行的内存态，仅下次启动读不到。
        }
    }

    /// 清除会话（登出）。
    func clear() {
        session = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 便捷访问当前登录态。
    var isLoggedIn: Bool {
        session != nil
    }

    /// 当前可用令牌（Bearer）。
    var token: String? {
        session?.token
    }

    /// 当前用户标识（接口 userId）。
    var unionId: String? {
        session?.unionId
    }
}
