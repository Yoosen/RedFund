import Foundation

/// 支持作者相关的文案常量。
enum SupportAuthorCopy {
    /// 引导用户支持作者的说明文案。
    static let motivation =
        "Red Fund 免费、开源且无广告。您的支持，是我持续更新、修复问题和适配新版 macOS 的最大动力。感谢您的认可与鼓励。"

    /// 支付边界说明：自愿、不解锁功能、支付由第三方处理。
    static let paymentBoundary =
        "支持完全自愿，不会解锁额外功能。支付由微信或支付宝处理，Red Fund 不读取、上传或保存支付信息。"
}

/// 支持作者的支付方式（微信 / 支付宝）。
enum SupportAuthorAsset: String, CaseIterable, Identifiable {
    case wechat = "wechat-support"
    case alipay = "alipay-support"

    var id: String { rawValue }

    /// 支付方式的中文展示名。
    var title: String {
        switch self {
        case .wechat:
            "微信支付"
        case .alipay:
            "支付宝"
        }
    }
}

/// 支持作者收款二维码资源的加载工具。
enum SupportAuthorResources {
    /// 在 Bundle 的 Resources 或 Support 子目录中查找指定支付方式的收款二维码图片。
    static func url(
        for asset: SupportAuthorAsset,
        bundle: Bundle = .redFundResources
    ) -> URL? {
        bundle.url(forResource: asset.rawValue, withExtension: "png")
            ?? bundle.url(
                forResource: asset.rawValue,
                withExtension: "png",
                subdirectory: "Support"
            )
    }
}
