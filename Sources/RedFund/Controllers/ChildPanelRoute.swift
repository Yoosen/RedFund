// 引导流程的来源：首次启动 vs 从设置进入
enum OnboardingOrigin: Equatable {
    case firstLaunch
    case settings
}

// 隐私声明页的来源：来自设置，或来自引导流程（需记录具体引导来源以便返回）
enum PrivacyDisclaimerOrigin: Equatable {
    case settings
    case onboarding(OnboardingOrigin)
}

// 子面板的"路由"枚举：每个 case 对应一个可弹出的子面板；带关联值的是需要基金代码/记录 ID 的面板
enum ChildPanelRoute: Equatable {
    case settings
    case privacyDisclaimer(origin: PrivacyDisclaimerOrigin)
    case onboarding(origin: OnboardingOrigin)
    case sampleExperience(origin: OnboardingOrigin)
    case portfolioPerformance
    case jdFinancePerformanceSync
    case jdFinanceSync
    case portfolioBreakdown
    case todayIncomeRanking(IncomeRankingMetric)
    case addFund
    case onboardingAddFund(origin: OnboardingOrigin)
    case fundDetail(fundCode: String)
    case fundDailyIncome(fundCode: String)
    case tradeRecords(fundCode: String)
    case buyFund(fundCode: String)
    case sellFund(fundCode: String)
    case convertFund(fundCode: String)
    case editTradeRecord(fundCode: String, recordID: String)
    case editConversion(sourceFundCode: String, recordID: String, returnFundCode: String)
    case editPendingTradeRecord(fundCode: String, recordID: String)
    case editPendingConversion(fundCode: String, recordID: String)
    case editFund(fundCode: String)

    // 该路由对应的"选中基金代码"（用于主面板高亮/数据定位；无关联基金则为 nil）
    var selectedFundCode: String? {
        switch self {
        case .fundDetail(let fundCode),
             .fundDailyIncome(let fundCode),
             .tradeRecords(let fundCode),
             .buyFund(let fundCode),
             .sellFund(let fundCode),
             .convertFund(let fundCode),
             .editTradeRecord(let fundCode, _),
             .editPendingTradeRecord(let fundCode, _),
             .editPendingConversion(let fundCode, _),
             .editFund(let fundCode):
            fundCode
        case .editConversion(let sourceFundCode, _, _):
            sourceFundCode
        case .settings, .privacyDisclaimer, .onboarding, .sampleExperience,
             .portfolioPerformance, .jdFinancePerformanceSync, .jdFinanceSync, .portfolioBreakdown,
             .todayIncomeRanking, .addFund, .onboardingAddFund:
            nil
        }
    }

    // 该路由是否"拥有"京东金融登录面板（这类面板在切换/收起时需一并处理京东面板）
    var ownsJDFinanceLoginPanel: Bool {
        switch self {
        case .jdFinanceSync, .jdFinancePerformanceSync:
            true
        default:
            false
        }
    }
}

// 路由校验结果：可用 / 重定向到某个兜底路由 / 直接关闭
enum ChildPanelRouteDisposition: Equatable {
    case available
    case redirect(ChildPanelRoute)
    case close
}

// 子面板路由的"解析器"：根据当前持仓快照判断某路由所依赖的数据是否还在，以及提取对应基金/记录
enum ChildPanelRouteResolver {
    // 取路由对应的基金
    static func fund(for route: ChildPanelRoute, in snapshot: PortfolioSnapshot) -> FundPosition? {
        guard let code = route.selectedFundCode else { return nil }
        return snapshot.funds.first { $0.code == code }
    }

    // 取路由对应的交易记录
    static func record(for route: ChildPanelRoute, in snapshot: PortfolioSnapshot) -> FundTradeRecord? {
        guard let recordID = recordID(for: route) else { return nil }
        return snapshot.tradeRecords?.first { $0.id == recordID }
    }

    // 取路由对应的"某基金全部交易记录"
    static func tradeRecords(
        for route: ChildPanelRoute,
        in snapshot: PortfolioSnapshot
    ) -> [FundTradeRecord]? {
        guard case .tradeRecords(let fundCode) = route else { return nil }
        return (snapshot.tradeRecords ?? []).filter { $0.code == fundCode }
    }

    // 核心校验：依据快照判断路由是否仍可展示
    static func disposition(
        for route: ChildPanelRoute,
        in snapshot: PortfolioSnapshot
    ) -> ChildPanelRouteDisposition {
        // 路由依赖的基金已不存在 => 关闭
        if let fundCode = route.selectedFundCode,
           !snapshot.funds.contains(where: { $0.code == fundCode }) {
            return .close
        }

        // 编辑转换的"返回基金"已不存在 => 关闭
        if case .editConversion(_, _, let returnFundCode) = route,
           !snapshot.funds.contains(where: { $0.code == returnFundCode }) {
            return .close
        }

        // 路由依赖的交易记录已不存在 => 若知道返回基金则重定向到该基金交易记录，否则关闭
        if let recordID = recordID(for: route),
           !((snapshot.tradeRecords ?? []).contains { $0.id == recordID }) {
            guard let returnFundCode = returnFundCode(for: route) else {
                return .close
            }
            return .redirect(.tradeRecords(fundCode: returnFundCode))
        }

        return .available
    }

    // 从路由中提取"交易记录 ID"（仅编辑类路由有）
    private static func recordID(for route: ChildPanelRoute) -> String? {
        switch route {
        case .editTradeRecord(_, let recordID),
             .editPendingTradeRecord(_, let recordID),
             .editPendingConversion(_, let recordID):
            recordID
        case .editConversion(_, let recordID, _):
            recordID
        case .settings, .privacyDisclaimer, .onboarding, .sampleExperience,
             .portfolioPerformance, .jdFinancePerformanceSync, .jdFinanceSync, .portfolioBreakdown,
             .todayIncomeRanking, .addFund, .onboardingAddFund,
             .fundDetail, .fundDailyIncome, .tradeRecords, .buyFund, .sellFund,
             .convertFund, .editFund:
            nil
        }
    }

    // 从路由中提取"返回基金代码"（编辑交易/转换时用于失败时回退）
    private static func returnFundCode(for route: ChildPanelRoute) -> String? {
        switch route {
        case .editTradeRecord(let fundCode, _),
             .editPendingTradeRecord(let fundCode, _),
             .editPendingConversion(let fundCode, _):
            fundCode
        case .editConversion(_, _, let returnFundCode):
            returnFundCode
        case .settings, .privacyDisclaimer, .onboarding, .sampleExperience,
             .portfolioPerformance, .jdFinancePerformanceSync, .jdFinanceSync, .portfolioBreakdown,
             .todayIncomeRanking, .addFund, .onboardingAddFund,
             .fundDetail, .fundDailyIncome, .tradeRecords, .buyFund, .sellFund,
             .convertFund, .editFund:
            nil
        }
    }
}
