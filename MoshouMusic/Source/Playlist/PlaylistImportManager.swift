import Foundation

/// 导入任务管理单例
///
/// 维护所有当前活动 + 已完成（最近 N 个）的 Job，提供：
/// - 全局 `activeJobs` 给 banner 展示
/// - 单 Job 的 cancel 入口（外部 UI 调）
/// - 已完成 Job 的清理（避免无限累积）
final class PlaylistImportManager {

    static let shared = PlaylistImportManager()

    private var jobs: [String: PlaylistImportJob] = [:]
    private let maxHistory = 8

    /// 全部 Job（含已完成）—— 给 banner 在用户点击「查看」时显示历史
    var allJobs: [PlaylistImportJob] {
        Array(jobs.values).sorted { $0.createdAt > $1.createdAt }
    }

    /// 当前活动的 Job（running 状态）—— banner 实时展示用
    var activeJobs: [PlaylistImportJob] {
        jobs.values.filter {
            if case .running = $0.phase { return !$0.isCancelled }
            return false
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(onJobFinished(_:)),
            name: PlaylistImportJob.didFinishNotification, object: nil
        )
    }

    func register(job: PlaylistImportJob) {
        jobs[job.jobId] = job
        // 上限保护：丢弃最老的已完成/失败任务
        trimIfNeeded()
    }

    @objc private func onJobFinished(_ note: Notification) {
        guard let job = note.userInfo?[PlaylistImportJob.userInfoKey] as? PlaylistImportJob else { return }
        // 完成后保留 30 秒再清理（让 banner 有时间展示完成态）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if case .running = job.phase { return }
            // 已经在 finalize 之后了；只有非 running 才允许清理
            // 但仍要尊重「flag 状态」——如果用户在 30s 内重新打开这歌单并确认进度，就不要清
            self?.jobs.removeValue(forKey: job.jobId)
        }
    }

    func cancel(jobId: String) {
        jobs[jobId]?.cancel()
    }

    private func trimIfNeeded() {
        guard jobs.count > maxHistory else { return }
        let sorted = jobs.values.sorted { $0.createdAt < $1.createdAt }
        let toRemove = sorted.prefix(jobs.count - maxHistory)
        for j in toRemove where j.phase != .running {
            jobs.removeValue(forKey: j.jobId)
        }
    }
}
