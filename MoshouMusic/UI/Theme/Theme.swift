import UIKit

/// Material Design 3 色彩系统 — 鲜艳活泼风格
struct Theme {

    // MARK: - 主色

    /// Primary — 鲜艳紫
    static let primary = UIColor(hex: 0x6C5CE7)
    static let primaryDark = UIColor(hex: 0x534AB7)
    static let primaryLight = UIColor(hex: 0xA29BFE)
    static let primaryContainer = UIColor(hex: 0xEEEDFE)
    static let onPrimary = UIColor.white
    static let onPrimaryContainer = UIColor(hex: 0x1A1535)

    // MARK: - 辅助色

    /// Secondary — 珊瑚红
    static let secondary = UIColor(hex: 0xFF6B6B)
    static let secondaryContainer = UIColor(hex: 0xFFE8E8)

    /// Tertiary — 青色
    static let tertiary = UIColor(hex: 0x00CEC9)
    static let tertiaryContainer = UIColor(hex: 0xE1F5EE)

    // MARK: - 功能色

    static let success = UIColor(hex: 0x34A853)
    static let warning = UIColor(hex: 0xFBBC04)
    static let error = UIColor(hex: 0xEA4335)

    // MARK: - 中性色

    static let background = UIColor(hex: 0xFAFAFE)
    static let surface = UIColor.white
    static let surfaceVariant = UIColor(hex: 0xF2F0FA)
    static let onSurface = UIColor(hex: 0x1A1B25)
    static let onSurfaceVariant = UIColor(hex: 0x56556A)
    static let outline = UIColor(hex: 0xC8C5D8)
    static let outlineVariant = UIColor(hex: 0xE4E1F0)

    // MARK: - 深色模式

    static let darkBackground = UIColor(hex: 0x14121F)
    static let darkSurface = UIColor(hex: 0x221F35)
    static let darkSurfaceVariant = UIColor(hex: 0x2E2B45)
    static let darkOnSurface = UIColor(hex: 0xE6E1F0)
    static let darkOnSurfaceVariant = UIColor(hex: 0x9B98B5)
    static let darkOutline = UIColor(hex: 0x4A4768)

    // MARK: - 音源标识色

    static func sourceColor(_ source: String) -> UIColor {
        switch source {
        case "tx": return secondary        // QQ音乐 — 珊瑚红
        case "wy": return tertiary         // 网易云 — 青
        case "kg": return warning          // 酷狗 — 黄
        case "mg": return success          // 咪咕 — 绿
        default: return primary
        }
    }

    static func sourceColorLight(_ source: String) -> UIColor {
        switch source {
        case "tx": return secondaryContainer
        case "wy": return tertiaryContainer
        case "kg": return UIColor(hex: 0xFAEEDA)
        case "mg": return UIColor(hex: 0xE8F5E9)
        default: return primaryContainer
        }
    }

    /// 深色饱和变体 — 用于「选中」chip 背景，确保白字有足够对比
    static func sourceColorDark(_ source: String) -> UIColor {
        switch source {
        case "tx": return UIColor(hex: 0xC83A3A)  // 深珊瑚红
        case "wy": return UIColor(hex: 0x00807A)  // 深青
        case "kg": return UIColor(hex: 0x8C6500)  // 深琥珀
        case "mg": return UIColor(hex: 0x1E7A35)  // 深绿
        default: return primaryDark
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "tx": return "QQ音乐"
        case "wy": return "网易云"
        case "kg": return "酷狗"
        case "mg": return "咪咕"
        default: return source.uppercased()
        }
    }

    /// 根据背景色亮度返回对比文字色（亮背景用深色字，暗背景用白色字）
    static func contrastingTextColor(for color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        // sRGB 相对亮度 — 提高阈值，让黄/珊瑚等中等亮度也走深色字
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum < 0.55 ? .white : UIColor(hex: 0x1A1B25)
    }

    // MARK: - 圆角

    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 16
    static let cornerLarge: CGFloat = 28
    static let cornerFull: CGFloat = 999

    // MARK: - 间距

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24

    // MARK: - 字体

    static let titleLarge = UIFont.systemFont(ofSize: 28, weight: .bold)
    static let titleMedium = UIFont.systemFont(ofSize: 22, weight: .bold)
    static let titleSmall = UIFont.systemFont(ofSize: 16, weight: .semibold)
    static let bodyLarge = UIFont.systemFont(ofSize: 16, weight: .regular)
    static let bodyMedium = UIFont.systemFont(ofSize: 14, weight: .regular)
    static let bodySmall = UIFont.systemFont(ofSize: 12, weight: .regular)
    static let labelLarge = UIFont.systemFont(ofSize: 14, weight: .semibold)

    // MARK: - 应用外观

    static func applyAppearance() {
        let isDark = ConfigStore.shared.isDarkMode

        // 导航栏
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = isDark ? darkSurface : surface
        navAppearance.titleTextAttributes = [
            .foregroundColor: isDark ? darkOnSurface : onSurface,
            .font: titleSmall
        ]
        navAppearance.largeTitleTextAttributes = [
            .foregroundColor: isDark ? darkOnSurface : onSurface,
            .font: titleLarge
        ]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().tintColor = primary

        // TabBar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = isDark ? darkSurface : surface

        UITabBar.appearance().standardAppearance = tabAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        }
        UITabBar.appearance().tintColor = primary

        // 注: 搜索框已改为自绘的 MDSearchField (普通 UITextField),
        // 不再依赖 UISearchBar 的 appearance 代理 —— 那种做法在 iOS 14 上
        // 会被导航栏外观 / 内部视图重建反复覆盖, 导致输入文字不可见。
    }

    // MARK: - 获取当前模式颜色

    static var bg: UIColor {
        ConfigStore.shared.isDarkMode ? darkBackground : background
    }
    static var cardBg: UIColor {
        ConfigStore.shared.isDarkMode ? darkSurface : surface
    }
    static var text: UIColor {
        ConfigStore.shared.isDarkMode ? darkOnSurface : onSurface
    }
    static var subtext: UIColor {
        ConfigStore.shared.isDarkMode ? darkOnSurfaceVariant : onSurfaceVariant
    }
    static var border: UIColor {
        ConfigStore.shared.isDarkMode ? darkOutline : outline
    }
    /// 搜索框底色 (MDSearchField 使用)
    static var searchFieldBg: UIColor {
        ConfigStore.shared.isDarkMode ? darkSurfaceVariant : surfaceVariant
    }
}

// MARK: - UIColor Hex 扩展

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    /// 调整亮度 (1.0 = 原色, >1 亮, <1 暗)
    func adjusted(brightness: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s, brightness: min(1, max(0, b * brightness)), alpha: a)
        }
        return self
    }

    /// 混合颜色
    func mix(with color: UIColor, ratio: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return UIColor(
            red: r1 * (1 - ratio) + r2 * ratio,
            green: g1 * (1 - ratio) + g2 * ratio,
            blue: b1 * (1 - ratio) + b2 * ratio,
            alpha: a1 * (1 - ratio) + a2 * ratio
        )
    }
}
