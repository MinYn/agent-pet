// 펫 자체 알림 — 업데이트·연동 설정 같은 안내를 창(NSAlert) 대신 말풍선으로 띄운다.
// 버튼 id 는 "update:…" · "integration:…" 처럼 앱이 직접 처리한다 (AppDelegate.answer).
import Foundation

enum PetNotice {
    static func post(_ id: String, headline: String, detail: String = "", fullMarkdown: String = "",
                     options: [String] = [], ids: [String] = [], primary: Int? = nil, expires: TimeInterval? = nil) {
        var body: [String: Any] = [
            "source": "pet", "tag": "에이전트 펫", "headline": headline, "detail": detail,
            "options": options, "ids": ids,
        ]
        if !fullMarkdown.isEmpty { body["full_md"] = fullMarkdown; body["full"] = fullMarkdown }
        if let p = primary { body["primary"] = p }
        if let e = expires { body["expires_at"] = Date().timeIntervalSince1970 + e }
        guard let d = try? JSONSerialization.data(withJSONObject: body) else { return }
        let path = "\(reqDir)/\(id).json"
        fm.createFile(atPath: path + ".tmp", contents: d)
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: path + ".tmp"))
    }

    static func clear(_ id: String) {
        try? fm.removeItem(atPath: "\(reqDir)/\(id).json")
    }

    /// 잠깐 보였다 사라지는 안내
    static func info(_ headline: String, _ detail: String = "") {
        post("pet-info-\(Int(Date().timeIntervalSince1970))", headline: headline, detail: detail, expires: 12)
    }
}
