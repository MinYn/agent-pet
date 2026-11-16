// 알림함 — 지난 알림(닫음·답함·열어 봄·만료·다른 곳에서 처리됨)을 메일함처럼 본다.
// 왼쪽: 목록(최근 것부터) · 오른쪽: 고른 알림의 전체 내용과 그때 고른 답. 「다시 띄우기」로 말풍선에 되살린다.
// 보관: <데이터 폴더>/history/<시각>-<알림 id>.json — 최근 300개만 남긴다.
import AppKit

struct InboxEntry {
    let file: String
    let id: String
    let at: Date
    let reason: String
    let decision: String
    let choice: String
    let req: [String: Any]

    var source: String { req["source"] as? String ?? "" }
    var tag: String { req["tag"] as? String ?? "" }
    var headline: String { req["headline"] as? String ?? "" }
    var link: String { req["link"] as? String ?? "" }
    var awaits: Bool { req["await"] as? Bool ?? false }
}

final class Inbox: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = Inbox()
    static let dir = petDir + "/history"
    static let keep = 300

    /// 앱이 채워 준다 — 말풍선 「열기」와 같은 동작 · Multica 닫음 기록 지우고 다시 훑기
    var openLink: ((String) -> Void)?
    var restoreMultica: ((String, @escaping () -> Void) -> Void)?

    private var window: NSWindow?
    private let table = NSTableView()
    private var entries: [InboxEntry] = []
    private var lastListing: [String] = []
    private var timer: Timer?

    private let tagLabel = Inbox.text(11, .medium, .secondaryLabelColor)
    private let headLabel = Inbox.text(17, .semibold, .labelColor)
    private let metaLabel = Inbox.text(12, .regular, .secondaryLabelColor)
    private let choiceBox = NSStackView()   // 「그때 고른 답」 — 옅은 배경 상자
    private let choiceLabel = Inbox.text(13, .medium, .labelColor)
    private let bodyView = NSTextView()
    private let statusLabel = Inbox.text(11, .regular, .secondaryLabelColor)
    private lazy var restoreButton = NSButton(title: "다시 띄우기", target: self, action: #selector(restore))
    private lazy var openButton = NSButton(title: "원문 열기", target: self, action: #selector(openOriginal))
    private lazy var deleteButton = NSButton(title: "삭제", target: self, action: #selector(deleteEntry))
    private let emptyLabel = Inbox.text(13, .regular, .secondaryLabelColor)

    // -------------------------------------------------------------------------
    // 보관
    // -------------------------------------------------------------------------

    /// 말풍선에서 사라지는 알림 하나를 보관한다 (펫 자체 안내·시험 알림은 빼고)
    static func archive(_ r: PetRequest, reason: String, decision: String = "") {
        guard r.source != "pet", r.source != "demo" else { return }
        var req = r.raw
        req.removeValue(forKey: "replies")   // 추천 답장 원문 목록은 보관할 필요 없다
        let at = Date()
        let entry: [String: Any] = ["id": r.id, "at": at.timeIntervalSince1970, "reason": reason,
                                    "decision": decision, "choice": choiceText(r, decision), "req": req]
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "\(Int(at.timeIntervalSince1970 * 1000))-\(r.id.replacingOccurrences(of: "/", with: "_")).json"
        if let d = try? JSONSerialization.data(withJSONObject: entry) { fm.createFile(atPath: dir + "/" + name, contents: d) }
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for f in files.dropLast(keep) { try? fm.removeItem(atPath: dir + "/" + f) }
    }

    /// 누른 버튼을 사람이 읽을 말로 — 그때 고른 답
    static func choiceText(_ r: PetRequest, _ decision: String) -> String {
        if decision == "allow" { return "허용" }
        if decision == "deny" { return "거부" }
        if decision.hasPrefix("reply:"), let i = Int(decision.dropFirst(6)), i < r.options.count {
            return r.options[i].replacingOccurrences(of: "⭐ ", with: "")
        }
        if decision.hasPrefix("multi:"), let d = String(decision.dropFirst(6)).data(using: .utf8),
           let answers = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            return r.questions.map { q in
                let v = answers[q.id] ?? ""
                let shown: String
                if v.hasPrefix("text:") { shown = "직접 입력 — " + v.dropFirst(5) }
                else {
                    let names = Dictionary(q.options.map { ($0.no, $0.label) }, uniquingKeysWith: { a, _ in a })
                    shown = v.split(separator: ",").map { n in
                        let k = String(n).trimmingCharacters(in: .whitespaces)
                        return names[k].map { "\(k). \($0)" } ?? k
                    }.joined(separator: ", ")
                }
                return "\(q.id) · \(q.title)\n   → \(shown)"
            }.joined(separator: "\n")
        }
        return ""
    }

    static func load() -> [InboxEntry] {
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted().reversed()
        return files.compactMap { f in
            guard let d = fm.contents(atPath: dir + "/" + f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let req = o["req"] as? [String: Any] else { return nil }
            return InboxEntry(file: f, id: o["id"] as? String ?? "", at: Date(timeIntervalSince1970: o["at"] as? Double ?? 0),
                              reason: o["reason"] as? String ?? "", decision: o["decision"] as? String ?? "",
                              choice: o["choice"] as? String ?? "", req: req)
        }
    }

    // -------------------------------------------------------------------------
    // 창
    // -------------------------------------------------------------------------

    func show() {
        if window == nil { build() }
        reload(force: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()   // Dock 아이콘 없는 앱이라 다른 앱이 앞에 있어도 맨 앞으로

        timer?.invalidate()   // 열려 있는 동안 새로 쌓인 알림을 반영
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { self?.timer?.invalidate(); return }
            self.reload(force: false)
        }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "AgentPet 알림함"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 760, height: 520)   // 내용이 짧아도 창이 낮아지지 않게
        w.center()

        // 왼쪽 — 목록
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 62
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let left = NSScrollView()
        left.documentView = table
        left.hasVerticalScroller = true
        left.drawsBackground = false

        // 오른쪽 — 내용
        headLabel.maximumNumberOfLines = 3
        headLabel.lineBreakMode = .byWordWrapping
        choiceLabel.maximumNumberOfLines = 0
        choiceLabel.lineBreakMode = .byWordWrapping
        let choiceTitle = Inbox.text(11, .semibold, .secondaryLabelColor)
        choiceTitle.stringValue = "그때 고른 답"
        choiceBox.setViews([choiceTitle, choiceLabel], in: .top)
        choiceBox.orientation = .vertical
        choiceBox.alignment = .leading
        choiceBox.spacing = 4
        choiceBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        choiceBox.wantsLayer = true
        choiceBox.layer?.cornerRadius = 8
        choiceBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        choiceLabel.preferredMaxLayoutWidth = 520
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.textContainerInset = NSSize(width: 2, height: 6)
        bodyView.isVerticallyResizable = true
        bodyView.autoresizingMask = [.width]
        bodyView.textContainer?.widthTracksTextView = true
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        for b in [restoreButton, openButton, deleteButton] { b.bezelStyle = .rounded }
        restoreButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [restoreButton, openButton, NSView(), statusLabel, deleteButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        statusLabel.lineBreakMode = .byTruncatingTail

        let right = NSStackView(views: [tagLabel, headLabel, metaLabel, choiceBox, bodyScroll, buttons])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        for v in [headLabel, choiceBox, bodyScroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -36).isActive = true
        }
        bodyScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        emptyLabel.stringValue = "아직 지난 알림이 없어요.\n말풍선을 닫거나 답하면 여기에 쌓여요."
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        let rightHolder = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        rightHolder.addSubview(right)
        rightHolder.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            right.leadingAnchor.constraint(equalTo: rightHolder.leadingAnchor),
            right.trailingAnchor.constraint(equalTo: rightHolder.trailingAnchor),
            right.topAnchor.constraint(equalTo: rightHolder.topAnchor),
            right.bottomAnchor.constraint(equalTo: rightHolder.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: rightHolder.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rightHolder.centerYAnchor),
        ])

        // 왼쪽 목록은 폭 320 고정, 오른쪽 내용이 창 크기를 따라간다 (메일 앱처럼)
        let line = NSBox()
        line.boxType = .separator
        let root = NSStackView(views: [left, line, rightHolder])
        root.orientation = .horizontal
        root.spacing = 0
        root.alignment = .top
        for v in [left, line, rightHolder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        }
        left.widthAnchor.constraint(equalToConstant: 320).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true   // 세로 구분선 — 늘어나지 않게
        rightHolder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.distribution = .fill
        for v in [root, rightHolder] as [NSView] {   // 내용이 짧아도 창이 그 높이로 줄어들지 않게
            v.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true
        w.contentView = root
        w.setContentSize(NSSize(width: 960, height: 600))   // 내용 크기에 맞춰 줄어들지 않게
        w.center()
        window = w
    }

    private func reload(force: Bool) {
        let listing = ((try? fm.contentsOfDirectory(atPath: Inbox.dir)) ?? []).sorted()
        if !force && listing == lastListing { return }
        lastListing = listing
        let keep = selected?.file
        entries = Inbox.load()
        table.reloadData()
        if let k = keep, let i = entries.firstIndex(where: { $0.file == k }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else if !entries.isEmpty, table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        showSelected()
    }

    private var selected: InboxEntry? {
        let i = table.selectedRow
        return entries.indices.contains(i) ? entries[i] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let top = Inbox.text(11, .regular, .secondaryLabelColor)
        top.stringValue = "\(Inbox.when(e.at)) · \(e.reason)" + (e.choice.isEmpty ? "" : " · " + e.choice.split(separator: "\n").first.map(String.init)!)
        let head = Inbox.text(13, .semibold, .labelColor)
        head.stringValue = e.headline.isEmpty ? "(제목 없음)" : e.headline
        let tag = Inbox.text(11, .regular, .tertiaryLabelColor)
        tag.stringValue = e.tag
        for l in [top, head, tag] { l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1 }
        let v = NSStackView(views: [top, head, tag])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        v.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    private func showSelected() {
        let has = selected != nil
        emptyLabel.isHidden = !entries.isEmpty
        for v in [tagLabel, headLabel, metaLabel, choiceBox, bodyView.enclosingScrollView, restoreButton, openButton, deleteButton] {
            v?.isHidden = !has
        }
        statusLabel.stringValue = ""
        guard let e = selected else { return }
        tagLabel.stringValue = e.tag
        headLabel.stringValue = e.headline
        metaLabel.stringValue = "\(Inbox.when(e.at, full: true)) · \(e.reason)"
        choiceLabel.stringValue = e.choice
        choiceBox.isHidden = e.choice.isEmpty

        // 본문: 둘째 줄 · 요약 · 전문(마크다운) · 그때 있던 버튼
        let r = e.req
        var md = ""
        if let line = r["line"] as? String, !line.isEmpty { md += "*\(line)*\n\n" }
        let full = (r["full_md"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r["full"] as? String) ?? ""
        let detail = r["detail"] as? String ?? ""
        md += full.isEmpty ? detail : full
        if let qs = r["questions"] as? [[String: Any]], !qs.isEmpty, full.isEmpty {
            for q in qs {
                md += "\n\n**\(q["id"] as? String ?? "") · \(q["title"] as? String ?? "")**"
                for o in q["options"] as? [[String: Any]] ?? [] { md += "\n- \(o["no"] as? String ?? ""). \(o["label"] as? String ?? "")" }
            }
        }
        if let opts = r["options"] as? [String], !opts.isEmpty { md += "\n\n---\n보기: " + opts.joined(separator: " · ") }
        bodyView.textStorage?.setAttributedString(Markdown.render(md.isEmpty ? "(내용 없음)" : md, size: 13))
        bodyView.textColor = .labelColor
        bodyView.scrollToBeginningOfDocument(nil)

        openButton.isEnabled = !e.link.isEmpty
        restoreButton.isEnabled = !e.awaits
        restoreButton.toolTip = e.awaits ? "답을 기다리던 요청(권한·선택 질문)은 이미 끝나 다시 띄울 수 없어요" : "말풍선에 다시 띄워요"
    }

    // -------------------------------------------------------------------------
    // 버튼
    // -------------------------------------------------------------------------

    @objc private func restore() {
        guard let e = selected, !e.awaits else { return }
        if e.source == "multica", let issue = e.req["session"] as? String, !issue.isEmpty {
            // Multica: 닫음 기록을 지우고 다시 훑는다 — 아직 사람 차례면 최신 내용으로 다시 뜬다
            statusLabel.stringValue = "Multica 에서 다시 확인하는 중…"
            restoreMultica?(issue) { [weak self] in
                let back = ((try? fm.contentsOfDirectory(atPath: reqDir)) ?? []).contains { $0.hasPrefix(issue.prefix(13).replacingOccurrences(of: "-", with: "")) }
                self?.statusLabel.stringValue = back ? "말풍선에 다시 띄웠어요" : "지금은 사람 차례가 아니라 띄울 알림이 없어요"
            }
            return
        }
        var req = e.req
        for k in ["show_at", "pending", "await"] { req.removeValue(forKey: k) }
        req["expires_at"] = Date().timeIntervalSince1970 + 3600
        try? fm.createDirectory(atPath: reqDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: req) {
            fm.createFile(atPath: "\(reqDir)/\(e.id).json", contents: d)
            statusLabel.stringValue = "말풍선에 다시 띄웠어요"
        }
    }

    @objc private func openOriginal() {
        guard let e = selected, !e.link.isEmpty else { return }
        openLink?(e.link)
    }

    @objc private func deleteEntry() {
        guard let e = selected else { return }
        let row = table.selectedRow
        try? fm.removeItem(atPath: Inbox.dir + "/" + e.file)
        reload(force: true)
        if !entries.isEmpty { table.selectRowIndexes([min(row, entries.count - 1)], byExtendingSelection: false) }
        showSelected()
    }

    // -------------------------------------------------------------------------

    private static func text(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.isSelectable = true
        return f
    }

    private static func when(_ d: Date, full: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = full ? "yyyy-MM-dd (E) HH:mm:ss" : (Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm")
        return f.string(from: d)
    }
}
