import Foundation
import Testing

@testable import FosforoSSH

private let sample = """
  # mine
  AddKeysToAgent yes

  Host lab
    HostName 10.0.0.2
    # the old one
    User root
    ForwardAgent yes

  Host web-*
    User www

  Host *
    ServerAliveInterval 30

  """

@Test func hostsFileListsPlainHosts() {
  let f = SSHHostsFile(sample)
  #expect(f.hosts.map(\.alias) == ["lab"])
  #expect(f.hosts[0].hostName == "10.0.0.2" && f.hosts[0].user == "root" && !f.hosts[0].mosh)
}

/// The keys it knows change in place; comments and other keys stay.
@Test func hostsFileEditsInPlace() {
  var f = SSHHostsFile(sample)
  var h = f.hosts[0]
  h.user = "crg"
  h.port = 2222
  h.hostName = ""
  f.save(h)
  #expect(
    f.text == """
      # mine
      AddKeysToAgent yes

      Host lab
        # the old one
        User crg
        Port 2222
        ForwardAgent yes

      Host web-*
        User www

      Host *
        ServerAliveInterval 30

      """)
}

/// A new host goes before the first pattern, so Host * stays last; Mosh
/// brings IgnoreUnknown to the top, for OpenSSH.
@Test func hostsFileAddsBeforePatternsAndIgnoresMosh() {
  var f = SSHHostsFile(sample)
  var h = SSHHostsFile.Host(alias: "pi")
  h.hostName = "pi.local"
  h.mosh = true
  h.moshServer = "/usr/local/bin/mosh-server"
  f.save(h)
  #expect(f.lines.first == "IgnoreUnknown Mosh,MoshServer")
  let parsed = SSHHosts(f.text)
  #expect(parsed["pi"]?.hostName == "pi.local" && parsed["pi"]?.mosh == true)
  #expect(parsed["pi"]?.moshServer == "/usr/local/bin/mosh-server")
  #expect(parsed["pi"]?.aliveInterval == 30)  // Host * still applies, after it
  let order = f.lines.filter { $0.hasPrefix("Host ") }
  #expect(order == ["Host lab", "Host pi", "Host web-*", "Host *"])
}

@Test func hostsFileRenamesAndRemoves() {
  var f = SSHHostsFile(sample)
  var h = f.hosts[0]
  h.alias = "lab2"
  f.save(h, replacing: "lab")
  #expect(f.hosts.map(\.alias) == ["lab2"])
  #expect(f.text.contains("ForwardAgent yes"))
  f.remove("lab2")
  #expect(f.hosts.isEmpty)
  #expect(
    f.text
      == "# mine\nAddKeysToAgent yes\n\nHost web-*\n  User www\n\nHost *\n  ServerAliveInterval 30\n"
  )
}

@Test func hostsFileStartsEmpty() {
  var f = SSHHostsFile("")
  var h = SSHHostsFile.Host(alias: "a")
  h.user = "u"
  f.save(h)
  #expect(f.text == "Host a\n  User u\n")
}
