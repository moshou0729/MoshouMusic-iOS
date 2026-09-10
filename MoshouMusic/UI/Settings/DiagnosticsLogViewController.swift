import UIKit

/// 诊断日志页 —— 前台直接展示运行日志（音频会话激活失败 / 中断恢复 / 悬浮窗注册等），
/// 一键复制全部日志反馈问题。v1.0.116
final class DiagnosticsLogViewController: UIViewController {

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "诊断日志与恢复记录"
        view.backgroundColor = Theme.bg

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(closeTapped))
        // v1.0.129：拆两个复制 —— 会话缓冲 500 行太长导致剪贴板复制失败，
        // 排查所需的只是「跨进程事件 + 系统报告」，故「复制关键」为首选
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "复制关键", style: .plain, target: self, action: #selector(copyKeyTapped)),
            UIBarButtonItem(title: "复制全部", style: .plain, target: self, action: #selector(copyTapped)),
            UIBarButtonItem(title: "清空日志", style: .plain, target: self, action: #selector(clearTapped)),
        ]

        textView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .secondarySystemBackground
        textView.isEditable = false
        textView.layer.cornerRadius = 10
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        let tip = UILabel()
        tip.text = "复现问题后点「复制关键」发开发者（跨进程事件+系统报告，进程被杀也保留）；「复制全部」含 500 行会话日志，太长可能复制失败。"
        tip.font = UIFont.systemFont(ofSize: 12)
        tip.textColor = .tertiaryLabel
        tip.numberOfLines = 0
        tip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tip)
        NSLayoutConstraint.activate([
            tip.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            tip.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            tip.bottomAnchor.constraint(equalTo: textView.topAnchor, constant: -6),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// v1.0.129：关键日志 = 跨进程事件 + 系统报告（排查被杀/停播所需的全部内容，
    /// 不含 500 行会话缓冲 —— 那段太长会导致剪贴板复制失败）
    private func keyText() -> String {
        var full = ""
        // v1.0.130：只取最近 80 条持久化事件（控制剪贴板体积，保底可复制）
        let persist = Logger.dumpPersistText(maxLines: 80)
        full += "════ 跨进程事件（进程被杀也保留）════\n" + (persist.isEmpty ? "（暂无）" : persist)
        let doc = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        if let doc = doc,
           let rep = try? String(contentsOfFile: doc + "/system_report.log", encoding: .utf8),
           !rep.isEmpty {
            full += "\n\n════ 系统报告（终止原因取证）════\n" + rep
        }
        return full
    }

    /// v1.0.126：持久化事件在前、本次会话在后（持久化段跨进程存活，是「上次怎么死的」的现场）
    private func compositeText() -> String {
        let persist = Logger.dumpPersistText()
        let text = Logger.dumpText()
        var full = ""
        if !persist.isEmpty {
            full += "════ 跨进程事件（进程被杀也保留）════\n" + persist + "\n\n"
        }
        full += "════ 本次会话日志（最近 500 行）════\n" + (text.isEmpty ? "（暂无日志）" : text)
        // v1.0.128：系统崩溃/内存回收报告（被杀原因的最终答案在这段里）
        let doc = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        if let doc = doc,
           let rep = try? String(contentsOfFile: doc + "/system_report.log", encoding: .utf8),
           !rep.isEmpty {
            full += "\n\n════ 系统报告（终止原因取证）════\n" + rep
        }
        return full
    }

    private func reload() {
        let full = compositeText()
        textView.text = full
        if !full.isEmpty {
            textView.scrollRangeToVisible(NSRange(location: (full as NSString).length - 1, length: 1))
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func copyKeyTapped() {
        let full = keyText()
        UIPasteboard.general.string = full
        let lines = full.split(separator: "\n").count
        let alert = UIAlertController(title: "已复制关键日志",
                                      message: "共 \(lines) 行 / 约 \(full.count) 字符（跨进程事件 + 系统报告），直接粘贴发给开发者",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

    @objc private func copyTapped() {
        let full = compositeText()
        UIPasteboard.general.string = full
        let alert = UIAlertController(title: "已复制全部",
                                      message: "内容较长，若粘贴后不完整请改用「复制关键」",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

    /// v1.0.132：清空全部日志（跨进程事件 + 会话缓冲 + 系统报告摘要），防止历史现场累积挤占限额
    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: "清空全部日志？",
            message: "将清空跨进程事件、本次会话日志与系统报告摘要，清空前请先「复制关键」留存现场。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { _ in
            Logger.clearPersisted()
            Logger.clearBuffer()
            let doc = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            if let doc = doc {
                try? FileManager.default.removeItem(atPath: doc + "/system_report.log")
            }
            Logger.persist("日志已清空（持久化+会话+系统报告摘要），此后为新现场基线")
            self.reload()
        })
        present(alert, animated: true)
    }
}
