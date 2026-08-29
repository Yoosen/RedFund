import Foundation

/// 应用级共享 URLSession。
///
/// 原先各处默认注入 `URLSession.shared`，其配置是 `.default`——cookie、证书、
/// 响应缓存都会持久化到磁盘（`~/Library/Cookies`、`~/Library/Caches`），
/// 盘中每 5 秒的行情刷新会带来持续的零散磁盘写入。
///
/// 改用 `.ephemeral` 后这些内容只存在于内存，进程退出即释放，不产生磁盘 IO。
/// 行情/估值/净值数据每次刷新都是新值，磁盘与内存缓存只有副作用（陈旧命中 +
/// 额外占用），故直接关闭 `urlCache`。
///
/// 超时与并发数沿用系统默认值，避免改动网络行为。
enum SharedURLSession {
    /// 用于行情、估值、净值、指数等所有数据接口。
    static let `default`: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
