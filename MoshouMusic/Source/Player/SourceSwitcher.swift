import Foundation

/// 自动换源 — 播放失败时按顺序尝试其他音源
/// 换源顺序: kw → tx → mg → wy → kg
class SourceSwitcher {

    /// 默认换源顺序
    private let defaultOrder = ["kw", "tx", "mg", "wy", "kg"]

    /// 切换音源
    /// - Parameters:
    ///   - currentSource: 当前失败的源
    ///   - availableSources: 可用源列表
    ///   - attempt: 尝试回调，返回是否尝试该源
    func switchSource(
        currentSource: String,
        availableSources: [String],
        attempt: @escaping (String) -> Bool
    ) {
        let order = defaultOrder.filter { availableSources.contains($0) }

        guard let currentIndex = order.firstIndex(of: currentSource) else { return }

        // 从当前源后面开始尝试，绕一圈
        for i in 1...order.count {
            let nextIndex = (currentIndex + i) % order.count
            let nextSource = order[nextIndex]

            if nextSource != currentSource {
                Logger.info("尝试换源: \(currentSource) → \(nextSource)")
                if attempt(nextSource) {
                    return
                }
            }
        }

        Logger.error("所有源均失败")
    }
}
