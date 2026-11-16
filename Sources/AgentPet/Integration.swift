// 연동 설정 — 앱 안에 든 setup_integrations.py 로 Claude Code 훅 · Codex notify · 캐릭터 스킬을 넣고 뺀다.
// 처음 실행할 때 한 번 묻고, 앱을 옮기거나 업데이트해 경로가 바뀌면 조용히 다시 맞춘다.
import AppKit

enum Integration {
    static var setupScript: String { resourceDir + "/setup/setup_integrations.py" }
    static var sourcesDir: String { resourceDir + "/sources" }
    static var skillDir: String { resourceDir + "/skill/pet-character" }

    /// 설정 값 — "on" · "off" · nil(아직 안 물음)
    static var choice: String? {
        get { Settings.shared.data["integrations"] as? String }
        set { Settings.shared.data["integrations"] = newValue; Settings.shared.save() }
    }

    @discardableResult
    static func shell(_ exe: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// macOS 기본 python3 는 Xcode 명령줄 도구가 있어야 돈다
    static var commandLineToolsReady: Bool { shell("/usr/bin/xcode-select", ["-p"]).code == 0 }

    static func setup(_ args: [String]) -> (code: Int32, out: String) {
        shell("/usr/bin/python3", ["-I", setupScript] + args)
    }

    /// ok(지금 앱 위치로 걸림) · stale(옛 위치) · none
    static func status() -> String {
        guard commandLineToolsReady else { return "none" }
        return setup(["status", sourcesDir]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func install() -> (Bool, String) {
        let r = setup(["install", sourcesDir, skillDir])
        return (r.code == 0, r.out)
    }

    static func uninstall() -> (Bool, String) {
        let r = setup(["uninstall"])
        return (r.code == 0, r.out)
    }

    /// 실행할 때마다 — 처음이면 묻고, 켜져 있는데 경로가 옛 것이면 다시 맞춘다
    static func checkOnLaunch() {
        let st = status()
        switch choice {
        case nil:
            if st == "ok" || st == "stale" {   // 예전에 설치 스크립트로 이미 연동한 경우
                choice = "on"
                if st == "stale" { _ = install() }
            } else {
                promptInstall(firstRun: true)
            }
        case "on":
            if st == "stale" || st == "none" { _ = install() }   // 앱을 옮겼거나 업데이트로 경로가 바뀜
        default:
            break
        }
    }

    static let noticeId = "pet-integration"

    /// 연동 설정 묻기 — 처음 실행 때와 메뉴 「연동 설정…」. 창 대신 펫 말풍선으로
    static func promptInstall(firstRun: Bool = false) {
        guard commandLineToolsReady else {
            PetNotice.post(noticeId, headline: "Xcode 명령줄 도구가 필요해요",
                           detail: "알림 연동 스크립트가 macOS 기본 python3 로 돌아가요. 설치한 뒤 메뉴 「연동 설정…」을 다시 눌러 주세요.",
                           options: ["명령줄 도구 설치", "나중에"], ids: ["integration:clt", "integration:later"], primary: 0)
            if firstRun { choice = "off" }
            return
        }
        let linked = choice == "on"
        PetNotice.post(noticeId,
                       headline: firstRun ? "Claude Code·Codex 알림을 연결할까요?" : (linked ? "알림 연동이 연결돼 있어요" : "알림 연동이 꺼져 있어요"),
                       detail: "Claude Code 훅 · Codex notify · 캐릭터 스킬을 설정해요. 고치는 파일은 백업해 둬요. 「자세히 보기」로 내용을 볼 수 있어요.",
                       fullMarkdown: """
                       ### 연결하면 이렇게 설정해요
                       - `~/.claude/settings.json` — 펫 훅 5개 추가 (기존 훅은 그대로)
                       - `~/.codex/config.toml` — `notify` 감싸기 (원래 명령도 계속 불림)
                       - Claude Code 스킬 `pet-character` 설치
                       - 고치는 파일은 처음 한 번 `*.bak-agentpet` 으로 백업

                       Multica 알림은 연동 없이도 동작해요.
                       """,
                       options: linked ? ["다시 연결", "연결 해제", "닫기"] : ["연결하기", "나중에"],
                       ids: linked ? ["integration:install", "integration:uninstall", "integration:later"]
                                   : ["integration:install", firstRun ? "integration:decline" : "integration:later"],
                       primary: 0)
    }

    /// 말풍선 버튼에서
    static func handle(_ id: String) {
        switch id {
        case "integration:install":
            let (ok, out) = install()
            if ok { choice = "on" }
            PetNotice.info(ok ? "연결했어요" : "연결하지 못했어요",
                           ok ? "이미 열려 있던 Claude Code·Codex 세션은 다시 시작해야 알림이 와요." : out)
        case "integration:uninstall":
            let (ok, out) = uninstall()
            if ok { choice = "off" }
            PetNotice.info(ok ? "연결을 해제했어요" : "해제하지 못했어요", ok ? "" : out)
        case "integration:decline":
            choice = "off"
        case "integration:clt":
            shell("/usr/bin/xcode-select", ["--install"])
        default: break
        }
    }
}
