import Platform

extension GenshinCN {
  /// Telemetry and log-upload domains routed to 0.0.0.0 by the hosts blocklist (ADR 0001, #29).
  /// The TS launcher kept its list in a secret constant; this is the public set it blocked, minus
  /// the Zenless Zone Zero entry. The maintainer should diff it against the TS secret.
  public static let telemetryDomains = [
    "log-upload.mihoyo.com",
    "uspider.yuanshen.com",
    "prd-lender.cdp.internal.unity3d.com",
    "thind-prd-knob.data.ie.unity3d.com",
    "thind-gke-usc.prd.data.corp.unity3d.com",
    "cdp.cloud.unity3d.com",
  ]

  public static func hostsBlocklist() -> HostsBlocklist {
    HostsBlocklist(domains: telemetryDomains)
  }
}
