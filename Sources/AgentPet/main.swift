// AgentPet — 화면 위를 돌아다니는 펫이 여러 AI 도구(Multica·Claude Code·Codex·Orca)의 알림을 말풍선으로 보여 준다.
//
// 소스와 앱은 파일로만 주고받는다.
//   <데이터 폴더>/requests/<id>.json   소스가 쓴다 → 말풍선 하나
//   <데이터 폴더>/responses/<id>.json  앱이 쓴다   → {"decision": "<버튼 id>" | "open" | "dismiss"}
// 데이터 폴더: AGENT_PET_DIR 환경변수, 기본 ~/.agent-pet
import AppKit

// =============================================================================
// 경로·설정
// =============================================================================

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let petDir = ProcessInfo.processInfo.environment["AGENT_PET_DIR"] ?? home + "/.agent-pet"
let reqDir = petDir + "/requests"
let respDir = petDir + "/responses"
let charDir = petDir + "/characters"
let settingsPath = petDir + "/settings.json"
let resourceDir = Bundle.main.resourcePath ?? "."
let legacyCharDir = "/Applications/MulticaPet.app/Contents/Resources/characters"   // 동료가 만든 기존 펫

/// 소스 목록 — 메뉴 순서
let allSources: [(key: String, label: String)] = [
    ("multica", "Multica"), ("claude", "Claude Code"), ("codex", "Codex"), ("orca", "Orca"),
]

/// settings.json — 소스 스크립트(multica_watch.py)도 "scope"를 읽는다
final class Settings {
    static let shared = Settings()
    var data: [String: Any] = [:]

    init() { load() }

    func load() {
        if let d = fm.contents(atPath: settingsPath),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            data = obj
        }
    }

    func save() {
        try? fm.createDirectory(atPath: petDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            let tmp = settingsPath + ".tmp"
            fm.createFile(atPath: tmp, contents: d)
            _ = try? fm.replaceItemAt(URL(fileURLWithPath: settingsPath), withItemAt: URL(fileURLWithPath: tmp))
        }
    }

    var sources: [String: Bool] {
        get { data["sources"] as? [String: Bool] ?? ["multica": true, "claude": true, "codex": true, "orca": true] }
        set { data["sources"] = newValue; save() }
    }
    func sourceOn(_ key: String) -> Bool { sources[key] ?? false }

    /// 앱별 설정 apps.<앱>.<키> — 소스 스크립트도 같은 값을 읽는다
    func app<T>(_ app: String, _ key: String, _ fallback: T) -> T {
        ((data["apps"] as? [String: Any])?[app] as? [String: Any])?[key] as? T ?? fallback
    }
    func setApp(_ app: String, _ key: String, _ value: Any) {
        var apps = data["apps"] as? [String: Any] ?? [:]
        var a = apps[app] as? [String: Any] ?? [:]
        a[key] = value
        apps[app] = a
        data["apps"] = apps
        save()
    }

    var scope: String {
        get { data["scope"] as? String ?? "human_turn" }
        set { data["scope"] = newValue; save() }
    }
    var character: String {
        get { data["character"] as? String ?? "" }
        set { data["character"] = newValue; save() }
    }
    var theme: String {   // auto | light | dark
        get { data["theme"] as? String ?? "auto" }
        set { data["theme"] = newValue; save() }
    }
    /// 캐릭터 크기 배율 (0.6 ~ 2.0)
    var petScale: CGFloat {
        get { CGFloat(data["pet_scale"] as? Double ?? 1.0) }
        set { data["pet_scale"] = Double(newValue); save() }
    }
    /// 펫이 지낼 모니터 이름 (비면 주 모니터)
    var display: String {
        get { data["display"] as? String ?? "" }
        set { data["display"] = newValue; save() }
    }
    var home: NSPoint? {
        get {
            guard let a = data["home"] as? [Double], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set { data["home"] = newValue.map { [Double($0.x), Double($0.y)] }; save() }
    }
}

// =============================================================================
// 요청(말풍선 하나)
// =============================================================================

/// 여러 질문에 번호로 답하는 알림의 질문 하나 (Multica 결정 대기 등)
struct PetQuestion {
    let id: String
    let title: String
    let free: Bool                                       // 선택지 없이 직접 적는 질문
    let options: [(no: String, label: String, recommended: Bool)]
    var recommended: String? { options.first { $0.recommended }?.no }
}

struct PetRequest {
    let id: String
    let source: String
    /// Orca 세션일 때 실제 도구(claude·codex)
    let agent: String
    /// Orca 세션 추천 답장 — 버튼을 누르면 이 터미널에 replies[i] 를 보낸다
    let orcaHandle: String
    let replies: [String]
    /// 추천 답장을 만드는 중 — 붙을 때까지(최대 30초) 앱이 숨긴다
    let pending: Bool
    /// 여러 질문 — 있으면 말풍선이 질문 모드(하나씩 고르고 한 번에 보내기)
    let questions: [PetQuestion]
    let tag: String
    let headline: String
    let line: String
    let detail: String
    let full: String
    /// 원문 마크다운 — 있으면 펼쳤을 때 마크다운으로 그린다
    let fullMarkdown: String
    let options: [String]
    let ids: [String]
    let primary: Int?
    let openLabel: String
    let link: String
    let created: Date

    init?(id: String, path: String) {
        guard let d = fm.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        self.id = id
        source = o["source"] as? String ?? (id.hasPrefix("demo") ? "demo" : "multica")
        agent = o["agent"] as? String ?? ""
        orcaHandle = o["orca_handle"] as? String ?? ""
        replies = o["replies"] as? [String] ?? []
        pending = o["pending"] as? Bool ?? false
        questions = (o["questions"] as? [[String: Any]] ?? []).map { q in
            PetQuestion(id: q["id"] as? String ?? "", title: q["title"] as? String ?? "", free: q["free"] as? Bool ?? false,
                        options: (q["options"] as? [[String: Any]] ?? []).map {
                            (no: $0["no"] as? String ?? "", label: $0["label"] as? String ?? "", recommended: $0["recommended"] as? Bool ?? false)
                        })
        }
        tag = o["tag"] as? String ?? ""
        headline = o["headline"] as? String ?? ""
        line = o["line"] as? String ?? ""
        detail = o["detail"] as? String ?? ""
        full = o["full"] as? String ?? ""
        fullMarkdown = o["full_md"] as? String ?? ""
        options = o["options"] as? [String] ?? []
        ids = o["ids"] as? [String] ?? options.indices.map { "reply:\($0)" }
        primary = o["primary"] as? Int ?? options.firstIndex { $0.hasPrefix("⭐") }
        openLabel = o["openLabel"] as? String ?? "열기"
        link = o["link"] as? String ?? ""
        expiresAt = (o["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        awaitsResponse = o["await"] as? Bool ?? false
        let attrs = try? fm.attributesOfItem(atPath: path)
        created = (attrs?[.creationDate] as? Date) ?? Date()
    }

    /// 이 시각이 지나면 앱이 내린다 (작업 완료 알림 등)
    let expiresAt: Date?
    /// 훅이 응답 파일을 기다리는 요청(권한 요청 등) — 아니면 앱이 직접 정리한다
    let awaitsResponse: Bool

    /// 펼쳤을 때 보일 본문 — 전문이 짧은 본문보다 충분히 길 때만
    var expandable: Bool { max(full.count, fullMarkdown.count) > detail.count + 20 }
}

// =============================================================================
// 소스 실행 (Multica 감시 스크립트)
// =============================================================================

final class SourceRunner {
    private var running: Set<String> = []

    private func run(_ key: String, _ args: [String], completion: (() -> Void)? = nil) {
        if running.contains(key) { return }
        running.insert(key)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["AGENT_PET_DIR"] = petDir
        env["PATH"] = [env["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: petDir)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.running.remove(key); completion?() }
        }
        do { try p.run() } catch { running.remove(key) }
    }

    var multicaScript: String { resourceDir + "/sources/multica_watch.py" }

    func makeCharacter(_ prompt: String, done: @escaping () -> Void) {
        run("make-character-\(Date().timeIntervalSince1970)", ["-I", resourceDir + "/sources/make_character.py", "--prompt", prompt],
            completion: done)
    }

    /// Orca 터미널에 답장 입력 + Enter — 결과는 orca.log
    func sendToOrca(handle: String, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")
        p.arguments = ["terminal", "send", "--terminal", handle, "--text", text, "--enter", "--wait-submit", "5", "--json"]
        let logPath = petDir + "/orca.log"
        fm.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        try? p.run()
    }

    func undismissMultica() {
        run("multica-undismiss", ["-I", multicaScript, "--undismiss"])
    }

    func scanMultica() {
        guard Settings.shared.sourceOn("multica") else { return }
        run("multica-scan", ["-I", multicaScript])
    }

    /// 눌린 답장 보내기 — scan과 겹쳐도 되게 키를 나눈다(스크립트가 락으로 순서를 맞춘다)
    func respondMultica() {
        run("multica-respond-\(Date().timeIntervalSince1970)", ["-I", multicaScript, "--respond"])
    }
}

// =============================================================================
// 캐릭터 스프라이트
// =============================================================================

final class Sprites {
    static let frames = ["idle", "walk1", "walk2", "sleep", "happy", "special"]
    private(set) var images: [String: NSImage] = [:]
    private(set) var name = ""
    /// 원본 이미지가 왼쪽을 보고 있는지 — 캐릭터 폴더의 character.json {"faces": "right"} 로 바꾼다 (기본 왼쪽)
    private(set) var facesLeft = true

    /// 캐릭터 폴더 목록 (frames 중 idle 이 있는 폴더)
    static func available() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: charDir)) ?? []
        return names.filter { fm.fileExists(atPath: "\(charDir)/\($0)/idle.png") }.sorted()
    }

    func load(_ wanted: String) {
        let list = Sprites.available()
        let pick = list.contains(wanted) ? wanted : (list.first ?? "")
        name = pick
        images = [:]
        facesLeft = true
        if let d = fm.contents(atPath: "\(charDir)/\(pick)/character.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            facesLeft = (o["faces"] as? String ?? "left") != "right"
        }
        if pick.isEmpty {
            images["idle"] = Sprites.fallback()
        } else {
            for f in Sprites.frames {
                if let img = NSImage(contentsOfFile: "\(charDir)/\(pick)/\(f).png") { images[f] = img }
            }
        }
    }

    /// 메뉴용 썸네일 — 폴더의 thumb.png, 없으면 idle.png 를 28pt 로 (픽셀이 번지지 않게)
    static func thumbnail(_ name: String) -> NSImage? {
        let dir = "\(charDir)/\(name)"
        guard let src = NSImage(contentsOfFile: "\(dir)/thumb.png") ?? NSImage(contentsOfFile: "\(dir)/idle.png") else { return nil }
        let side: CGFloat = 28
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSGraphicsContext.current?.imageInterpolation = .none
            let s = src.size
            let k = min(side / s.width, side / s.height)
            let w = s.width * k, h = s.height * k
            src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return true
        }
    }

    func image(_ frame: String) -> NSImage? { images[frame] ?? images["idle"] ?? Sprites.fallback() }

    /// 캐릭터가 하나도 없을 때 — 동그란 기본 얼굴
    static func fallback() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 34, width: 6, height: 8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 36, y: 34, width: 6, height: 8)).fill()
            return true
        }
    }
}

// =============================================================================
// 펫 창
// =============================================================================

final class PetView: NSView {
    var image: NSImage?
    var mirrored = false
    var badge = 0
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var downAt: NSPoint?
    private var dragged = false

    /// 통통 튀는 높이(pt) · 착지 찌그러짐(0~1) · Zzz 위상(음수면 안 그림)
    var bob: CGFloat = 0
    var squash: CGFloat = 0
    var zzz: Double = -1
    /// 모니터를 옮길 때 작아지는 효과 (1 = 원래 크기)
    var fxScale: CGFloat = 1
    /// 반짝임 위상 0~1 (음수면 안 그림) — 사라질 때·나타날 때
    var sparkle: Double = -1
    /// 걸을 때 몸 기울기(도)
    var tilt: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        NSGraphicsContext.current?.imageInterpolation = .none   // 픽셀 아트가 번지지 않게
        let s = img.size
        let ground: CGFloat = 4   // 그림자 자리
        let scale = min((bounds.width - 8) / s.width, (bounds.height - 22 - ground) / s.height)   // 위는 튀는 높이만큼 비워 둔다
        let w = s.width * scale * (1 + squash * 0.5), h = s.height * scale * (1 - squash)
        let r = NSRect(x: (bounds.width - w) / 2, y: ground + bob, width: w, height: h)

        // 발밑 그림자 — 높이 뜰수록 작고 옅게
        let lift = min(bob / 14, 1)
        let sw = w * 0.62 * (1 - lift * 0.35)
        NSColor.black.withAlphaComponent(0.16 * (1 - lift * 0.5)).setFill()
        NSBezierPath(ovalIn: NSRect(x: (bounds.width - sw) / 2, y: 1, width: sw, height: 6)).fill()

        let transformed = tilt != 0 || fxScale != 1
        if transformed {   // 발 가운데를 축으로 기울이고 줄인다
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: r.midX, yBy: r.minY)
            t.rotate(byDegrees: tilt)
            t.scale(by: fxScale)
            t.translateX(by: -r.midX, yBy: -r.minY)
            t.concat()
        }

        if zzz >= 0 {   // 자는 중: 머리 위로 z 가 떠오른다
            for i in 0..<3 {
                let p = (zzz + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let size = 9 + CGFloat(p) * 7
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(CGFloat(1 - p)),
                ]
                let x = bounds.width * 0.62 + CGFloat(p) * 18 + CGFloat(sin(p * 6)) * 3
                ("z" as NSString).draw(at: NSPoint(x: x, y: h * 0.6 + CGFloat(p) * 26), withAttributes: attrs)
            }
        }
        if mirrored {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: bounds.width, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
            img.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            img.draw(in: r)
        }
        if transformed { NSGraphicsContext.restoreGraphicsState() }   // 배지는 기울이지 않는다
        if sparkle >= 0 {   // 반짝임: 펫 둘레로 퍼지며 사라지는 별 6개
            let p = CGFloat(sparkle)
            let c = NSPoint(x: bounds.midX, y: r.minY + r.height * 0.45)
            for i in 0..<6 {
                let a = CGFloat(i) / 6 * 2 * .pi + p * 1.2
                let d = 14 + p * bounds.width * 0.42
                let star = NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
                let k = 5 * (1 - p) + 1.5
                let path = NSBezierPath()   // 네 꼭짓점 별
                path.move(to: NSPoint(x: star.x, y: star.y + k))
                path.line(to: NSPoint(x: star.x + k * 0.3, y: star.y + k * 0.3))
                path.line(to: NSPoint(x: star.x + k, y: star.y))
                path.line(to: NSPoint(x: star.x + k * 0.3, y: star.y - k * 0.3))
                path.line(to: NSPoint(x: star.x, y: star.y - k))
                path.line(to: NSPoint(x: star.x - k * 0.3, y: star.y - k * 0.3))
                path.line(to: NSPoint(x: star.x - k, y: star.y))
                path.line(to: NSPoint(x: star.x - k * 0.3, y: star.y + k * 0.3))
                path.close()
                (i % 2 == 0 ? NSColor.systemYellow : NSColor.white).withAlphaComponent(1 - p).setFill()
                path.fill()
            }
        }
        if badge > 0 {   // 오른쪽 위 빨간 숫자
            let text = badge > 9 ? "9+" : "\(badge)"
            let b = NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 20, height: 20)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: b).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: b.midX - ts.width / 2, y: b.midY - ts.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation; dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let now = NSEvent.mouseLocation
        if abs(now.x - start.x) + abs(now.y - start.y) > 3 { dragged = true }
        if dragged { onDrag?(NSPoint(x: now.x - start.x, y: now.y - start.y)); downAt = now }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() } else { onClick?() }
        downAt = nil
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 말풍선 창 — 입력 칸을 누를 때만 키보드 입력을 받는다 (테두리 없는 패널은 기본적으로 못 받는다)
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

func makePanel(_ rect: NSRect, keyable: Bool = false) -> NSPanel {
    let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    let p = keyable ? KeyablePanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                    : NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.hidesOnDeactivate = false
    p.isMovableByWindowBackground = false
    return p
}

// =============================================================================
// 말풍선
// =============================================================================

/// 버튼 — 클로저로 동작을 받는다
final class ActionButton: NSButton {
    var action_: (() -> Void)?
    convenience init(_ title: String, primary: Bool = false, small: Bool = false, _ act: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = small ? .small : .regular
        font = small ? BubbleFont.font(11) : BubbleFont.font(12, primary ? .semibold : .regular)
        if primary { bezelColor = .controlAccentColor }   // Enter 단축키는 걸지 않는다 — 다른 곳에서 친 Enter 로 답장이 나가지 않게
        action_ = act
        target = self
        action = #selector(fire)
        lineBreakMode = .byTruncatingTail
    }
    @objc func fire() { action_?() }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, lines: Int = 0) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = BubbleFont.font(size, weight)
    f.textColor = color
    f.maximumNumberOfLines = lines
    f.lineBreakMode = .byWordWrapping
    f.isSelectable = true
    f.translatesAutoresizingMaskIntoConstraints = false
    return f
}

final class BubbleView: NSVisualEffectView {
    static let width: CGFloat = 360

    var onChoose: ((PetRequest, String) -> Void)?
    var onOpen: ((PetRequest) -> Void)?
    var onDismiss: ((PetRequest) -> Void)?
    var onNav: ((Int) -> Void)?
    var onResize: (() -> Void)?
    private var expanded: Set<String> = []
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: BubbleView.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ r: PetRequest, index: Int, total: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let inner = BubbleView.width - 28

        // 맨 위 줄: 칩 + ✕
        let chip = label(r.tag, size: 11, weight: .medium, color: .secondaryLabelColor, lines: 1)
        chip.lineBreakMode = .byTruncatingTail
        let close = ActionButton("✕", small: true) { [weak self] in self?.onDismiss?(r) }
        close.isBordered = false
        close.toolTip = "이 알림 닫기 (상태가 바뀔 때까지 다시 안 띄움)"
        let top = NSStackView(views: [chip, close])
        top.distribution = .fill
        chip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(top)

        if !r.headline.isEmpty { add(label(r.headline, size: 14, weight: .semibold, lines: 4), inner) }
        if !r.line.isEmpty { add(label(r.line, size: 12, color: .secondaryLabelColor, lines: 3), inner) }

        // 본문 — 펼치면 전문을 스크롤로
        let open = expanded.contains(r.id)
        let body = open ? (r.fullMarkdown.isEmpty ? r.full : r.fullMarkdown) : r.detail
        if !body.isEmpty {
            if open {
                let tv = NSTextView()
                tv.isEditable = false
                tv.isSelectable = true
                tv.drawsBackground = false
                tv.font = BubbleFont.font(12)
                tv.textColor = .labelColor
                if r.fullMarkdown.isEmpty {
                    tv.string = body
                } else {
                    tv.textStorage?.setAttributedString(Markdown.render(body))
                    tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                             .cursor: NSCursor.pointingHand]
                }
                tv.textContainerInset = .zero
                tv.textContainer?.lineFragmentPadding = 0
                tv.textContainer?.widthTracksTextView = true
                tv.isVerticallyResizable = true
                tv.autoresizingMask = [.width]
                tv.frame = NSRect(x: 0, y: 0, width: inner, height: 10)
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 100
                let sv = NSScrollView()
                sv.drawsBackground = false
                sv.hasVerticalScroller = true
                sv.autohidesScrollers = true
                sv.documentView = tv
                sv.translatesAutoresizingMaskIntoConstraints = false
                sv.heightAnchor.constraint(equalToConstant: min(used + 4, 320)).isActive = true
                add(sv, inner)
            } else {
                add(label(body, size: 12, lines: 5), inner)
            }
        }
        if r.expandable {
            let t = ActionButton(open ? "접기 ▲" : "자세히 보기 ▼", small: true) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(r.id) { self.expanded.remove(r.id) } else { self.expanded.insert(r.id) }
                self.show(r, index: index, total: total)
                self.onResize?()
            }
            t.isBordered = false
            t.contentTintColor = .linkColor
            stack.addArrangedSubview(t)
        }

        if !r.questions.isEmpty {
            showQuestions(r, index: index, total: total, inner: inner)
        }

        // 빠른 답장 — 추천 답은 강조
        for (i, title) in r.options.enumerated() where r.questions.isEmpty {
            let id = i < r.ids.count ? r.ids[i] : "reply:\(i)"
            let b = ActionButton(title, primary: i == r.primary) { [weak self] in self?.onChoose?(r, id) }
            add(b, inner)
        }

        // 아래 줄: 열기 · 이전/다음
        var bottom: [NSView] = []
        if !r.link.isEmpty {
            bottom.append(ActionButton(r.openLabel, small: true) { [weak self] in self?.onOpen?(r) })
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.append(spacer)
        if total > 1 {
            let prev = ActionButton("◀", small: true) { [weak self] in self?.onNav?(-1) }
            let pos = label("\(index + 1)/\(total)", size: 11, color: .secondaryLabelColor, lines: 1)
            let next = ActionButton("▶", small: true) { [weak self] in self?.onNav?(1) }
            [prev, next].forEach { $0.isBordered = false }
            bottom += [prev, pos, next]
        }
        let row = NSStackView(views: bottom)
        row.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(row)
    }

    // -------------------------------------------------------------------------
    // 질문 모드 — 질문을 하나씩 보여 주고, 모든 질문 번호가 채워져야 보낼 수 있다
    // -------------------------------------------------------------------------

    /// 요청별 진행 상태: 지금 질문 위치 · 질문 번호별 답
    private var qState: [String: (at: Int, answers: [String: String])] = [:]

    private func showQuestions(_ r: PetRequest, index: Int, total: Int, inner: CGFloat) {
        var st = qState[r.id] ?? (0, [:])
        st.at = min(max(st.at, 0), r.questions.count - 1)
        qState[r.id] = st
        let q = r.questions[st.at]
        let done = r.questions.filter { !(st.answers[$0.id] ?? "").isEmpty }.count
        let redraw = { [weak self] in
            guard let self else { return }
            self.show(r, index: index, total: total)
            self.onResize?()
        }

        // 질문 머리: 「질문 3/10 · R3」 + 질문 요약
        let head = label("질문 \(st.at + 1)/\(r.questions.count) · \(q.id)", size: 11, weight: .semibold, color: .secondaryLabelColor, lines: 1)
        add(head, inner)
        add(label(q.title, size: 13, weight: .medium, lines: 3), inner)

        if q.free {   // 직접 적는 질문 — 입력 칸 + 확인
            let field = NSTextField(string: st.answers[q.id] ?? "")
            field.placeholderString = "답을 적어 주세요"
            field.font = BubbleFont.font(12)
            let ok = ActionButton("확인", primary: true, small: true) { [weak self] in
                guard let self else { return }
                let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.qState[r.id]?.answers[q.id] = v.isEmpty ? nil : v
                self.advance(r)
                redraw()
            }
            let row = NSStackView(views: [field, ok])
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            add(row, inner)
        } else {      // 선택지 — 고른 답 ✓, 추천 ⭐
            for o in q.options {
                let picked = st.answers[q.id] == o.no
                let title = (picked ? "✓ " : "") + (o.recommended ? "⭐ " : "") + "\(o.no). \(o.label)"
                let b = ActionButton(title, primary: picked) { [weak self] in
                    self?.qState[r.id]?.answers[q.id] = o.no
                    self?.advance(r)
                    redraw()
                }
                add(b, inner)
            }
        }

        // 질문 이동 · 추천대로 채우기
        let prev = ActionButton("◀ 이전 질문", small: true) { [weak self] in
            self?.qState[r.id]?.at -= 1
            redraw()
        }
        let next = ActionButton("다음 질문 ▶", small: true) { [weak self] in
            self?.qState[r.id]?.at += 1
            redraw()
        }
        prev.isEnabled = st.at > 0
        next.isEnabled = st.at < r.questions.count - 1
        let fill = ActionButton("⭐ 추천대로 채우기", small: true) { [weak self] in
            guard let self else { return }
            for q in r.questions where (self.qState[r.id]?.answers[q.id] ?? "").isEmpty {
                if let rec = q.recommended { self.qState[r.id]?.answers[q.id] = rec }
            }
            self.jumpToFirstEmpty(r)   // 추천이 없거나 직접 적을 질문으로
            redraw()
        }
        fill.isEnabled = r.questions.contains { $0.recommended != nil && (st.answers[$0.id] ?? "").isEmpty }
        let nav = NSStackView(views: [prev, fill, next])
        nav.distribution = .equalSpacing
        add(nav, inner)

        // 보내기 — 모든 질문이 채워져야 누를 수 있다
        let send = ActionButton(done == r.questions.count ? "답 보내기 (\(done)/\(r.questions.count))"
                                                          : "답 보내기 — \(r.questions.count - done)개 남음", primary: done == r.questions.count) { [weak self] in
            guard let self, let st = self.qState[r.id],
                  r.questions.allSatisfy({ !(st.answers[$0.id] ?? "").isEmpty }),
                  let d = try? JSONSerialization.data(withJSONObject: st.answers),
                  let json = String(data: d, encoding: .utf8) else { return }
            self.onChoose?(r, "multi:" + json)
        }
        send.isEnabled = done == r.questions.count
        add(send, inner)
    }

    /// 답한 뒤 다음 빈 질문으로 (없으면 그대로)
    private func advance(_ r: PetRequest) {
        guard let st = qState[r.id] else { return }
        let n = r.questions.count
        for k in 1...n {
            let i = (st.at + k) % n
            if (st.answers[r.questions[i].id] ?? "").isEmpty { qState[r.id]?.at = i; return }
        }
    }

    private func jumpToFirstEmpty(_ r: PetRequest) {
        guard let st = qState[r.id] else { return }
        if let i = r.questions.firstIndex(where: { (st.answers[$0.id] ?? "").isEmpty }) { qState[r.id]?.at = i }
    }

    private func add(_ v: NSView, _ width: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

// =============================================================================
// 앱
// =============================================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let baseSize: CGFloat = 96
    var petSize: NSSize { NSSize(width: baseSize * Settings.shared.petScale, height: baseSize * Settings.shared.petScale) }
    var petPanel: NSPanel!
    var petView: PetView!
    var bubblePanel: NSPanel!
    var bubbleView: BubbleView!
    let sprites = Sprites()
    let runner = SourceRunner()

    var requests: [PetRequest] = []
    var current = 0
    var hidden: [String: Date] = [:]   // 방금 누른 요청 — 파일이 사라질 때까지 숨김
    var bubbleOpen = true
    var lastIds: Set<String> = []

    // 움직임
    var frameTick = 0
    var walkTarget: CGFloat?
    var facingRight = true
    var happyUntil = Date.distantPast
    var lastActivity = Date()
    var pauseUntil = Date()

    /// 가만히 있을 때 고르는 행동
    enum Behavior { case walk, stand, look, jump, wave, doze, climb, hopDown, dockHop }
    var dockHops = 0

    /// 펫이 있는 곳 — 창과 상호작용(창 위로 올라가기·떨어지기)
    enum Place {
        case ground
        case perched(id: Int, offset: CGFloat)   // 창 윗변 위 (창 왼쪽에서 떨어진 거리)
        case falling(vy: CGFloat, vx: CGFloat)
        case leaping(from: NSPoint, to: NSPoint, start: Date, duration: Double, perch: Int?)
        case held                                 // 끌고 있는 중
    }
    var place: Place = .ground
    var windows: [WinSurface] = []
    var lastWindowScan = Date.distantPast
    var landedAt = Date.distantPast
    var setHomeOnLanding = false
    var lastOrigin = NSPoint.zero
    var lastPlaceKind = ""
    var summonTarget: CGFloat?   // 알림이 오면 달려갈 x
    /// 모니터 옮겨 가기 — 사라지는 중(그다음 targetScreen 위쪽에서 나타나 떨어진다)
    var transit: (start: Date, screen: NSScreen, x: CGFloat, runTo: CGFloat?)?
    var appearAt = Date.distantPast
    var outsideSince: Date?
    var mouseScreenSince: (name: String, at: Date)?
    var followMouse: Bool { Settings.shared.data["follow_mouse_screen"] as? Bool ?? false }
    var sleepTarget: CGFloat?    // 잠자리(구석) x
    var windowPlay: Bool { Settings.shared.data["window_play"] as? Bool ?? true }
    var perchedWindow: WinSurface? {
        if case .perched(let id, _) = place { return windows.first { $0.id == id } }
        return nil
    }
    var behavior: Behavior = .stand
    var behaviorStart = Date()
    var behaviorUntil = Date()
    var walkSpeed: CGFloat = 24   // pt/초
    var nextTurn = Date()

    /// 다음 행동을 가중치로 고른다 — 걷기·멈춰 서기가 대부분이고 가끔 다른 행동
    func pickBehavior(_ now: Date) {
        var table: [(Behavior, Int)] = [(.walk, 40), (.stand, 28), (.look, 12), (.jump, 7), (.wave, 8), (.doze, 5)]
        if windowPlay {   // 바닥에선 가끔 창으로 올라가고, 창 위에선 가끔 뛰어내린다
            if case .ground = place { table.append((.climb, 12)) }
            if case .perched(let id, _) = place {
                table.append((.hopDown, 7))
                if id == WindowWorld.dockId && !WindowWorld.dockIcons().isEmpty { table.append((.dockHop, 14)) }   // Dock 아이콘 건너뛰기
            }
        }
        var roll = Int.random(in: 0..<table.reduce(0) { $0 + $1.1 })
        var pick: Behavior = .stand
        for (b, w) in table { if roll < w { pick = b; break }; roll -= w }
        if pick == behavior && pick != .walk { pick = .walk }   // 같은 행동 연달아 줄이기
        behavior = pick
        behaviorStart = now
        walkTarget = nil
        switch pick {
        case .walk:
            let home = Settings.shared.home ?? petPanel.frame.origin
            let x = petPanel.frame.origin.x
            var target = home.x + CGFloat.random(in: -70...70)   // 집에서 너무 멀어지지 않게
            if let w = perchedWindow {   // 창 위: 윗변 안에서, 가끔은 가장자리 밖으로 걸어가 떨어진다
                let half = petPanel.frame.width / 2
                let lo = w.frame.minX - half + 14, hi = w.frame.maxX - half - 14
                let near = min(max(x + CGFloat.random(in: -150...150), min(lo, hi)), max(lo, hi))   // 한 번에 너무 멀리 가지 않게
                target = Int.random(in: 0..<5) == 0 ? (Bool.random() ? lo - 40 : hi + 40) : near
            }
            if abs(target - x) < 15 { target = x + (Bool.random() ? 30 : -30) }
            walkTarget = clampToScreen(target)   // 설정한 모니터 밖으로는 걸어가지 않는다
            walkSpeed = CGFloat.random(in: 18...28)
            behaviorUntil = now.addingTimeInterval(20)   // 도착하면 그 전에 끝난다
        case .stand: behaviorUntil = now.addingTimeInterval(Double.random(in: 1.5...4.5))
        case .look: behaviorUntil = now.addingTimeInterval(Double.random(in: 1.8...3.2)); nextTurn = now
        case .jump: behaviorUntil = now.addingTimeInterval(Double([1.0, 1.5].randomElement()!))   // 2~3번
        case .wave: behaviorUntil = now.addingTimeInterval(Double.random(in: 1.2...2.2))
        case .doze: behaviorUntil = now.addingTimeInterval(Double.random(in: 3...6))
        case .climb:
            behaviorUntil = now.addingTimeInterval(1.2)
            if !startClimb(now) { behavior = .stand }
        case .dockHop:
            dockHops = Int.random(in: 2...4)
            behaviorUntil = now.addingTimeInterval(8)
            if !startDockHop(now) { behavior = .stand }
        case .hopDown:
            behaviorUntil = now.addingTimeInterval(1.2)
            facingRight = Bool.random()
            place = .falling(vy: 260, vx: facingRight ? 70 : -70)   // 살짝 뛰어올랐다가 떨어진다
        }
    }

    // -------------------------------------------------------------------------
    // 창과 상호작용 — 올라가기·따라 움직이기·떨어지기
    // -------------------------------------------------------------------------

    /// (x, y) 가 있는 모니터 — 위아래로 놓인 모니터를 구분한다. 모니터 사이 빈 곳이면 그 아래 가장 가까운 모니터
    func screenAt(x: CGFloat, y: CGFloat) -> NSScreen {
        let col = NSScreen.screens.filter { $0.frame.minX <= x && x < $0.frame.maxX }
        if let s = col.first(where: { $0.frame.minY <= y + 1 && y < $0.frame.maxY }) { return s }
        if let s = col.filter({ $0.frame.maxY <= y + 1 }).max(by: { $0.frame.maxY < $1.frame.maxY }) { return s }
        return col.first ?? petPanel.screen ?? NSScreen.main!
    }

    /// 이 자리의 바닥 높이 — 지금 있는 모니터의 맨 아래 (창 놀기를 끄면 집 높이)
    func groundY(at x: CGFloat, y: CGFloat? = nil) -> CGFloat {
        let sc = screenAt(x: x, y: y ?? petPanel.frame.minY)
        if windowPlay { return sc.frame.minY + 2 }   // 화면 맨 아래 — Dock 은 그 위의 발판
        if let h = Settings.shared.home, sc.frame.contains(NSPoint(x: h.x + 1, y: h.y + 1)) { return h.y }
        return sc.visibleFrame.minY + 10
    }

    /// 창 목록 다시 읽기 — Dock 발판을 맨 앞에 (Dock 은 창들보다 위에 그려진다)
    func refreshWindows(_ now: Date) {
        windows = (WindowWorld.dockSurface().map { [$0] } ?? []) + WindowWorld.surfaces()
        lastWindowScan = now
    }

    /// Dock 아이콘 하나 건너뛰기 — 보는 방향의 다음 아이콘으로, 끝이면 돌아선다
    func startDockHop(_ now: Date) -> Bool {
        guard case .perched(let id, _) = place, id == WindowWorld.dockId,
              let dock = windows.first(where: { $0.id == id }) else { return false }
        let icons = WindowWorld.dockIcons().map { $0.frame.midX }.sorted()
        let f = petPanel.frame
        var next = facingRight ? icons.first { $0 > f.midX + 12 } : icons.last { $0 < f.midX - 12 }
        if next == nil { facingRight.toggle(); next = facingRight ? icons.first { $0 > f.midX + 12 } : icons.last { $0 < f.midX - 12 } }
        guard let nx = next else { return false }
        let to = NSPoint(x: nx - f.width / 2, y: dock.top)
        place = .leaping(from: f.origin, to: to, start: now, duration: 0.42, perch: id)
        dockHops -= 1
        return true
    }

    /// 가까운 창 윗변으로 점프 — 올라갈 창이 없으면 false
    func startClimb(_ now: Date) -> Bool {
        let f = petPanel.frame
        let half = f.width / 2
        var best: (WinSurface, CGFloat, CGFloat)?
        for w in windows where w.top > f.minY + 40 && w.top < f.minY + 850 && w.id != perchedWindow?.id {
            let tx = min(max(f.midX, w.frame.minX + half + 10), w.frame.maxX - half - 10)   // 윗변에서 펫과 가장 가까운 자리
            let dist = abs(tx - f.midX)
            guard dist < 800, homeScreen().frame.contains(NSPoint(x: tx, y: w.top + 1)),   // 설정한 모니터 안의 창만
                  WindowWorld.topVisible(w, x: tx, in: windows),
                  WindowWorld.roomAbove(w, x: tx, height: f.height) else { continue }
            if best == nil || dist < best!.2 { best = (w, tx, dist) }
        }
        guard let (w, tx, _) = best else { return false }
        motionLog("올라감 id=\(w.id) 창=\(w.frame) x=\(Int(tx))")
        let to = NSPoint(x: tx - half, y: w.top)
        facingRight = to.x > f.minX
        place = .leaping(from: f.origin, to: to, start: now, duration: 0.55 + Double(abs(to.y - f.minY)) / 900, perch: w.id)
        return true
    }

    /// 매 프레임 위치 처리. 펫을 직접 움직였으면(점프·낙하) 그 프레임 이름을 돌려준다
    func physics(_ now: Date) -> String? {
        guard windowPlay else { place = .ground; return nil }
        if now.timeIntervalSince(lastWindowScan) > 0.15 { refreshWindows(now) }
        let f = petPanel.frame
        switch place {
        case .ground, .held:
            return nil
        case .perched(let id, let offset):   // 창을 따라 움직인다. 창이 사라지거나 가려지거나 가장자리를 벗어나면 떨어진다
            guard let w = windows.first(where: { $0.id == id }) else {
                motionLog("창 사라짐 id=\(id) 목록=\(windows.count)")
                place = .falling(vy: 0, vx: 0); return "walk2"
            }
            let x = w.frame.minX + offset
            let cx = x + f.width / 2
            if cx < w.frame.minX || cx > w.frame.maxX || !WindowWorld.topVisible(w, x: cx, in: windows) {
                motionLog("떨어짐 cx=\(Int(cx)) 창=\(w.frame) 보임=\(WindowWorld.topVisible(w, x: cx, in: windows)) 앞창=\(windows.prefix(4).map { "\($0.id):\($0.frame)" })")
                place = .falling(vy: 0, vx: 0)
                return "walk2"
            }
            if abs(x - f.minX) > 0.5 || abs(w.top - f.minY) > 0.5 { petPanel.setFrameOrigin(NSPoint(x: x, y: w.top)) }
            return nil
        case .falling(var vy, let vx):
            vy -= 1600.0 / 30   // 중력
            let ny = f.minY + vy / 30
            let nx = clampToScreen(f.minX + vx / 30)
            let cx = nx + f.width / 2
            let sc = screenAt(x: cx, y: f.minY)
            var land = groundY(at: cx, y: f.minY)
            var landId: Int?
            for w in windows where w.frame.minX <= cx && cx <= w.frame.maxX && w.top <= f.minY + 0.5 && w.top >= ny && w.top > land
                && sc.frame.contains(NSPoint(x: cx, y: w.top)) {   // 같은 모니터 안의 창에만 내려앉는다
                if WindowWorld.topVisible(w, x: cx, in: windows) { land = w.top; landId = w.id }
            }
            if ny <= land {   // 착지
                petPanel.setFrameOrigin(NSPoint(x: nx, y: land))
                landedAt = now
                if let id = landId, let w = windows.first(where: { $0.id == id }) {
                    place = .perched(id: id, offset: nx - w.frame.minX)
                } else {
                    place = .ground
                    if setHomeOnLanding { Settings.shared.home = NSPoint(x: nx, y: land) }
                }
                setHomeOnLanding = false
                walkTarget = nil
                behaviorUntil = now   // 착지하면 새 행동
                return "idle"
            }
            place = .falling(vy: vy, vx: vx)
            petPanel.setFrameOrigin(NSPoint(x: nx, y: ny))
            return vy > 0 ? "happy" : "walk2"
        case .leaping(let from, let to, let start, let duration, let perch):
            let p = min(1, now.timeIntervalSince(start) / duration)
            let e = CGFloat(p)
            let arc = CGFloat(sin(p * .pi)) * (40 + abs(to.y - from.y) * 0.25)
            petPanel.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e + arc))
            if p >= 1 {
                landedAt = now
                if let id = perch, let w = windows.first(where: { $0.id == id }) {
                    place = .perched(id: id, offset: to.x - w.frame.minX)
                    if behavior == .dockHop && dockHops > 0 && startDockHop(now) { return "happy" }   // 다음 아이콘으로
                } else {
                    place = .falling(vy: 0, vx: 0)   // 그 사이 창이 사라졌으면 떨어진다
                }
                return "idle"
            }
            return "happy"
        }
    }

    func motionLog(_ msg: String) {   // 창 상호작용 문제 추적용
        let line = "\(Date()) \(msg)\n"
        let path = petDir + "/motion.log"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { fm.createFile(atPath: path, contents: line.data(using: .utf8)) }
    }

    /// 끌어다 놓은 곳 — 창 윗변 근처면 올라앉고, 공중이면 떨어지고, 바닥이면 거기가 집
    func dropPet() {
        let f = petPanel.frame
        guard windowPlay else { Settings.shared.home = f.origin; place = .ground; return }
        refreshWindows(Date())
        if let w = windows.first(where: { $0.frame.minX <= f.midX && f.midX <= $0.frame.maxX && abs(f.minY - $0.top) < 28
                                          && WindowWorld.topVisible($0, x: f.midX, in: windows) }) {
            petPanel.setFrameOrigin(NSPoint(x: f.minX, y: w.top))
            place = .perched(id: w.id, offset: f.minX - w.frame.minX)
        } else if f.minY > groundY(at: f.midX, y: f.minY) + 12 {
            place = .falling(vy: 0, vx: 0)
            setHomeOnLanding = true
        } else {
            place = .ground
            Settings.shared.home = f.origin
        }
    }
    let sleepAfter: TimeInterval = 180   // 3분 동안 알림·클릭이 없으면 잔다

    func applicationDidFinishLaunching(_ n: Notification) {
        [petDir, reqDir, respDir, charDir].forEach { try? fm.createDirectory(atPath: $0, withIntermediateDirectories: true) }
        if Settings.shared.data["sources"] == nil { Settings.shared.sources = Settings.shared.sources }   // 기본값 기록
        sprites.load(Settings.shared.character)

        let start = Settings.shared.home ?? defaultHome(on: preferredScreen())
        petPanel = makePanel(NSRect(origin: start, size: petSize))
        petView = PetView(frame: NSRect(origin: .zero, size: petSize))
        petView.autoresizingMask = [.width, .height]
        petPanel.contentView = petView
        petView.onClick = { [weak self] in self?.toggleBubble() }
        petView.onMenu = { [weak self] e in self?.showMenu(e) }
        petView.onDrag = { [weak self] d in
            self?.place = .held
            self?.walkTarget = nil
            self?.pauseUntil = Date().addingTimeInterval(1.5)   // 끌고 있는 동안은 걷지 않음
            self?.movePet(by: d)
        }
        petView.onDragEnd = { [weak self] in
            guard let self else { return }
            if let sc = self.petPanel.screen { Settings.shared.display = sc.localizedName }   // 끌어다 놓은 모니터를 기억
            self.walkTarget = nil
            self.dropPet()
        }
        petPanel.orderFrontRegardless()
        if windowPlay { place = .falling(vy: 0, vx: 0) }   // 시작하면 아래 발판(창·Dock·바닥)으로 내려앉는다

        bubblePanel = makePanel(NSRect(x: 0, y: 0, width: BubbleView.width, height: 200), keyable: true)
        bubblePanel.becomesKeyOnlyIfNeeded = true
        bubbleView = BubbleView(frame: bubblePanel.contentView!.bounds)
        bubblePanel.contentView = bubbleView
        bubbleView.onChoose = { [weak self] r, id in self?.answer(r, id) }
        bubbleView.onOpen = { [weak self] r in
            if r.link.hasPrefix("orca-worktree:") {   // Orca 채팅 모드 세션 → 그 작업 폴더를 열고 Orca 를 앞으로
                let path = String(r.link.dropFirst("orca-worktree:".count))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")
                p.arguments = ["worktree", "activate", "--worktree", "path:" + path, "--json"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { _ in
                    DispatchQueue.main.async {
                        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.stablyai.orca" }?.activate()
                    }
                }
                try? p.run()
            } else if r.link.hasPrefix("orca-terminal:") {   // Orca 에서 실행한 세션 → 그 터미널 탭으로
                let handle = String(r.link.dropFirst("orca-terminal:".count))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")
                p.arguments = ["terminal", "switch", "--terminal", handle, "--json"]
                let logPath = petDir + "/orca.log"   // 실패 원인 추적용
                fm.createFile(atPath: logPath, contents: nil)
                let log = FileHandle(forWritingAtPath: logPath)
                p.standardOutput = log ?? FileHandle.nullDevice
                p.standardError = log ?? FileHandle.nullDevice
                p.terminationHandler = { _ in
                    DispatchQueue.main.async {
                        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.stablyai.orca" }?.activate()
                    }
                }
                try? p.run()
            } else if r.link.hasPrefix("app:") {   // 터미널 앱 등을 앞으로 (claude 훅이 TERM_PROGRAM 으로 정함)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", String(r.link.dropFirst(4))]
                try? p.run()
            } else if let u = URL(string: r.link) {
                NSWorkspace.shared.open(u)
            }
            if !r.awaitsResponse { self?.answer(r, "open") }   // 권한 요청은 열어도 답은 그대로 기다린다
        }
        bubbleView.onDismiss = { [weak self] r in self?.answer(r, "dismiss") }
        bubbleView.onNav = { [weak self] d in self?.navigate(d) }
        bubbleView.onResize = { [weak self] in self?.layoutBubble() }
        applyTheme()
        ensureOnScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.ensureOnScreen() }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollRequests() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.animate() }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.runner.scanMultica() }
        runner.scanMultica()
        pollRequests()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {   // 연동 확인(처음이면 묻기) · 업데이트 확인(하루 한 번)
            Integration.checkOnLaunch()
            Updater.checkDaily()
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Updater.checkDaily() }
    }

    // -------------------------------------------------------------------------
    // 요청 읽기 — 처음 들어온 순서(파일 생성 시각)로 고정
    // -------------------------------------------------------------------------

    /// 시험용 명령 — <데이터 폴더>/cmd 에 climb · hopdown · dockhop 을 쓰면 바로 실행
    func pollCommand() {
        let path = petDir + "/cmd"
        guard let d = fm.contents(atPath: path), let cmd = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        try? fm.removeItem(atPath: path)
        let now = Date()
        lastActivity = now
        refreshWindows(now)
        let ok: Bool
        switch cmd {
        case "climb": behavior = .climb; behaviorStart = now; behaviorUntil = now.addingTimeInterval(1.5); ok = startClimb(now)
        case "dockhop": behavior = .dockHop; dockHops = 3; behaviorUntil = now.addingTimeInterval(8); ok = startDockHop(now)
        case "hopdown": behavior = .hopDown; place = .falling(vy: 260, vx: 70); ok = true
        case "sleep": lastActivity = .distantPast; ok = true   // 바로 졸리게 (잠자리로 가는지 시험)
        default:
            if cmd == "update-check" { Updater.check(manual: true); ok = true }
            else if cmd.hasPrefix("press:") {   // 시험용: 말풍선 버튼 누르기 — press:<요청 id>:<버튼 id>
                let parts = cmd.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3, let r = requests.first(where: { $0.id == parts[1] }) { answer(r, parts[2]); ok = true } else { ok = false }
            }
            else if cmd.hasPrefix("update-file:") {   // 시험용: 로컬 zip 으로 업데이트 교체
                Updater.install(from: URL(fileURLWithPath: String(cmd.dropFirst("update-file:".count))))
                ok = true
            } else { ok = false }
        }
        motionLog("명령 \(cmd) → \(ok) 장소=\(place)")
    }

    func pollRequests() {
        pollCommand()
        let files = ((try? fm.contentsOfDirectory(atPath: reqDir)) ?? []).filter { $0.hasSuffix(".json") }
        let now = Date()
        hidden = hidden.filter { files.contains($0.key + ".json") && now.timeIntervalSince($0.value) < 120 }
        var list: [PetRequest] = []
        for f in files {
            let id = String(f.dropLast(5))
            if hidden[id] != nil { continue }
            guard let r = PetRequest(id: id, path: "\(reqDir)/\(f)") else { continue }
            if r.pending && now.timeIntervalSince(r.created) < 30 { continue }   // 추천 답장 준비 중 — 다 되면 한 번에 보인다
            if let exp = r.expiresAt, exp < now {   // 만료된 알림은 내림
                try? fm.removeItem(atPath: "\(reqDir)/\(f)")
                continue
            }
            if r.source == "demo" || r.source == "pet" || Settings.shared.sourceOn(r.source) {   // Orca 세션은 Orca 설정만 따른다
                list.append(r)
            }
        }
        list.sort { ($0.created, $0.id) < ($1.created, $1.id) }

        let keepId = requests.indices.contains(current) ? requests[current].id : nil
        let ids = Set(list.map(\.id))
        let fresh = ids.subtracting(lastIds)
        let changed = list.map { "\($0.id)|\($0.headline)|\($0.detail)|\($0.options)" } !=
            requests.map { "\($0.id)|\($0.headline)|\($0.detail)|\($0.options)" }
        requests = list
        lastIds = ids
        if let k = keepId, let i = list.firstIndex(where: { $0.id == k }) { current = i } else { current = min(current, max(list.count - 1, 0)) }
        if !fresh.isEmpty && !requests.isEmpty && !list.allSatisfy({ $0.source == "pet" }) {
            summon()   // 새 알림 — 보고 있는 곳으로 와서 알린다 (캐릭터 만들기 진행 알림은 제외)
        }
        if !fresh.isEmpty {
            bubbleOpen = true
            lastActivity = Date()
            if let first = list.firstIndex(where: { fresh.contains($0.id) }), keepId == nil { current = first }
        }
        petView.badge = list.count
        petView.needsDisplay = true
        if changed || !fresh.isEmpty { refreshBubble() }
    }

    func refreshBubble() {
        guard bubbleOpen, requests.indices.contains(current) else { bubblePanel.orderOut(nil); return }
        bubbleView.show(requests[current], index: current, total: requests.count)
        layoutBubble()
        bubblePanel.orderFrontRegardless()
    }

    func layoutBubble() {
        bubbleView.layoutSubtreeIfNeeded()
        let size = bubbleView.fittingSize
        let pet = petPanel.frame
        let screen = (petPanel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = pet.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        var y = pet.maxY + 4
        if y + size.height > screen.maxY { y = pet.minY - size.height - 4 }   // 위가 좁으면 아래로
        y = max(screen.minY + 4, y)
        bubblePanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func toggleBubble() {
        if Date().timeIntervalSince(lastActivity) > sleepAfter { happyUntil = Date().addingTimeInterval(1.0) }   // 깨우면 기뻐함
        lastActivity = Date()
        bubbleOpen.toggle()
        if bubbleOpen && requests.isEmpty { happyUntil = Date().addingTimeInterval(1.2) }
        refreshBubble()
    }

    func navigate(_ d: Int) {
        guard !requests.isEmpty else { return }
        current = (current + d + requests.count) % requests.count
        refreshBubble()
    }

    // -------------------------------------------------------------------------
    // 버튼 → 응답 파일
    // -------------------------------------------------------------------------

    func answer(_ r: PetRequest, _ decision: String) {
        let path = "\(respDir)/\(r.id).json"
        if let d = try? JSONSerialization.data(withJSONObject: ["decision": decision]) {
            fm.createFile(atPath: path + ".tmp", contents: d)
            _ = try? fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: path + ".tmp"))
        }
        hidden[r.id] = Date()
        if decision.hasPrefix("reply:") { happyUntil = Date().addingTimeInterval(2) }
        lastActivity = Date()
        if r.source == "pet" && (decision.hasPrefix("update:") || decision.hasPrefix("integration:")) {
            try? fm.removeItem(atPath: "\(reqDir)/\(r.id).json")   // 펫 자체 안내 — 앱이 직접 처리
            try? fm.removeItem(atPath: path)
            if decision.hasPrefix("update:") { Updater.handle(decision) } else { Integration.handle(decision) }
        } else if r.source == "multica" {
            runner.respondMultica()
        } else if r.source == "orca", decision.hasPrefix("reply:"), !r.orcaHandle.isEmpty,
                  let i = Int(decision.dropFirst(6)), i < r.replies.count {   // Orca 추천 답장 → 그 터미널에 입력하고 제출
            runner.sendToOrca(handle: r.orcaHandle, text: r.replies[i])
            try? fm.removeItem(atPath: "\(reqDir)/\(r.id).json")
            try? fm.removeItem(atPath: path)
        } else if !r.awaitsResponse {   // 기다리는 훅이 없는 알림(작업 완료 등)은 앱이 바로 정리
            try? fm.removeItem(atPath: "\(reqDir)/\(r.id).json")
            try? fm.removeItem(atPath: path)
        }   // 권한 요청처럼 훅이 기다리는 요청은 훅이 응답 파일을 읽고 정리한다
        pollRequests()
        refreshBubble()
    }

    // -------------------------------------------------------------------------
    // 움직임·애니메이션
    // -------------------------------------------------------------------------

    func movePet(by d: NSPoint) {
        var f = petPanel.frame
        f.origin.x += d.x
        f.origin.y += d.y
        petPanel.setFrameOrigin(f.origin)
        if bubblePanel.isVisible { layoutBubble() }
    }

    /// target(x) 쪽으로 한 걸음 — 도착했으면 nil, 아니면 (프레임, 들썩임, 기울기).
    /// 바닥에서 Dock 에 닿으면 Dock 위로 뛰어오르고, 창 위면 창 기준 위치를 갱신한다
    func walkStep(toward target: CGFloat, speed: CGFloat, now: Date, t: Double) -> (String, CGFloat, CGFloat)? {
        let x = petPanel.frame.origin.x
        let step = speed / 30
        if abs(target - x) <= step { return nil }
        facingRight = target > x
        let nextX = x + (facingRight ? step : -step)
        let cx = nextX + petPanel.frame.width / 2
        if case .ground = place, windowPlay, let dock = windows.first(where: { $0.id == WindowWorld.dockId }),
           cx > dock.frame.minX, cx < dock.frame.maxX, petPanel.frame.minY < dock.top - 10 {   // Dock 뒤로 들어가 가려지지 않게
            let to = NSPoint(x: nextX + (facingRight ? 30 : -30), y: dock.top)
            place = .leaping(from: petPanel.frame.origin, to: to, start: now, duration: 0.6, perch: dock.id)
            return ("happy", 0, 0)
        }
        petPanel.setFrameOrigin(NSPoint(x: nextX, y: petPanel.frame.origin.y))
        if case .perched(let id, _) = place, let w = windows.first(where: { $0.id == id }) {
            place = .perched(id: id, offset: petPanel.frame.minX - w.frame.minX)   // 창 위에서 걸은 만큼
        }
        let beat = 0.22 * 24 / Double(speed)   // 느릴수록 걸음도 느리게
        let frame = Int(t / beat) % 2 == 0 ? "walk1" : "walk2"
        let bob = hop(t, period: beat * 2, height: speed > 50 ? 4 : 2).bob
        return (frame, bob, CGFloat(sin(t * .pi / beat)) * 2.5)   // 걸음마다 살짝 기우뚱
    }

    /// 창(Dock 제외) 위에 있으면 뛰어내린다 — 잠자리·알림 위치로 가기 전에
    func hopDownIfOnWindow(towardRight right: Bool) -> Bool {
        if case .perched(let id, _) = place, id != WindowWorld.dockId {
            place = .falling(vy: 220, vx: right ? 80 : -80)
            return true
        }
        return false
    }

    // -------------------------------------------------------------------------
    // 잠자리 · 알림 위치
    // -------------------------------------------------------------------------

    /// 지금 모니터의 가까운 아래 구석 x
    func bedX() -> CGFloat {
        let f = petPanel.frame
        let sc = NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? petPanel.screen ?? NSScreen.main!
        return f.midX < sc.frame.midX ? sc.frame.minX + 6 : sc.frame.maxX - f.width - 6
    }

    /// 다른 모니터로 옮겨 가기 — 폴짝 뛰며 작아져 사라졌다가, 그 모니터 위쪽에서 반짝 나타나 떨어진다
    /// runTo: 나타난 뒤 달려갈 x (알림으로 불려 갈 때)
    func travel(to sc: NSScreen, x: CGFloat, runTo: CGFloat? = nil) {
        guard transit == nil else { return }
        walkTarget = nil
        summonTarget = nil
        sleepTarget = nil
        transit = (Date(), sc, min(max(x, sc.frame.minX + 20), sc.frame.maxX - petPanel.frame.width - 20), runTo)
    }

    /// 옮겨 가기 진행 — 진행 중이면 프레임 이름, 끝났으면 nil
    func transitStep(_ now: Date) -> String? {
        guard let tr = transit else { return nil }
        let p = min(1, now.timeIntervalSince(tr.start) / 0.45)
        petView.fxScale = 1 - CGFloat(p) * 0.85
        petView.sparkle = p
        petPanel.alphaValue = 1 - CGFloat(p) * 0.9
        if p < 1 { return "happy" }
        // 도착: 새 모니터의 아래 구석(목표 x 에 가까운 쪽)에 순간이동하듯 나타난다
        transit = nil
        let f = petPanel.frame
        let sc = tr.screen
        let cornerX = tr.x + f.width / 2 < sc.frame.midX ? sc.frame.minX + 6 : sc.frame.maxX - f.width - 6
        appearAt = now
        Settings.shared.display = sc.localizedName
        if windowPlay {
            refreshWindows(now)
            let cx = cornerX + f.width / 2
            if let dock = windows.first(where: { $0.id == WindowWorld.dockId && $0.frame.minX <= cx && cx <= $0.frame.maxX
                                                  && sc.frame.contains(NSPoint(x: cx, y: $0.top)) }) {
                petPanel.setFrameOrigin(NSPoint(x: cornerX, y: dock.top))   // 구석이 Dock 위면 Dock 에
                place = .perched(id: dock.id, offset: cornerX - dock.frame.minX)
            } else {
                petPanel.setFrameOrigin(NSPoint(x: cornerX, y: sc.frame.minY + 2))
                place = .ground
            }
        } else {
            petPanel.setFrameOrigin(NSPoint(x: cornerX, y: sc.visibleFrame.minY + 10))
            Settings.shared.home = petPanel.frame.origin
            place = .ground
        }
        summonTarget = tr.runTo   // 알림이면 나타난 뒤 마우스 쪽으로 달려간다
        if bubblePanel.isVisible { layoutBubble() }
        return "happy"
    }

    /// 마우스가 다른 모니터에 1.2초 넘게 머물면 그리로 옮겨 간다 (설정 「마우스 모니터 따라다니기」)
    func followMouseStep(_ now: Date) {
        guard followMouse, transit == nil, frameTick % 10 == 0 else { return }
        if case .held = place { return }
        let mouse = NSEvent.mouseLocation
        guard let msc = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        let f = petPanel.frame
        if msc.frame.contains(NSPoint(x: f.midX, y: f.midY)) { mouseScreenSince = nil; return }
        if mouseScreenSince?.name != msc.localizedName { mouseScreenSince = (msc.localizedName, now); return }
        if now.timeIntervalSince(mouseScreenSince!.at) >= 1.2 {
            mouseScreenSince = nil
            travel(to: msc, x: mouse.x - f.width / 2)
        }
    }

    /// 알림 위치로 한 번 점프 (최대 200pt) — 도착했으면 false
    func summonHop(toward target: CGFloat, now: Date) -> Bool {
        let f = petPanel.frame
        let remain = target - f.minX
        if abs(remain) < 4 { summonTarget = nil; return false }
        guard case .ground = place else {   // Dock 위면 그대로 이어서, 창 위면 먼저 내려온다
            if case .perched(let id, _) = place, id == WindowWorld.dockId {} else { return false }
            return startSummonHop(remain, f, now)
        }
        return startSummonHop(remain, f, now)
    }

    private func startSummonHop(_ remain: CGFloat, _ f: NSRect, _ now: Date) -> Bool {
        let dx = remain > 0 ? min(remain, 200) : max(remain, -200)
        let tx = f.minX + dx
        let cx = tx + f.width / 2
        let sc = screenAt(x: cx, y: f.minY)
        facingRight = dx > 0
        if windowPlay, let dock = windows.first(where: { $0.id == WindowWorld.dockId && $0.frame.minX <= cx && cx <= $0.frame.maxX
                                                         && sc.frame.contains(NSPoint(x: cx, y: $0.top)) }) {
            place = .leaping(from: f.origin, to: NSPoint(x: tx, y: dock.top), start: now, duration: 0.5, perch: dock.id)
        } else {
            let gy = windowPlay ? groundY(at: cx, y: f.minY) : f.minY
            place = .leaping(from: f.origin, to: NSPoint(x: tx, y: gy), start: now, duration: 0.5, perch: nil)
        }
        return true
    }

    /// 새 알림 — 마우스가 있는 모니터(지금 보고 있는 곳)로 와서 알린다
    func summon() {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        // 모니터 설정을 따른다 — 따라다니기를 켜면 마우스 모니터, 끄면 메뉴에서 고른 모니터
        let sc = followMouse ? (mouseScreen ?? preferredScreen()) : preferredScreen()
        let f = petPanel.frame
        let mouseHere = mouseScreen == sc
        sleepTarget = nil
        // 마우스가 그 모니터에 있으면 마우스 아래로, 아니면 지금 x 를 그대로 (그 모니터 안으로만)
        let wantX = mouseHere ? mouse.x - f.width / 2 : f.minX
        let tx = min(max(wantX, sc.frame.minX + 20), sc.frame.maxX - f.width - 20)
        let onScreen = sc.frame.contains(NSPoint(x: f.midX, y: f.midY))
        if !windowPlay {   // 창 놀기를 끄면 그 모니터 아래쪽으로 바로
            if mouseHere || !onScreen { petPanel.setFrameOrigin(NSPoint(x: tx, y: sc.visibleFrame.minY + 10)) }
            return
        }
        if !onScreen {   // 다른 모니터에 있으면 그 모니터 구석으로 순간이동 (마우스가 거기 있으면 이어서 점프해 온다)
            travel(to: sc, x: tx, runTo: mouseHere ? tx : nil)
            return
        }
        guard mouseHere else { return }   // 마우스가 다른 모니터 — 그 자리에서 손짓만
        summonTarget = tx
        _ = hopDownIfOnWindow(towardRight: tx > f.minX)
    }

    /// 통통 튀기 — 주기 period 초, 높이 height. 땅에 닿는 순간 살짝 찌그러진다
    func hop(_ t: Double, period: Double, height: CGFloat) -> (bob: CGFloat, squash: CGFloat) {
        let p = t.truncatingRemainder(dividingBy: period) / period   // 0~1
        let up = CGFloat(sin(p * .pi))                                // 0 → 1 → 0
        let landing = p < 0.12 ? CGFloat(1 - p / 0.12) : 0           // 착지 직후
        return (up * height, landing * 0.12)
    }

    func animate() {
        frameTick += 1
        let now = Date()
        let t = now.timeIntervalSinceReferenceDate
        var frame = "idle"
        var bob: CGFloat = 0, squash: CGFloat = 0
        var zzz: Double = -1
        var tilt: CGFloat = 0

        followMouseStep(now)
        let appear = now.timeIntervalSince(appearAt)
        petView.sparkle = appear < 0.6 ? appear / 0.6 : -1   // 나타날 때 반짝
        if transit == nil {   // 나타날 때 작게 시작해 커진다
            let g = CGFloat(min(1, appear / 0.35))
            petView.fxScale = 0.15 + 0.85 * g
            petPanel.alphaValue = 0.1 + 0.9 * g
        }
        if let moving = transitStep(now) {   // 모니터 옮겨 가는 중
            frame = moving
            bob = CGFloat(min(1, now.timeIntervalSince(transit?.start ?? now) / 0.45)) * 26
        } else if let moved = physics(now) {   // 점프·낙하 중엔 행동 대신 그 동작
            frame = moved
            if case .falling = place { tilt = CGFloat(sin(t * 9)) * 6 }   // 떨어질 땐 버둥버둥
        } else if now.timeIntervalSince(landedAt) < 0.18 {   // 착지 찌그러짐
            squash = 0.18 * CGFloat(1 - now.timeIntervalSince(landedAt) / 0.18)
        } else if now < happyUntil {   // 답장·클릭 직후 기뻐서 높이 뜀
            frame = "happy"
            (bob, squash) = hop(t, period: 0.45, height: 12)
        } else if !requests.isEmpty {   // 알림: 보고 있는 곳까지 달려온 뒤 제자리에서 손짓
            walkTarget = nil
            if let target = summonTarget, windowPlay, summonHop(toward: target, now: now) {   // 폴짝폴짝 점프해서 다가온다
                frame = "happy"
            } else if let target = summonTarget, !windowPlay, let st = walkStep(toward: target, speed: 110, now: now, t: t) {
                (frame, bob, tilt) = st   // 창 놀기를 끄면 점프 처리가 없어 달려온다
            } else {
                summonTarget = nil
                frame = "special"
                (bob, squash) = hop(t, period: 0.9, height: 2)
            }
        } else if now.timeIntervalSince(lastActivity) > sleepAfter {   // 오래 조용하면 구석으로 가서 잔다
            walkTarget = nil
            if sleepTarget == nil {
                sleepTarget = windowPlay ? bedX() : nil
                if let b = sleepTarget { _ = hopDownIfOnWindow(towardRight: b > petPanel.frame.minX) }
            }
            if let bed = sleepTarget, let st = walkStep(toward: bed, speed: 20, now: now, t: t) {   // 졸린 걸음으로 천천히
                (frame, bob, tilt) = st
            } else {
                frame = "sleep"   // 숨쉬듯 들썩이고 z 가 떠오름
                squash = CGFloat(sin(t * 1.6) + 1) * 0.025
                zzz = (t / 2.4).truncatingRemainder(dividingBy: 1)
            }
        } else {   // 가만히: 무작위 행동 (걷기·멈춰 서기·두리번·점프·손 흔들기·꾸벅꾸벅)
            sleepTarget = nil
            if now < pauseUntil {   // 끌어다 놓은 직후엔 잠깐 서 있기
                behavior = .stand
                behaviorUntil = pauseUntil
            } else if now >= behaviorUntil || (behavior == .walk && walkTarget == nil) {
                pickBehavior(now)
            }
            let local = now.timeIntervalSince(behaviorStart)
            switch behavior {
            case .walk:
                if let target = walkTarget, let st = walkStep(toward: target, speed: walkSpeed, now: now, t: t) {
                    (frame, bob, tilt) = st
                } else {
                    walkTarget = nil   // 도착 → 다음 행동
                }
            case .stand:
                (bob, squash) = hop(t, period: 1.6, height: 2)
            case .look:   // 두리번: 0.6~1초마다 방향을 바꾼다
                if now >= nextTurn {
                    facingRight.toggle()
                    nextTurn = now.addingTimeInterval(Double.random(in: 0.6...1.0))
                }
            case .jump:   // 제자리에서 2~3번 콩콩
                (bob, squash) = hop(local, period: 0.5, height: 11)
                frame = "happy"
            case .wave:
                frame = "special"
                (bob, squash) = hop(t, period: 0.8, height: 2)
            case .doze:   // 꾸벅꾸벅 (z 없이)
                frame = "sleep"
                squash = CGFloat(sin(t * 2.2) + 1) * 0.02
            case .climb, .hopDown, .dockHop:   // 점프·낙하는 physics 가 움직인다 — 끝난 뒤 잠깐 서 있기
                (bob, squash) = hop(t, period: 1.6, height: 2)
            }
        }
        petView.tilt = tilt
        petView.mirrored = sprites.facesLeft ? facingRight : !facingRight   // 가는 방향을 보게
        let img = sprites.image(frame)
        if petView.image !== img { petView.image = img }
        petView.bob = bob
        petView.squash = squash
        petView.zzz = zzz
        petView.needsDisplay = true
        let kind = "\(place)".components(separatedBy: "(").first ?? ""
        if kind != lastPlaceKind { motionLog("장소 \(lastPlaceKind) → \(place)"); lastPlaceKind = kind }
        keepOnHomeScreen(now)
        let origin = petPanel.frame.origin
        if bubblePanel.isVisible, origin != lastOrigin { layoutBubble() }
        lastOrigin = origin
    }

    // -------------------------------------------------------------------------
    // 메뉴
    // -------------------------------------------------------------------------

    func item(_ title: String, checked: Bool = false, _ act: @escaping () -> Void) -> NSMenuItem {
        let m = ClosureMenuItem(title: title, act)
        m.state = checked ? .on : .off
        return m
    }

    func showMenu(_ e: NSEvent) {
        let menu = NSMenu()
        if let av = Updater.available {   // 새 버전이 남아 있는 동안 계속 보인다 (건너뛴 버전도)
            menu.addItem(item("⬆︎ \(av.version) 로 업데이트 (지금 \(Updater.current))") { Updater.handle("update:install") })
            menu.addItem(.separator())
        }
        if !requests.isEmpty {
            menu.addItem(item("다음 알림 \(requests.count)개 보기") { [weak self] in self?.bubbleOpen = true; self?.refreshBubble() })
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "알림 범위", action: nil, keyEquivalent: "").submenu = notifyMenu()

        let chars = NSMenu()
        let names = Sprites.available()
        if !names.isEmpty {   // 썸네일 격자 — 누르면 바로 바뀌고 메뉴가 닫힌다
            let grid = CharacterGrid(names: names, selected: sprites.name) { [weak self] c in
                Settings.shared.character = c
                self?.sprites.load(c)
                self?.petView.image = nil
            }
            let m = NSMenuItem()
            m.view = grid
            chars.addItem(m)
        }
        if !chars.items.isEmpty { chars.addItem(.separator()) }
        if fm.fileExists(atPath: legacyCharDir) {
            chars.addItem(item("기존 Multica 펫에서 캐릭터 가져오기") { [weak self] in self?.importLegacyCharacters() })
        }
        chars.addItem(item("AI로 캐릭터 만들기…") { [weak self] in self?.makeCharacter() })
        chars.addItem(item("캐릭터 폴더 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: charDir)) })
        chars.addItem(item("다시 읽기") { [weak self] in self?.sprites.load(Settings.shared.character); self?.petView.image = nil })
        menu.addItem(withTitle: "캐릭터", action: nil, keyEquivalent: "").submenu = chars
        menu.addItem(sizeSliderItem())
        let play = windowPlay
        let playItem = item("창·Dock 위에 올라가 놀기", checked: play) { [weak self] in
            Settings.shared.data["window_play"] = !play
            Settings.shared.save()
            if !play && !AXIsProcessTrusted() {   // 켤 때 Dock 아이콘을 읽을 손쉬운 사용 권한을 함께 요청
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            if !play { self?.place = .falling(vy: 0, vx: 0) }
            if play, let self {   // 끄면 바닥(집)으로 돌아간다
                self.place = .ground
                if let h = Settings.shared.home { self.petPanel.setFrameOrigin(h) }
            }
        }
        playItem.toolTip = AXIsProcessTrusted() ? "Dock 아이콘 위도 건너뛰어요" : "손쉬운 사용 권한을 주면 Dock 아이콘 위도 건너뛰어요 (끄고 다시 켜면 요청)"
        menu.addItem(playItem)

        let screens = NSMenu()
        let cur = petPanel.screen
        for sc in NSScreen.screens {
            let title = sc.localizedName + (sc == NSScreen.screens.first ? " (주 모니터)" : "")
            screens.addItem(item(title, checked: sc == cur) { [weak self] in self?.moveToScreen(sc) })
        }
        screens.addItem(.separator())
        let follow = followMouse
        screens.addItem(item("마우스가 있는 모니터 따라다니기", checked: follow) {
            Settings.shared.data["follow_mouse_screen"] = !follow
            Settings.shared.save()
        })
        menu.addItem(withTitle: "모니터", action: nil, keyEquivalent: "").submenu = screens

        let theme = NSMenu()
        for (key, title) in [("auto", "자동 (시스템 따라)"), ("light", "밝게"), ("dark", "어둡게")] {
            theme.addItem(item(title, checked: Settings.shared.theme == key) { [weak self] in
                Settings.shared.theme = key
                self?.applyTheme()
            })
        }
        menu.addItem(withTitle: "말풍선 테마", action: nil, keyEquivalent: "").submenu = theme
        menu.addItem(withTitle: "말풍선 글꼴", action: nil, keyEquivalent: "").submenu = fontMenu()

        menu.addItem(.separator())
        menu.addItem(item("지금 확인") { [weak self] in self?.runner.scanMultica() })
        menu.addItem(item("테스트 알림 보기") { [weak self] in self?.writeDemo() })
        menu.addItem(item("여기를 집으로") { [weak self] in
            guard let self else { return }
            Settings.shared.home = self.petPanel.frame.origin
        })
        menu.addItem(item("데이터 폴더 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: petDir)) })
        menu.addItem(.separator())
        let linked = Integration.choice == "on"
        menu.addItem(item(linked ? "연동 설정… (Claude Code·Codex 연결됨)" : "연동 설정… (Claude Code·Codex 연결 안 됨)") {
            Integration.promptInstall()
        })
        menu.addItem(item("업데이트 확인… (지금 \(Updater.current))") { Updater.check(manual: true) })
        menu.addItem(.separator())
        menu.addItem(item("펫 종료") { NSApp.terminate(nil) })
        NSMenu.popUpContextMenu(menu, with: e, for: petView)
    }

    // -------------------------------------------------------------------------
    // 크기·모니터
    // -------------------------------------------------------------------------

    /// 메뉴 안의 크기 슬라이더 — 움직이는 대로 바로 바뀌고 저장된다
    func sizeSliderItem() -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let title = NSTextField(labelWithString: "캐릭터 크기 \(Int(Settings.shared.petScale * 100))%")
        title.font = .menuFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 24, width: 200, height: 18)
        let slider = ClosureSlider(value: Double(Settings.shared.petScale), min: 0.6, max: 2.0) { [weak self] val in
            let snapped = (val * 20).rounded() / 20   // 5% 단위
            title.stringValue = "캐릭터 크기 \(Int(snapped * 100))%"
            self?.applyScale(CGFloat(snapped))
        }
        slider.frame = NSRect(x: 18, y: 2, width: 204, height: 22)
        v.addSubview(title)
        v.addSubview(slider)
        let m = NSMenuItem()
        m.view = v
        return m
    }

    /// 발 위치(아래 가운데)를 그대로 두고 크기만 바꾼다
    func applyScale(_ scale: CGFloat) {
        guard abs(scale - Settings.shared.petScale) > 0.001 else { return }
        let old = petPanel.frame
        Settings.shared.petScale = scale
        let size = petSize
        let origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        petPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        if let h = Settings.shared.home { Settings.shared.home = NSPoint(x: h.x + (old.width - size.width) / 2, y: h.y) }
        if bubblePanel.isVisible { layoutBubble() }
    }

    /// 펫이 머물 모니터 — 메뉴에서 고른 모니터 (따라다니기를 켜면 옮겨 갈 때마다 바뀐다)
    func homeScreen() -> NSScreen { preferredScreen() }

    /// x 를 머물 모니터 안으로
    func clampToScreen(_ x: CGFloat) -> CGFloat {
        let f = homeScreen().frame
        return min(max(x, f.minX + 4), f.maxX - petPanel.frame.width - 4)
    }

    /// 머물 모니터를 1초 넘게 벗어나 있으면(올라탄 창이 다른 모니터로 옮겨졌을 때 등) 그 모니터로 돌아온다
    func keepOnHomeScreen(_ now: Date) {
        guard frameTick % 10 == 0, transit == nil else { return }
        switch place { case .held, .leaping: return; default: break }
        let f = petPanel.frame
        let sc = homeScreen()
        if sc.frame.contains(NSPoint(x: f.midX, y: f.minY + 4)) { outsideSince = nil; return }
        if outsideSince == nil { outsideSince = now; return }
        if now.timeIntervalSince(outsideSince!) >= 1 {
            outsideSince = nil
            motionLog("모니터 밖 → \(sc.localizedName) 로 돌아옴")
            travel(to: sc, x: clampToScreen(f.minX))
        }
    }

    func preferredScreen() -> NSScreen {
        NSScreen.screens.first { $0.localizedName == Settings.shared.display } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func defaultHome(on screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        return NSPoint(x: f.maxX - petSize.width - 40, y: f.minY + 10)
    }

    /// 고른 모니터의 오른쪽 아래로 옮기고 그 자리를 집으로
    func moveToScreen(_ screen: NSScreen, animated: Bool = true) {
        Settings.shared.display = screen.localizedName
        let home = defaultHome(on: screen)
        Settings.shared.home = home
        walkTarget = nil
        if animated && petPanel != nil && petPanel.isVisible {
            travel(to: screen, x: home.x)
            return
        }
        petPanel.setFrameOrigin(home)
        if bubblePanel.isVisible { layoutBubble() }
    }

    /// 모니터를 빼거나 배치가 바뀌어 펫이 화면 밖에 있으면 고른 모니터(없으면 주 모니터)로 데려온다
    func ensureOnScreen() {
        let f = petPanel.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(f.insetBy(dx: f.width * 0.3, dy: f.height * 0.3)) }
        let want = preferredScreen()
        let onWanted = want.visibleFrame.intersects(f)
        if !visible || (!onWanted && want.localizedName == Settings.shared.display) {
            moveToScreen(want, animated: visible)   // 화면 밖이면 바로, 보이는 곳이면 애니메이션
        }
    }

    /// 설명을 받아 make_character.py 로 오리지널 캐릭터를 만든다 — 진행·완료는 스크립트가 말풍선으로 알린다
    func makeCharacter() {
        let a = NSAlert()
        a.messageText = "AI로 캐릭터 만들기"
        a.informativeText = "어떤 캐릭터를 원하세요? 2~5분쯤 걸려요.\n기존 작품의 캐릭터를 따라 그리지 않고, 설명의 분위기를 살린 오리지널로 만들어요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "예: 빨간 목도리를 한 졸린 아기 고양이"
        a.accessoryView = field
        a.addButton(withTitle: "만들기")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        runner.makeCharacter(prompt) { [weak self] in
            self?.happyUntil = Date().addingTimeInterval(2)
            self?.lastActivity = Date()
        }
    }

    // -------------------------------------------------------------------------
    // 알림 범위 — 앱별 알림 받기 + 앱 전용 설정
    // -------------------------------------------------------------------------

    func header(_ title: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        m.isEnabled = false
        return m
    }

    /// 작업 완료 알림을 자동으로 내리는 시간 고르기 (claude·codex 공용)
    func expireItems(_ app: String, into m: NSMenu) {
        m.addItem(.separator())
        m.addItem(header("작업 완료 알림 내리기"))
        let cur = Settings.shared.app(app, "expire", 3600.0)
        for (sec, title) in [(600.0, "10분 뒤"), (3600.0, "1시간 뒤 (기본)"), (0.0, "직접 닫을 때까지")] {
            m.addItem(item(title, checked: cur == sec) { Settings.shared.setApp(app, "expire", sec) })
        }
    }

    func notifyMenu() -> NSMenu {
        let root = NSMenu()
        for s in allSources {
            let sub = NSMenu()
            sub.addItem(item("알림 받기", checked: Settings.shared.sourceOn(s.key)) { [weak self] in
                var m = Settings.shared.sources
                m[s.key] = !(m[s.key] ?? false)
                Settings.shared.sources = m
                if s.key == "multica" { self?.runner.scanMultica() }
                self?.pollRequests()
            })
            sub.addItem(.separator())
            switch s.key {
            case "multica":
                sub.addItem(header("알릴 이슈"))
                for (key, title) in [("human_turn", "사람 차례만 · 하위 이슈 모두 끝남 (기본)"),
                                     ("decision", "결정 대기 (AI가 내 선택을 기다림)"),
                                     ("all", "내가 볼 것 전부 (메뉴바 빨간 줄 모두)")] {
                    sub.addItem(item(title, checked: Settings.shared.scope == key) { [weak self] in
                        Settings.shared.scope = key
                        self?.runner.scanMultica()
                    })
                }
                sub.addItem(.separator())
                sub.addItem(header("멈춤 알림 기준 (마지막 활동 뒤)"))
                let cur = Settings.shared.app("multica", "stuck_min", 5)
                for m in [3, 5, 10, 20] {
                    sub.addItem(item("\(m)분" + (m == 5 ? " (기본)" : ""), checked: cur == m) { [weak self] in
                        Settings.shared.setApp("multica", "stuck_min", m)
                        self?.runner.scanMultica()
                    })
                }
                sub.addItem(.separator())
                let rec = Settings.shared.app("multica", "suggest", true)
                sub.addItem(item("추천 답장 만들기 (Claude)", checked: rec) { Settings.shared.setApp("multica", "suggest", !rec) })
            case "claude":
                sub.addItem(header("Orca 밖에서 실행한 세션 (Orca 세션은 Orca 설정)"))
                sub.addItem(header("알릴 때 — Orca 세션에도 적용"))
                for (key, title) in [("stop", "작업 완료"), ("idle", "입력을 기다릴 때"), ("permission_prompt", "승인을 기다릴 때")] {
                    let on = Settings.shared.app("claude", key, true)
                    sub.addItem(item(title, checked: on) { Settings.shared.setApp("claude", key, !on) })
                }
                sub.addItem(.separator())
                let perm = Settings.shared.data["claude_permission"] as? Bool ?? false
                sub.addItem(item("권한 요청을 펫에서 답하기 (실험)", checked: perm) {
                    Settings.shared.data["claude_permission"] = !perm
                    Settings.shared.save()
                })
                expireItems("claude", into: sub)
            case "codex":
                sub.addItem(header("알릴 때: 작업 완료 (Codex 가 알려 주는 것은 이것뿐)"))
                expireItems("codex", into: sub)
            case "orca":
                sub.addItem(header("Orca 에서 실행한 Claude Code·Codex 세션 — Claude·Codex 를 꺼도 따로 알림"))
                sub.addItem(header("알림을 누르면 그 Orca 탭으로 이동해요"))
                sub.addItem(.separator())
                let rec = Settings.shared.app("orca", "suggest", true)
                sub.addItem(item("추천 답장 만들기 — 누르면 그 터미널에 입력 (Claude)", checked: rec) {
                    Settings.shared.setApp("orca", "suggest", !rec)
                })
            default: break
            }
            let top = NSMenuItem(title: s.label + (Settings.shared.sourceOn(s.key) ? "" : " (꺼짐)"), action: nil, keyEquivalent: "")
            top.submenu = sub
            root.addItem(top)
        }
        root.addItem(.separator())
        root.addItem(item("닫은 Multica 알림 다시 보기") { [weak self] in self?.runner.undismissMultica() })
        return root
    }

    /// 말풍선 글꼴 메뉴 — 글꼴 종류 + 글자 크기 슬라이더. 바꾸면 떠 있는 말풍선에 바로 적용
    func fontMenu() -> NSMenu {
        let m = NSMenu()
        let cur = BubbleFont.family
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        func pick(_ fam: String) -> () -> Void {
            { [weak self] in
                Settings.shared.data["font_family"] = fam
                Settings.shared.save()
                self?.refreshBubble()
            }
        }
        m.addItem(item("시스템 기본 (SF)", checked: cur.isEmpty, pick("")))
        for fam in BubbleFont.preferred where installed.contains(fam) {
            let it = item(fam, checked: cur == fam, pick(fam))
            it.attributedTitle = NSAttributedString(string: fam, attributes: [.font: NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13) ?? NSFont.menuFont(ofSize: 13)])
            m.addItem(it)
        }
        let more = NSMenu()
        for fam in BubbleFont.koreanFamilies() where !BubbleFont.preferred.contains(fam) {
            more.addItem(item(fam, checked: cur == fam, pick(fam)))
        }
        if !more.items.isEmpty { m.addItem(withTitle: "다른 글꼴 (한글 지원)", action: nil, keyEquivalent: "").submenu = more }
        m.addItem(.separator())
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let title = NSTextField(labelWithString: "글자 크기 \(Int(BubbleFont.scale * 100))%")
        title.font = .menuFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 24, width: 200, height: 18)
        let slider = ClosureSlider(value: Double(BubbleFont.scale), min: 0.8, max: 1.4) { [weak self] val in
            let snapped = (val * 20).rounded() / 20   // 5% 단위
            title.stringValue = "글자 크기 \(Int(snapped * 100))%"
            guard abs(snapped - Double(BubbleFont.scale)) > 0.001 else { return }
            Settings.shared.data["font_scale"] = snapped
            Settings.shared.save()
            self?.refreshBubble()
        }
        slider.frame = NSRect(x: 18, y: 2, width: 204, height: 22)
        v.addSubview(title)
        v.addSubview(slider)
        let s = NSMenuItem()
        s.view = v
        m.addItem(s)
        return m
    }

    func applyTheme() {
        switch Settings.shared.theme {
        case "light": bubblePanel.appearance = NSAppearance(named: .aqua)
        case "dark": bubblePanel.appearance = NSAppearance(named: .darkAqua)
        default: bubblePanel.appearance = nil
        }
    }

    /// 이 맥에 설치된 기존 Multica 펫의 캐릭터 이미지를 내 캐릭터 폴더로 복사한다 (앱에는 넣지 않는다)
    func importLegacyCharacters() {
        let names = (try? fm.contentsOfDirectory(atPath: legacyCharDir)) ?? []
        var n = 0
        for c in names where fm.fileExists(atPath: "\(legacyCharDir)/\(c)/idle.png") {
            let dst = "\(charDir)/\(c)"
            if !fm.fileExists(atPath: dst), (try? fm.copyItem(atPath: "\(legacyCharDir)/\(c)", toPath: dst)) != nil { n += 1 }
            let thumb = "\(legacyCharDir)/\(c).png"   // 기존 펫은 폴더 옆 <이름>.png 를 썸네일로 썼다
            if fm.fileExists(atPath: thumb), !fm.fileExists(atPath: "\(dst)/thumb.png") {
                try? fm.copyItem(atPath: thumb, toPath: "\(dst)/thumb.png")
            }
        }
        if Settings.shared.character.isEmpty, let first = Sprites.available().first {
            Settings.shared.character = first
        }
        sprites.load(Settings.shared.character)
        petView.image = nil
        let a = NSAlert()
        a.messageText = "캐릭터 \(n)개를 가져왔어요"
        a.informativeText = "펫을 우클릭 → 캐릭터에서 고를 수 있어요."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func writeDemo() {
        let body: [String: Any] = [
            "source": "demo", "tag": "테스트 · AgentPet",
            "headline": "말풍선이 잘 보이나요?", "line": "↑ 상위 이슈 제목 › 이슈 제목",
            "detail": "짧은 본문이에요. 아래 「자세히 보기」를 누르면 전문이 펼쳐져요.",
            "full": (1...12).map { "\($0)번째 문단 — 펼친 본문은 스크롤로 끝까지 볼 수 있어요." }.joined(separator: "\n"),
            "options": ["⭐ 추천 답", "다른 답"], "ids": ["reply:0", "reply:1"], "primary": 0,
            "openLabel": "열기", "link": "https://multica.ai",
        ]
        if let d = try? JSONSerialization.data(withJSONObject: body) {
            fm.createFile(atPath: "\(reqDir)/demo-\(Int(Date().timeIntervalSince1970)).json", contents: d)
        }
        pollRequests()
    }
}

/// 캐릭터 메뉴의 썸네일 격자
final class CharacterGrid: NSView {
    static let cols = 4
    static let cell = NSSize(width: 70, height: 78)

    init(names: [String], selected: String, onPick: @escaping (String) -> Void) {
        let rows = (names.count + CharacterGrid.cols - 1) / CharacterGrid.cols
        let size = NSSize(width: CGFloat(CharacterGrid.cols) * CharacterGrid.cell.width + 16,
                          height: CGFloat(rows) * CharacterGrid.cell.height + 12)
        super.init(frame: NSRect(origin: .zero, size: size))
        for (i, name) in names.enumerated() {
            let col = i % CharacterGrid.cols, row = i / CharacterGrid.cols
            let x = 8 + CGFloat(col) * CharacterGrid.cell.width
            let y = size.height - 6 - CGFloat(row + 1) * CharacterGrid.cell.height
            let cellView = CharacterCell(name: name, selected: name == selected) { [weak self] in
                onPick(name)
                self?.enclosingMenuItem?.menu?.cancelTracking()
            }
            cellView.frame = NSRect(x: x, y: y, width: CharacterGrid.cell.width, height: CharacterGrid.cell.height)
            addSubview(cellView)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class CharacterCell: NSView {
    private let name: String
    private let selected: Bool
    private let onPick: () -> Void
    private let thumb: NSImage?
    private let title: String
    private var hover = false

    init(name: String, selected: Bool, onPick: @escaping () -> Void) {
        self.name = name
        self.selected = selected
        self.onPick = onPick
        thumb = NSImage(contentsOfFile: "\(charDir)/\(name)/thumb.png") ?? NSImage(contentsOfFile: "\(charDir)/\(name)/idle.png")
        if let d = fm.contents(atPath: "\(charDir)/\(name)/character.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["title"] as? String, !t.isEmpty {
            title = t
        } else {
            title = name
        }
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { onPick() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 3, dy: 3)
        if selected || hover {
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
        if selected {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            p.lineWidth = 1.5
            p.stroke()
        }
        if let img = thumb {
            NSGraphicsContext.current?.imageInterpolation = .none
            let side: CGFloat = 46
            let k = min(side / img.size.width, side / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            img.draw(in: NSRect(x: (bounds.width - w) / 2, y: 22 + (side - h) / 2, width: w, height: h))
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor,
                                                    .paragraphStyle: para]
        (title as NSString).draw(in: NSRect(x: 4, y: 6, width: bounds.width - 8, height: 14), withAttributes: attrs)
        toolTip = title == name ? name : "\(title) (\(name))"
    }
}

final class ClosureSlider: NSSlider {
    private let onChange: (Double) -> Void
    init(value: Double, min: Double, max: Double, _ onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        minValue = min
        maxValue = max
        doubleValue = value
        isContinuous = true
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed() { onChange(doubleValue) }
}

final class ClosureMenuItem: NSMenuItem {
    private let act: () -> Void
    init(title: String, _ act: @escaping () -> Void) {
        self.act = act
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { act() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
