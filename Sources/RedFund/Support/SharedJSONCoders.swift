import Foundation

/// 共享的 JSON 编解码器。
///
/// 原先全项目有 22 处现场 `JSONDecoder()`/`JSONEncoder()`，盘中每 5 秒的行情刷新
/// 会对多只基金的响应逐个解码，重复实例化累积起来是可省的固定开销。
///
/// `JSONDecoder`/`JSONEncoder` 在 Swift 6 中已声明为 `Sendable`（`decode`/`encode`
/// 不修改编解码器自身状态，策略属性只在配置期写入），因此共享实例可安全跨任务使用。
///
/// **注意：只可共用不可再配置。** 若对某个共享实例改写 `dateDecodingStrategy`
/// 等属性，会污染全局其他调用点——需要不同策略请在此处新增一个预配置实例。
enum SharedJSONCoders {
    /// 默认解码策略（日期沿用 `Date` 的 `Decodable` 默认实现，即秒级时间戳）。
    /// 网络接口（东财/同花顺/小北）的响应适用。
    static let decoder = JSONDecoder()

    /// ISO-8601 日期策略：用于本地落盘文件（portfolio / performance）与 GitHub Release API。
    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 默认编码策略。
    static let encoder = JSONEncoder()

    /// 格式化输出（不改写日期策略）：用于设置等无 `Date` 字段的落盘文件。
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// ISO-8601 日期 + 格式化输出：用于导入导出的人类可读备份文件。
    static let iso8601PrettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
