import UIKit

/// 全局"导入进度"悬浮 banner（v1.0.38 P2 新增）
///
/// - 监听 `PlaylistImportJob.didStart/Progress/Finish` 通知
/// - 同一时刻只展示"最顶"的活跃任务（多个任务排队展示队列摘要）
/// - 点击 banner 展开/收起详情：取消按钮、查看对应歌单
/// - banner 永远在主线程显示 / 隐藏；不在主线程的通知不会引起 UI 闪退
final class PlaylistImportProgressBannerController {

    static let shared = PlaylistImportProgressBannerController()

    private weak var hostView: UIView?
    private let banner = PlaylistImportBannerView()
    private var pinnedJob: PlaylistImportJob?
    private var heightConstraint: NSLayoutConstraint?

    private init() {
        // 通知都在 PlaylistImportJob 内部已经派发到主线程了
        NotificationCenter.default.addObserver(
            self, selector: #selector(onStart(_:)),
            name: PlaylistImportJob.didStartNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onProgress(_:)),
            name: PlaylistImportJob.didProgressNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onFinish(_:)),
            name: PlaylistImportJob.didFinishNotification, object: nil
        )
    }

    /// 在 MainTabBarController 的主 view 上挂载这个 banner，让它永远浮在最上层
    func attach(to host: UIView) {
        self.hostView = host
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alpha = 0
        host.addSubview(banner)

        heightConstraint = banner.heightAnchor.constraint(equalToConstant: 0)
        // 顶边固定在状态栏下沿（safeArea.top）；height=0 时完全折叠在屏幕外
        let topConstraint = banner.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            topConstraint,
            heightConstraint!,
        ])
        banner.topConstraintRef = topConstraint
        banner.onCancel = { [weak self] in
            guard let self = self, let job = self.pinnedJob else { return }
            PlaylistImportManager.shared.cancel(jobId: job.jobId)
        }
        banner.onTap = { [weak self] in
            self?.openPlaylistForCurrentJob()
        }
        observeActiveJobs()
    }

    private func observeActiveJobs() {
        let active = PlaylistImportManager.shared.activeJobs
        if let first = active.first {
            pinnedJob = first
            show(for: first)
        } else {
            pinnedJob = nil
            hide()
        }
    }

    private func show(for job: PlaylistImportJob) {
        guard let host = hostView else { return }
        if banner.alpha > 0 && banner.jobId == job.jobId {
            // 已经显示中，只更新进度
            banner.update(platform: job.platformName, stage: job.lastProgress.stage,
                          current: job.lastProgress.current, total: job.lastProgress.total,
                          matched: job.lastProgress.matched,
                          playlistName: job.playlistName)
            return
        }
        banner.bindJob(job)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.banner.alpha = 1
            self.heightConstraint?.constant = 60
            host.layoutIfNeeded()
        }
    }
    private func hide() {
        guard let host = hostView else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.banner.alpha = 0
            self.heightConstraint?.constant = 0
            host.layoutIfNeeded()
        }
    }

    @objc private func onStart(_ note: Notification) {
        guard let job = note.userInfo?[PlaylistImportJob.userInfoKey] as? PlaylistImportJob else { return }
        if pinnedJob == nil { show(for: job) }
    }
    @objc private func onProgress(_ note: Notification) {
        guard let job = note.userInfo?[PlaylistImportJob.userInfoKey] as? PlaylistImportJob,
              job === pinnedJob else { return }
        banner.update(platform: job.platformName, stage: job.lastProgress.stage,
                      current: job.lastProgress.current, total: job.lastProgress.total,
                      matched: job.lastProgress.matched,
                      playlistName: job.playlistName)
    }
    @objc private func onFinish(_ note: Notification) {
        // 当前任务结束：观察下一个活跃任务；如果全部完成，1.2 秒后隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let active = PlaylistImportManager.shared.activeJobs
            if let next = active.first {
                self.pinnedJob = next
                self.show(for: next)
            } else {
                // 本任务已经 finalize；显示一个"完成"状态，再隐藏
                if let lastJob = note.userInfo?[PlaylistImportJob.userInfoKey] as? PlaylistImportJob {
                    self.banner.showFinished(playlistName: lastJob.playlistName,
                                             success: lastJob)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.pinnedJob = nil
                    self.hide()
                }
            }
        }
    }

    private func openPlaylistForCurrentJob() {
        guard let job = pinnedJob else { return }
        // 通过通知让感兴趣的页面（播放页 / 我的歌单页）切换到对应歌单
        NotificationCenter.default.post(
            name: .openPlaylistDetailRequested,
            object: nil,
            userInfo: ["playlistId": job.playlistId]
        )
    }
}

extension Notification.Name {
    static let openPlaylistDetailRequested = Notification.Name("OpenPlaylistDetailRequested")
}

// MARK: - Banner View

final class PlaylistImportBannerView: UIView {

    private(set) var jobId: String?
    var topConstraintRef: NSLayoutConstraint?

    private let titleLabel = UILabel()
    private let progressLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let progressBar = UIProgressView(progressViewStyle: .bar)

    var onCancel: (() -> Void)?
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = Theme.cardBg
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        clipsToBounds = false

        titleLabel.font = Theme.labelLarge
        titleLabel.textColor = Theme.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        progressLabel.font = Theme.bodySmall
        progressLabel.textColor = Theme.subtext
        progressLabel.numberOfLines = 2
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressLabel)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        cancelButton.backgroundColor = Theme.error
        cancelButton.layer.cornerRadius = 6
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelButton)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = Theme.primary
        addSubview(progressBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            progressLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            progressLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            cancelButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            cancelButton.widthAnchor.constraint(equalToConstant: 64),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        addGestureRecognizer(tap)
    }

    func bindJob(_ job: PlaylistImportJob) {
        jobId = job.jobId
        titleLabel.text = "导入歌单：\(job.playlistName)"
        progressLabel.text = "\(job.platformName) · 准备中…"
        progressBar.setProgress(0, animated: false)
        cancelButton.isHidden = false
    }

    func update(platform: String, stage: String, current: Int, total: Int,
                matched: Int, playlistName: String) {
        titleLabel.text = "导入歌单：\(playlistName)"
        if total > 0 {
            let pct = Float(current) / Float(total)
            progressBar.setProgress(pct, animated: true)
            progressLabel.text = "\(platform) · \(stage) · 命中 \(matched)"
        } else {
            progressLabel.text = "\(platform) · \(stage)"
        }
    }

    func showFinished(playlistName: String, success job: PlaylistImportJob) {
        titleLabel.text = "导入完成：\(playlistName)"
        switch job.phase {
        case .finished(let matched, let total):
            progressLabel.text = "命中 \(matched)/\(total) 首"
            progressBar.setProgress(1, animated: true)
        case .failed(let reason):
            progressLabel.text = "失败：\(reason)"
            progressBar.setProgress(0, animated: false)
        case .cancelled:
            progressLabel.text = "已取消"
            progressBar.setProgress(0, animated: false)
        default:
            progressLabel.text = ""
        }
        cancelButton.isHidden = true
        progressBar.isHidden = false
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func viewTapped() { onTap?() }
}
