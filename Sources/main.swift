// LidAwake: 맥북 뚜껑을 닫아도 안 꺼지게 하는 메뉴바 앱
// 내부 동작: sudo pmset -a disablesleep 1 / 0
import Cocoa
import IOKit.ps
import ServiceManagement
import UserNotifications

let appName = "LidAwake"
let repoURL = "https://github.com/jinnyjiinlee/lid-awake"
let siteURL = "https://getlidawake.vercel.app"
let releasesAPI = "https://api.github.com/repos/jinnyjiinlee/lid-awake/releases/latest"
let sudoersPath = "/etc/sudoers.d/lidawake"
let batteryLimit = 20
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

// MARK: - 한국어 / 영어

let isKorean = (Locale.preferredLanguages.first ?? "").hasPrefix("ko")
func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

// MARK: - 시스템 명령

@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// AppleScript 관리자 권한으로 셸 명령 실행 (macOS 비밀번호 창이 뜸)
func runAsAdmin(_ command: String, prompt: String) -> Bool {
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
    var err: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&err)
    return err == nil
}

func isSleepDisabled() -> Bool {
    let out = run("/usr/bin/pmset", ["-g"]).out
    for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
    }
    return false
}

func hasPasswordlessRule() -> Bool {
    FileManager.default.fileExists(atPath: sudoersPath)
}

func setSleepDisabled(_ on: Bool) -> Bool {
    let arg = on ? "1" : "0"
    if hasPasswordlessRule(),
       run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]).code == 0 {
        return true
    }
    return runAsAdmin("/usr/bin/pmset -a disablesleep \(arg)",
                      prompt: L("\(appName)가 잠자기 설정을 바꾸려고 해요.",
                                "\(appName) wants to change the sleep setting."))
}

func batteryStatus() -> (percent: Int, onBattery: Bool)? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cur = d["Current Capacity"] as? Int,
              let max = d["Max Capacity"] as? Int, max > 0 else { continue }
        let onBattery = (d["Power Source State"] as? String) == "Battery Power"
        return (cur * 100 / max, onBattery)
    }
    return nil
}

/// "1.2.0" > "1.1.9" 비교
func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").compactMap { Int($0) }
    let pb = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var tickTimer: Timer?
    var isOn = false
    var lastNote: String?
    var newVersion: String?
    let defaults = UserDefaults.standard

    var endDate: Date? {
        get { defaults.object(forKey: "endDate") as? Date }
        set { defaults.set(newValue, forKey: "endDate") }
    }
    var batteryGuard: Bool {
        get { defaults.object(forKey: "batteryGuard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "batteryGuard") }
    }
    var heatGuard: Bool {
        get { defaults.object(forKey: "heatGuard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "heatGuard") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.tick()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkForUpdate()

        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            DispatchQueue.main.async { self.showWelcome(); self.showPanel() }
        } else if !launchedAtLogin() {
            // 사용자가 직접 연 경우에만 조작 창 (로그인 자동 실행 땐 조용히)
            DispatchQueue.main.async { self.showPanel() }
        }
    }

    /// 로그인 자동 실행으로 켜졌는지 추정: 자동 실행이 켜져 있고 부팅한 지 5분 안
    func launchedAtLogin() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 300
    }

    // 앱 아이콘을 다시 더블클릭하면 조작 창 (메뉴바 아이콘이 노치에 가려진 경우 대비)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    // 상태 읽고 메뉴바 아이콘·남은 시간 갱신
    func refresh() {
        isOn = isSleepDisabled()
        if !isOn { endDate = nil }
        let symbol = isOn ? "sun.max.fill" : "moon.zzz"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: appName)
        img?.isTemplate = true
        guard let button = statusItem.button else { return }
        button.image = img
        button.imagePosition = .imageLeading
        if isOn, let end = endDate {
            button.title = " " + shortRemaining(until: end)
        } else {
            button.title = ""
        }
        button.toolTip = isOn ? L("\(appName): 뚜껑 닫아도 안 꺼짐", "\(appName): stays awake with lid closed")
                              : L("\(appName): 평소처럼 잠자기", "\(appName): normal sleep")
    }

    func tick() {
        refresh()
        guard isOn else { return }
        if let end = endDate, Date() >= end {
            turnOff(note: L("정해둔 시간이 끝나서 자동으로 껐어요", "Timer finished, turned off"))
            return
        }
        if batteryGuard, let b = batteryStatus(), b.onBattery, b.percent <= batteryLimit {
            turnOff(note: L("배터리가 \(b.percent)%라서 자동으로 껐어요", "Battery at \(b.percent)%, turned off"))
            return
        }
        checkHeat()
    }

    @objc func thermalChanged() {
        DispatchQueue.main.async { self.checkHeat() }
    }

    func checkHeat() {
        guard isOn, heatGuard else { return }
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical {
            turnOff(note: L("맥이 너무 뜨거워져서 자동으로 껐어요", "Mac got too hot, turned off"))
        }
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        let title = isOn ? L("켜짐 · 뚜껑 닫아도 안 꺼져요", "ON · Stays awake with lid closed")
                         : L("꺼짐 · 평소처럼 잠자기", "OFF · Normal sleep")
        menu.addItem(disabledItem(title))
        if isOn, let end = endDate {
            menu.addItem(disabledItem(L("   \(remaining(until: end)) 뒤 자동으로 꺼져요",
                                        "   Turns off in \(remaining(until: end))")))
        }
        if let note = lastNote { menu.addItem(disabledItem("   \(note)")) }
        menu.addItem(.separator())

        menu.addItem(item(L("계속 켜두기", "Keep awake"), #selector(onForever)))
        let timed = NSMenuItem(title: L("시간 정해서 켜기", "Keep awake for…"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for h in [1, 2, 4, 8] {
            let it = item(L("\(h)시간", h == 1 ? "1 hour" : "\(h) hours"), #selector(onTimed(_:)))
            it.tag = h
            sub.addItem(it)
        }
        timed.submenu = sub
        menu.addItem(timed)
        let off = item(L("끄기 (평소대로)", "Turn off"), #selector(offClicked))
        off.isEnabled = isOn
        menu.addItem(off)
        menu.addItem(.separator())

        let safety = NSMenuItem(title: L("안전장치", "Safety"), action: nil, keyEquivalent: "")
        let safetySub = NSMenu()
        let b = item(L("배터리 \(batteryLimit)% 이하면 자동으로 끄기", "Turn off below \(batteryLimit)% battery"),
                     #selector(toggleBattery))
        b.state = batteryGuard ? .on : .off
        safetySub.addItem(b)
        let h = item(L("맥이 뜨거워지면 자동으로 끄기", "Turn off when Mac gets hot"), #selector(toggleHeat))
        h.state = heatGuard ? .on : .off
        safetySub.addItem(h)
        safety.submenu = safetySub
        menu.addItem(safety)

        if #available(macOS 13.0, *) {
            let login = item(L("로그인할 때 자동 실행", "Open at login"), #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        if hasPasswordlessRule() {
            menu.addItem(item(L("비밀번호 없이 쓰기 해제", "Require password again"), #selector(removeRule)))
        } else {
            menu.addItem(item(L("비밀번호 없이 쓰기 설정 (한 번만)", "Skip password (one-time setup)"),
                              #selector(installRule)))
        }
        menu.addItem(.separator())
        if let v = newVersion {
            menu.addItem(item(L("새 버전 \(v) 받기", "Download new version \(v)"), #selector(openSite)))
        }
        menu.addItem(item(L("\(appName) 소개 페이지", "About \(appName)"), #selector(openSite)))
        menu.addItem(disabledItem("v\(appVersion)"))
        menu.addItem(item(L("종료", "Quit"), #selector(quitClicked), key: "q"))
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func remaining(until end: Date) -> String {
        let mins = max(0, Int(end.timeIntervalSinceNow / 60))
        if mins >= 60 { return L("\(mins / 60)시간 \(mins % 60)분", "\(mins / 60)h \(mins % 60)m") }
        return L("\(mins)분", "\(mins)m")
    }

    /// 메뉴바용 짧은 표기 "2:05"
    func shortRemaining(until end: Date) -> String {
        let mins = max(0, Int(end.timeIntervalSinceNow / 60))
        return String(format: "%d:%02d", mins / 60, mins % 60)
    }

    // MARK: 동작

    @objc func onForever() { turnOn(hours: nil) }
    @objc func onTimed(_ sender: NSMenuItem) { turnOn(hours: sender.tag) }
    @objc func offClicked() { turnOff(note: nil) }

    func turnOn(hours: Int?) {
        guard setSleepDisabled(true) else { return }
        endDate = hours.map { Date().addingTimeInterval(Double($0) * 3600) }
        lastNote = nil
        refresh()
    }

    func turnOff(note: String?) {
        guard setSleepDisabled(false) else { return }
        endDate = nil
        lastNote = note
        refresh()
        if let note { notify(note) }
    }

    func notify(_ body: String) {
        let c = UNMutableNotificationContent()
        c.title = appName
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: c, trigger: nil))
    }

    @objc func toggleBattery() { batteryGuard.toggle() }
    @objc func toggleHeat() { heatGuard.toggle() }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(L("설정하지 못했어요", "Couldn't change it"),
                  L("앱을 응용 프로그램 폴더로 옮긴 뒤 다시 해 주세요.",
                    "Move the app to the Applications folder and try again."))
        }
    }

    @objc func installRule() {
        let user = NSUserName()
        // 사용자 이름은 안전한 문자만 허용 (셸·sudoers 주입 방지)
        guard user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            alert(L("설정할 수 없어요", "Can't set this up"),
                  L("사용자 이름에 특수문자가 있어서 자동 설정을 할 수 없어요.",
                    "Your user name has special characters, so this can't be set up automatically."))
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        // 규칙 파일은 root 전용 임시 폴더에서 root가 직접 만든다 (사용자 폴더 파일 바꿔치기 방지)
        let cmd = "umask 077; t=$(/usr/bin/mktemp /private/var/root/lidawake.XXXXXX) || exit 1; "
            + "/usr/bin/printf '%s\\n' '\(rule)' > \"$t\" && /usr/sbin/visudo -cf \"$t\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); rc=$?; /bin/rm -f \"$t\"; exit $rc"
        let ok = runAsAdmin(cmd, prompt: L("처음 한 번만 비밀번호를 넣으면 다음부터는 클릭만으로 켜고 끌 수 있어요.",
                                           "Enter your password once, then switch with a single click."))
        if ok {
            alert(L("설정 끝!", "All set!"),
                  L("이제 클릭 한 번으로 켜고 끌 수 있어요.", "You can now switch with a single click."))
        }
    }

    @objc func removeRule() {
        if runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: L("비밀번호 없이 쓰기 설정을 지워요.",
                                                             "Remove the no-password setting.")) {
            alert(L("해제했어요", "Removed"),
                  L("다음부터는 켜고 끌 때마다 비밀번호를 물어봐요.", "You'll be asked for your password each time."))
        }
    }

    @objc func openSite() { NSWorkspace.shared.open(URL(string: siteURL)!) }

    func checkForUpdate() {
        guard let url = URL(string: releasesAPI) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if isNewer(latest, than: appVersion) {
                DispatchQueue.main.async { self.newVersion = latest }
            }
        }.resume()
    }

    @objc func quitClicked() {
        refresh()
        if isOn {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L("아직 켜져 있어요", "Still on")
            a.informativeText = L("앱을 끄면 자동 해제(시간·배터리·과열)가 동작하지 않아요. 끄고 종료할까요?",
                                  "Auto-off (timer, battery, heat) won't work after quitting. Turn off and quit?")
            a.addButton(withTitle: L("끄고 종료", "Turn off & Quit"))
            a.addButton(withTitle: L("켜둔 채 종료", "Quit, keep on"))
            a.addButton(withTitle: L("취소", "Cancel"))
            switch a.runModal() {
            case .alertFirstButtonReturn: turnOff(note: nil)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        NSApp.terminate(nil)
    }

    func showPanel() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = isOn ? L("지금: 켜짐 · 뚜껑 닫아도 안 꺼져요", "Now: ON · Stays awake with lid closed")
                             : L("지금: 꺼짐 · 평소처럼 잠들어요", "Now: OFF · Normal sleep")
        a.informativeText = L("""
        화면 맨 위 오른쪽 메뉴바의 해·달 아이콘으로도 켜고 끌 수 있어요.
        아이콘이 안 보이면 이 앱을 다시 열면 이 창이 떠요.
        """, """
        You can also use the sun/moon icon in the menu bar.
        If you can't see the icon, open this app again to get this window.
        """)
        a.addButton(withTitle: isOn ? L("끄기", "Turn off") : L("켜기", "Turn on"))
        a.addButton(withTitle: L("닫기", "Close"))
        if a.runModal() == .alertFirstButtonReturn {
            if isOn { turnOff(note: nil) } else { turnOn(hours: nil) }
            showPanel()
        }
    }

    func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("\(appName)에 오신 걸 환영해요", "Welcome to \(appName)")
        a.informativeText = L("""
        켜두면 맥북 뚜껑을 닫아도 안 꺼져요.
        메뉴바의 해(켜짐)·달(꺼짐) 아이콘으로 켜고 끄면 돼요.

        가방에 넣을 땐 꼭 꺼 주세요. 배터리가 \(batteryLimit)% 아래로 떨어지거나 맥이 뜨거워지면 자동으로 꺼져요.

        관리자 비밀번호를 한 번만 넣어 두면, 다음부터는 클릭만으로 켜고 끌 수 있어요.
        """, """
        When on, your MacBook keeps running with the lid closed.
        Use the sun (on) / moon (off) icon in the menu bar.

        Turn it off before putting it in a bag. It turns off automatically below \(batteryLimit)% battery or when your Mac gets hot.

        Enter your admin password once, then switch with a single click.
        """)
        a.addButton(withTitle: L("지금 설정하기", "Set up now"))
        a.addButton(withTitle: L("나중에", "Later"))
        if a.runModal() == .alertFirstButtonReturn { installRule() }
    }

    func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
