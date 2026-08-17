import Foundation

/// 下载管理器 — 后台下载音乐文件
class MusicDownloadManager: NSObject {

    static let shared = MusicDownloadManager()

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        ensureDownloadDirectory()
    }

    private func ensureDownloadDirectory() {
        let dir = ConfigStore.shared.downloadsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 下载

    func download(
        song: Song,
        quality: String = "320k",
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloadId = song.id

        guard downloadTasks[downloadId] == nil else {
            completion(.failure(NSError(
                domain: "DownloadManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "已在下载队列中"]
            )))
            return
        }

        ScriptEngine.shared.getMusicUrl(
            source: song.source,
            songId: song.songmid,
            quality: quality
        ) { [weak self] result in
            switch result {
            case .success(let url):
                guard let self = self,
                      let downloadURL = URL(string: url) else {
                    completion(.failure(NSError(
                        domain: "DownloadManager",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "无效的下载链接"]
                    )))
                    return
                }

                let task = self.session.downloadTask(with: downloadURL)
                self.downloadTasks[downloadId] = task
                self.progressHandlers[downloadId] = progress
                self.completionHandlers[downloadId] = completion
                task.resume()

                Logger.info("开始下载: \(song.name)")

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func cancelDownload(songId: String) {
        downloadTasks[songId]?.cancel()
        downloadTasks.removeValue(forKey: songId)
        progressHandlers.removeValue(forKey: songId)
        completionHandlers.removeValue(forKey: songId)
    }

    // MARK: - 文件路径

    func localPath(for song: Song) -> URL {
        let fileName = "\(song.id).mp3"
        return ConfigStore.shared.downloadsDirectory.appendingPathComponent(fileName)
    }

    func isDownloaded(_ song: Song) -> Bool {
        return FileManager.default.fileExists(atPath: localPath(for: song).path)
    }
}

// MARK: - URLSessionDownloadDelegate

extension MusicDownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 找到对应的下载 ID
        guard let downloadId = downloadTasks.first(where: { $0.value === downloadTask })?.key else {
            return
        }

        let destURL = ConfigStore.shared.downloadsDirectory.appendingPathComponent("\(downloadId).mp3")

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)

            downloadTasks.removeValue(forKey: downloadId)
            progressHandlers.removeValue(forKey: downloadId)
            completionHandlers[downloadId]?(.success(destURL))
            completionHandlers.removeValue(forKey: downloadId)

            Logger.info("下载完成: \(downloadId)")

        } catch {
            completionHandlers[downloadId]?(.failure(error))
            completionHandlers.removeValue(forKey: downloadId)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let downloadId = downloadTasks.first(where: { $0.value === downloadTask })?.key else {
            return
        }

        let progress = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
        progressHandlers[downloadId]?(progress)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error,
              let downloadId = downloadTasks.first(where: { $0.value === task })?.key else {
            return
        }

        downloadTasks.removeValue(forKey: downloadId)
        progressHandlers.removeValue(forKey: downloadId)
        completionHandlers[downloadId]?(.failure(error))
        completionHandlers.removeValue(forKey: downloadId)

        Logger.error("下载失败: \(error.localizedDescription)")
    }
}
