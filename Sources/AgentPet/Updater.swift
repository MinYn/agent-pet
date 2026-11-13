// 업데이트 확인 — GitHub 최신 Release 를 보고, 새 버전이면 AgentPet.zip 을 받아 지금 앱과 바꿔 끼운 뒤 다시 실행한다.
import AppKit

enum Updater {
    static var repo: String { Bundle.main.object(forInfoDictionaryKey: "AgentPetRepository") as? String ?? "MinYn/agent-pet" }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    /// "1.2.10" > "1.2.9" 같은 숫자 비교
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 하루 한 번 자동 확인 (조용히 — 새 버전이 있을 때만 펫이 알린다)
    static func checkDaily() {
        let last = Settings.shared.data["update_checked_at"] as? Double ?? 0
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        check(manual: false)
    }

    /// 받을 수 있는 새 버전 — 있으면 우클릭 메뉴에 「업데이트」가 보인다
    static var available: (version: String, zip: URL?, page: String)?
    static let noticeId = "pet-update"

    static func check(manual: Bool) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AgentPet-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 예전 응답(옛 최신 버전)을 캐시에서 읽지 않게
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                Settings.shared.data["update_checked_at"] = Date().timeIntervalSince1970
                Settings.shared.save()
                guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = o["tag_name"] as? String else {
                    if manual { PetNotice.info("업데이트를 확인하지 못했어요", error?.localizedDescription ?? "GitHub 응답을 읽지 못했어요.") }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard isNewer(latest, than: current) else {
                    available = nil
                    PetNotice.clear(noticeId)
                    if manual { PetNotice.info("최신 버전이에요", "지금 버전 \(current)") }
                    return
                }
                let assets = o["assets"] as? [[String: Any]] ?? []
                let zip = (assets.first { ($0["name"] as? String) == "AgentPet.zip" }?["browser_download_url"] as? String).flatMap(URL.init(string:))
                available = (latest, zip, o["html_url"] as? String ?? "https://github.com/\(repo)/releases")
                // 건너뛰기로 한 버전은 메뉴에만 두고 말풍선은 띄우지 않는다 (직접 확인하면 띄움)
                if manual || Settings.shared.data["update_skip"] as? String != latest {
                    offer(latest, notes: o["body"] as? String ?? "", hasZip: zip != nil)
                }
            }
        }.resume()
    }

    /// 펫이 말풍선으로 알린다 — 릴리스 노트는 「자세히 보기」로
    static func offer(_ version: String, notes: String, hasZip: Bool) {
        PetNotice.post(noticeId, headline: "새 버전 \(version) 이 나왔어요 (지금 \(current))",
                       detail: hasZip ? "업데이트를 누르면 받아서 바꿔 끼우고 다시 열려요." : "릴리스 페이지에서 받아 주세요.",
                       fullMarkdown: notes,
                       options: [hasZip ? "업데이트" : "릴리스 페이지 열기", "나중에", "이 버전 건너뛰기"],
                       ids: ["update:install", "update:later", "update:skip"], primary: 0)
    }

    /// 말풍선 버튼·메뉴에서
    static func handle(_ id: String) {
        guard let av = available else { return }
        switch id {
        case "update:install":
            if let z = av.zip { install(from: z) } else if let u = URL(string: av.page) { NSWorkspace.shared.open(u) }
        case "update:skip":
            Settings.shared.data["update_skip"] = av.version
            Settings.shared.save()
        default: break   // 나중에 — 메뉴에는 계속 남는다
        }
    }

    /// 실패 이유를 남긴다 (말풍선 안내는 잠깐 보였다 사라지므로)
    static func fail(_ title: String, _ detail: String) {
        PetNotice.info(title, detail)
        let line = "\(Date()) update \(title) \(detail)\n"
        let path = petDir + "/watch.err"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { fm.createFile(atPath: path, contents: line.data(using: .utf8)) }
    }

    /// zip 을 받아(로컬 파일이면 그대로) 바꿔 끼운다
    static func install(from url: URL) {
        if url.isFileURL { apply(zip: url); return }
        PetNotice.info("업데이트를 내려받는 중이에요…")
        URLSession.shared.downloadTask(with: url) { file, _, error in
            // 받은 임시 파일은 이 콜백이 끝나면 지워지므로 여기서 옮겨 둔다
            var kept: URL?
            if let file {
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPet-\(Int(Date().timeIntervalSince1970)).zip")
                if (try? FileManager.default.moveItem(at: file, to: dst)) != nil { kept = dst }
            }
            DispatchQueue.main.async {
                guard let zip = kept else { fail("내려받지 못했어요", error?.localizedDescription ?? ""); return }
                apply(zip: zip)
            }
        }.resume()
    }

    /// zip 을 풀고, 앱이 끝나면 바꿔 끼운 뒤 다시 여는 작은 스크립트를 띄운다
    static func apply(zip: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-update-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Integration.shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("AgentPet.app").path
        guard unzip.code == 0, FileManager.default.fileExists(atPath: newApp) else {
            fail("압축을 풀지 못했어요", unzip.out); return
        }
        let target = Bundle.main.bundlePath
        let script = work.appendingPathComponent("swap.sh").path
        let body = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target)"
        mv "\(newApp)" "\(target)"
        xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        open "\(target)"
        rm -rf "\(work.path)"
        """
        FileManager.default.createFile(atPath: script, contents: body.data(using: .utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        do { try p.run() } catch { fail("업데이트를 시작하지 못했어요", "\(error)"); return }
        PetNotice.info("업데이트하는 중이에요…", "잠시 뒤 다시 열려요.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }   // 스크립트가 끝나길 기다렸다 바꿔 끼우고 다시 연다
    }
}
