import UIKit

/// 手动添加音源 — 填写名称并粘贴脚本代码 (LXMusic 兼容格式)
/// 也可点「从文件夹选择」直接读取 App 文档目录里的 .js 文件，省去复制粘贴
class AddSourceViewController: UIViewController {

    /// true 时切换为「导入洛雪(lx-music)社区脚本」模式，保存走 LXCompatEngine
    var lxMode = false

    private let scrollView = UIScrollView()
    private let container = UIStackView()
    private let nameField = UITextField()
    private let idField = UITextField()
    private let codeView = UITextView()
    private let pickButton = UIButton(type: .system)
    private let fileLabel = UILabel()
    private let codeLabel = UILabel()

    /// 从文件读取到的完整脚本内容（大文件在编辑框里只预览，保存时用这份）
    private var pendingCode: String?

    /// 超过这个字符数就只往编辑框里放预览，避免大脚本卡住 UI
    private let previewLimit = 20000

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

        container.addArrangedSubview(makeField(title: "音源名称", field: nameField, placeholder: "如：我的镜像源"))
        container.addArrangedSubview(makeField(title: "音源ID (可选)", field: idField, placeholder: "留空则自动生成"))

        codeLabel.text = lxMode ? "洛雪(lx-music)脚本代码 (.js)" : "脚本代码 (.js, LXMusic 兼容)"
        codeLabel.font = Theme.labelLarge
        codeLabel.textColor = Theme.text
        codeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pickButton.setTitle("从文件夹选择…", for: .normal)
        pickButton.titleLabel?.font = Theme.labelLarge
        pickButton.setTitleColor(Theme.primary, for: .normal)
        pickButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pickButton.addTarget(self, action: #selector(pickFileTapped), for: .touchUpInside)

        let codeHeader = UIStackView(arrangedSubviews: [codeLabel, pickButton])
        codeHeader.axis = .horizontal
        codeHeader.alignment = .center
        codeHeader.spacing = 8
        container.addArrangedSubview(codeHeader)

        codeView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.backgroundColor = Theme.cardBg
        codeView.textColor = Theme.text
        codeView.layer.cornerRadius = Theme.cornerMedium
        codeView.layer.masksToBounds = true
        codeView.isEditable = true
        codeView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        container.addArrangedSubview(codeView)

        fileLabel.font = Theme.bodySmall
        fileLabel.textColor = Theme.primary
        fileLabel.numberOfLines = 0
        fileLabel.isHidden = true
        container.addArrangedSubview(fileLabel)

        let tip = UILabel()
        if lxMode {
            tip.text = "提示：粘贴洛雪音乐(lx-music)桌面端社区音源脚本；脚本太长时点上方「从文件夹选择…」，把 .js 放进「文件」App ▸ 我的 iPhone ▸ 墨守music 后直接读取。App 会自动用 Babel 转译成 iOS14 可运行的 ES5 并加载。脚本需调用 lx.send('inited',{sources:[...]}) 声明平台（如 kw/kg/tx/wy/mg）。仅作播放链接补充，不提供搜索。"
        } else {
            tip.text = "提示：可从洛雪音乐等社区获取音源脚本粘贴到此，或点「从文件夹选择…」直接读取本机 .js 文件；脚本需声明 lx.send(inited,{sources:['你的ID']})。"
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

    // MARK: - 从本机文件读取

    @objc private func pickFileTapped() {
        let picker = LocalScriptPickerViewController()
        picker.mode = lxMode ? .lxScript : .builtinScript
        picker.onPick = { [weak self] url, name in
            self?.applySelectedFile(url: url, name: name)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func applySelectedFile(url: URL, name: String) {
        guard let code = LocalScriptPickerViewController.readText(url) else {
            showAlert(title: "读取失败", message: "无法以文本方式读取该文件，可能不是 .js 脚本文本")
            return
        }
        pendingCode = code

        if (nameField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            nameField.text = name
        }
        if (idField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            idField.text = LocalScriptPickerViewController.makeID(from: name)
        }

        if code.count > previewLimit {
            codeView.text = String(code.prefix(previewLimit))
                + "\n\n…（文件共 \(code.count) 字符，这里只预览前 \(previewLimit) 字符；点保存时使用完整内容）"
        } else {
            codeView.text = code
        }

        fileLabel.text = "已选择文件：\(url.lastPathComponent)（共 \(code.count) 字符）"
        fileLabel.isHidden = false
        Logger.info("添加音源：已从本机文件载入 \(url.lastPathComponent)（\(code.count) 字符）")
    }

    @objc private func saveTapped() {
        guard let name = nameField.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            showAlert(title: "请填写名称", message: nil)
            return
        }
        // 选过文件时用完整文件内容；否则用编辑框里的粘贴内容
        let rawCode = pendingCode ?? codeView.text ?? ""
        guard rawCode.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            showAlert(title: pendingCode == nil ? "请粘贴脚本代码" : "脚本内容为空",
                      message: "代码过短，可能不是有效脚本")
            return
        }
        let id = (idField.text?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? name.lowercased().replacingOccurrences(of: " ", with: "_")

        if lxMode {
            // 部分脚本走异步 inited（LXCompatEngine 最多等 3.2s 才回调 completion），
            // 同步判 false 会把「其实成功了」误报成失败 → 先记回调结果，没等到就延时再判。
            var settled = false
            var okFinal = false
            var platsFinal: [String] = []
            LXCompatEngine.shared.importUserScript(id: id, displayName: name, rawCode: rawCode) { ok, plats in
                guard !settled else { return }
                settled = true
                okFinal = ok
                platsFinal = plats
            }
            let report = { [weak self] in
                guard let self = self else { return }
                if okFinal {
                    let platText = platsFinal.isEmpty ? "但未声明可用平台（可能无法提供播放链接）" : "可用平台: \(platsFinal.joined(separator: ", "))"
                    self.showAlert(title: "已导入", message: "洛雪脚本「\(name)」已加载。\(platText)") { [weak self] in
                        self?.navigationController?.popViewController(animated: true)
                    }
                } else {
                    self.showAlert(title: "导入失败", message: "脚本未声明任何平台（缺少 lx.send('inited')），或格式无法解析。")
                }
            }
            if settled {
                report()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { report() }
            }
            return
        }

        let ok = ScriptManager.shared.saveCustomScript(id: id, name: name, code: rawCode)
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
