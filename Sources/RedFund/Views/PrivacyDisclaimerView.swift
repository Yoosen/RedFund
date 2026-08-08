import SwiftUI

struct PrivacyDisclaimerView: View {
    let onBack: () -> Void
    let onOpenURL: (URL) -> Void

    /// 渲染隐私与免责声明页面：头部标题栏 + 可滚动的声明正文 + 相关链接区。
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                systemImage: "hand.raised.fill",
                title: LegalContent.title,
                subtitle: LegalContent.updatedAtText,
                tint: Color(nsColor: .systemIndigo),
                onClose: onBack
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    introductionCard

                    ForEach(LegalContent.sections) { section in
                        LegalSectionView(section: section)
                    }

                    linksSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelDesign.panelBackground)
    }

    /// 顶部“本地优先”简介卡片：概括应用本地存储、不上传个人数据的原则。
    private var introductionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text("本地优先")
                    .font(.system(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelDesign.accent)
            }

            Text(LegalContent.introduction)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }

    /// 相关链接区：在线隐私政策与问题反馈入口。
    private var linksSection: some View {
        PanelSection(title: "相关链接") {
            VStack(spacing: 7) {
                PanelLinkButton(
                    title: "在线隐私政策",
                    subtitle: "查看仓库中的最新版本",
                    systemImage: "doc.text",
                    action: {
                        onOpenURL(AppExternalLinks.privacyPolicyURL)
                    }
                )
                PanelLinkButton(
                    title: "问题反馈",
                    subtitle: "选择 GitHub Issue 模板",
                    systemImage: "questionmark.circle",
                    action: {
                        onOpenURL(AppExternalLinks.issueChooserURL)
                    }
                )
            }
        }
    }
}

/// 单条法律/隐私章节的展示视图：渲染章节标题下的段落与要点。
private struct LegalSectionView: View {
    let section: LegalContent.Section

    /// 渲染章节标题下的段落列表与要点列表。
    var body: some View {
        PanelSection(title: section.title) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(PanelDesign.accent.opacity(0.72))
                            .frame(width: 4, height: 4)
                        Text(bullet)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

#if canImport(PreviewsMacros)
#Preview("隐私与免责声明") {
    PrivacyDisclaimerView(
        onBack: {},
        onOpenURL: { _ in }
    )
    .frame(
        width: PopoverLayout.privacyDisclaimerSize.width,
        height: PopoverLayout.privacyDisclaimerSize.height
    )
}
#endif
