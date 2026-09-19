import UIKit

/// 悬浮窗主题（可更换皮肤）
///
/// - `original`（纯色）：原始默认皮肤，保持旧版「用户自选纯色背景 + 无车图」行为，
///   与 GT 主题完全独立，互不干扰。
/// - `gtA`..`gtF`：领克 GT 六套方案（贯穿光刃 / 顶峰蓝液态金属 / 性能模式 / 前脸正视 / 侧面剪影 / 行驶进度）
/// - `newA`..`newD`：新四套方案（窄条 / 大卡 / 车头窗 / 极简）
///
/// 关键区分：**纯色主题是「背景 = 用户纯色」；GT/新主题是「背景 = 各自 GT 渐变 + 星火黄贯穿光带」，
/// 车图只是外观融入的一层装饰**，两者视觉上完全分开，不会「纯色 + 车」糊在一起。
/// 渲染逻辑集中在 `FloatingLyricsView.applyTheme(_:model:)`，新增主题只改本文件。
enum FloatingTheme: String, CaseIterable {
    case original
    case gtA, gtB, gtC, gtD, gtE, gtF
    case newA, newB, newC, newD

    /// 设置页 / 预览展示名
    var displayName: String {
        switch self {
        case .original: return "纯色"
        case .gtA: return "GT·贯穿光刃"
        case .gtB: return "GT·顶峰蓝"
        case .gtC: return "GT·性能模式"
        case .gtD: return "GT·前脸正视"
        case .gtE: return "GT·侧面剪影"
        case .gtF: return "GT·行驶进度"
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
        case .original, .gtB, .gtC, .gtE, .gtF, .newA, .newB, .newD:
            return .side
        case .gtA, .gtD, .newC:
            return .front
        }
    }

    /// 车图在悬浮窗中的摆放方式
    /// v1.0.179：newA/newB/newC/newD 严格对齐 HTML 的 A/B/C/D 四种布局
    var carPlacement: CarPlacement {
        switch self {
        case .original:                 return .none
        case .gtA:                      return .backdrop      // GT·贯穿光刃：车头铺底
        case .gtB:                      return .bottom        // GT·顶峰蓝：侧身贴底
        case .gtC, .gtE:                return .right         // GT 侧身类：右侧分栏
        case .gtD:                      return .card          // GT·前脸正视：顶部卡片
        case .gtF, .newA, .newD:        return .cursorBottom  // 行驶进度 / 窄条 / 极简：车=游标
        case .newB:                     return .rightLarge    // 大卡：侧身大图占右侧
        case .newC:                     return .frontLeft     // 车头窗：车头靠左
        }
    }

    /// 歌词布局：覆盖式（前脸/背景/游标类）、左分栏（车在右）、右分栏（车在左）
    var lyricsLayout: LyricsLayout {
        switch self {
        case .gtC, .gtE, .newB:         return .leftColumn    // 车在右，歌词在左
        case .newC:                     return .rightColumn   // 车头靠左，歌词在右
        default:                        return .overlay
        }
    }

    /// 贯穿光带颜色：GT 签名「星火黄」，所有 GT/新主题统一；纯色主题不使用
    var bladeColor: UIColor {
        self == .original ? .white : UIColor(hex: 0xF2D024)
    }

    /// 车图是否作为「进度游标」沿光带移动（行驶进度 / 窄条 / 极简）
    var carFollowsProgress: Bool {
        self == .gtF || self == .newA || self == .newD
    }

    /// 车头是否朝右（行驶方向）：游标/行驶类主题把侧影水平翻转，让车头朝右
    var carFacesRight: Bool {
        self == .gtF || self == .newA || self == .newD
    }

    /// 是否显示右上角小号车头徽标（窄条 / 极简，呼应参考稿角标）
    var badgeFront: Bool {
        self == .newA || self == .newD
    }

    /// 歌词区底部留白（给底部「光带 + 车游标」让位）；游标类主题需要
    var lyricsBottomInset: CGFloat {
        (self == .gtF || self == .newA || self == .newD) ? 64 : 0
    }

    /// 车图透明度（原图多为实拍抠图，压一点避免抢歌词可读性）
    var carAlpha: CGFloat {
        switch self {
        case .original:        return 0
        case .gtA, .newC, .newA: return 0.9
        default:               return 0.95
        }
    }

    /// 强调色：用于悬浮窗描边 + 控制条点缀，让不同主题一眼可辨
    var accent: UIColor {
        switch self {
        case .original: return .white
        case .gtA: return UIColor(hex: 0x00E5FF)   // 青色光刃
        case .gtB: return UIColor(hex: 0x2E6FB8)   // 顶峰蓝
        case .gtC: return UIColor(hex: 0xE53935)   // 性能红
        case .gtD: return UIColor(hex: 0xFFC107)   // 前脸金
        case .gtE: return UIColor(hex: 0x26A69A)   // 剪影青绿
        case .gtF: return UIColor(hex: 0xFB8C00)   // 行驶橙
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
    /// - `.original` → `.solid`：沿用用户自选纯色，不做任何 GT 处理（与 GT 主题彻底分开）
    /// - 其余 → `.gradient(...)`：各自 GT 视觉的渐变底，是「GT 主题」与「纯色」最直观的区分
    var background: ThemeBackground {
        switch self {
        case .original:
            return .solid
        case .gtA:  // 贯穿光刃：暗顶峰蓝，星火黄光带做主视觉
            return .gradient([UIColor(hex: 0x0A1E38), UIColor(hex: 0x071A32)])
        case .gtB:  // 顶峰蓝液态金属：三层递变深蓝
            return .gradient([UIColor(hex: 0x0E3A6E), UIColor(hex: 0x0A2A50), UIColor(hex: 0x071A32)])
        case .gtC:  // 性能模式：碳纤维近黑底
            return .gradient([UIColor(hex: 0x14171A), UIColor(hex: 0x212730)])
        case .gtD:  // GT 前脸正视：机盖分缝的蓝调渐变
            return .gradient([UIColor(hex: 0x12365E), UIColor(hex: 0x0A2440), UIColor(hex: 0x071A32)])
        case .gtE:  // GT 侧面剪影：卡面深蓝渐变
            return .gradient([UIColor(hex: 0x0E2C4C), UIColor(hex: 0x071A32)])
        case .gtF:  // GT 行驶进度：横向蓝调渐变，车=游标
            return .gradient([UIColor(hex: 0x0E2C4C), UIColor(hex: 0x071A32)])
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
/// - `gradient`：GT 渐变背景（多段色，自上而下渐变），是 GT 主题区别于纯色主题的核心
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
