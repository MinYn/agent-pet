// 펫이 올라설 수 있는 다른 앱 창의 윗변 — CGWindowList 로 창 위치만 읽는다(창 제목은 안 읽어서 화면 기록 권한이 필요 없다).
import AppKit

struct WinSurface {
    let id: Int
    /// Cocoa 좌표(왼쪽 아래 원점)의 창 영역
    let frame: NSRect
    /// 펫 발이 닿는 높이 — 창 윗변
    var top: CGFloat { frame.maxY - 3 }
}

enum WindowWorld {
    /// 화면에 보이는 일반 창들 — 앞에 있는 창부터
    static func surfaces() -> [WinSurface] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let mainH = NSScreen.screens.first?.frame.height else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [WinSurface] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  let id = w[kCGWindowNumber as String] as? Int,
                  r.width >= 160, r.height >= 100 else { continue }
            out.append(WinSurface(id: id, frame: NSRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)))
        }
        return out
    }

    /// 창 하나의 지금 영역 — 앉아 있는 창을 매 프레임 따라가려고 (전체 목록보다 훨씬 가볍다). 창이 없으면 nil
    static func frame(of id: Int) -> NSRect? {
        // 창 번호는 숫자 객체가 아니라 포인터 값 배열로 넘겨야 한다 — [CGWindowID] as CFArray 는 빈 결과가 나온다
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let ids = CFArrayCreate(nil, &values, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let w = list.first, let b = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              let mainH = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)
    }

    /// x 지점에서 이 창 윗변이 다른(앞쪽) 창에 가려지지 않았는지
    static func topVisible(_ w: WinSurface, x: CGFloat, in list: [WinSurface]) -> Bool {
        let p = NSPoint(x: x, y: w.frame.maxY + 6)
        for o in list {
            if o.id == w.id { return true }
            if o.frame.contains(p) { return false }
        }
        return true
    }

    // =========================================================================
    // Dock — 화면 아래 Dock 윗면을 발판으로. 아이콘 위치는 손쉬운 사용 권한이 있을 때만 읽는다
    // =========================================================================

    static let dockId = -1
    private static var iconCache: [(title: String, frame: NSRect)] = []
    private static var iconCacheAt = Date.distantPast

    /// Dock 아이콘들 (Cocoa 좌표) — 5초마다 다시 읽는다. 권한이 없으면 빈 목록
    static func dockIcons() -> [(title: String, frame: NSRect)] {
        if Date().timeIntervalSince(iconCacheAt) < 5 { return iconCache }
        iconCacheAt = Date()
        iconCache = []
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let mainH = NSScreen.screens.first?.frame.height else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids)
        guard let list = (kids as? [AXUIElement])?.first else { return [] }
        var items: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items)
        for it in (items as? [AXUIElement]) ?? [] {
            var pv: CFTypeRef?, sv: CFTypeRef?, tv: CFTypeRef?
            AXUIElementCopyAttributeValue(it, kAXPositionAttribute as CFString, &pv)
            AXUIElementCopyAttributeValue(it, kAXSizeAttribute as CFString, &sv)
            AXUIElementCopyAttributeValue(it, kAXTitleAttribute as CFString, &tv)
            var pos = CGPoint.zero, size = CGSize.zero
            guard let p = pv, let s = sv,
                  AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  size.width > 8 else { continue }
            iconCache.append((tv as? String ?? "", NSRect(x: pos.x, y: mainH - pos.y - size.height, width: size.width, height: size.height)))
        }
        return iconCache
    }

    /// Dock 윗면 발판 — 아래쪽 Dock 이 보일 때만. 아이콘을 읽을 수 있으면 실제 길이, 아니면 화면 너비
    static func dockSurface() -> WinSurface? {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        if dockDefaults?.bool(forKey: "autohide") == true { return nil }
        if let o = dockDefaults?.string(forKey: "orientation"), o != "bottom" { return nil }
        guard let sc = NSScreen.screens.first(where: { $0.visibleFrame.minY - $0.frame.minY > 20 }) else { return nil }
        let h = sc.visibleFrame.minY - sc.frame.minY
        var minX = sc.frame.minX, maxX = sc.frame.maxX
        let icons = dockIcons().filter { sc.frame.contains(NSPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        if let lo = icons.map({ $0.frame.minX }).min(), let hi = icons.map({ $0.frame.maxX }).max() {
            minX = lo - 8
            maxX = hi + 8
        }
        return WinSurface(id: dockId, frame: NSRect(x: minX, y: sc.frame.minY, width: maxX - minX, height: h))
    }

    /// 윗변 위로 펫이 설 자리가 화면 안에 있는지 (메뉴 막대·화면 밖 제외)
    static func roomAbove(_ w: WinSurface, x: CGFloat, height: CGFloat) -> Bool {
        guard let sc = NSScreen.screens.first(where: { $0.frame.minX <= x && x < $0.frame.maxX }) else { return false }
        let v = sc.visibleFrame
        if w.id == dockId { return true }
        return w.top >= v.minY + 20 && w.top + height <= v.maxY
    }
}
