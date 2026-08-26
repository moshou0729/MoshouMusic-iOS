import UIKit

/// LX Music 桌面版同步设置页
/// v1.0.15 仅支持 URL 配置 + HTTP /hello 握手
/// 完整 WebSocket RPC + 加密双向同步将在 v1.0.16+ 上线
class LXSyncViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let containerView = UIView()

    private let urlField = UITextField()
    private let statusBadge = UILabel()
    private let detailLabel = UILabel()
    private let testButton = UIButton(type: .system)
    private let enableSwitch = UISwitch()

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
        scrollView.addSubview(containerView)
        [scrollView, containerView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        // 顶部卡片：URL 输入
        let urlCard = makeCard(title: "同步服务地址", subtitle: "LX 桌面版 v2.4+ 或独立版数据同步服务")
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "http://192.168.1.5:23332"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .done
        urlField.font = Theme.bodyMedium
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlCard.addRow(urlField)

        // 提示
        let hint = UILabel()
        hint.text = "桌面端：「设置 → 数据同步」选择「服务端模式」\n同步 URL 在桌面版上显示，例：http://192.168.1.5:23332"
        hint.font = Theme.bodySmall
        hint.textColor = Theme.subtext
        hint.numberOfLines = 0
        urlCard.addRow(hint)

        urlCard.addTo(containerView, topSpacing: 16)

        // 状态卡片
        let statusCard = makeCard(title: "连接状态", subtitle: nil)

        statusBadge.font = .systemFont(ofSize: 15, weight: .semibold)
        statusBadge.numberOfLines = 0
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addRow(statusBadge)

        detailLabel.font = Theme.bodySmall
        detailLabel.textColor = Theme.subtext
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addRow(detailLabel)

        testButton.setTitle("测试连接", for: .normal)
        testButton.titleLabel?.font = Theme.titleSmall
        testButton.setTitleColor(.white, for: .normal)
        testButton.backgroundColor = Theme.primary
        testButton.layer.cornerRadius = Theme.cornerMedium
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        statusCard.addRow(testButton)
        testButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        statusCard.addTo(containerView, topSpacing: 16)

        // 启用开关卡片
        let enableCard = makeCard(title: "启用同步", subtitle: nil)
        enableSwitch.onTintColor = Theme.primary
        enableSwitch.addTarget(self, action: #selector(enableChanged), for: .valueChanged)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        let enableRow = UIStackView()
        enableRow.axis = .horizontal
        enableRow.alignment = .center
        enableRow.spacing = 12
        enableRow.translatesAutoresizingMaskIntoConstraints = false
        let enableLabel = UILabel()
        enableLabel.text = "打开后，启动时尝试与上述服务器建立连接"
        enableLabel.font = Theme.bodyMedium
        enableLabel.textColor = Theme.text
        enableLabel.numberOfLines = 0
        enableRow.addArrangedSubview(enableLabel)
        enableRow.addArrangedSubview(enableSwitch)
        enableCard.addRow(enableRow)
        enableCard.addTo(containerView, topSpacing: 16)

        // 说明卡片
        let helpCard = makeCard(title: "关于本功能", subtitle: nil)
        let helpText = UILabel()
        helpText.font = Theme.bodySmall
        helpText.textColor = Theme.subtext
        helpText.numberOfLines = 0
        helpText.translatesAutoresizingMaskIntoConstraints = false
        helpText.text = """
        当前版本（v1.0.15）仅完成 HTTP 握手验证，可用于：
        · 确认手机与 LX 桌面版/独立服务在同一网络
        · 桌面端「服务端模式」是否已开启
        · 端口 / AP 隔离 等基础连通性排查

        下一步（v1.0.16+）将基于 LX 桌面版的 WebSocket RPC 协议（message2call）实现：
        · 收藏歌单双向同步
        · 「不喜欢」列表双向同步
        · 首次连接时的「合并 / 覆盖」选择
        · 同局域网自动发现 LX 桌面端

        提示：协议传输的数据是明文，请仅在受信任的局域网使用（官方文档原话）。
        """
        helpCard.addRow(helpText)
        helpCard.addTo(containerView, topSpacing: 16)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            containerView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
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
            detail = "请填写上方同步服务地址后点击「保存」"
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
        // 测试前先保存当前输入
        let text = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.shared.lxSyncServerURL = text
        LXSyncService.shared.refreshInitialState()
        LXSyncService.shared.testConnection()
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

    private class Card {
        let container = UIView()
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let stack = UIStackView()

        init(title: String, subtitle: String?) {
            container.backgroundColor = Theme.cardBg
            container.layer.cornerRadius = Theme.cornerMedium
            container.translatesAutoresizingMaskIntoConstraints = false

            titleLabel.font = Theme.titleSmall
            titleLabel.textColor = Theme.text
            titleLabel.text = title
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            subtitleLabel.font = Theme.bodySmall
            subtitleLabel.textColor = Theme.subtext
            subtitleLabel.text = subtitle
            subtitleLabel.numberOfLines = 0
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(titleLabel)
            container.addSubview(subtitleLabel)
            container.addSubview(stack)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

                stack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            ])
        }

        func addRow(_ view: UIView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }

        func addTo(_ parent: UIView, topSpacing: CGFloat) {
            parent.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: parent.topAnchor, constant: topSpacing),
                container.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            ])
        }
    }

    private func makeCard(title: String, subtitle: String?) -> Card {
        return Card(title: title, subtitle: subtitle)
    }
}

extension LXSyncViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
