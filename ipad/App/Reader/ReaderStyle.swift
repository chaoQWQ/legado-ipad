import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case day
    case paper
    case green
    case night

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "系统"
        case .day: "亮色"
        case .paper: "米纸"
        case .green: "绿纸"
        case .night: "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day, .paper, .green: .light
        case .night: .dark
        }
    }

    func palette(for system: ColorScheme) -> ReadingPalette {
        switch self {
        case .system: system == .dark ? .night : .day
        case .day: .day
        case .paper: .paper
        case .green: .green
        case .night: .night
        }
    }
}

enum ReadingPalette {
    case day
    case paper
    case green
    case night

    var background: Color {
        switch self {
        case .day: Color(red: 0.984, green: 0.976, blue: 0.953)
        case .paper: Color(red: 0.953, green: 0.902, blue: 0.816)
        case .green: Color(red: 0.875, green: 0.925, blue: 0.855)
        case .night: Color(red: 0.09, green: 0.106, blue: 0.125)
        }
    }

    var foreground: Color {
        switch self {
        case .day: Color(red: 0.157, green: 0.153, blue: 0.141)
        case .paper: Color(red: 0.22, green: 0.169, blue: 0.129)
        case .green: Color(red: 0.14, green: 0.20, blue: 0.15)
        case .night: Color(red: 0.925, green: 0.914, blue: 0.89)
        }
    }

    var accent: Color {
        switch self {
        case .day: Color(red: 0.22, green: 0.353, blue: 0.298)
        case .paper: Color(red: 0.427, green: 0.306, blue: 0.224)
        case .green: Color(red: 0.20, green: 0.36, blue: 0.24)
        case .night: Color(red: 0.761, green: 0.855, blue: 0.788)
        }
    }

    var panel: Color {
        switch self {
        case .day, .green: Color(red: 0.958, green: 0.944, blue: 0.924)
        case .paper: Color(red: 0.929, green: 0.865, blue: 0.768)
        case .night: Color(red: 0.125, green: 0.141, blue: 0.16)
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable, Codable {
    case serif
    case sourceHanSerif
    case sansSerif
    case kai
    case monospaced

    var id: Self { self }

    var title: String {
        switch self {
        case .serif: "宋体"
        case .sourceHanSerif: "思源宋体"
        case .sansSerif: "无衬线"
        case .kai: "楷体"
        case .monospaced: "等宽"
        }
    }

    var supportedWeightRange: ClosedRange<Double> {
        self == .sourceHanSerif ? ReaderBundledFont.sourceHanWeightRange : 100...900
    }
}

struct ReaderTypography: Equatable {
    let fontSize: Double
    let lineSpacing: Double
    let font: ReaderFont
    let palette: ReadingPalette
    var paragraphSpacing: Double = 8
    var letterSpacing: Double = 0
    var fontWeight: Double = 400
    var indentWidth: Double = 0
    var leadingMargin: Double = 24
    var trailingMargin: Double = 24
    var topMargin: Double = 14
    var bottomMargin: Double = 28
    var justifiesText = false
}

enum ReaderColumnWidth: String, CaseIterable, Identifiable, Codable {
    case narrow
    case standard
    case wide

    var id: Self { self }
    var title: String {
        switch self {
        case .narrow: "窄"
        case .standard: "适中"
        case .wide: "宽"
        }
    }
    var maxWidth: CGFloat {
        switch self {
        case .narrow: 570
        case .standard: 740
        case .wide: 950
        }
    }
}

struct ReaderLayoutPreferences: Codable, Equatable {
    var font: ReaderFont = .serif
    var fontSize: Double = 23
    var letterSpacing: Double = 0
    var lineSpacing: Double = 8
    var paragraphSpacing: Double = 8
    var fontWeight: Double = 400
    var indentWidth: Double = 0
    var columnWidth: ReaderColumnWidth = .standard
    var leadingMargin: Double = 24
    var trailingMargin: Double = 24
    var topMargin: Double = 14
    var bottomMargin: Double = 28
    var turnMode: ReaderPageMode = .scroll
    var turnSpeed: ReaderPageSpeed = .standard

    static func legacy(from defaults: UserDefaults) -> Self {
        var layout = Self()
        layout.font = defaults.string(forKey: "reader.font").flatMap(ReaderFont.init(rawValue:)) ?? layout.font
        layout.fontSize = defaults.object(forKey: "reader.fontSize") as? Double ?? layout.fontSize
        layout.lineSpacing = defaults.object(forKey: "reader.lineSpacing") as? Double ?? layout.lineSpacing
        layout.paragraphSpacing = defaults.object(forKey: "reader.paragraphSpacing") as? Double ?? layout.paragraphSpacing
        layout.indentWidth = defaults.bool(forKey: "reader.indentParagraphs") ? 2 : 0
        layout.columnWidth = defaults.string(forKey: "reader.columnWidth").flatMap(ReaderColumnWidth.init(rawValue:)) ?? layout.columnWidth
        return layout
    }
}

struct ReaderLayoutProfiles: Codable, Equatable {
    var isShared = true
    var shared: ReaderLayoutPreferences
    var perTheme: [String: ReaderLayoutPreferences] = [:]

    subscript(theme: ReaderTheme) -> ReaderLayoutPreferences {
        get { isShared ? shared : perTheme[theme.rawValue] ?? shared }
        set {
            if isShared { shared = newValue }
            else { perTheme[theme.rawValue] = newValue }
        }
    }
}

enum ReaderPageSpeed: String, CaseIterable, Identifiable, Codable {
    case fast, standard, gentle, slow
    var id: Self { self }
    var title: String {
        switch self {
        case .fast: "极速"
        case .standard: "标准"
        case .gentle: "舒缓"
        case .slow: "优雅"
        }
    }
    var duration: Double {
        switch self {
        case .fast: 0.18
        case .standard: 0.30
        case .gentle: 0.42
        case .slow: 0.56
        }
    }
}

enum ReaderScript: String, CaseIterable, Identifiable, Codable {
    case off, simplified, traditional
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "关闭"
        case .simplified: "简体"
        case .traditional: "繁体"
        }
    }

    func convert(_ text: String) -> String {
        guard self != .off else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: self == .traditional) ?? text
    }
}

enum ReaderTitleAlignment: String, CaseIterable, Identifiable, Codable {
    case left, center, hidden
    var id: Self { self }
    var title: String {
        switch self {
        case .left: "左对齐"
        case .center: "居中"
        case .hidden: "隐藏"
        }
    }
}

struct ReaderInformationPreferences: Codable, Equatable {
    var showsChapterInfo = true
    var showsReadingProgress = false
    var showsClock = false
    var titleAlignment: ReaderTitleAlignment = .left
}

enum ReaderOrientation: String, CaseIterable, Identifiable, Codable {
    case system, portrait, landscape
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .portrait: "竖屏"
        case .landscape: "横屏"
        }
    }
}

enum ReaderScreenTimeout: String, CaseIterable, Identifiable, Codable {
    case system, oneMinute, fiveMinutes, tenMinutes, always
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "默认"
        case .oneMinute: "1 分钟"
        case .fiveMinutes: "5 分钟"
        case .tenMinutes: "10 分钟"
        case .always: "常亮"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .system, .always: nil
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .tenMinutes: 600
        }
    }
}

enum ReaderProgressBehavior: String, CaseIterable, Identifiable, Codable {
    case chapter, book
    var id: Self { self }
    var title: String { self == .chapter ? "调整章内进度" : "调整章节位置" }
}

enum ReaderTapAction: String, CaseIterable, Identifiable, Codable {
    case previousPage, showControls, nextPage, none
    var id: Self { self }
    var title: String {
        switch self {
        case .previousPage: "上一页"
        case .showControls: "打开或关闭菜单"
        case .nextPage: "下一页"
        case .none: "无操作"
        }
    }
}

struct ReaderBehavior: Codable, Equatable {
    var orientation: ReaderOrientation = .system
    var screenTimeout: ReaderScreenTimeout = .system
    var hidesStatusBar = false
    var hidesNavigationBar = false
    var progressBehavior: ReaderProgressBehavior = .chapter
    var justifiesText = false
    var allowsTextSelection = true
    var showsBrightnessControl = false
    var swipeThreshold: Double = 0
    var tapPrevious: ReaderTapAction = .previousPage
    var tapCenter: ReaderTapAction = .showControls
    var tapNext: ReaderTapAction = .nextPage
    // Optional so saved settings from before the vertical zones were split still decode.
    private var tapTopOverride: ReaderTapAction?
    private var tapBottomOverride: ReaderTapAction?
    var tapTop: ReaderTapAction {
        get { tapTopOverride ?? .showControls }
        set { tapTopOverride = newValue }
    }
    var tapBottom: ReaderTapAction {
        get { tapBottomOverride ?? .showControls }
        set { tapBottomOverride = newValue }
    }
    var menuOpacity: Double = 1
    var animatesScrollTaps = true
    var showsChapterAccessory = true
    var keyboardPageTurns = true
    var automaticSpeed: Double = 36
    var automaticPageInterval: Double = 8
}

func saveReaderPreference<T: Encodable>(_ value: T, into data: inout Data) {
    if let payload = try? JSONEncoder().encode(value) { data = payload }
}
