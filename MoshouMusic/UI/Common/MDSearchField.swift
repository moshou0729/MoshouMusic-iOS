import UIKit

/// Material Design 3 风格搜索框 — 完全自绘 (基于普通 UITextField)
///
/// 为什么不用 UISearchBar:
/// UISearchBar 内部的 searchTextField 是私有子视图, 系统会在多个时机
/// (进入导航栏 titleView / 键盘弹出 / 外观切换) 重建并重置它的 textColor,
/// 加上 `UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])`
/// 与 UINavigationBarAppearance 互相覆盖, 在 iOS 14 上极易出现"输入文字不可见"。
/// 这里改为普通 UITextField, 不受任何 appearance 代理影响, 颜色 100% 可控。
final class MDSearchField: UIView {

    // MARK: - 子视图

    let textField = UITextField()
    private let iconView = UIImageView()
    private let clearButton = UIButton(type: .system)

    // MARK: - 回调

    /// 输入变化 (已做 trim, 未做防抖 — 防抖交给调用方)
    var onTextChanged: ((String) -> Void)?
    /// 点击键盘搜索键
    var onSearchTapped: ((String) -> Void)?

    var text: String {
        get { textField.text ?? "" }
        set {
            textField.text = newValue
            updateClearButton()
        }
    }

    var placeholder: String = "" {
        didSet { applyPlaceholder() }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.cornerRadius = 24
        clipsToBounds = true

        // 放大镜
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(systemName: "magnifyingglass")
        addSubview(iconView)

        // 输入框
        textField.font = Theme.bodyLarge
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .never
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        addSubview(textField)

        // 清空按钮
        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.isHidden = true
        addSubview(clearButton)

        setupConstraints()
        applyTheme()
    }

    private func setupConstraints() {
        [iconView, textField, clearButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),

            clearButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 6),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 22),
            clearButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: - 主题

    /// 主题切换后由外部调用, 重新上色
    func applyTheme() {
        backgroundColor = Theme.searchFieldBg
        iconView.tintColor = Theme.subtext
        clearButton.tintColor = Theme.subtext

        // 关键: 显式指定输入文字颜色, 不依赖任何 appearance 代理
        textField.textColor = Theme.text
        textField.tintColor = Theme.primary
        textField.keyboardAppearance = ConfigStore.shared.isDarkMode ? .dark : .light

        applyPlaceholder()
    }

    private func applyPlaceholder() {
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Theme.subtext,
                .font: Theme.bodyLarge
            ]
        )
    }

    // MARK: - 行为

    @objc private func editingChanged() {
        updateClearButton()
        onTextChanged?(text)
    }

    @objc private func clearTapped() {
        textField.text = ""
        updateClearButton()
        onTextChanged?("")
    }

    private func updateClearButton() {
        clearButton.isHidden = text.isEmpty
    }

    override func becomeFirstResponder() -> Bool {
        return textField.becomeFirstResponder()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        return textField.resignFirstResponder()
    }
}

// MARK: - UITextFieldDelegate

extension MDSearchField: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        onSearchTapped?(text)
        return true
    }
}
