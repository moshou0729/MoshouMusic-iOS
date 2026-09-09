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
        tip.text = "复现问题（弹窗后不续播 / 悬浮不刷新）后回到本页点「复制全部」发给开发者；日志保留最近 500 行。"
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

    private func reload() {
        let text = Logger.dumpText()
        textView.text = text.isEmpty ? "（暂无日志）" : text
        // 滚到底部（最新日志在最后）
        if !text.isEmpty {
            textView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1))
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = Logger.dumpText()
        let alert = UIAlertController(title: "已复制",
                                      message: "已复制 \(Logger.lineCount) 行日志到剪贴板",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}
