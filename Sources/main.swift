// WiFi Failover — keeps the Mac online:
//  • Wi‑Fi lost (or Wi‑Fi without internet) → fall back to the iPhone Personal Hotspot
//  • while on the hotspot → hop back to a known Wi‑Fi (eduroam, …) as soon as one is in range
//
// Runs as a LaunchAgent inside an .app bundle so it can hold Location permission, which macOS
// requires before CoreWLAN reveals network names. Switching back to a known network is done by
// power-cycling Wi‑Fi so macOS auto-join reconnects with its own stored credentials (incl. 802.1X
// for eduroam) — joining a saved network directly needs admin access to the System keychain.
//
// Written by Claude.

import AppKit
import CoreLocation
import CoreWLAN
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/wifi-failover")
let logDir = home.appendingPathComponent("Library/Logs/wifi-failover")
let configURL = supportDir.appendingPathComponent("config.json")
let stateURL = supportDir.appendingPathComponent("state.json")
let learnedHotspotsURL = supportDir.appendingPathComponent("learned-hotspots.json")
let logURL = logDir.appendingPathComponent("wifi-failover.log")
let keychainService = "wifi-failover"

// MARK: - Config

struct Config: Codable {
    var hotspotSSID = ""
    var preferredSSIDs = ["eduroam"]          // tried first, in this order
    var allowAnyKnownNetwork = true           // otherwise only preferredSSIDs
    var excludeSSIDPatterns = ["iphone", "galaxy", "oneplus", "pixel", "android", "redmi", "xiaomi", "huawei", "phone"]
    var minRSSI = -75
    var tickSec = 10.0
    var hotspotScanSec = 90.0
    var disconnectGraceSec = 20.0             // let macOS auto-join / Instant Hotspot act first
    var internetCheckSec = 30.0
    var noInternetFailoverSec = 60.0
    var switchVerifySec = 60.0
    var badNetworkCooldownSec = 1800.0
    var dryRun = false

    // Missing keys in config.json fall back to the defaults above.
    static func load() -> Config {
        let def = Config()
        guard let data = try? Data(contentsOf: configURL),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(def),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return def }
        merged.merge(user) { _, new in new }
        guard let m = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(Config.self, from: m)
        else { log("config.json is invalid, using defaults"); return def }
        return cfg
    }
}

// MARK: - Helpers

func log(_ msg: String) {
    let fm = FileManager.default
    try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
        let old = logURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
    }
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    let line = Data("\(ts) \(msg)\n".utf8)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
        try? line.write(to: logURL)
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func ipv4(_ ifname: String) -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return nil }
    defer { freeifaddrs(addrs) }
    var p = addrs
    while let a = p {
        let i = a.pointee
        if String(cString: i.ifa_name) == ifname, let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let s = String(cString: host)
            if !s.hasPrefix("169.254.") { return s }
        }
        p = i.ifa_next
    }
    return nil
}

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 6
    c.waitsForConnectivity = false
    return URLSession(configuration: c)
}()

// Apple's captive-portal probe: real internet only if it answers "Success".
func hasInternet() -> Bool {
    let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    let task = session.dataTask(with: url) { data, resp, _ in
        ok = (resp as? HTTPURLResponse)?.statusCode == 200
            && String(decoding: data ?? Data(), as: UTF8.self).contains("Success")
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + 8) == .timedOut { task.cancel(); return false }
    return ok
}

func knownNetworks(_ ifname: String) -> [String] {
    run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", ifname]).out
        .split(separator: "\n").dropFirst()
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// Optional: stored with `security add-generic-password -s wifi-failover -a "<hotspot SSID>" -w`.
func hotspotPassword(_ ssid: String) -> String? {
    let r = run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", ssid, "-w"])
    let pw = r.out.trimmingCharacters(in: .newlines)
    return r.status == 0 && !pw.isEmpty ? pw : nil
}

// MARK: - Location permission (unlocks SSIDs in CoreWLAN)

final class LocationGate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            log("requesting Location permission (needed to see Wi‑Fi network names)")
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s: String
        switch m.authorizationStatus {
        case .authorizedAlways: s = "granted"
        case .denied: s = "DENIED — enable it in System Settings › Privacy & Security › Location Services"
        case .restricted: s = "restricted"
        case .notDetermined: s = "not determined yet"
        @unknown default: s = "unknown"
        }
        log("Location permission: \(s)")
    }
}

// MARK: - Agent

final class Agent {
    let iface: CWInterface
    let ifname: String
    var cfg = Config()

    var disconnectedSince: Date?
    var noInternetSince: Date?
    var lastInternetCheck = Date.distantPast
    var lastHotspotScan = Date.distantPast
    var lastRecoverAttempt = Date.distantPast
    var badUntil: [String: Date] = [:]
    var pending: (target: String, at: Date)?
    var lastNote = ""
    var mode = "starting"
    var lastEvent = ""
    // SSIDs seen handing out iPhone hotspot addresses (172.20.10.x), so a renamed phone is still recognised
    var learnedHotspots = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: learnedHotspotsURL))) ?? [])

    var hotspotNames: Set<String> { cfg.hotspotSSID.isEmpty ? learnedHotspots : learnedHotspots.union([cfg.hotspotSSID]) }

    init?() {
        guard let i = CWWiFiClient.shared().interface(), let n = i.interfaceName else { return nil }
        iface = i
        ifname = n
    }

    // Logs only when the message changes, so steady states don't flood the log.
    func note(_ msg: String) {
        guard msg != lastNote else { return }
        lastNote = msg
        lastEvent = msg
        log(msg)
    }

    func event(_ msg: String) {
        lastNote = ""
        lastEvent = msg
        log(msg)
    }

    func scan() -> Set<CWNetwork> {
        do { return try iface.scanForNetworks(withSSID: nil) } catch {
            log("scan failed: \(error.localizedDescription)")
            return []
        }
    }

    func isExcluded(_ ssid: String) -> Bool {
        if hotspotNames.contains(ssid) { return true }
        if cfg.preferredSSIDs.contains(ssid) { return false }
        let l = ssid.lowercased()
        return cfg.excludeSSIDPatterns.contains { l.contains($0.lowercased()) }
    }

    // Best known, non-phone network in range: preferred list order first, then signal strength.
    func bestKnown(_ nets: Set<CWNetwork>) -> (ssid: String, rssi: Int)? {
        let known = Set(knownNetworks(ifname))
        let now = Date()
        var best: [String: Int] = [:]
        for n in nets {
            guard let s = n.ssid, known.contains(s), !isExcluded(s),
                  (badUntil[s] ?? .distantPast) < now, n.rssiValue >= cfg.minRSSI,
                  cfg.allowAnyKnownNetwork || cfg.preferredSSIDs.contains(s)
            else { continue }
            best[s] = max(best[s] ?? Int.min, n.rssiValue)
        }
        func rank(_ s: String) -> Int { cfg.preferredSSIDs.firstIndex(of: s) ?? Int.max }
        return best.map { ($0.key, $0.value) }
            .min { (rank($0.0), -$0.1) < (rank($1.0), -$1.1) }
    }

    // Lets macOS auto-join pick the best known network, using its own stored credentials.
    func powerCycle() {
        if cfg.dryRun { log("[dry run] would power-cycle Wi‑Fi"); return }
        do {
            try iface.setPower(false)
            Thread.sleep(forTimeInterval: 2)
            try iface.setPower(true)
        } catch {
            log("CoreWLAN power cycle failed (\(error.localizedDescription)), using networksetup")
            run("/usr/sbin/networksetup", ["-setairportpower", ifname, "off"])
            Thread.sleep(forTimeInterval: 2)
            run("/usr/sbin/networksetup", ["-setairportpower", ifname, "on"])
        }
    }

    func switchTo(_ target: (ssid: String, rssi: Int), from: String) {
        event("\(from); \"\(target.ssid)\" in range (\(target.rssi) dBm) → reconnecting via macOS auto-join")
        powerCycle()
        pending = cfg.dryRun ? nil : (target.ssid, Date())
    }

    func joinHotspot(_ nets: Set<CWNetwork>, reason: String) {
        let names = hotspotNames
        guard let net = nets.filter({ $0.ssid.map(names.contains) ?? false }).max(by: { $0.rssiValue < $1.rssiValue }),
              let hs = net.ssid else {
            note("\(reason); iPhone hotspot not broadcasting — relying on macOS Instant Hotspot")
            return
        }
        if let pw = hotspotPassword(hs) {
            event("\(reason) → joining hotspot \"\(hs)\" (\(net.rssiValue) dBm)")
            if cfg.dryRun { log("[dry run] would join \"\(hs)\""); return }
            do { try iface.associate(to: net, password: pw) } catch {
                log("joining hotspot failed: \(error.localizedDescription)")
            }
        } else if ipv4(ifname) == nil && knownNetworks(ifname).contains(hs) {
            // Saved hotspot and nothing else to join: macOS auto-join picks it after a power cycle
            event("\(reason) → hotspot \"\(hs)\" visible (\(net.rssiValue) dBm), nudging macOS auto-join")
            powerCycle()
        } else {
            note("\(reason); \"\(hs)\" is visible but no password is stored in the keychain")
        }
    }

    func tick() {
        cfg = Config.load()
        let now = Date()
        guard iface.powerOn() else {
            mode = "wifi-off"
            note("Wi‑Fi is turned off — leaving it alone")
            return
        }
        let ssid = iface.ssid()
        let ip = ipv4(ifname)
        let onHotspot = ip?.hasPrefix("172.20.10.") == true || (ssid.map(hotspotNames.contains) ?? false)
        if ip?.hasPrefix("172.20.10.") == true, let s = ssid, !hotspotNames.contains(s) {
            learnedHotspots.insert(s)
            if let d = try? JSONEncoder().encode(learnedHotspots.sorted()) { try? d.write(to: learnedHotspotsURL) }
            event("learned that \"\(s)\" is an iPhone hotspot")
        }

        if let p = pending {
            if ip != nil && !onHotspot && hasInternet() {
                event("now online via \"\(ssid ?? "Wi‑Fi")\"")
                pending = nil
                disconnectedSince = nil
                lastInternetCheck = now
            } else if now.timeIntervalSince(p.at) >= cfg.switchVerifySec {
                // Never got an IP (slow join, flaky signal) → retry soon; got an IP but no internet
                // (captive portal) → full cooldown. A 30 min skip while offline left us stuck offline.
                let cooldown = ip == nil ? min(300, cfg.badNetworkCooldownSec) : cfg.badNetworkCooldownSec
                badUntil[p.target] = now.addingTimeInterval(cooldown)
                event("switch to \"\(p.target)\" didn't give internet — skipping it for \(Int(cooldown / 60)) min")
                pending = nil
                if ip != nil && !onHotspot {
                    // We moved onto a network without internet (e.g. captive portal). Leaving it makes macOS
                    // pause auto-join for that network, so it falls back to the hotspot.
                    event("leaving \"\(ssid ?? "Wi‑Fi")\" so macOS falls back to the hotspot")
                    iface.disassociate()
                    return
                }
            } else {
                mode = "switching"
                writeState(ssid: ssid, ip: ip)
                return
            }
        }

        if ip == nil {
            mode = "disconnected"
            noInternetSince = nil
            if disconnectedSince == nil {
                disconnectedSince = now
                event("Wi‑Fi connection lost")
            }
            if now.timeIntervalSince(disconnectedSince!) >= cfg.disconnectGraceSec,
               now.timeIntervalSince(lastRecoverAttempt) >= 45 {
                lastRecoverAttempt = now
                let nets = scan()
                if let t = bestKnown(nets) {
                    switchTo(t, from: "still offline")
                } else {
                    joinHotspot(nets, reason: "still offline, no usable known Wi‑Fi in range")
                }
            }
        } else if onHotspot {
            mode = "hotspot"
            if disconnectedSince != nil { disconnectedSince = nil; event("online via iPhone hotspot") }
            note("on iPhone hotspot — watching for known Wi‑Fi every \(Int(cfg.hotspotScanSec))s")
            if ssid == nil {
                note("on hotspot but network names are hidden — Location permission missing")
            } else if now.timeIntervalSince(lastHotspotScan) >= cfg.hotspotScanSec {
                lastHotspotScan = now
                if let t = bestKnown(scan()) { switchTo(t, from: "on hotspot") }
            }
        } else {
            mode = "wifi"
            if disconnectedSince != nil { disconnectedSince = nil; event("online via \"\(ssid ?? "Wi‑Fi")\"") }
            note("on Wi‑Fi \"\(ssid ?? "?")\"")
            if now.timeIntervalSince(lastInternetCheck) >= cfg.internetCheckSec {
                lastInternetCheck = now
                if hasInternet() {
                    noInternetSince = nil
                } else if noInternetSince == nil {
                    noInternetSince = now
                    event("\"\(ssid ?? "Wi‑Fi")\" has no internet")
                } else if now.timeIntervalSince(noInternetSince!) >= cfg.noInternetFailoverSec {
                    if let s = ssid { badUntil[s] = now.addingTimeInterval(cfg.badNetworkCooldownSec) }
                    noInternetSince = nil
                    joinHotspot(scan(), reason: "no internet on \"\(ssid ?? "Wi‑Fi")\" for \(Int(cfg.noInternetFailoverSec))s")
                }
            }
        }
        writeState(ssid: ssid, ip: ip)
    }

    func writeState(ssid: String?, ip: String?) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let state: [String: Any] = [
            "updated": iso.string(from: now),
            "mode": mode,
            "ssid": ssid ?? NSNull(),
            "ip": ip ?? NSNull(),
            "networkNamesVisible": ssid != nil || ip == nil,
            "skipping": badUntil.filter { $0.value > now }.mapValues { iso.string(from: $0) },
            "lastEvent": lastEvent,
            "dryRun": cfg.dryRun,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: stateURL, options: .atomic)
        }
    }
}

// MARK: - Main

try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

// `wifi-failover --check`: read-only report of what the agent sees and would pick.
if CommandLine.arguments.contains("--check") {
    guard let a = Agent() else { print("no Wi‑Fi interface"); exit(1) }
    a.cfg = Config.load()
    let ip = ipv4(a.ifname)
    print("current:", a.iface.ssid() ?? "(name hidden — Location permission missing — or not connected)", ip ?? "(no IP)",
          ip?.hasPrefix("172.20.10.") == true ? "[hotspot]" : "")
    let nets = a.scan()
    let known = Set(knownNetworks(a.ifname))
    var seen: [String: Int] = [:]
    for n in nets { if let s = n.ssid { seen[s] = max(seen[s] ?? Int.min, n.rssiValue) } }
    print("in range: \(seen.count) networks (\(nets.filter { $0.ssid == nil }.count) unnamed)")
    for (s, r) in seen.sorted(by: { $0.value > $1.value }) where known.contains(s) || a.hotspotNames.contains(s) {
        print(String(format: "  %4d dBm  %@%@", r, s, a.hotspotNames.contains(s) ? "  [hotspot]" : a.isExcluded(s) ? "  [excluded]" : "  [known]"))
    }
    if let t = a.bestKnown(nets) { print("on hotspot it would switch to: \(t.ssid) (\(t.rssi) dBm)") }
    else { print("on hotspot it would stay (no usable known Wi‑Fi in range)") }
    print("hotspot names:", a.hotspotNames.sorted().joined(separator: ", "))
    print("hotspot password in keychain:", a.hotspotNames.contains { hotspotPassword($0) != nil } ? "yes" : "no")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let gate = LocationGate()
guard let agent = Agent() else { log("no Wi‑Fi interface found"); exit(1) }
log("started (pid \(getpid()), interface \(agent.ifname))")
Thread {
    while true {
        // A plain Thread has no run loop draining autoreleased objects; without this pool every tick's
        // CoreWLAN/JSON/Process temporaries accumulated forever (~125 MB/day).
        autoreleasepool { agent.tick() }
        Thread.sleep(forTimeInterval: agent.cfg.tickSec)
    }
}.start()
app.run()
