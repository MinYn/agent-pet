// 행동 직접 시키기 · 혼자 말하기
// - 메뉴 「행동」: 걷기·점프·손 흔들기·잠자기·창 위로 올라가기 등을 바로 시킨다 (cmd 「do:<이름>」으로도)
// - 메뉴 「혼자 말하기」: 가끔 펫 머리 위에 작은 말풍선으로 한마디 — 시간·상황(잠, 창 위, 쌓인 알림, 오늘 끝난 작업)에 맞춰
//   내 문장은 <데이터 폴더>/talk.txt (한 줄에 하나)
import AppKit

/// 펫 머리 위 작은 말풍선 — 알림 말풍선과 따로, 눌러지지 않고 몇 초 뒤 사라진다
final class TalkBubble {
    let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let box = NSVisualEffectView()
    private var hideAt = Date.distantPast
    var visible: Bool { panel.isVisible }

    init() {
        panel = makePanel(NSRect(x: 0, y: 0, width: 120, height: 30))
        panel.ignoresMouseEvents = true   // 지나가는 말 — 클릭은 뒤로 통과
        box.material = .popover
        box.state = .active
        box.blendingMode = .behindWindow
        box.wantsLayer = true
        box.layer?.cornerRadius = 11
        box.layer?.masksToBounds = true
        label.font = BubbleFont.font(12, .medium)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 220
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        panel.contentView = box
    }

    func say(_ text: String, above pet: NSRect, seconds: Double) {
        label.stringValue = text
        box.layoutSubtreeIfNeeded()
        let size = box.fittingSize
        panel.setContentSize(NSSize(width: min(max(size.width, 40), 240), height: size.height))
        follow(pet)
        hideAt = Date().addingTimeInterval(seconds)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    /// 펫을 따라간다 — 펫 머리 위 가운데, 화면 밖으로 나가지 않게
    func follow(_ pet: NSRect) {
        let f = panel.frame
        let screen = (NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = pet.midX - f.width / 2
        x = max(screen.minX + 4, min(x, screen.maxX - f.width - 4))
        panel.setFrameOrigin(NSPoint(x: x, y: min(pet.maxY + 2, screen.maxY - f.height)))
    }

    func tick(_ pet: NSRect, now: Date) {
        guard visible else { return }
        if now >= hideAt { hide(); return }
        follow(pet)
    }

    func hide() {
        guard visible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in panel.orderOut(nil) })
    }
}

/// 혼잣말 상태 (확장에는 저장 속성을 못 둔다)
final class TalkState {
    static let shared = TalkState()
    let bubble = TalkBubble()
    var nextAt = Date().addingTimeInterval(90)   // 켠 직후 바로 말하지 않게
    var last = ""
}

extension AppDelegate {
    // -------------------------------------------------------------------------
    // 행동 직접 시키기
    // -------------------------------------------------------------------------

    func actionMenu() -> NSMenu {
        let m = NSMenu()
        let onWindow: Bool = { if case .perched(let id, _) = place { return id != WindowWorld.dockId }; return false }()
        let onDock: Bool = { if case .perched(let id, _) = place { return id == WindowWorld.dockId }; return false }()
        let onGround: Bool = { if case .ground = place { return true }; return false }()
        let items: [(String, String, Bool)] = [
            ("걷기", "walk", true), ("멈춰 서기", "stand", true), ("두리번거리기", "look", true),
            ("점프", "jump", true), ("손 흔들기", "wave", true), ("기뻐하기", "happy", true),
            ("꾸벅꾸벅 졸기", "doze", true), ("잠자러 가기", "sleep", true),
        ]
        for (title, key, on) in items {
            let it = item(title) { [weak self] in _ = self?.perform(key) }
            it.isEnabled = on
            m.addItem(it)
        }
        m.addItem(.separator())
        let windowItems: [(String, String, Bool)] = [
            ("창 위로 올라가기", "climb", windowPlay && onGround),
            ("뛰어내리기", "hopdown", windowPlay && (onWindow || onDock)),
            ("Dock 아이콘 건너뛰기", "dockhop", windowPlay && onDock),
        ]
        for (title, key, on) in windowItems {
            let it = item(title) { [weak self] in _ = self?.perform(key) }
            it.isEnabled = on
            if !windowPlay { it.toolTip = "메뉴 「창·Dock 위에 올라가 놀기」를 켜면 할 수 있어요" }
            m.addItem(it)
        }
        m.autoenablesItems = false
        return m
    }

    /// 행동 하나를 바로 시킨다 — 잠에서 깨우고 하던 이동을 멈춘 뒤. 할 수 없는 상황이면 false
    @discardableResult
    func perform(_ key: String) -> Bool {
        let now = Date()
        let wasAsleep = now.timeIntervalSince(lastActivity) > sleepAfter
        lastActivity = now          // 깨운다 (자고 있었으면)
        if wasAsleep && key != "sleep" { sayWake() }
        sleepTarget = nil
        summonTarget = nil
        walkTarget = nil
        refreshWindows(now)
        let map: [String: Behavior] = ["walk": .walk, "stand": .stand, "look": .look, "jump": .jump, "wave": .wave,
                                       "doze": .doze, "climb": .climb, "hopdown": .hopDown, "dockhop": .dockHop]
        switch key {
        case "sleep":
            lastActivity = .distantPast   // 바로 졸려서 잠자리로 간다
            manualUntil = .distantPast
            return true
        case "happy":
            happyUntil = now.addingTimeInterval(2)
            manualUntil = happyUntil
            return true
        default:
            guard let b = map[key] else { return false }
            if [.climb, .hopDown, .dockHop].contains(b) && !windowPlay { return false }
            if b == .hopDown, case .perched = place {} else if b == .hopDown { return false }
            startBehavior(b, now)
            if b == .jump || b == .wave || b == .look || b == .doze || b == .stand {   // 시킨 건 조금 더 길게 보여 준다
                behaviorUntil = max(behaviorUntil, now.addingTimeInterval(2.5))
            }
            manualUntil = behaviorUntil
            motionLog("행동 시킴 \(key) → \(behavior)")
            return behavior == b
        }
    }

    // -------------------------------------------------------------------------
    // 혼자 말하기
    // -------------------------------------------------------------------------

    /// off · sometimes(기본, 약 15분마다) · often(약 5분마다)
    var talkMode: String {
        get { Settings.shared.data["talk"] as? String ?? "sometimes" }
        set { Settings.shared.data["talk"] = newValue; Settings.shared.save(); scheduleTalk() }
    }

    static let talkFile = petDir + "/talk.txt"

    func talkMenu() -> NSMenu {
        let m = NSMenu()
        for (title, key) in [("가끔 (15분쯤마다)", "sometimes"), ("자주 (5분쯤마다)", "often"), ("말하지 않기", "off")] {
            m.addItem(item(title, checked: talkMode == key) { [weak self] in self?.talkMode = key })
        }
        m.addItem(.separator())
        m.addItem(item("지금 한마디") { [weak self] in self?.talkNow() })
        m.addItem(item("내 문장 고치기… (talk.txt)") { AppDelegate.openTalkFile() })
        return m
    }

    func scheduleTalk() {
        let base: Double = talkMode == "often" ? 300 : 900
        TalkState.shared.nextAt = Date().addingTimeInterval(base * Double.random(in: 0.6...1.4))
    }

    /// 매 프레임 — 떠 있는 말풍선은 펫을 따라가고, 때가 되면 한마디
    func talkTick(_ now: Date) {
        let t = TalkState.shared
        if bubblePanel.isVisible { t.bubble.hide() }   // 알림 말풍선이 우선
        t.bubble.tick(petPanel.frame, now: now)
        guard talkMode != "off", now >= t.nextAt else { return }
        scheduleTalk()
        guard !bubblePanel.isVisible else { return }
        switch place {
        case .held, .falling, .leaping: return   // 끌리거나 떨어지는 중엔 말하지 않는다
        default: break
        }
        talkNow()
    }

    func talkNow() {
        let t = TalkState.shared
        guard !bubblePanel.isVisible else { return }
        let lines = talkLines(Date()).filter { $0 != t.last }
        guard let line = lines.randomElement() else { return }
        t.last = line
        t.bubble.say(line, above: petPanel.frame, seconds: max(3.5, min(7, Double(line.count) * 0.18)))
        noticeLog("혼잣말 \(line)")
    }

    /// 지금 상황에 맞는 문장들 — 지금 캐릭터의 말투(persona)가 있으면 그 문장, 없으면 기본 문장. 상황 문장을 더 자주
    func talkLines(_ now: Date) -> [String] {
        let hour = Calendar.current.component(.hour, from: now)
        let minute = Calendar.current.component(.minute, from: now)
        let my = sprites.talk
        let lines = { (key: String, fallback: [String]) -> [String] in my[key] ?? fallback }
        let template = { (key: String, n: Int, fallback: String) -> String in
            (self.sprites.talkTemplate[key] ?? fallback).replacingOccurrences(of: "{n}", with: "\(n)")
        }
        if now.timeIntervalSince(lastActivity) > sleepAfter {
            return lines("sleep", ["쿨쿨…", "zzz…", "음냐음냐…"])
        }

        var context: [String] = []
        let waiting = requests.filter { $0.source != "pet" }.count   // 펫 자체 안내는 세지 않는다
        if waiting > 0 && !bubbleOpen {
            context.append(template("alerts", waiting, "확인할 알림이 {n}개 있어요. 저를 눌러 주세요!"))
        }
        let done = AppDelegate.doneToday()
        if done >= 1 { context.append(template("done", done, "오늘 작업이 {n}개 끝났어요. 잘하고 있어요!")) }
        if case .perched(let id, _) = place {
            context += id == WindowWorld.dockId ? lines("dock", ["Dock 위는 아이콘 구경하기 좋아요"])
                                                : lines("perched", ["여기 경치 좋다!", "높은 데 올라왔어요"])
        }
        switch hour {
        case 6..<10: context += lines("morning", ["좋은 아침이에요!", "오늘 할 일은 뭐예요?"])
        case 11 where minute >= 30, 12: context += lines("lunch", ["점심 뭐 먹어요?", "밥 먹고 해요!"])
        case 15: context += lines("snack", ["간식 시간이에요!", "커피 한 잔 어때요?"])
        case 18..<20: context += lines("evening", ["오늘도 수고했어요!", "퇴근은 언제 해요?"])
        case 22..<24, 0..<5: context += lines("night", ["늦었어요, 쉬엄쉬엄 해요", "졸려요…"])
        default: break
        }
        let mine = AppDelegate.myLines()
        let general = lines("general", ["물 한 잔 마셔요", "스트레칭 한 번 해요!", "에이전트들이 열심히 일하는 중이에요",
                                        "심심해요…", "저 여기 있어요!", "같이 일하니까 좋아요", "눈 좀 쉬어 가요"])
        // 상황 문장 2배 + 내 문장 2배 + 평소 문장
        return context + context + mine + mine + general
    }

    /// 깨웠을 때 한마디 — 캐릭터 말투의 wake 문장 (없으면 말하지 않는다)
    func sayWake() {
        guard let line = sprites.talk["wake"]?.randomElement(), !bubblePanel.isVisible else { return }
        TalkState.shared.last = line
        TalkState.shared.bubble.say(line, above: petPanel.frame, seconds: 3.5)
    }

    /// 오늘 끝난 작업 수 — 알림함 기록 중 오늘 받은 「작업 완료」
    static func doneToday() -> Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        let files = ((try? fm.contentsOfDirectory(atPath: Inbox.dir)) ?? []).filter {
            (Double($0.split(separator: "-").first ?? "") ?? 0) >= start
        }
        return files.filter { f in
            guard let d = fm.contents(atPath: Inbox.dir + "/" + f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let req = o["req"] as? [String: Any] else { return false }
            return (req["headline"] as? String ?? "").hasPrefix("작업 완료")
        }.count
    }

    /// 내 문장 — talk.txt 한 줄에 하나 (# 로 시작하는 줄·빈 줄은 건너뜀)
    static func myLines() -> [String] {
        guard let text = try? String(contentsOfFile: talkFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func openTalkFile() {
        if !fm.fileExists(atPath: talkFile) {
            let sample = """
            # 펫이 혼자 말할 내 문장 — 한 줄에 하나. # 로 시작하는 줄은 무시해요.
            # 저장하면 다음 한마디부터 섞여 나와요.
            오늘도 화이팅!
            코드 리뷰 잊지 마요
            """
            try? (sample + "\n").write(toFile: talkFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: talkFile))
    }
}
