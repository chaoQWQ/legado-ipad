import SwiftUI

struct ReaderAppearanceConfigurationView: View {
    let palette: ReadingPalette
    @Binding var layout: ReaderLayoutPreferences
    @Binding var theme: ReaderTheme
    @Binding var sharesLayout: Bool
    @Binding var script: ReaderScript
    @Binding var information: ReaderInformationPreferences

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var detail: Detail?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    typography
                    controls
                    themes
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .navigationTitle("原生排版")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $detail) { detail in
                ReaderAppearanceDetailView(detail: detail, palette: palette, layout: $layout, information: $information)
            }
        }
        .tint(palette.accent)
    }

    private var typography: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicType.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, spacing: 8) {
            metric("字号", value: $layout.fontSize, range: 12...50)
            metric("字间距", value: $layout.letterSpacing, range: -2...8, step: 0.25, decimals: 2)
            metric("行间距", value: $layout.lineSpacing, range: 0...30)
            metric("段间距", value: $layout.paragraphSpacing, range: 0...40)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            ReaderPillPicker("翻页方式", choices: Array(ReaderPageMode.allCases), selection: $layout.turnMode, palette: palette, title: { $0.title })
            ReaderPillPicker("翻页速度", choices: Array(ReaderPageSpeed.allCases), selection: $layout.turnSpeed, palette: palette, title: { $0.title })
            ReaderMetricControl(
                "字重", value: displayedFontWeight, range: layout.font.supportedWeightRange,
                step: 50, accent: palette.accent
            )
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    Menu {
                        Picker("字体", selection: $layout.font) {
                            ForEach(ReaderFont.allCases) { font in Text(font.title).tag(font) }
                        }
                    } label: {
                        shortcut("字体", symbol: "textformat")
                    }
                    .accessibilityValue(layout.font.title)
                    Button { detail = .indentation } label: {
                        shortcut("缩进", symbol: "increase.indent", selected: layout.indentWidth > 0)
                    }
                    .accessibilityValue(layout.indentWidth > 0 ? "\(layout.indentWidth.formatted()) 字" : "关闭")
                    Button { detail = .margins } label: {
                        shortcut("边距", symbol: "arrow.left.and.right")
                    }
                    Button(action: cycleScript) {
                        shortcut(script.title, symbol: "character", selected: script != .off)
                    }
                    .accessibilityLabel("繁简转换")
                    .accessibilityValue(script.title)
                    .accessibilityHint("轻点切换繁简模式")
                    Button { detail = .information } label: {
                        shortcut("信息", symbol: "info.circle")
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollIndicators(.hidden)
            Toggle(isOn: $sharesLayout) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("共用布局")
                    Text("各主题沿用同一套排版参数")
                        .font(.caption)
                        .foregroundStyle(palette.foreground.opacity(0.72))
                }
            }
        }
        .padding(13)
        .background(palette.panel, in: .rect(cornerRadius: 16))
    }

    private var displayedFontWeight: Binding<Double> {
        let range = layout.font.supportedWeightRange
        return Binding(
            get: { min(range.upperBound, max(range.lowerBound, layout.fontWeight)) },
            set: { layout.fontWeight = $0 }
        )
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("主题").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 75), spacing: 8)], spacing: 8) {
                ForEach(ReaderTheme.allCases) { option in
                    let sample = option.palette(for: colorScheme)
                    Button {
                        theme = option
                    } label: {
                        VStack(spacing: 6) {
                            Text("阅")
                                .font(.system(.title3, design: .serif, weight: .semibold))
                                .foregroundStyle(sample.foreground)
                                .frame(maxWidth: .infinity, minHeight: 43)
                                .background(sample.background, in: .rect(cornerRadius: 9))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9)
                                        .strokeBorder(theme == option ? palette.accent : palette.foreground.opacity(0.21), lineWidth: theme == option ? 2 : 1)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if theme == option {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(sample.accent)
                                            .padding(5)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .accessibilityHidden(true)
                            Text(option.title)
                                .font(.caption.weight(theme == option ? .semibold : .regular))
                                .foregroundStyle(palette.foreground)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(theme == option ? .isSelected : [])
                }
            }
        }
        .padding(13)
        .background(palette.panel, in: .rect(cornerRadius: 16))
    }

    private func metric(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, decimals: Int = 0) -> some View {
        ReaderMetricControl(title, value: value, range: range, step: step, decimals: decimals, accent: palette.accent, showsSteps: true)
            .padding(12)
            .background(palette.panel, in: .rect(cornerRadius: 14))
    }

    private func shortcut(_ title: String, symbol: String, selected: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? palette.accent : palette.foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(selected ? palette.accent.opacity(0.15) : palette.background, in: .rect(cornerRadius: 10))
    }

    private func cycleScript() {
        let choices = Array(ReaderScript.allCases)
        guard let index = choices.firstIndex(of: script), !choices.isEmpty else { return }
        script = choices[(index + 1) % choices.count]
    }

    enum Detail: String, Identifiable {
        case indentation, margins, information

        var id: Self { self }
        var title: String {
            switch self {
            case .indentation: "缩进"
            case .margins: "边距"
            case .information: "阅读信息"
            }
        }
    }
}

struct ReaderBehaviorConfigurationView: View {
    let palette: ReadingPalette
    @Binding var behavior: ReaderBehavior

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("屏幕") {
                    configurationPicker("屏幕方向", selection: $behavior.orientation, title: { $0.title })
                    configurationPicker("屏幕超时", selection: $behavior.screenTimeout, title: { $0.title })
                    Toggle("隐藏状态栏", isOn: $behavior.hidesStatusBar)
                    Toggle("隐藏导航栏", isOn: $behavior.hidesNavigationBar)
                    Toggle("显示亮度调节控件", isOn: $behavior.showsBrightnessControl)
                }
                Section("正文与进度") {
                    configurationPicker("进度条行为", selection: $behavior.progressBehavior, title: { $0.title })
                    Toggle("两端对齐", isOn: $behavior.justifiesText)
                    Toggle("可选中正文", isOn: $behavior.allowsTextSelection)
                    Toggle("显示顶部附加信息", isOn: $behavior.showsChapterAccessory)
                }
                Section("翻页操作") {
                    Toggle("滚动模式点按动画", isOn: $behavior.animatesScrollTaps)
                    Toggle("键盘翻页", isOn: $behavior.keyboardPageTurns)
                    ReaderMetricControl("滑动翻页阈值", value: $behavior.swipeThreshold, range: 0...140, step: 5, accent: palette.accent) { value in
                        value == 0 ? "默认" : "\(value.formatted()) 点"
                    }
                }
                Section("点按区域") {
                    configurationPicker("左侧和上方", selection: $behavior.tapPrevious, title: { $0.title })
                    configurationPicker("正中央", selection: $behavior.tapCenter, title: { $0.title })
                    configurationPicker("右侧和下方", selection: $behavior.tapNext, title: { $0.title })
                }
                Section("阅读工具栏") {
                    ReaderMetricControl("菜单不透明度", value: $behavior.menuOpacity, range: 0.35...1, step: 0.05, accent: palette.accent) { value in
                        value.formatted(.percent.precision(.fractionLength(0)))
                    }
                }
                Section("自动阅读") {
                    ReaderMetricControl("滚动速度", value: $behavior.automaticSpeed, range: 12...110, accent: palette.accent)
                    ReaderMetricControl("自动翻页间隔", value: $behavior.automaticPageInterval, range: 2...60, accent: palette.accent) { value in
                        "\(value.formatted()) 秒"
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .navigationTitle("阅读设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(palette.accent)
    }
}

private struct ReaderAppearanceDetailView: View {
    let detail: ReaderAppearanceConfigurationView.Detail
    let palette: ReadingPalette
    @Binding var layout: ReaderLayoutPreferences
    @Binding var information: ReaderInformationPreferences

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch detail {
                case .indentation:
                    Section("段落") {
                        ReaderMetricControl("首行缩进", value: $layout.indentWidth, range: 0...4, step: 0.5, accent: palette.accent) { value in
                            value == 0 ? "关闭" : "\(value.formatted()) 字"
                        }
                    }
                case .margins:
                    Section("正文留白") {
                        ReaderMetricControl("左边距", value: $layout.leadingMargin, range: 0...72, accent: palette.accent)
                        ReaderMetricControl("右边距", value: $layout.trailingMargin, range: 0...72, accent: palette.accent)
                        ReaderMetricControl("上边距", value: $layout.topMargin, range: 0...72, accent: palette.accent)
                        ReaderMetricControl("下边距", value: $layout.bottomMargin, range: 0...72, accent: palette.accent)
                        Picker("正文宽度", selection: $layout.columnWidth) {
                            ForEach(ReaderColumnWidth.allCases) { width in Text(width.title).tag(width) }
                        }
                    }
                case .information:
                    Section("阅读界面") {
                        Toggle("显示章节信息", isOn: $information.showsChapterInfo)
                        Toggle("显示阅读进度", isOn: $information.showsReadingProgress)
                        Toggle("显示时钟", isOn: $information.showsClock)
                        configurationPicker("正文标题", selection: $information.titleAlignment, title: { $0.title })
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .navigationTitle(detail.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(palette.accent)
    }
}

private struct ReaderMetricControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let accent: Color
    let showsSteps: Bool
    let format: ((Double) -> String)?

    init(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1,
        decimals: Int = 0, accent: Color, showsSteps: Bool = false, format: ((Double) -> String)? = nil
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.decimals = decimals
        self.accent = accent
        self.showsSteps = showsSteps
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent {
                Text(format?(value) ?? value.formatted(.number.precision(.fractionLength(0...decimals))))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            } label: {
                Text(title).font(.subheadline.weight(.medium))
            }
            if showsSteps {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        stepButton(increasing: false)
                        slider.frame(minWidth: 72)
                        stepButton(increasing: true)
                    }
                    slider
                }
            } else {
                slider
            }
        }
    }

    private var slider: some View {
        Slider(value: $value, in: range, step: step) { Text(title) }
            .tint(accent)
            .frame(minHeight: 32)
    }

    private func stepButton(increasing: Bool) -> some View {
        let isAtLimit = increasing ? value >= range.upperBound : value <= range.lowerBound
        return Button {
            value = min(range.upperBound, max(range.lowerBound, value + (increasing ? step : -step)))
        } label: {
            Image(systemName: increasing ? "plus" : "minus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.10), in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(increasing ? "增加" : "减少")\(title)")
        .opacity(isAtLimit ? 0.42 : 1)
        .disabled(isAtLimit)
    }
}

private func configurationPicker<Option: CaseIterable & Hashable>(
    _ label: String, selection: Binding<Option>, title: @escaping (Option) -> String
) -> some View {
    Picker(label, selection: selection) {
        ForEach(Array(Option.allCases), id: \.self) { option in Text(title(option)).tag(option) }
    }
}

private struct ReaderPillPicker<Option: Hashable>: View {
    let label: String
    let choices: [Option]
    @Binding var selection: Option
    let palette: ReadingPalette
    let title: (Option) -> String

    init(_ label: String, choices: [Option], selection: Binding<Option>, palette: ReadingPalette, title: @escaping (Option) -> String) {
        self.label = label
        self.choices = choices
        self._selection = selection
        self.palette = palette
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline.weight(.medium))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { option in
                        let selected = selection == option
                        Button { selection = option } label: {
                            Text(title(option))
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? palette.accent : palette.foreground)
                                .padding(.horizontal, 13)
                                .frame(minHeight: 44)
                                .background(selected ? palette.accent.opacity(0.17) : palette.background, in: .capsule)
                                .overlay {
                                    if selected { Capsule().strokeBorder(palette.accent.opacity(0.42)) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
