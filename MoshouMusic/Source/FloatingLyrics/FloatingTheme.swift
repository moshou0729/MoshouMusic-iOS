import UIKit

/// 悬浮窗主题（可更换皮肤）
///
/// - `original`：原始默认皮肤（无车图，纯色背景，保持旧版行为）
/// - `gtA`..`gtF`：领克 GT 六套方案（贯穿光刃 / 顶峰蓝液态金属 / 性能模式 / 前脸正视 / 侧面剪影 / 行驶进度）
/// - `newA`..`newD`：新四套方案（窄条 / 大卡 / 车头窗 / 极简）
///
/// 全部为数据驱动：每个主题只描述「车图朝向 + 摆放 + 强调色」，渲染逻辑统一在
/// `FloatingLyricsView.applyTheme(_:model:)` 一处，新增主题无需改动渲染代码。
enum FloatingTheme: String, CaseIterable {
    case original
    case gtA, gtB, gtC, gtD, gtE, gtF
    case newA, newB, newC, newD

    /// 设置页 / 预览展示名
    var displayName: String {
        switch self {
        case .original: return "默认"
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
    var carOrientation: CarOrientation {
        switch self {
        case .original, .gtB, .gtC, .gtE, .gtF, .newD:
            return .side
        case .gtA, .gtD, .newA, .newB, .newC:
            return .front
        }
    }

    /// 车图在悬浮窗中的摆放方式
    var carPlacement: CarPlacement {
        switch self {
        case .original:            return .none
        case .gtA, .newC, .newA:   return .backdrop
        case .gtB, .gtE, .newD:    return .bottom
        case .gtC, .gtF:           return .right
        case .gtD, .newB:          return .card
        }
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
    case right = 3      // 贴右
    case card = 4       // 顶部卡片区
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
