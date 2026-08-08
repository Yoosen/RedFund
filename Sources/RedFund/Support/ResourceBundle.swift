import Foundation

extension Bundle {
    /// 资源 bundle 的统一入口，完全绕过 SwiftPM 自动生成的 `Bundle.module`。
    ///
    /// SwiftPM 生成的 `Bundle.module` 是 `static let`，初始化时只查
    /// `App根/RedFund_RedFund.bundle` 与编译期绝对路径，两者在非本机打包
    /// 环境下都不存在，会直接 `fatalError` 导致整个 App 启动即崩溃。
    /// 这里直接从标准 `Contents/Resources` 目录查找同名 bundle，避免触发
    /// `Bundle.module` 的初始化。
    static var redFundResources: Bundle {
        // 1. 标准打包位置（CI/发布产物）：Contents/Resources 下的资源 bundle
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("RedFund_RedFund.bundle"),
            let bundle = Bundle(url: url) {
            return bundle
        }
        // 回退到 SwiftPM 生成的 Bundle.module（本机测试/debug 环境下可用）
        // 注意：Bundle.module 在找不到资源时会 fatalError，因此仅在
        // Contents/Resources 查找失败后才访问，而发布产物必定存在于
        // Contents/Resources，不会走到这里。
        return .module
    }
}
