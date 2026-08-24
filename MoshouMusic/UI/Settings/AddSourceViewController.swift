import UIKit

/// 手动添加音源 — 填写名称并粘贴脚本代码 (LXMusic 兼容格式)
class AddSourceViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let container = UIStackView()
    private let nameField = UITextField()
    private let idField = UITextField()
    private let codeView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "添加音源"
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
        codeLabel.text = "脚本代码 (.js, LXMusic 兼容)"
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
        tip.text = "提示：可从洛雪音乐等社区获取音源脚本粘贴到此；脚本需声明 lx.send(inited,{sources:['你的ID']})。"
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
