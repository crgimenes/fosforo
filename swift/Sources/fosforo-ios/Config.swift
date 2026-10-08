#if os(iOS)
  import FosforoMosh
  import FosforoRender
  import FosforoSSH
  import UIKit
  import UniformTypeIdentifiers

  /// `config` in the shell: the settings in the look of the iOS Settings
  /// app, a grouped table that grows a section at a time. The files stay
  /// the truth: servers are ~/.ssh/config, appearance is settings.filo, and
  /// what changes a key (making, protecting) is the shell's own command,
  /// typed in the session so it asks as it always does.
  @MainActor
  final class ConfigController: UITableViewController {
    private let ssh: URL
    private let run: (String) -> Void  // a command line, typed in the session in front
    private let reload: () -> Void  // the config again, for every window
    private var hosts: [SSHHostsFile.Host] = []
    private var keys: [Launcher.KeyInfo] = []
    private var themes: [String] = []
    private var settings = SettingsFile("")
    private var theme = Theme()
    private var notice: String?  // init.filo set what this screen just changed

    private enum Section: Int, CaseIterable {
      case servers, keys, appearance, about
    }

    init(ssh: URL, run: @escaping (String) -> Void, reload: @escaping () -> Void) {
      self.ssh = ssh
      self.run = run
      self.reload = reload
      super.init(style: .insetGrouped)
      title = "Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func viewDidLoad() {
      super.viewDidLoad()
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        systemItem: .done,
        primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      refresh()
    }

    private var configFile: URL { ssh.appendingPathComponent("config") }

    private func refresh() {
      hosts = SSHHostsFile(contentsOf: configFile).hosts
      keys = Launcher.keys(in: ssh)
      settings = SettingsFile(contentsOf: SettingsFile.url)
      theme = (try? Theme.load()) ?? Theme()
      let dir = Theme.configURL.deletingLastPathComponent().appendingPathComponent("themes")
      themes =
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".filo") }.map { String($0.dropLast(5)) }.sorted()
      tableView.reloadData()
    }

    /// Closes the screen and types the line in the session, as if typed there.
    private func type(_ line: String) {
      dismiss(animated: true) { [run] in run(line + "\r") }
    }

    // MARK: - table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      switch Section(rawValue: section) {
      case .servers: hosts.count + 1
      case .keys: keys.count + 2
      case .appearance: 4
      case .about: 3
      case nil: 0
      }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int)
      -> String?
    {
      ["Servers", "Keys", "Appearance", "About"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int)
      -> String?
    {
      switch Section(rawValue: section) {
      case .servers:
        "~/.ssh/config: `ssh NAME` connects, over Mosh where Mosh is on."
      case .keys: "~/.ssh"
      case .appearance:
        notice ?? "~/.config/fosforo/settings.filo; init.filo runs after it and wins."
      default: nil
      }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
      -> UITableViewCell
    {
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      var c = UIListContentConfiguration.valueCell()
      switch Section(rawValue: indexPath.section) {
      case .servers:
        if indexPath.row < hosts.count {
          let h = hosts[indexPath.row]
          c = .subtitleCell()
          c.text = h.alias
          var place = h.hostName.isEmpty ? h.alias : h.hostName
          if !h.user.isEmpty { place = h.user + "@" + place }
          if let p = h.port { place += ":\(p)" }
          c.secondaryText = place + (h.mosh ? " · mosh" : "")
          cell.accessoryType = .disclosureIndicator
        } else {
          c.text = "Add Server"
          c.textProperties.color = .tintColor
        }
      case .keys:
        if indexPath.row < keys.count {
          let k = keys[indexPath.row]
          c = .subtitleCell()
          c.text = k.name
          c.secondaryText = k.type.replacingOccurrences(of: "ssh-", with: "") + " · " + k.state
        } else {
          c.text = indexPath.row == keys.count ? "New Key…" : "Import from Files…"
          c.textProperties.color = .tintColor
        }
      case .appearance:
        switch indexPath.row {
        case 0:
          c.text = "Font Size"
          c.secondaryText = String(Int(theme.fontSize))
          let step = UIStepper()
          step.minimumValue = 8
          step.maximumValue = 48
          step.value = theme.fontSize
          step.addAction(
            UIAction { [weak self] a in
              guard let s = a.sender as? UIStepper else { return }
              self?.change("FontSize", { $0.set("FontSize", number: s.value) }) {
                $0.fontSize == s.value
              }
            }, for: .valueChanged)
          cell.accessoryView = step
        case 1:
          c.text = "Theme"
          c.secondaryText = settings.theme ?? "None"
          cell.accessoryType = .disclosureIndicator
        case 2:
          c.text = "Gohan at Start"
          cell.accessoryView = toggle(
            "Banner", !theme.banner.isEmpty, shows: { !$0.banner.isEmpty },
            apply: { on, s in
              if on {
                s.unset("Banner")
                s.unset("BannerNarrow")
              } else {
                s.set("Banner", string: "")
                s.set("BannerNarrow", string: "")
              }
            })
        default:
          c.text = "Tips at Start"
          cell.accessoryView = toggle(
            "Greeting", !theme.greeting.isEmpty, shows: { !$0.greeting.isEmpty },
            apply: { on, s in
              if on { s.unset("Greeting") } else { s.set("Greeting", string: "") }
            })
        }
      case .about:
        switch indexPath.row {
        case 0:
          c.text = "Version"
          let info = Bundle.main.infoDictionary
          let v = info?["CFBundleShortVersionString"] as? String ?? "?"
          c.secondaryText = v + " (\(info?["CFBundleVersion"] as? String ?? "?"))"
        case 1:
          c.text = "Help"
          c.secondaryText = "help"
          cell.accessoryType = .disclosureIndicator
        default:
          c.text = "Source"
          c.secondaryText = "github.com/crgimenes/fosforo"
          cell.accessoryType = .disclosureIndicator
        }
      case nil: break
      }
      cell.contentConfiguration = c
      return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      tableView.deselectRow(at: indexPath, animated: true)
      switch Section(rawValue: indexPath.section) {
      case .servers:
        let host = indexPath.row < hosts.count ? hosts[indexPath.row] : nil
        let editor = HostEditor(
          host: host, keys: keys.map(\.name), file: configFile,
          connect: { [weak self] alias in self?.type("ssh " + alias) })
        navigationController?.pushViewController(editor, animated: true)
      case .keys:
        if indexPath.row < keys.count {
          keyActions(keys[indexPath.row], at: tableView.cellForRow(at: indexPath))
        } else if indexPath.row == keys.count {
          newKey()
        } else {
          importKey()
        }
      case .appearance where indexPath.row == 1:
        navigationController?.pushViewController(
          ThemePicker(themes: themes, current: settings.theme) { [weak self] name in
            self?.change("a theme", { $0.theme = name }) { _ in true }
          }, animated: true)
      case .about where indexPath.row == 1:
        type("help")
      case .about where indexPath.row == 2:
        if let url = URL(string: "https://github.com/crgimenes/fosforo") {
          UIApplication.shared.open(url)
        }
      default: break
      }
    }

    // MARK: - appearance

    private func toggle(
      _ key: String, _ on: Bool, shows: @escaping (Theme) -> Bool,
      apply: @escaping (Bool, inout SettingsFile) -> Void
    ) -> UISwitch {
      let s = UISwitch()
      s.isOn = on
      s.addAction(
        UIAction { [weak self] a in
          guard let sw = a.sender as? UISwitch else { return }
          let want = sw.isOn
          self?.change(key, { apply(want, &$0) }) { shows($0) == want }
        }, for: .valueChanged)
      return s
    }

    /// settings.filo changed, written, and the config read again by every
    /// window. took: whether the theme now shows the change; when it does
    /// not, init.filo set that key over it, and the footer says so.
    private func change(
      _ key: String, _ edit: (inout SettingsFile) -> Void, took: @escaping (Theme) -> Bool
    ) {
      var s = SettingsFile(contentsOf: SettingsFile.url)
      edit(&s)
      do {
        try s.write()
      } catch {
        alert("settings.filo", "\(error)")
        return
      }
      reload()
      refresh()
      notice = took(theme) ? nil : "init.filo sets \(key), and what it sets wins over this screen."
      tableView.reloadSections(IndexSet(integer: Section.appearance.rawValue), with: .none)
    }

    // MARK: - keys

    private func keyActions(_ k: Launcher.KeyInfo, at cell: UITableViewCell?) {
      let sheet = UIAlertController(title: k.name, message: nil, preferredStyle: .actionSheet)
      if let pub = k.publicLine {
        sheet.addAction(
          UIAlertAction(title: "Copy Public Key", style: .default) { _ in
            UIPasteboard.general.string = pub
          })
      }
      if k.state == "plain text" {
        sheet.addAction(
          UIAlertAction(title: "Protect with Face ID…", style: .default) { [weak self] _ in
            self?.type("key protect " + k.name)
          })
      }
      sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      sheet.popoverPresentationController?.sourceView = cell ?? tableView
      present(sheet, animated: true)
    }

    private func newKey() {
      let taken = Set(keys.map(\.name))
      var name = "id_ed25519"
      var n = 2
      while taken.contains(name)
        || FileManager.default.fileExists(
          atPath: ssh.appendingPathComponent(name).path)
      {
        name = "id_ed25519_\(n)"
        n += 1
      }
      let ask = UIAlertController(
        title: "New Key", message: "An ed25519 key pair in ~/.ssh, made by ssh-keygen.",
        preferredStyle: .alert)
      ask.addTextField { $0.text = name }
      ask.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      ask.addAction(
        UIAlertAction(title: "Make", style: .default) { [weak self, weak ask] _ in
          let chosen = ask?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
          guard !chosen.isEmpty, !chosen.contains("/"), !chosen.contains(" ") else { return }
          self?.type("ssh-keygen -t ed25519 -f ~/.ssh/" + chosen)
        })
      present(ask, animated: true)
    }

    private func importKey() {
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
      picker.delegate = self
      present(picker, animated: true)
    }

    private func alert(_ title: String, _ message: String) {
      let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "OK", style: .default))
      present(a, animated: true)
    }
  }

  extension ConfigController: UIDocumentPickerDelegate {
    /// A key from Files into ~/.ssh under its own name; one there already
    /// is never overwritten.
    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      guard let url = urls.first else { return }
      let dest = ssh.appendingPathComponent(url.lastPathComponent)
      guard let text = try? String(contentsOf: url, encoding: .utf8),
        text.contains("PRIVATE KEY") || text.contains("FOSFORO PROTECTED KEY")
      else {
        alert(url.lastPathComponent, "not a private key")
        return
      }
      guard !FileManager.default.fileExists(atPath: dest.path) else {
        alert(
          url.lastPathComponent, "~/.ssh/\(dest.lastPathComponent) exists: rename the file first")
        return
      }
      do {
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
      } catch {
        alert(url.lastPathComponent, "\(error)")
      }
      refresh()
    }
  }

  /// One server: its block in ~/.ssh/config.
  @MainActor
  final class HostEditor: UITableViewController {
    private var host: SSHHostsFile.Host
    private let original: String?  // the alias it had in the file
    private let keys: [String]
    private let file: URL
    private let connect: (String) -> Void

    init(
      host: SSHHostsFile.Host?, keys: [String], file: URL, connect: @escaping (String) -> Void
    ) {
      self.host = host ?? SSHHostsFile.Host(alias: "")
      original = host?.alias
      self.keys = keys
      self.file = file
      self.connect = connect
      super.init(style: .insetGrouped)
      title = host?.alias ?? "New Server"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func viewDidLoad() {
      super.viewDidLoad()
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
    }

    // sections: name; where; key; mosh; actions
    override func numberOfSections(in tableView: UITableView) -> Int { original == nil ? 4 : 5 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      switch section {
      case 1: 3
      case 3: host.mosh ? 2 : 1
      case 4: 2
      default: 1
      }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int)
      -> String?
    {
      switch section {
      case 0: "The name for `ssh NAME`."
      case 2: "Default: the keys ssh tries on its own."
      case 3: "ssh to this server uses Mosh, unless a jump or a forward needs ssh."
      default: nil
      }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
      -> UITableViewCell
    {
      switch (indexPath.section, indexPath.row) {
      case (0, _):
        return field("Name", host.alias, placeholder: "lab") { $0.alias = $1 }
      case (1, 0):
        return field("Host", host.hostName, placeholder: "lab.example.com") { $0.hostName = $1 }
      case (1, 1):
        return field("User", host.user, placeholder: "your login there") { $0.user = $1 }
      case (1, _):
        return field("Port", host.port.map(String.init) ?? "", placeholder: "22", number: true) {
          $0.port = Int($1)
        }
      case (2, _):
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        c.text = "Key"
        c.secondaryText =
          host.identityFile.isEmpty ? "Default" : (host.identityFile as NSString).lastPathComponent
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
      case (3, 0):
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        c.text = "Mosh"
        cell.contentConfiguration = c
        let s = UISwitch()
        s.isOn = host.mosh
        s.addAction(
          UIAction { [weak self] a in
            guard let self, let sw = a.sender as? UISwitch else { return }
            self.host.mosh = sw.isOn
            self.tableView.reloadSections(IndexSet(integer: 3), with: .automatic)
          }, for: .valueChanged)
        cell.accessoryView = s
        return cell
      case (3, _):
        return field("Server", host.moshServer, placeholder: "mosh-server (in the PATH)") {
          $0.moshServer = $1
        }
      default:
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.cell()
        c.text = indexPath.row == 0 ? "Connect" : "Delete Server"
        c.textProperties.color = indexPath.row == 0 ? .tintColor : .systemRed
        cell.contentConfiguration = c
        return cell
      }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      tableView.deselectRow(at: indexPath, animated: true)
      switch (indexPath.section, indexPath.row) {
      case (2, _): pickKey()
      case (4, 0):
        guard let alias = original else { return }
        connect(alias)
      case (4, _): delete()
      default: break
      }
    }

    private func field(
      _ label: String, _ value: String, placeholder: String, number: Bool = false,
      _ set: @escaping (inout SSHHostsFile.Host, String) -> Void
    ) -> UITableViewCell {
      let cell = FieldCell(label: label, value: value, placeholder: placeholder)
      cell.field.keyboardType = number ? .numberPad : .URL
      cell.onChange = { [weak self] text in
        guard let self else { return }
        set(&self.host, text.trimmingCharacters(in: .whitespaces))
      }
      return cell
    }

    private func pickKey() {
      let sheet = UIAlertController(title: "Key", message: nil, preferredStyle: .actionSheet)
      for name in ["Default"] + keys {
        sheet.addAction(
          UIAlertAction(title: name, style: .default) { [weak self] _ in
            self?.host.identityFile = name == "Default" ? "" : "~/.ssh/" + name
            self?.tableView.reloadSections(IndexSet(integer: 2), with: .none)
          })
      }
      sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      sheet.popoverPresentationController?.sourceView =
        tableView.cellForRow(at: IndexPath(row: 0, section: 2)) ?? tableView
      present(sheet, animated: true)
    }

    private func save() {
      view.endEditing(true)
      let alias = host.alias
      guard !alias.isEmpty, !alias.contains(where: { " \t*?!".contains($0) }) else {
        complain("A name, without spaces or * ? !")
        return
      }
      var f = SSHHostsFile(contentsOf: file)
      if alias != original, f.hosts.contains(where: { $0.alias == alias }) {
        complain("\(alias) is in ~/.ssh/config already")
        return
      }
      f.save(host, replacing: original)
      do {
        try f.write(to: file)
      } catch {
        complain("\(error)")
        return
      }
      navigationController?.popViewController(animated: true)
    }

    private func delete() {
      guard let alias = original else { return }
      let ask = UIAlertController(
        title: "Delete \(alias)?", message: "Its block goes from ~/.ssh/config.",
        preferredStyle: .alert)
      ask.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      ask.addAction(
        UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
          guard let self else { return }
          var f = SSHHostsFile(contentsOf: self.file)
          f.remove(alias)
          do {
            try f.write(to: self.file)
            self.navigationController?.popViewController(animated: true)
          } catch {
            self.complain("\(error)")
          }
        })
      present(ask, animated: true)
    }

    private func complain(_ message: String) {
      let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "OK", style: .default))
      present(a, animated: true)
    }
  }

  /// A label and a text field, as in the Settings app.
  @MainActor
  final class FieldCell: UITableViewCell, UITextFieldDelegate {
    let field = UITextField()
    var onChange: ((String) -> Void)?

    init(label: String, value: String, placeholder: String) {
      super.init(style: .default, reuseIdentifier: nil)
      selectionStyle = .none
      let name = UILabel()
      name.text = label
      name.setContentHuggingPriority(.required, for: .horizontal)
      field.text = value
      field.placeholder = placeholder
      field.textAlignment = .right
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.spellCheckingType = .no
      field.clearButtonMode = .whileEditing
      field.delegate = self
      field.addAction(
        UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
      let row = UIStackView(arrangedSubviews: [name, field])
      row.spacing = 12
      row.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(row)
      let m = contentView.layoutMarginsGuide
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: m.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: m.trailingAnchor),
        row.topAnchor.constraint(equalTo: m.topAnchor),
        row.bottomAnchor.constraint(equalTo: m.bottomAnchor),
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      textField.resignFirstResponder()
      return true
    }
  }

  /// The themes in ~/.config/fosforo/themes, and none.
  @MainActor
  final class ThemePicker: UITableViewController {
    private let names: [String?]
    private var current: String?
    private let pick: (String?) -> Void

    init(themes: [String], current: String?, pick: @escaping (String?) -> Void) {
      names = [nil] + themes
      self.current = current
      self.pick = pick
      super.init(style: .insetGrouped)
      title = "Theme"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      names.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int)
      -> String?
    {
      "~/.config/fosforo/themes: a theme is a .filo file of (set ...) lines."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
      -> UITableViewCell
    {
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      var c = UIListContentConfiguration.cell()
      c.text = names[indexPath.row] ?? "None"
      cell.contentConfiguration = c
      cell.accessoryType = names[indexPath.row] == current ? .checkmark : .none
      return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      tableView.deselectRow(at: indexPath, animated: true)
      current = names[indexPath.row]
      pick(current)
      tableView.reloadData()
    }
  }
#endif
