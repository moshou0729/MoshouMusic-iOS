import Foundation

/// 单个导入任务的运行时状态（详情页/搜索页/歌单页触发导入后，后台跑，进度通过 Notification 上报）
///
/// ⚠️ 通知按需加入 userInfo（避免每次都 N 次 post 通知），banner 监听者按需过滤自己的 jobId。
/// 通知改在主线程派发（详情参 .didProgressNotification 注释）。
final class PlaylistImportJob {

    enum Phase: Equatable {
        case running           // 拉取/匹配进行中
        case finished(matched: Int, total: Int)   // 完成（成功/部分匹配）
        case failed(String)    // 失败（reason 是给用户看的中文）
        case cancelled         // 用户取消
    }

    let jobId: String
    let playlistId: String
    var playlistName: String
    let source: String                // wy / tx / kg
    let sourceListId: String
    private(set) var platformName: String
    let createdAt: Date

    private(set) var phase: Phase = .running
    private(set) var lastProgress: (stage: String, current: Int, total: Int, matched: Int) =
        ("等待中", 0, 0, 0)

    private(set) var isCancelled: Bool = false

    /// 用户主动取消
    func cancel() {
        isCancelled = true
    }

    init(playlistId: String, playlistName: String, source: String, sourceListId: String,
         platformName: String, createdAt: Date = Date()) {
        self.jobId = UUID().uuidString
        self.playlistId = playlistId
        self.playlistName = playlistName
        self.source = source
        self.sourceListId = sourceListId
        self.platformName = platformName
        self.createdAt = createdAt
    }

    // MARK: - 通知

    enum NotificationEvent {
        case didStart
        case didProgress
        case didFinish
    }

    static let userInfoKey = "job"
    static let didStartNotification = Notification.Name("PlaylistImportJobDidStart")
    static let didProgressNotification = Notification.Name("PlaylistImportJobDidProgress")
    static let didFinishNotification = Notification.Name("PlaylistImportJobDidFinish")

    func post(_ event: NotificationEvent) {
        // 统一在主线程派发：观察者（全局 banner / 歌单页 / 详情页）要做 UI / 模型读写，
        // 必须在主线程，否则会触发布局引擎崩溃。
        DispatchQueue.main.async {
            let name: Notification.Name
            switch event {
            case .didStart:    name = Self.didStartNotification
            case .didProgress: name = Self.didProgressNotification
            case .didFinish:   name = Self.didFinishNotification
            }
            NotificationCenter.default.post(name: name, object: nil, userInfo: [Self.userInfoKey: self])
        }
    }

    /// 后台线程上报进度（内部自动节流 + 切主线程 post 通知）
    func reportProgress(platform: String, stage: String, current: Int, total: Int, matched: Int) {
        lastProgress = (stage, current, total, matched)
        platformName = platform
        post(.didProgress)
    }

    /// 完成（成功 / 失败 / 取消统一入口）
    func finalize(success total: Int, matched: Int) {
        phase = .finished(matched: matched, total: total)
        post(.didFinish)
    }
    func finalize(failure error: Error) {
        phase = .failed(error.localizedDescription)
        post(.didFinish)
    }
}
