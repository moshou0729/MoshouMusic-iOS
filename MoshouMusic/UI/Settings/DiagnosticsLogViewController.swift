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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "复制全部", style: .plain, target: self, action: #selector(copyTapped))

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
        tip.text = "复现问题后回本页点「复制全部」：顶部「跨进程事件」段在进程被杀后依然保留，是排查熄屏停播/被杀的关键现场。"
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

    @objc private func copyTapped() {
        let full = compositeText()
        UIPasteboard.general.string = full
        let alert = UIAlertController(title: "已复制",
                                      message: "已复制日志到剪贴板（含跨进程事件段）",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}
