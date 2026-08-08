import SwiftUI

enum PanelDesign {
    static let accent = Color(nsColor: .systemRed)
    static let panelBackground = Color(nsColor: panelBackgroundNSColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.64)
    static let selectorBackground = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let inputBackground = Color(nsColor: .textBackgroundColor).opacity(0.78)
    static let buttonBackground = Color(nsColor: buttonBackgroundNSColor)
    static let buttonBorder = Color(nsColor: buttonBorderNSColor)
    static let segmentSelectionBackground = Color(nsColor: segmentSelectionBackgroundNSColor)
    static let segmentSelectionBorder = Color(nsColor: segmentSelectionBorderNSColor)
    static let warningBackground = Color(nsColor: warningBackgroundNSColor)
    static let warningBorder = Color(nsColor: warningBorderNSColor)
    static let warningAccent = Color(nsColor: warningAccentNSColor)

    static let panelBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 17 / 255, green: 19 / 255, blue: 24 / 255, alpha: 0.98)
        }
        return NSColor(red: 251 / 255, green: 249 / 255, blue: 245 / 255, alpha: 0.99)
    }

    static let panelChromeNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 35 / 255, green: 39 / 255, blue: 46 / 255, alpha: 1)
        }
        return NSColor(red: 254 / 255, green: 247 / 255, blue: 236 / 255, alpha: 1)
    }

    static let panelChromeBackground = Color(nsColor: panelChromeNSColor)

    static let buttonBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 42 / 255, green: 46 / 255, blue: 54 / 255, alpha: 0.94)
        }
        return NSColor.white.withAlphaComponent(0.92)
    }

    static let buttonBorderNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor.white.withAlphaComponent(0.22)
        }
        return NSColor.black.withAlphaComponent(0.16)
    }

    static let segmentSelectionBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 52 / 255, green: 56 / 255, blue: 65 / 255, alpha: 0.98)
        }
        return NSColor.white.withAlphaComponent(0.96)
    }

    static let segmentSelectionBorderNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor.white.withAlphaComponent(0.30)
        }
        return NSColor.black.withAlphaComponent(0.18)
    }

    static let warningBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 98 / 255, green: 49 / 255, blue: 18 / 255, alpha: 0.34)
        }
        return NSColor(red: 255 / 255, green: 235 / 255, blue: 218 / 255, alpha: 0.96)
    }

    static let warningBorderNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 255 / 255, green: 137 / 255, blue: 62 / 255, alpha: 0.42)
        }
        return NSColor(red: 238 / 255, green: 111 / 255, blue: 38 / 255, alpha: 0.34)
    }

    static let warningAccentNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(red: 255 / 255, green: 153 / 255, blue: 84 / 255, alpha: 0.96)
        }
        return NSColor(red: 202 / 255, green: 83 / 255, blue: 13 / 255, alpha: 0.98)
    }

    /// 生成统一风格的描边视图（圆角矩形 + 半透明分隔线色）。
    static func border(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.6)
    }
}

enum PanelFocusAppearance {
    /// 禁用内容根视图的焦点光环，返回包装后的 AnyView。
    static func suppressedRoot<Content: View>(_ content: Content) -> AnyView {
        AnyView(content.focusEffectDisabled())
    }

    @MainActor
    /// 生成已禁用焦点光环的 NSHostingView 容器，用于承载 SwiftUI 面板内容。
    static func hostingView<Content: View>(_ content: Content) -> NSHostingView<AnyView> {
        NSHostingView(rootView: PanelFocusAppearance.suppressedRoot(content))
    }
}

struct PanelHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var subtitleWeight: Font.Weight = .medium
    var tint: Color = PanelDesign.accent
    var accessoryText: String? = nil
    var accessoryColor: Color = .orange
    var actionSystemImage: String? = nil
    var actionTitle: String? = nil
    var actionBadgeText: String? = nil
    var actionTint: Color? = nil
    var actionHelp: String? = nil
    var onAction: (() -> Void)? = nil
    let onClose: () -> Void

    /// 渲染面板标题栏：左侧图标 + 标题/副标题，中部可选标识与功能按钮，右侧关闭按钮。
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10, weight: subtitleWeight))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            if let accessoryText {
                Text(accessoryText)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(accessoryColor)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(accessoryColor.opacity(0.11), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(accessoryColor.opacity(0.18), lineWidth: 0.6)
                    )
            }

            Spacer()

            if let actionTitle, let onAction {
                let resolvedActionTint = actionTint ?? Color.secondary
                Button {
                    onAction()
                } label: {
                    HStack(spacing: 5) {
                        if let actionSystemImage {
                            Image(systemName: actionSystemImage)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(actionTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if let actionBadgeText {
                            Text(actionBadgeText)
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(resolvedActionTint.opacity(0.82))
                        }
                    }
                    .foregroundStyle(resolvedActionTint)
                    .padding(.horizontal, actionSystemImage == nil ? 8 : 9)
                    .frame(minWidth: 68, minHeight: 28)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(PanelDesign.selectorBackground)
                            if let actionTint {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(actionTint.opacity(0.11))
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(resolvedActionTint.opacity(actionTint == nil ? 0.24 : 0.28), lineWidth: 0.75)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(actionTitle)
                .help(actionHelp ?? actionTitle)
                .layoutPriority(2)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("关闭")
            .help("关闭")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    /// 带标题的卡片容器：标题 + 自定义内容，统一卡片背景与描边。
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelDesign.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(PanelDesign.border(cornerRadius: 10))
    }
}

struct PanelLinkButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = PanelDesign.accent
    var trailingSystemImage = "arrow.up.right"
    let action: () -> Void

    /// 链接式按钮：左图标 + 标题/副标题 + 右跳转箭头，整体可点。
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: trailingSystemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 42)
            .background(
                PanelDesign.inputBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(PanelDesign.border(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

struct PanelSegmentedPicker<Value: Hashable & Identifiable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var tint: Color = PanelDesign.accent
    var accessibilityLabelText: String? = nil
    /// 是否启用左右方向键导航。菜单栏 App 中某些场景下焦点会自动落在选择器上，
    /// 持续的方向键事件会导致选中项反复跳变，此时应关闭。
    var enableArrowNavigation: Bool = true

    /// 胶囊式分段选择器：点击切换选中并高亮，支持左右方向键导航。
    var body: some View {
        HStack(spacing: 4) {
            ForEach(values) { value in
                let isSelected = selection == value
                Button {
                    selection = value
                } label: {
                    Text(title(value))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            Capsule()
                                .fill(isSelected ? Color(nsColor: .textBackgroundColor).opacity(0.94) : PanelDesign.inputBackground.opacity(0.88))
                        }
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected ? tint.opacity(0.18) : Color(nsColor: .separatorColor).opacity(0.42),
                                    lineWidth: 0.6
                                )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(title(value))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(PanelDesign.selectorBackground, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 0.6)
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard enableArrowNavigation else { return }
            guard let currentIndex = values.firstIndex(of: selection) else { return }
            let nextIndex: Int
            switch direction {
            case .left:
                nextIndex = max(values.startIndex, currentIndex - 1)
            case .right:
                nextIndex = min(values.index(before: values.endIndex), currentIndex + 1)
            default:
                return
            }
            selection = values[nextIndex]
        }
        .accessibilityLabel(accessibilityLabelText ?? "分段选择")
        .accessibilityValue(title(selection))
        .accessibilityHint("使用左右方向键切换")
    }
}

struct PanelTextInput: View {
    let placeholder: String
    @Binding var text: String
    var suffix: String?
    var isDisabled = false

    /// 初始化文本框：占位符 + 文本绑定 + 可选后缀 + 是否禁用。
    init(_ placeholder: String, text: Binding<String>, suffix: String? = nil, isDisabled: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.suffix = suffix
        self.isDisabled = isDisabled
    }

    /// 渲染单行输入框：文本字段 + 可选后缀单位，禁用时降低不透明度。
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .monospacedDigit()
                .disabled(isDisabled)

            if let suffix {
                Text(suffix)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(PanelDesign.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(isDisabled ? 0.24 : 0.45), lineWidth: 0.6)
        )
        .opacity(isDisabled ? 0.68 : 1)
    }
}

struct PanelNativeDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    var elements: NSDatePicker.ElementFlags
    var isEnabled = true

    /// 创建触发日期/时间弹窗的 NSButton（AppKit 包装），并绑定协调器。
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showPicker(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: isTimeOnly ? "clock" : "calendar", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setButtonType(.momentaryPushIn)
        context.coordinator.button = button
        context.coordinator.elements = elements
        context.coordinator.isTimeOnly = isTimeOnly
        context.coordinator.updateButtonTitle()
        return button
    }

    /// 把选中值、元素类型与可用状态同步到协调器与按钮外观。
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.elements = elements
        context.coordinator.isTimeOnly = isTimeOnly
        context.coordinator.updateButtonTitle()
        button.isEnabled = isEnabled
        button.alphaValue = isEnabled ? 1 : 0.58
    }

    /// 创建协调器，桥接 AppKit 弹窗与 SwiftUI 的日期绑定。
    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, elements: elements, isTimeOnly: isTimeOnly)
    }

    /// 是否仅选择时分（不含年月日）：用于切换时间选择器或日历弹窗。
    private var isTimeOnly: Bool {
        elements.contains(.hourMinute) && !elements.contains(.yearMonthDay)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var selection: Binding<Date>
        var elements: NSDatePicker.ElementFlags
        var isTimeOnly: Bool
        weak var button: NSButton?
        private var popover: NSPopover?

        init(selection: Binding<Date>, elements: NSDatePicker.ElementFlags, isTimeOnly: Bool) {
            self.selection = selection
            self.elements = elements
            self.isTimeOnly = isTimeOnly
        }

        @MainActor
        /// 点击按钮时弹出时间选择器或日历弹窗（再次点击则关闭）。
        @objc func showPicker(_ sender: NSButton) {
            if popover?.isShown == true {
                popover?.close()
                return
            }

            if !isTimeOnly {
                showCalendarPicker(relativeTo: sender)
                return
            }

            let picker = NSDatePicker()
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = elements
            picker.dateValue = selection.wrappedValue
            picker.locale = Locale(identifier: "zh_CN")
            picker.calendar = Calendar.current
            picker.timeZone = TimeZone.current
            picker.controlSize = .regular
            picker.focusRingType = .none
            picker.target = self
            picker.action = #selector(valueChanged(_:))

            picker.sizeToFit()
            let pickerSize = picker.fittingSize
            let contentSize = NSSize(
                width: max(pickerSize.width + 16, isTimeOnly ? 136 : 206),
                height: max(pickerSize.height + 16, isTimeOnly ? 82 : 176)
            )
            let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
            picker.frame = NSRect(
                x: (contentSize.width - pickerSize.width) / 2,
                y: (contentSize.height - pickerSize.height) / 2,
                width: pickerSize.width,
                height: pickerSize.height
            )
            container.addSubview(picker)

            let controller = NSViewController()
            controller.view = container
            controller.preferredContentSize = contentSize

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = contentSize
            popover.contentViewController = controller
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            PanelAuxiliaryPopoverRegistry.register(popover)
        }

        @MainActor
        /// 弹出 SwiftUI 日历选择器弹窗，选择后回写日期并关闭。
        private func showCalendarPicker(relativeTo sender: NSButton) {
            let contentSize = NSSize(width: 300, height: 336)
            let hostingView = NSHostingView(
                rootView: PanelCalendarPopoverContent(selectedDate: selection.wrappedValue) { [weak self] date in
                    guard let self else { return }
                    selection.wrappedValue = date
                    updateButtonTitle()
                    self.popover?.close()
                }
            )
            hostingView.frame = NSRect(origin: .zero, size: contentSize)

            let controller = NSViewController()
            controller.view = hostingView
            controller.preferredContentSize = contentSize

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = contentSize
            popover.contentViewController = controller
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            PanelAuxiliaryPopoverRegistry.register(popover)
        }

        @MainActor
        /// 时间选择器值变化时写回绑定并刷新按钮标题；非时间选择时直接关闭弹窗。
        @objc func valueChanged(_ sender: NSDatePicker) {
            selection.wrappedValue = sender.dateValue
            updateButtonTitle()
            if !isTimeOnly {
                popover?.close()
            }
        }

        @MainActor
        /// 按当前选中日期刷新按钮标题文本。
        func updateButtonTitle() {
            button?.title = formatted(selection.wrappedValue)
        }

        @MainActor
        /// 弹窗关闭时从注册表注销并清理引用。
        func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover else { return }
            PanelAuxiliaryPopoverRegistry.unregister(popover)
            if self.popover === popover {
                self.popover = nil
            }
        }

        /// 把日期格式化为按钮标题文本（仅时分或年月日）。
        private func formatted(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar.current
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = isTimeOnly ? "HH:mm" : "yyyy/M/d"
            return formatter.string(from: date)
        }
    }
}

@MainActor
enum PanelAuxiliaryPopoverRegistry {
    private final class WeakPopover {
        weak var value: NSPopover?

        init(_ value: NSPopover) {
            self.value = value
        }
    }

    private static var popovers: [WeakPopover] = []
    private static var recentlyClosedUntil: Date?

    /// 注册一个辅助弹窗到活动列表，并清除“最近关闭”缓冲。
    static func register(_ popover: NSPopover) {
        pruneClosedPopovers()
        popovers.append(WeakPopover(popover))
        recentlyClosedUntil = nil
    }

    /// 注销弹窗，并记录短暂缓冲时段以避免紧接着的鼠标事件误关其他弹窗。
    static func unregister(_ popover: NSPopover) {
        popovers.removeAll { $0.value == nil || $0.value === popover }
        recentlyClosedUntil = Date().addingTimeInterval(0.25)
    }

    /// 面板内发生鼠标按下时：若命中外部辅助弹窗则关闭并返回 true；命中内部则返回 true。
    static func handlePanelMouseDown(at screenLocation: NSPoint) -> Bool {
        pruneClosedPopovers()

        if let recentlyClosedUntil, recentlyClosedUntil > Date() {
            return true
        }
        recentlyClosedUntil = nil

        let activePopovers = popovers.compactMap(\.value)
        guard !activePopovers.isEmpty else { return false }

        if activePopovers.contains(where: { popover in
            popover.contentViewController?.view.window?.frame.contains(screenLocation) == true
        }) {
            return true
        }

        activePopovers.forEach { $0.close() }
        recentlyClosedUntil = Date().addingTimeInterval(0.25)
        return true
    }

    /// 清理已关闭或失效的弹窗弱引用，保持活动列表整洁。
    private static func pruneClosedPopovers() {
        popovers.removeAll { popover in
            guard let value = popover.value else { return true }
            return !value.isShown
        }
    }
}

private struct PanelCalendarPopoverContent: View {
    let selectedDate: Date
    let onSelect: (Date) -> Void

    @State private var visibleMonth: Date

    private let calendar: Calendar
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 7)
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    /// 初始化日历弹窗内容：选定日期 + 选择回调，并定位到选定日期所在月。
    init(selectedDate: Date, onSelect: @escaping (Date) -> Void) {
        self.selectedDate = selectedDate
        self.onSelect = onSelect
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        self.calendar = calendar
        _visibleMonth = State(initialValue: calendar.startOfMonth(for: selectedDate))
    }

    /// 渲染日历弹窗：标题与当前选中日 + 月份切换 + 7 列日期网格。
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日期")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(selectedDateText)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: Capsule())
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            Divider()
                .opacity(0.45)

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        visibleMonth = calendar.startOfMonth(for: selectedDate)
                    } label: {
                        HStack(spacing: 5) {
                            Text(monthTitle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Spacer()

                    calendarIconButton("chevron.left") {
                        moveMonth(-1)
                    }
                    calendarIconButton("chevron.right") {
                        moveMonth(1)
                    }
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(weekdays, id: \.self) { weekday in
                        Text(weekday)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 20)
                    }

                    ForEach(calendarDays) { day in
                        Button {
                            onSelect(day.date)
                        } label: {
                            Text("\(calendar.component(.day, from: day.date))")
                                .font(.system(size: 15, weight: isSelected(day.date) ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(dayForeground(day))
                                .frame(width: 34, height: 34)
                                .background(dayBackground(day), in: Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.56),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .padding(12)
        }
        .frame(width: 300, height: 336)
        .background(PanelDesign.panelBackground)
    }

    /// 当前可见月份标题（yyyy年 M月）。
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: visibleMonth)
    }

    /// 当前选中日期文本（yyyy/M/d）。
    private var selectedDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy/M/d"
        return formatter.string(from: selectedDate)
    }

    /// 生成 6×7 共 42 格的日期数组（含月初前置空白对应的非当月偏移）。
    private var calendarDays: [CalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth),
              let firstGridDate = calendar.date(
                byAdding: .day,
                value: -weekdayOffset(from: monthInterval.start),
                to: monthInterval.start
              )
        else {
            return []
        }

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstGridDate) else { return nil }
            return CalendarDay(
                date: date,
                isCurrentMonth: calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
            )
        }
    }

    /// 生成圆形图标按钮（用于翻月等动作）。
    private func calendarIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemBlue))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 计算某日期在网格中的星期偏移（以周一为每周首日）。
    private func weekdayOffset(from date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// 前后翻月（offset 为负/正表示上/下月）。
    private func moveMonth(_ offset: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: offset, to: visibleMonth) ?? visibleMonth
    }

    /// 判断日期是否为当前选中日。
    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    /// 判断日期是否为今天。
    private func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    /// 日期文字颜色：选中/非当月/今天/普通 四种情形。
    private func dayForeground(_ day: CalendarDay) -> Color {
        if isSelected(day.date) { return Color(nsColor: .systemBlue) }
        if !day.isCurrentMonth { return Color.secondary.opacity(0.26) }
        if isToday(day.date) { return Color(nsColor: .systemBlue) }
        return .primary
    }

    /// 日期背景色：选中或今天高亮，其余透明。
    private func dayBackground(_ day: CalendarDay) -> Color {
        if isSelected(day.date) {
            Color(nsColor: .systemBlue).opacity(0.18)
        } else if isToday(day.date) {
            Color(nsColor: .systemBlue).opacity(0.08)
        } else {
            Color.clear
        }
    }

    /// 单日模型：日期与是否当月，用于日历网格渲染。
    private struct CalendarDay: Identifiable {
        let date: Date
        let isCurrentMonth: Bool

        var id: TimeInterval { date.timeIntervalSince1970 }
    }
}

private extension Calendar {
    /// 返回某日期所在月份的第一天（置零时分秒）。
    func startOfMonth(for date: Date) -> Date {
        guard let interval = dateInterval(of: .month, for: date) else { return startOfDay(for: date) }
        return interval.start
    }
}

struct PanelButtonLabel: View {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    let title: String
    var systemImage: String?
    var style: Style = .secondary
    var tint: Color = PanelDesign.accent
    var isEnabled = true
    @Environment(\.isEnabled) private var environmentIsEnabled

    /// 渲染统一按钮外观：图标 + 标题，按样式与可用性呈现前景/背景/边框/阴影。
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: style == .primary ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(foregroundColor)
        .frame(maxWidth: .infinity)
        .frame(height: 31)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(borderColor, lineWidth: style == .primary ? 0 : 0.7)
        )
        .shadow(color: shadowColor, radius: 4, x: 0, y: 1.5)
        .contentShape(Rectangle())
    }

    /// 按钮文字颜色：按样式（主/次/危险）与可用性决定。
    private var foregroundColor: Color {
        switch style {
        case .primary:
            resolvedIsEnabled ? .white : .secondary
        case .secondary:
            resolvedIsEnabled ? .primary : .secondary
        case .destructive:
            resolvedIsEnabled ? .red : .secondary
        }
    }

    /// 按钮背景色：按样式与可用性决定（主色填充或中性背景）。
    private var backgroundColor: Color {
        switch style {
        case .primary:
            resolvedIsEnabled ? tint : Color(nsColor: .controlBackgroundColor).opacity(0.72)
        case .secondary, .destructive:
            resolvedIsEnabled ? PanelDesign.buttonBackground : PanelDesign.cardBackground
        }
    }

    /// 按钮边框色：主按钮无边框，其余按样式与可用性决定。
    private var borderColor: Color {
        switch style {
        case .primary:
            .clear
        case .secondary:
            resolvedIsEnabled ? PanelDesign.buttonBorder : Color(nsColor: .separatorColor).opacity(0.28)
        case .destructive:
            resolvedIsEnabled ? Color.red.opacity(0.36) : Color(nsColor: .separatorColor).opacity(0.28)
        }
    }

    /// 按钮阴影色：仅可用时添加轻微阴影。
    private var shadowColor: Color {
        resolvedIsEnabled ? Color.black.opacity(0.035) : .clear
    }

    /// 综合自身的 isEnabled 与环境可用性，得到最终可用状态。
    private var resolvedIsEnabled: Bool {
        isEnabled && environmentIsEnabled
    }
}
