import UIKit

/// 悬浮窗主题（可更换皮肤）
///
/// - `original`（纯色）：原始默认皮肤，保持旧版「用户自选纯色背景 + 无车图」行为。
/// - `newA`..`newD`：新四套方案（窄条 / 大卡 / 车头窗 / 极简）
///
/// 渲染逻辑集中在 `FloatingLyricsView.applyTheme(_:model:)`，新增主题只改本文件。
enum FloatingTheme: String, CaseIterable {
    case original
    case newA, newB, newC, newD

    /// 设置页 / 预览展示名
    var displayName: String {
        switch self {
        case .original: return "纯色"
        case .newA: return "窄条"
        case .newB: return "大卡"
        case .newC: return "车头窗"
        case .newD: return "极简"
        }
    }

    /// 是否使用车图装饰（original 不用）
    var usesCarDecoration: Bool { self != .original }

    /// 使用车头正视图还是侧面剪影图
    /// v1.0.179：四种布局对齐参考稿 lynk_skin_studio.html
    ///   A 窄条 → 侧身游标 / B 大卡 → 侧身大背景 / C 车头窗 → 车头正视 / D 极简 → 侧身游标
    var carOrientation: CarOrientation {
        switch self {
        case .original, .newA, .newB, .newD:
            return .side
        case .newC:
            return .front
        }
    }

    /// 车图在悬浮窗中的摆放方式
    /// v1.0.181：newA/newB/newC/newD 严格对齐用户确认的设计稿
    ///   A 窄条   → 左侧封面 + 右侧歌名歌手，底部进度条 + 车侧影游标
    ///   B 大卡   → 左上三行歌词 + 车左侧空白歌名歌手，右下大车，底部粗进度条
    ///   C 车头窗 → 左侧车头正视，右侧歌名歌手 + 歌词 + 进度条
    ///   D 极简   → 纯底部进度条 + 车侧影游标 + 右侧车头徽标
    var carPlacement: CarPlacement {
        switch self {
        case .original:                 return .none
        case .newA, .newD:             return .cursorBottom  // 窄条 / 极简：车=游标
        case .newB:                    return .bottomRight   // 大卡：车大图占右下
        case .newC:                    return .frontLeft     // 车头窗：车头靠左
        }
    }

    /// 是否为 v1.0.181 四套新版卡片主题
    var isNewTheme: Bool {
        switch self {
        case .newA, .newB, .newC, .newD: return true
        default: return false
        }
    }

    /// 新版主题固定窗口高度（不让用户手动拉伸）；其余主题返回 nil（沿用用户设置）
    var windowHeight: CGFloat? {
        switch self {
        case .newA: return 88
        case .newB: return 260
        case .newC: return 150
        case .newD: return 58
        default: return nil
        }
    }

    /// 新版主题固定窗口宽度（不让用户手动拉伸）；其余主题返回 nil（沿用用户设置）
    var windowWidth: CGFloat? {
        switch self {
        case .newA: return 360
        case .newB: return 320
        case .newC: return 340
        case .newD: return 320
        default: return nil
        }
    }

    /// 新版主题的深色卡片背景（设计稿统一深色卡片）；original 返回 nil（沿用用户纯色），其余非纯色返回 nil（用渐变层）
    var solidBackgroundColor: UIColor? {
        switch self {
        case .newA, .newB, .newC, .newD: return UIColor(hex: 0x141418)
        default: return nil
        }
    }

    /// 歌词布局：覆盖式（前脸/背景/游标类/大卡）、左分栏（车在右）、右分栏（车在左）
    var lyricsLayout: LyricsLayout {
        switch self {
        case .newC:                     return .rightColumn   // 车头靠左，歌词在右
        default:                        return .overlay
        }
    }

    /// 进度条品牌渐变：设计稿统一的黄→青蓝（所有新版主题）
    var progressGradient: [UIColor] {
        [UIColor(hex: 0xE5FF00), UIColor(hex: 0x00E5FF)]
    }

    /// 进度条底轨颜色：深色半透明，让渐变填充更突出
    var progressTrackColor: UIColor {
        UIColor(hex: 0x2A2A2A).withAlphaComponent(0.65)
    }

    /// 贯穿光带颜色（保留兼容）：GT 签名「星火黄」
    var bladeColor: UIColor {
        self == .original ? .white : UIColor(hex: 0xF2D024)
    }

    /// 车图是否作为「进度游标」沿光带移动（行驶进度 / 窄条 / 极简）
    var carFollowsProgress: Bool {
        self == .newA || self == .newD
    }

    /// 车头是否朝右（行驶方向）：游标/行驶类主题把侧影水平翻转，让车头朝右
    var carFacesRight: Bool {
        self == .newA || self == .newD
    }

    /// 是否显示右上角小号车头徽标（仅极简主题，呼应参考稿角标）
    var badgeFront: Bool {
        self == .newD
    }

    /// 歌词区底部留白（给底部「光带 + 车游标」让位）；游标类主题需要
    var lyricsBottomInset: CGFloat {
        (self == .newA || self == .newD) ? 64 : 0
    }

    /// 车图透明度（原图多为实拍抠图，压一点避免抢歌词可读性）
    var carAlpha: CGFloat {
        switch self {
        case .original:        return 0
        case .newC, .newA: return 0.9
        default:               return 0.95
        }
    }

    /// 强调色：用于悬浮窗描边 + 控制条点缀，让不同主题一眼可辨
    var accent: UIColor {
        switch self {
        case .original: return .white
        case .newA: return UIColor(hex: 0xAB47BC)  // 紫
        case .newB: return UIColor(hex: 0x5C6BC0)  // 靛
        case .newC: return UIColor(hex: 0xEC407A)  // 粉
        case .newD: return UIColor(hex: 0x78909C)  // 蓝灰
        }
    }

    /// 悬浮窗描边宽度（original 为 0 = 无描边）
    var accentBorderWidth: CGFloat {
        self == .original ? 0 : 1.5
    }

    /// 背景样式：
    /// - `.original` → `.solid`：沿用用户自选纯色，不与渐变主题混用
    /// - 其余 → `.gradient(...)`：各自视觉的渐变底（新版主题实际以纯深色呈现，此处仅作兜底）
    var background: ThemeBackground {
        switch self {
        case .original:
            return .solid
        case .newA: // 窄条：紫调暗底
            return .gradient([UIColor(hex: 0x2A1A3E), UIColor(hex: 0x140D1F)])
        case .newB: // 大卡：靛调暗底
            return .gradient([UIColor(hex: 0x1B1F3A), UIColor(hex: 0x0E1130)])
        case .newC: // 车头窗：品红暗底
            return .gradient([UIColor(hex: 0x3A1626), UIColor(hex: 0x1A0B14)])
        case .newD: // 极简：蓝灰暗底
            return .gradient([UIColor(hex: 0x1C2630), UIColor(hex: 0x0E141A)])
        }
    }

    /// 是否显示「星火黄贯穿光带」（GT 签名元素）：纯色主题不显示，GT/新主题显示
    var showsLightBlade: Bool {
        self != .original
    }
}

/// 车图朝向
enum CarOrientation: Int {
    case front = 0
    case side = 1
}

/// 车图摆放方式
enum CarPlacement: Int {
    case none = 0
    case backdrop = 1   // 整窗铺底（车头/侧身居中铺满）
    case bottom = 2     // 贴底
    case right = 3      // 贴右（侧身类，歌词在左）
    case card = 4       // 顶部卡片区
    case rightLarge = 5 // 大卡：侧身大图占右侧，纵向居中接近铺满
    case frontLeft = 6  // 车头窗：车头正视图靠左，右半留给歌词
    case cursorBottom = 7 // 行驶/窄条/极简：车=游标，沿底部光带随进度横向移动
    case bottomLarge = 8 // 大卡（旧）：车大图占中下部，歌词在顶部
    case bottomRight = 9  // v1.0.181 大卡：车大图占右下角
}

/// 歌词布局
enum LyricsLayout: Int {
    case overlay = 0    // 覆盖式：居中跨整窗，车图作背景装饰 / 游标类主题
    case leftColumn = 1 // 左侧分栏：歌词缩在左半，车图在右侧（侧身/剪影/大卡）
    case rightColumn = 2 // 右侧分栏：歌词在右半，车头图在左（车头窗）
}

/// 悬浮窗背景样式
///
/// - `solid`：纯色背景（仅 `original` 用，直接沿用用户设置的纯色）
/// - `gradient`：渐变背景（多段色，自上而下渐变），用于非纯色主题
enum ThemeBackground {
    case solid
    case gradient([UIColor])
}

/// 可选车型（与 lynk_skin_studio.html 的 14 款一致）
///
/// 资源命名统一为 `car_<norm>_front.png` / `car_<norm>_side.png`，
/// 放在 `MoshouMusic/Resources/FloatingCars/`（随主包打包）。
/// ⚠️ 设备端 bundle 区分大小写，故资源名全部小写；"05+" / "10+" 的 "+" 替换为 "p"。
struct FloatingCarModel {
    let id: String
    let name: String
    let frontAsset: String
    let sideAsset: String

    /// 全部车型（顺序即设置页展示顺序）
    static let all: [FloatingCarModel] = [
        FloatingCarModel(id: "gt",   name: "领克 GT",   frontAsset: "car_gt_front",   sideAsset: "car_gt_side"),
        FloatingCarModel(id: "01",   name: "领克 01",   frontAsset: "car_01_front",   sideAsset: "car_01_side"),
        FloatingCarModel(id: "02hb", name: "领克 02 HB", frontAsset: "car_02hb_front", sideAsset: "car_02hb_side"),
        FloatingCarModel(id: "03",   name: "领克 03",   frontAsset: "car_03_front",   sideAsset: "car_03_side"),
        FloatingCarModel(id: "05+",  name: "领克 05+",  frontAsset: "car_05p_front",  sideAsset: "car_05p_side"),
        FloatingCarModel(id: "06",   name: "领克 06",   frontAsset: "car_06_front",   sideAsset: "car_06_side"),
        FloatingCarModel(id: "07",   name: "领克 07",   frontAsset: "car_07_front",   sideAsset: "car_07_side"),
        FloatingCarModel(id: "07gt", name: "领克 07 GT", frontAsset: "car_07gt_front", sideAsset: "car_07gt_side"),
        FloatingCarModel(id: "08",   name: "领克 08",   frontAsset: "car_08_front",   sideAsset: "car_08_side"),
        FloatingCarModel(id: "09",   name: "领克 09",   frontAsset: "car_09_front",   sideAsset: "car_09_side"),
        FloatingCarModel(id: "10",   name: "领克 10",   frontAsset: "car_10_front",   sideAsset: "car_10_side"),
        FloatingCarModel(id: "10+",  name: "领克 10+",  frontAsset: "car_10p_front",  sideAsset: "car_10p_side"),
        FloatingCarModel(id: "20",   name: "领克 Z20",  frontAsset: "car_20_front",   sideAsset: "car_20_side"),
        FloatingCarModel(id: "900",  name: "领克 900",  frontAsset: "car_900_front",  sideAsset: "car_900_side"),
    ]

    /// 默认车型（GT）
    static let `default` = all.first { $0.id == "gt" } ?? all[0]

    /// 按 id 取车型
    static func model(for id: String) -> FloatingCarModel? {
        all.first { $0.id == id }
    }

    /// 取对应朝向的车图（bundle 内 PNG，无图返回 nil → 该主题退化为纯色背景）
    /// 用 path(forResource:) 递归搜索，避免资源在 bundle 内的子目录层级影响加载。
    func image(orientation: CarOrientation) -> UIImage? {
        let name = orientation == .front ? frontAsset : sideAsset
        if let path = Bundle.main.path(forResource: name, ofType: "png"),
           let img = UIImage(contentsOfFile: path) {
            return img
        }
        return UIImage(named: name)
    }
}
