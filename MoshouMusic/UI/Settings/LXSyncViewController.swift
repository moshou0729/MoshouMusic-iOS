import UIKit

/// LX Music 桌面版同步设置页
/// v1.0.17 修复：4 张卡片改用 UIStackView 堆叠（修复所有卡片全叠顶部看不见 URL 输入的 bug）
/// v1.0.18+ 将基于 LX 桌面版 WebSocket RPC（message2call）实现完整双向同步
class LXSyncViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let containerStack = UIStackView()

    private let urlField = UITextField()
    private let statusBadge = UILabel()
    private let detailLabel = UILabel()
    private let testButton = UIButton(type: .system)
    private let enableSwitch = UISwitch()
    private let saveButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "LX 数据同步"
        view.backgroundColor = Theme.bg

        setupUI()
        refreshStatus(LXSyncService.shared.status)
        urlField.text = ConfigStore.shared.lxSyncServerURL
        enableSwitch.isOn = ConfigStore.shared.lxSyncEnabled

        NotificationCenter.default.addObserver(
            self, selector: #selector(lxStateChanged),
            name: LXSyncService.stateChangedNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag

        // 一个 vertical stack 装所有卡片 — 自动按顺序堆叠，不会再叠在一起
        containerStack.axis = .vertical
        containerStack.spacing = 16
        containerStack.alignment = .fill
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(containerStack)

        // ===== 卡片 1：URL 输入（首屏第一张，可见） =====
        let urlCard = makeCard(
            title: "同步服务地址",
            subtitle: "LX 桌面版 v2.4+ / 独立版 sync-server v2.0+"
        )
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "http://192.168.1.5:23332"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .done
        urlField.font = Theme.bodyMedium
        urlField.delegate = self
        urlCard.stack.addArrangedSubview(urlField)
        urlField.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let urlHint = UILabel()
        urlHint.text = "桌面端：「设置 → 数据同步 → 服务端模式」；URL 在桌面版同步设置里显示。"
        urlHint.font = Theme.bodySmall
        urlHint.textColor = Theme.subtext
        urlHint.numberOfLines = 0
        urlCard.stack.addArrangedSubview(urlHint)

        saveButton.setTitle("保存地址", for: .normal)
        saveButton.titleLabel?.font = Theme.titleSmall
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = Theme.success
        saveButton.layer.cornerRadius = Theme.cornerMedium
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        urlCard.stack.addArrangedSubview(saveButton)
        saveButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        urlCard.add(to: containerStack)

        // ===== 卡片 2：连接状态 + 测试按钮 =====
        let statusCard = makeCard(title: "连接状态", subtitle: nil)

        statusBadge.font = .systemFont(ofSize: 16, weight: .semibold)
        statusBadge.numberOfLines = 0
        statusCard.stack.addArrangedSubview(statusBadge)

        detailLabel.font = Theme.bodySmall
        detailLabel.textColor = Theme.subtext
        detailLabel.numberOfLines = 0
        statusCard.stack.addArrangedSubview(detailLabel)

        testButton.setTitle("测试连接", for: .normal)
        testButton.titleLabel?.font = Theme.titleSmall
        testButton.setTitleColor(.white, for: .normal)
        testButton.backgroundColor = Theme.primary
        testButton.layer.cornerRadius = Theme.cornerMedium
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        statusCard.stack.addArrangedSubview(testButton)
        testButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        statusCard.add(to: containerStack)

        // ===== 卡片 3：启用同步 =====
        let enableCard = makeCard(title: "启用同步", subtitle: nil)

        let enableRow = UIStackView()
        enableRow.axis = .horizontal
        enableRow.alignment = .center
        enableRow.spacing = 12

        let enableLabel = UILabel()
        enableLabel.text = "启动时尝试与上述服务器建立连接"
        enableLabel.font = Theme.bodyMedium
        enableLabel.textColor = Theme.text
        enableLabel.numberOfLines = 0
        enableRow.addArrangedSubview(enableLabel)

        enableSwitch.onTintColor = Theme.primary
        enableSwitch.addTarget(self, action: #selector(enableChanged), for: .valueChanged)
        enableSwitch.setContentHuggingPriority(.required, for: .horizontal)
        enableSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        enableRow.addArrangedSubview(enableSwitch)

        enableCard.stack.addArrangedSubview(enableRow)
        enableCard.add(to: containerStack)

        // ===== 卡片 4：使用说明（页底，可滚动查看） =====
        let helpCard = makeCard(title: "关于本功能", subtitle: nil)
        let helpText = UILabel()
        helpText.font = Theme.bodySmall
        helpText.textColor = Theme.subtext
        helpText.numberOfLines = 0
        helpText.text = """
        当前版本（v1.0.17）仅完成 HTTP 握手验证，可用于：
        · 确认手机与 LX 桌面版/独立服务在同一网络
        · 桌面端「服务端模式」是否已开启
        · 端口 / AP 隔离 等基础连通性排查

        下一步（v1.0.18+）将基于 LX 桌面版的 WebSocket RPC 协议（message2call）实现：
        · 收藏歌单双向同步
        · 「不喜欢」列表双向同步
        · 首次连接时的「合并 / 覆盖」选择
        · 同局域网自动发现 LX 桌面端

        提示：协议传输的数据是明文，请仅在受信任的局域网使用（官方文档原话）。
        """
        helpCard.stack.addArrangedSubview(helpText)
        helpCard.add(to: containerStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            containerStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            containerStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            containerStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            containerStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            containerStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存", style: .done, target: self, action: #selector(saveTapped)
        )
    }

    @objc private func lxStateChanged() {
        refreshStatus(LXSyncService.shared.status)
    }

    private func refreshStatus(_ status: LXSyncService.Status) {
        statusBadge.text = status.displayText.split(separator: "\n").first.map(String.init) ?? ""
        let color: UIColor
        let detail: String
        switch status {
        case .notConfigured:
            color = Theme.subtext
            detail = "请填写上方同步服务地址后点「保存地址」"
        case .idle:
            color = Theme.subtext
            detail = "点「测试连接」可立即验证网络可达性"
        case .testing:
            color = Theme.warning
            detail = "向 /hello 发起 HTTP 请求，最多 8 秒超时"
        case .ok(let h, _):
            color = Theme.success
            let parts = h.split(separator: "\n").map(String.init)
            detail = "握手成功，服务器标识：\n" + (parts.last ?? h)
        case .failed(let r):
            color = Theme.error
            detail = r
        }
        statusBadge.textColor = color
        detailLabel.text = detail
    }

    @objc private func testTapped() {
        let text = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.shared.lxSyncServerURL = text
        ConfigStore.shared.save()
        LXSyncService.shared.refreshInitialState()
        LXSyncService.shared.testConnection()
        showToast("已发起测试…")
    }

    @objc private func saveTapped() {
        let text = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.shared.lxSyncServerURL = text
        ConfigStore.shared.save()
        LXSyncService.shared.refreshInitialState()
        showToast("已保存")
    }

    @objc private func enableChanged() {
        ConfigStore.shared.lxSyncEnabled = enableSwitch.isOn
        ConfigStore.shared.save()
    }

    private func showToast(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            alert.dismiss(animated: true)
        }
    }

    // MARK: - 卡片构建

    private func makeCard(title: String, subtitle: String?) -> Card {
        return Card(title: title, subtitle: subtitle)
    }

    private final class Card {
        let view: UIView
        let stack: UIStackView

        init(title: String, subtitle: String?) {
            let container = UIView()
            container.backgroundColor = Theme.cardBg
            container.layer.cornerRadius = Theme.cornerMedium
            container.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = UILabel()
            titleLabel.font = Theme.titleSmall
            titleLabel.textColor = Theme.text
            titleLabel.text = title
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let subtitleLabel = UILabel()
            subtitleLabel.font = Theme.bodySmall
            subtitleLabel.textColor = Theme.subtext
            subtitleLabel.text = subtitle
            subtitleLabel.numberOfLines = 0
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.isHidden = (subtitle == nil || subtitle!.isEmpty)

            let inner = UIStackView()
            inner.axis = .vertical
            inner.spacing = 12
            inner.alignment = .fill
            inner.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(titleLabel)
            container.addSubview(subtitleLabel)
            container.addSubview(inner)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

                inner.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: subtitleLabel.isHidden ? 0 : 12),
                inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            ])

            self.view = container
            self.stack = inner
        }

        /// 把卡片 view 加入任何 vertical stack — 由 stack 自动堆叠，不再发生"全叠顶部"的 bug
        func add(to parentStack: UIStackView) {
            parentStack.addArrangedSubview(view)
        }
    }
}

extension LXSyncViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
