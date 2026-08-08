import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// 金额与百分比的格式化工具。
enum MoneyFormatter {
    /// 格式化为带 ¥ 符号的金额，可带正负号。
    static func money(_ value: Double, signed: Bool = false) -> String {
        let value = normalizedZero(value)
        let sign: String
        if signed {
            sign = value > 0 ? "+" : value < 0 ? "-" : ""
        } else {
            sign = value < 0 ? "-" : ""
        }
        return "\(sign)¥ \(abs(value).formatted(.number.precision(.fractionLength(2))))"
    }

    /// 格式化为带 ¥ 符号的纯金额（不强制符号）。
    static func plainMoney(_ value: Double) -> String {
        let value = normalizedZero(value)
        return "¥ \(value.formatted(.number.precision(.fractionLength(2))))"
    }

    /// 格式化为带百分号的涨跌幅，可带正号。
    static func percent(_ value: Double, signed: Bool = false) -> String {
        let sign = signed && value > 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(2))))%"
    }

    /// 将绝对值小于 0.005 的值按 0 处理，避免负零。
    private static func normalizedZero(_ value: Double) -> Double {
        abs(value) < 0.005 ? 0 : value
    }
}

/// 菜单栏状态文案格式化工具。
enum MenuBarStatusFormatter {
    /// 按展示模式生成菜单栏文本（金额 / 涨跌幅 / 两者 / 隐藏）。
    static func text(amount: Double, rate: Double, mode: MenuBarContentMode) -> String {
        switch mode {
        case .amount:
            signedAmount(amount)
        case .rate:
            MoneyFormatter.percent(rate, signed: true)
        case .both:
            "\(signedAmount(amount)) | \(MoneyFormatter.percent(rate, signed: true))"
        case .hidden:
            ""
        }
    }

    /// 生成带正负号、不带货币符号的净值文本。
    private static func signedAmount(_ value: Double) -> String {
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        return "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(2))))"
    }
}

/// 基金代码展示格式化工具。
enum FundCodeFormatter {
    /// 清理并展示基金代码（去空白、去 # 前缀，空则返回 --）。
    static func display(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "--" }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
}

/// 根据收益正负决定展示颜色（红涨绿跌）。
enum ValueTone {
    /// 返回收益对应的语义颜色。
    static func color(for value: Double) -> Color {
        if value > 0 { return .red }
        if value < 0 { return .green }
        return .secondary
    }
}

/// 菜单栏文字色调强度工具，依据涨跌幅绝对值分级。
enum StatusBarTone {
    /// 涨跌幅对应的色调强度等级。
    enum Intensity: Equatable {
        case neutral
        case subtle
        case normal
        case clear
        case strong
        case extreme
        case maximum
    }

    /// 根据涨跌幅绝对值映射到色调强度。
    static func intensity(forRate rate: Double) -> Intensity {
        let magnitude = abs(rate)
        if magnitude <= 0.10 { return .neutral }
        if magnitude < 1.00 { return .subtle }
        if magnitude < 2.00 { return .normal }
        if magnitude < 3.00 { return .clear }
        if magnitude < 4.00 { return .strong }
        if magnitude <= 5.00 { return .extreme }
        return .maximum
    }
}

extension Color {
    /// 应用主题绿色（SwiftUI 版本）。
    static let redFundGreen = Color(red: 75 / 255, green: 166 / 255, blue: 110 / 255)
}

#if canImport(AppKit)
extension NSColor {
    /// 应用主题绿色（AppKit 版本）。
    static let redFundGreen = NSColor(red: 75 / 255, green: 166 / 255, blue: 110 / 255, alpha: 1)
}

extension StatusBarTone {
    /// 根据涨跌幅返回菜单栏使用的 NSColor（区分涨跌两套调色板）。
    static func menuBarColor(forRate rate: Double) -> NSColor {
        let palette: [Intensity: (red: CGFloat, green: CGFloat, blue: CGFloat)] = rate > 0
            ? [
                .neutral: (142, 142, 147),
                .subtle: (255, 159, 154),
                .normal: (225, 130, 125),
                .clear: (196, 101, 98),
                .strong: (167, 72, 71),
                .extreme: (138, 43, 45),
                .maximum: (110, 7, 20)
            ]
            : [
                .neutral: (142, 142, 147),
                .subtle: (142, 221, 162),
                .normal: (114, 186, 135),
                .clear: (87, 152, 108),
                .strong: (60, 119, 83),
                .extreme: (35, 88, 59),
                .maximum: (7, 59, 36)
            ]
        let color = palette[intensity(forRate: rate)] ?? (142, 142, 147)
        return NSColor(red: color.red / 255, green: color.green / 255, blue: color.blue / 255, alpha: 1)
    }
}
#endif
