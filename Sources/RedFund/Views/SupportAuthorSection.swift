import AppKit
import SwiftUI

struct SupportAuthorSection: View {
    @State private var selectedAsset: SupportAuthorAsset

    /// 初始化时设定默认选中的收款方式（微信或支付宝）。
    init(initialAsset: SupportAuthorAsset = .wechat) {
        _selectedAsset = State(initialValue: initialAsset)
    }

    /// 渲染“支持作者”区块：引导文案 + 支付方式选择器 + 收款码 + 说明文字。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SupportAuthorCopy.motivation)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PanelSegmentedPicker(
                values: SupportAuthorAsset.allCases,
                selection: $selectedAsset,
                title: \SupportAuthorAsset.title,
                tint: selectedAsset.tint,
                accessibilityLabelText: "支付方式",
                enableArrowNavigation: false
            )

            SupportQRCodeImage(asset: selectedAsset)
                .id(selectedAsset)
                .frame(maxWidth: .infinity, maxHeight: 320)
                .aspectRatio(1, contentMode: .fit)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.16), value: selectedAsset)

            Text(SupportAuthorCopy.paymentBoundary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// 内部视图：根据资源加载对应支付方式的收款码图片，加载失败则显示不可用占位。
private struct SupportQRCodeImage: View {
    let asset: SupportAuthorAsset

    /// 加载并展示选中支付方式的收款码图片，或“收款码不可用”提示。
    var body: some View {
        Group {
            if let url = SupportAuthorResources.url(for: asset),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                ContentUnavailableView(
                    "收款码不可用",
                    systemImage: "qrcode",
                    description: Text("请重新安装应用后再试。")
                )
            }
        }
        .accessibilityLabel("\(asset.title)收款码")
    }
}

private extension SupportAuthorAsset {
    /// 各支付方式的主题色（微信绿 / 支付宝蓝）。
    var tint: Color {
        switch self {
        case .wechat:
            Color(red: 0.02, green: 0.72, blue: 0.36)
        case .alipay:
            Color(red: 0.05, green: 0.46, blue: 0.96)
        }
    }

}

#if canImport(PreviewsMacros)
#Preview("支持作者 - 微信") {
    SupportAuthorSection()
        .frame(width: 312)
        .padding()
}

#Preview("支持作者 - 支付宝") {
    SupportAuthorSection(initialAsset: .alipay)
        .frame(width: 312)
        .padding()
}
#endif
