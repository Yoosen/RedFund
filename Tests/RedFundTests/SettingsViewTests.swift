import Foundation
import XCTest
@testable import RedFund

final class SettingsViewTests: XCTestCase {
    func testSectionsHaveStableOrderAndTitles() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.display, .refreshAndReminders, .data, .support, .about]
        )
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["显示", "提醒", "数据", "支持", "关于"]
        )
    }

    func testSessionDefaultsToDisplayAndRetainsSelection() {
        var session = SettingsSectionSession()

        XCTAssertEqual(session.selectedSection, .display)

        session.select(.about)

        XCTAssertEqual(session.selectedSection, .about)
    }

    func testSupportHasItsOwnTopLevelSectionAndAboutSeparatesFeedbackFromContact() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/RedFund/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let supportStart = try XCTUnwrap(source.range(of: "private var supportSettingsContent"))
        let aboutStart = try XCTUnwrap(source.range(of: "private var aboutSettingsContent"))
        let supportSource = source[supportStart.lowerBound..<aboutStart.lowerBound]
        let aboutEnd = try XCTUnwrap(
            source.range(of: "private var operationReminderSettingsSection", range: aboutStart.upperBound..<source.endIndex)
        )
        let aboutSource = source[aboutStart.lowerBound..<aboutEnd.lowerBound]
        let feedback = try XCTUnwrap(aboutSource.range(of: "PanelSection(title: \"建议反馈\")"))
        let privacy = try XCTUnwrap(aboutSource.range(of: "PanelSection(title: \"关于与隐私\")"))

        XCTAssertLessThan(feedback.lowerBound, privacy.lowerBound)
        XCTAssertTrue(supportSource.contains("PanelSection(title: \"支持作者\")"))
        XCTAssertTrue(supportSource.contains("supportAuthorSection"))
        XCTAssertTrue(source.contains("SupportAuthorSection()"))
        XCTAssertFalse(aboutSource.contains("支持作者"))
        XCTAssertFalse(source.contains("onOpenSupportAuthor"))
        XCTAssertFalse(aboutSource.contains("联系作者"))
        XCTAssertFalse(aboutSource.contains("ContactAuthorResources"))

        let feedbackSectionStart = try XCTUnwrap(source.range(of: "private var feedbackSection"))
        let canClearStart = try XCTUnwrap(source.range(of: "private var canClearHoldings"))
        let feedbackSectionSource = source[feedbackSectionStart.lowerBound..<canClearStart.lowerBound]

        XCTAssertTrue(feedbackSectionSource.contains("报告问题"))
        XCTAssertTrue(feedbackSectionSource.contains("提出建议"))
        XCTAssertFalse(feedbackSectionSource.contains("邮件联系"))
        XCTAssertFalse(feedbackSectionSource.contains("联系作者"))
        XCTAssertFalse(source.contains("openFeedbackMail"))
        XCTAssertFalse(source.contains("feedbackMailURL"))
    }

    func testSupportAuthorIsNotAChildPanelRoute() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/RedFund/Controllers/ChildPanelRoute.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("case supportAuthor"))
    }

    // MARK: - 盘中走势数据源

    func testIntradayDataSourceDefaultsToEastmoney() {
        XCTAssertEqual(AppSettings.defaultIntradayDataSource, .eastmoney)
        XCTAssertEqual(AppSettings().intradayDataSource, .eastmoney)
    }

    /// 历史 settings.json 里没有 `intradayDataSource` 字段。
    /// 合成的 Decodable 对缺失的**非可选**字段会抛 keyNotFound，而
    /// `AppSettingsStore.load()` 捕获异常后会**把全部设置重置为默认值**——
    /// 即升级后用户设置被清空。故该字段必须走 decodeIfPresent 回退。
    func testDecodingLegacySettingsWithoutIntradayDataSourceKeepsOtherValues() throws {
        var settings = AppSettings()
        settings.mainPanelHeight = 720
        settings.dailyGrowthReminderEnabled = true
        settings.autoUpdateCheckEnabled = false

        // 以「当前编码结果」为基线再删掉新字段，模拟升级前落盘的老文件。
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: SharedJSONCoders.prettyEncoder.encode(settings))
                as? [String: Any]
        )
        var legacy = object
        legacy.removeValue(forKey: "intradayDataSource")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try SharedJSONCoders.decoder.decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.intradayDataSource, .eastmoney, "缺字段应回退到数据源1（东财）")
        // 关键：其余既有设置必须原样保留（一旦解码失败会被整体重置）。
        XCTAssertEqual(decoded.mainPanelHeight, 720)
        XCTAssertEqual(decoded.dailyGrowthReminderEnabled, true)
        XCTAssertEqual(decoded.autoUpdateCheckEnabled, false)
    }

    func testIntradayDataSourceRoundTrips() throws {
        var settings = AppSettings()
        settings.intradayDataSource = .sina

        let data = try SharedJSONCoders.prettyEncoder.encode(settings)
        let decoded = try SharedJSONCoders.decoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.intradayDataSource, .sina)
    }

    /// 新浪盘中走势数据源入口当前处于关闭状态：
    /// UI（详情页下拉 + 设置页分区）不再展示，且残留值一律回落到东财。
    /// 恢复该数据源时请把 `FeatureAvailability.sinaIntradayDataSource` 改回 true，
    /// 并同步更新本用例。
    func testSinaIntradayDataSourceIsCurrentlyHidden() {
        XCTAssertFalse(
            FeatureAvailability.sinaIntradayDataSource,
            "新浪入口当前应处于关闭状态"
        )
        XCTAssertEqual(
            FeatureAvailability.availableIntradayDataSources,
            [.eastmoney],
            "只剩一个可用数据源时，UI 不再展示数据源选择器"
        )
        XCTAssertEqual(
            FeatureAvailability.resolvedIntradayDataSource(.sina),
            .eastmoney,
            "已关闭的新浪必须回落到东财，否则 UI 隐藏了却仍在请求新浪"
        )
        XCTAssertEqual(
            FeatureAvailability.resolvedIntradayDataSource(.eastmoney),
            .eastmoney
        )
    }

    func testQuitActionLivesInGlobalFooterInsteadOfAboutSection() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/RedFund/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let bodyEnd = try XCTUnwrap(
            source.range(of: "private var header", range: bodyStart.upperBound..<source.endIndex)
        )
        let bodySource = source[bodyStart.lowerBound..<bodyEnd.lowerBound]
        XCTAssertTrue(bodySource.contains("settingsFooter"))

        let aboutStart = try XCTUnwrap(source.range(of: "private var aboutSettingsContent"))
        let aboutEnd = try XCTUnwrap(
            source.range(of: "private var operationReminderSettingsSection", range: aboutStart.upperBound..<source.endIndex)
        )
        let aboutSource = source[aboutStart.lowerBound..<aboutEnd.lowerBound]
        XCTAssertFalse(aboutSource.contains("退出 Red Fund"))

        let footerStart = try XCTUnwrap(source.range(of: "private var settingsFooter"))
        let footerEnd = try XCTUnwrap(source.range(of: "private var aboutSettingsContent"))
        let footerSource = source[footerStart.lowerBound..<footerEnd.lowerBound]
        XCTAssertTrue(footerSource.contains("退出 Red Fund"))
        XCTAssertFalse(footerSource.contains("PanelSection"))
        XCTAssertFalse(footerSource.contains("\"应用\""))
    }
}
