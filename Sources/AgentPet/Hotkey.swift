// 단축키
// - 전역 ⌃⌥P: 어느 앱에서든 말풍선을 앞으로 불러와 키보드를 받게 한다 (최소화한 말풍선도 다시 연다).
//   Carbon RegisterEventHotKey — 손쉬운 사용 같은 권한이 필요 없다.
// - 말풍선이 키보드를 받을 때만: Esc 닫기 · M/- 최소화 · 1~9 답 고르기 · O 열기 · D/스페이스 자세히 보기 ·
//   ←/→ 이전·다음 알림(질문 모드에선 이전·다음 질문) · [ ] 이전·다음 알림 · ⌘↩ 질문 답 보내기
//   Esc·숫자 같은 키를 전역으로 가로채면 다른 앱의 키를 빼앗게 되어, 말풍선에 초점이 있을 때만 받는다.
import AppKit
import Carbon

enum Hotkey {
    static var onPress: (() -> Void)?
    static let label = "⌃⌥P"
    private static var ref: EventHotKeyRef?

    static func register() {
        // 사용자가 직접 다른 앱을 누르면 되돌릴 필요가 없다
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Hotkey.previousApp = nil
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x50455431), id: 1)   // 'PET1'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    /// 메뉴 「단축키」 — 안내만 (누를 수 없는 줄)
    static func helpMenu() -> NSMenu {
        let m = NSMenu()
        for line in ["\(label)  말풍선 열기 · 키보드로 조작 (어느 앱에서든)",
                     "Esc  닫기", "M 또는 -  최소화 (펫을 누르면 다시)", "1 ~ 9  답 고르기 (질문 모드: 선택지)",
                     "O  열기 (Multica·Orca·GitHub 등)", "D 또는 스페이스  자세히 보기 / 접기",
                     "← →  이전·다음 알림 (질문 모드: 이전·다음 질문)", "[ ]  이전·다음 알림", "⌘↩  질문 답 보내기"] {
            let it = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
        }
        return m
    }
}

extension AppDelegate {
    /// ⌃⌥P — 말풍선을 열고 키보드를 받게 한다. 끝나면(닫기·답·최소화) 원래 쓰던 앱으로 돌려준다
    func focusBubble() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            Hotkey.previousApp = front
        }
        lastActivity = Date()
        if requests.isEmpty {   // 알림이 없으면 한마디만
            TalkState.shared.bubble.say("알림이 없어요", above: petPanel.frame, seconds: 2.5)
            return
        }
        bubbleOpen = true
        refreshBubble()
        NSApp.activate(ignoringOtherApps: true)
        bubblePanel.makeKeyAndOrderFront(nil)
    }

    /// 말풍선이 키보드를 받을 때 — 처리했으면 true
    func handleBubbleKey(_ e: NSEvent) -> Bool {
        guard bubbleOpen, requests.indices.contains(current) else { return false }
        let r = requests[current]
        // 글자가 아니라 키 위치(keyCode)로 본다 — 한글 입력 상태면 D 가 「ㅇ」으로 들어오기 때문
        let cmd = e.modifierFlags.contains(.command)
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                     83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]   // 위 숫자줄 · 숫자 패드
        var leave = false   // 말풍선을 떠나는 동작이면 원래 앱으로
        switch e.keyCode {
        case 53:                                         // Esc — 닫기
            answer(r, "dismiss"); leave = true
        case 46, 27, 78:                                 // M · - · 숫자 패드 - — 최소화
            minimizeBubble(); leave = true
        case 31:                                         // O — 열기
            guard !r.link.isEmpty else { NSSound.beep(); return true }
            bubbleView.onOpen?(r); leave = true
        case 2, 49:                                      // D · 스페이스 — 자세히 보기
            if !bubbleView.toggleExpand() { NSSound.beep() }
        case 123:                                        // ←
            if !bubbleView.moveQuestion(-1) { navigate(-1) }
        case 124:                                        // →
            if !bubbleView.moveQuestion(1) { navigate(1) }
        case 33: navigate(-1)                            // [
        case 30: navigate(1)                             // ]
        case 36 where cmd, 76 where cmd:                 // ⌘↩ — 질문 답 보내기
            if bubbleView.sendAnswers() { leave = true } else { NSSound.beep() }
        default:
            guard let n = digits[e.keyCode], !cmd else { return false }
            switch bubbleView.pick(n) {
            case .answered: leave = true
            case .picked: break
            case .none: NSSound.beep()
            }
        }
        if leave { returnFocus() }
        return true
    }

    /// 단축키로 끝냈으면 원래 쓰던 앱으로 — 말풍선에 남은 알림이 있어도 키보드는 돌려준다
    func returnFocus() {
        bubblePanel.resignKey()
        Hotkey.previousApp?.activate()
        Hotkey.previousApp = nil
    }
}

extension Hotkey {
    /// 말풍선으로 키보드를 옮겨 오기 전에 쓰던 앱 — 끝나면 돌려준다
    static var previousApp: NSRunningApplication?
    /// 새 알림이 와서 말풍선으로 키보드를 옮길 차례 — 키보드를 쉬는 틈을 기다린다
    static var pendingFocus: Date?
    /// 알림이 오면 말풍선으로 키보드 옮기기 (기본 켬)
    static var autoFocus: Bool {
        get { Settings.shared.data["auto_focus"] as? Bool ?? true }
        set { Settings.shared.data["auto_focus"] = newValue; Settings.shared.save() }
    }
    /// 이만큼 키를 안 눌러야 옮긴다 — 치던 글자가 말풍선으로 들어가 답이 나가지 않게
    static let typingQuiet: Double = 1.5
}

extension AppDelegate {
    /// 매 프레임 — 옮길 차례인데 키보드를 쉬고 있으면 말풍선으로. 30초 안에 틈이 없으면 그만둔다
    func autoFocusTick(_ now: Date) {
        guard let since = Hotkey.pendingFocus else { return }
        if now.timeIntervalSince(since) > 30 || requests.isEmpty || requests.allSatisfy({ $0.source == "pet" }) {
            Hotkey.pendingFocus = nil
            return
        }
        guard !bubbleOpen || !bubblePanel.isKeyWindow else { Hotkey.pendingFocus = nil; return }   // 이미 말풍선에 있음
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard quiet >= Hotkey.typingQuiet else { return }
        Hotkey.pendingFocus = nil
        focusBubble()
        noticeLog("키보드 옮김 → 말풍선 (이전 앱: \(Hotkey.previousApp?.localizedName ?? "없음"))")
    }
}
