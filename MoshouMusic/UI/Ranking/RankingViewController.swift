import UIKit

/// 排行榜页 — 各平台排行榜浏览
class RankingViewController: UIViewController {

    private let tableView = UITableView()
    private let sources = ["kw", "tx", "mg", "wy", "kg"]

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "排行"

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RankCell")
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension RankingViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RankCell", for: indexPath)
        let source = sources[indexPath.row]

        cell.textLabel?.text = "\(Theme.sourceName(source)) 排行榜"
        cell.textLabel?.font = Theme.bodyLarge
        cell.textLabel?.textColor = Theme.text

        cell.imageView?.image = UIImage(systemName: "chart.bar.fill")?
            .withTintColor(Theme.sourceColor(source), renderingMode: .alwaysOriginal)

        cell.backgroundColor = .clear
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .none

        // 添加容器背景
        cell.contentView.backgroundColor = Theme.cardBg
        cell.contentView.layer.cornerRadius = Theme.cornerMedium
        cell.contentView.layer.masksToBounds = true

        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 64
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.contentView.backgroundColor = indexPath.row % 2 == 0 ? Theme.cardBg : Theme.surfaceVariant
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let source = sources[indexPath.row]
        let boardVC = BoardViewController(source: source)
        navigationController?.pushViewController(boardVC, animated: true)
    }
}
