// LidAwake: 맥북 뚜껑을 닫아도 안 꺼지게 하는 메뉴바 앱
// 내부 동작: sudo pmset -a disablesleep 1 / 0
import Cocoa
import IOKit.ps

let appName = "LidAwake"
let repoURL = "https://github.com/jinnyjiinlee/lid-awake"
let sudoersPath = "/etc/sudoers.d/lidawake"
let batteryLimit = 20

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
                      prompt: "\(appName)가 잠자기 설정을 바꾸려고 해요.")
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

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var tickTimer: Timer?
    var isOn = false
    var lastNote: String?
    let defaults = UserDefaults.standard

    var endDate: Date? {
        get { defaults.object(forKey: "endDate") as? Date }
        set { defaults.set(newValue, forKey: "endDate") }
    }
    var batteryGuard: Bool {
        get { defaults.object(forKey: "batteryGuard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "batteryGuard") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            DispatchQueue.main.async { self.showWelcome(); self.showPanel() }
        } else {
            DispatchQueue.main.async { self.showPanel() }
        }
    }

    // 앱 아이콘을 다시 더블클릭하면 조작 창을 띄운다 (메뉴바 아이콘이 노치에 가려진 경우 대비)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func showPanel() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = isOn ? "지금: 켜짐 ☕ 뚜껑 닫아도 안 꺼져요" : "지금: 꺼짐 🌙 평소처럼 잠들어요"
        a.informativeText = """
        화면 맨 위 오른쪽 메뉴바의 컵·달 아이콘으로도 켜고 끌 수 있어요.
        아이콘이 안 보이면 이 앱을 다시 더블클릭하면 이 창이 떠요.
        """
        a.addButton(withTitle: isOn ? "끄기" : "켜기")
        a.addButton(withTitle: "닫기")
        if a.runModal() == .alertFirstButtonReturn {
            if isOn { turnOff(note: nil) } else { turnOn(hours: nil) }
            showPanel()
        }
    }

    // 상태 읽고 아이콘 갱신
    func refresh() {
        isOn = isSleepDisabled()
        if !isOn { endDate = nil }
        let symbol = isOn ? "cup.and.saucer.fill" : "moon.zzz"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: appName)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = isOn ? "\(appName): 뚜껑 닫아도 안 꺼짐" : "\(appName): 평소처럼 잠자기"
    }

    func tick() {
        refresh()
        guard isOn else { return }
        if let end = endDate, Date() >= end {
            turnOff(note: "정해둔 시간이 끝나서 자동으로 껐어요")
            return
        }
        if batteryGuard, let b = batteryStatus(), b.onBattery, b.percent <= batteryLimit {
            turnOff(note: "배터리가 \(b.percent)%라서 자동으로 껐어요")
        }
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        let title = isOn ? "켜짐 · 뚜껑 닫아도 안 꺼져요" : "꺼짐 · 평소처럼 잠자기"
        menu.addItem(disabledItem(title))
        if isOn, let end = endDate {
            menu.addItem(disabledItem("   \(remaining(until: end)) 뒤 자동으로 꺼져요"))
        }
        if let note = lastNote { menu.addItem(disabledItem("   \(note)")) }
        menu.addItem(.separator())

        menu.addItem(item("계속 켜두기", #selector(onForever)))
        let timed = NSMenuItem(title: "시간 정해서 켜기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for h in [1, 2, 4, 8] {
            let it = item("\(h)시간", #selector(onTimed(_:)))
            it.tag = h
            sub.addItem(it)
        }
        timed.submenu = sub
        menu.addItem(timed)
        let off = item("끄기 (평소대로)", #selector(offClicked))
        off.isEnabled = isOn
        menu.addItem(off)
        menu.addItem(.separator())

        let guardItem = item("배터리 \(batteryLimit)% 이하면 자동으로 끄기", #selector(toggleGuard))
        guardItem.state = batteryGuard ? .on : .off
        menu.addItem(guardItem)
        if hasPasswordlessRule() {
            menu.addItem(item("비밀번호 없이 쓰기 해제", #selector(removeRule)))
        } else {
            menu.addItem(item("비밀번호 없이 쓰기 설정 (한 번만)", #selector(installRule)))
        }
        menu.addItem(.separator())
        menu.addItem(item("\(appName) 소개 페이지", #selector(openRepo)))
        menu.addItem(item("종료", #selector(quitClicked), key: "q"))
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
        return mins >= 60 ? "\(mins / 60)시간 \(mins % 60)분" : "\(mins)분"
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
    }

    @objc func toggleGuard() { batteryGuard.toggle() }

    @objc func installRule() {
        let user = NSUserName()
        // 사용자 이름은 안전한 문자만 허용 (셸·sudoers 주입 방지)
        guard user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            alert("설정할 수 없어요", "사용자 이름에 특수문자가 있어서 자동 설정을 할 수 없어요.")
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        // 규칙 파일은 root 전용 임시 폴더에서 root가 직접 만든다 (사용자 폴더 파일 바꿔치기 방지)
        let cmd = "umask 077; t=$(/usr/bin/mktemp /private/var/root/lidawake.XXXXXX) || exit 1; "
            + "/usr/bin/printf '%s\\n' '\(rule)' > \"$t\" && /usr/sbin/visudo -cf \"$t\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); rc=$?; /bin/rm -f \"$t\"; exit $rc"
        let ok = runAsAdmin(cmd, prompt: "처음 한 번만 비밀번호를 넣으면 다음부터는 클릭만으로 켜고 끌 수 있어요.")
        if ok { alert("설정 끝!", "이제 메뉴에서 클릭 한 번으로 켜고 끌 수 있어요.") }
    }

    @objc func removeRule() {
        if runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "비밀번호 없이 쓰기 설정을 지워요.") {
            alert("해제했어요", "다음부터는 켜고 끌 때마다 비밀번호를 물어봐요.")
        }
    }

    @objc func openRepo() { NSWorkspace.shared.open(URL(string: repoURL)!) }

    @objc func quitClicked() {
        refresh()
        if isOn {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "아직 켜져 있어요"
            a.informativeText = "앱을 끄면 자동 해제(시간·배터리)가 동작하지 않아요. 끄고 종료할까요?"
            a.addButton(withTitle: "끄고 종료")
            a.addButton(withTitle: "켜둔 채 종료")
            a.addButton(withTitle: "취소")
            switch a.runModal() {
            case .alertFirstButtonReturn: turnOff(note: nil)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        NSApp.terminate(nil)
    }

    func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(appName)에 오신 걸 환영해요"
        a.informativeText = """
        화면 맨 위 메뉴바의 컵(켜짐)·달(꺼짐) 아이콘을 눌러서 쓰면 돼요.

        켜두면 맥북 뚜껑을 닫아도 안 꺼져요.
        가방에 넣을 땐 꼭 꺼 주세요. 열이 날 수 있어요.

        관리자 비밀번호를 한 번만 넣어 두면, 다음부터는 클릭만으로 켜고 끌 수 있어요.
        """
        a.addButton(withTitle: "지금 설정하기")
        a.addButton(withTitle: "나중에")
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
