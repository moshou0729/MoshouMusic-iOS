import UIKit

/// 手动添加音源 — 填写名称并粘贴脚本代码 (LXMusic 兼容格式)
class AddSourceViewController: UIViewController {

    /// true 时切换为「导入洛雪(lx-music)社区脚本」模式，保存走 LXCompatEngine
    var lxMode = false

    private let scrollView = UIScrollView()
    private let container = UIStackView()
    private let nameField = UITextField()
    private let idField = UITextField()
    private let codeView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = lxMode ? "导入洛雪脚本" : "添加音源"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(saveTapped))

        setupUI()
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        container.axis = .vertical
        container.spacing = 16
        container.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        container.isLayoutMarginsRelativeArrangement = true
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        container.addArrangedSubview(makeField(title: "音源名称", field: nameField, placeholder: "如：我的酷我镜像"))
        container.addArrangedSubview(makeField(title: "音源ID (可选)", field: idField, placeholder: "留空则自动生成"))

        let codeLabel = UILabel()
        codeLabel.text = lxMode ? "洛雪(lx-music)脚本代码 (.js)" : "脚本代码 (.js, LXMusic 兼容)"
        codeLabel.font = Theme.labelLarge
        codeLabel.textColor = Theme.text
        container.addArrangedSubview(codeLabel)

        codeView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.backgroundColor = Theme.cardBg
        codeView.textColor = Theme.text
        codeView.layer.cornerRadius = Theme.cornerMedium
        codeView.layer.masksToBounds = true
        codeView.isEditable = true
        codeView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        container.addArrangedSubview(codeView)

        let tip = UILabel()
        if lxMode {
            tip.text = "提示：粘贴洛雪音乐(lx-music)桌面端社区音源脚本。App 会自动用 Babel 转译成 iOS14 可运行的 ES5 并加载。脚本需调用 lx.send('inited',{sources:[...]}) 声明平台（如 kw/kg/tx/wy/mg）。仅作播放链接补充，不提供搜索。"
        } else {
            tip.text = "提示：可从洛雪音乐等社区获取音源脚本粘贴到此；脚本需声明 lx.send(inited,{sources:['你的ID']})。"
        }
        tip.font = Theme.bodySmall
        tip.textColor = Theme.subtext
        tip.numberOfLines = 0
        container.addArrangedSubview(tip)
    }

    private func makeField(title: String, field: UITextField, placeholder: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.labelLarge
        label.textColor = Theme.text

        field.placeholder = placeholder
        field.backgroundColor = Theme.cardBg
        field.textColor = Theme.text
        field.layer.cornerRadius = Theme.cornerMedium
        field.layer.masksToBounds = true
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        field.leftView = padding
        field.leftViewMode = .always

        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    @objc private func saveTapped() {
        guard let name = nameField.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            showAlert(title: "请填写名称", message: nil)
            return
        }
        guard let code = codeView.text?.trimmingCharacters(in: .whitespacesAndNewlines), code.count > 20 else {
            showAlert(title: "请粘贴脚本代码", message: "代码过短，可能不是有效脚本")
            return
        }
        let id = (idField.text?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? name.lowercased().replacingOccurrences(of: " ", with: "_")

        if lxMode {
            var imported = false
            var platforms: [String] = []
            LXCompatEngine.shared.importUserScript(id: id, displayName: name, rawCode: code) { ok, plats in
                imported = ok
                platforms = plats
            }
            if imported {
                let platText = platforms.isEmpty ? "但未声明可用平台（可能无法提供播放链接）" : "可用平台: \(platforms.joined(separator: ", "))"
                showAlert(title: "已导入", message: "洛雪脚本「\(name)」已加载。\(platText)") { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                }
            } else {
                showAlert(title: "导入失败", message: "脚本未声明任何平台（缺少 lx.send('inited')），或格式无法解析。")
            }
            return
        }

        let ok = ScriptManager.shared.saveCustomScript(id: id, name: name, code: code)
        if ok {
            showAlert(title: "已添加", message: "音源「\(name)」已保存并加载，搜索页可切换使用") { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }
        } else {
            showAlert(title: "保存失败", message: "请检查脚本格式或文件权限")
        }
    }

    private func showAlert(title: String, message: String?, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completion?() })
        present(alert, animated: true)
    }
}
