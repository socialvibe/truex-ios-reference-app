import UIKit

private struct RefItem {
    let title: String
    let subtitle: String
    let storyboard: String
}

class HomeViewController: UITableViewController {

    private let items: [RefItem] = [
        RefItem(title: "SSAI GAM",
                subtitle: "Server-side ad insertion via Google Ad Manager",
                storyboard: "SSAIGAMRef")
    ]

    private let cellIdentifier = "RefItemCell"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Integrations"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: cellIdentifier)
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath)
        let item = items[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = item.subtitle
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = items[indexPath.row]
        let storyboard = UIStoryboard(name: item.storyboard, bundle: nil)
        let vc = storyboard.instantiateInitialViewController()!
        vc.title = item.title
        navigationController?.pushViewController(vc, animated: true)
    }
}
