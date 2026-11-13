// 말풍선 글꼴 — 메뉴 「말풍선 글꼴」 설정(font_family · font_scale)을 한곳에서 적용한다
import AppKit

enum BubbleFont {
    /// 메뉴에 먼저 보일 한글 글꼴 (설치된 것만)
    static let preferred = ["Apple SD Gothic Neo", "Pretendard", "NanumGothic", "NanumSquare", "Noto Sans KR",
                            "Spoqa Han Sans Neo", "IBM Plex Sans KR", "Gowun Dodum", "KakaoBig Sans", "D2Coding"]

    static var family: String { Settings.shared.data["font_family"] as? String ?? "" }
    static var scale: CGFloat { CGFloat(Settings.shared.data["font_scale"] as? Double ?? 1.0) }

    /// 설정 크기 배율을 적용한 글꼴
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        exact(size * scale, weight)
    }

    /// 배율 없이 (이미 배율이 들어간 크기) 설정 글꼴만 적용
    static func exact(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let fam = family
        if !fam.isEmpty {
            let w = weight == .bold || weight == .heavy ? 9 : weight == .semibold ? 8 : weight == .medium ? 6 : 5
            if let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: w, size: size) { return f }
            if let f = NSFontManager.shared.font(withFamily: fam, traits: w >= 8 ? .boldFontMask : [], weight: 5, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// 코드·표 — 고정폭은 그대로, 크기만 배율을 따른다
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size * scale, weight: .regular) }

    /// 설치된 글꼴 중 한글을 쓸 수 있는 것 (메뉴 「다른 글꼴」)
    static func koreanFamilies() -> [String] {
        let hangul = CharacterSet(charactersIn: "가")
        return NSFontManager.shared.availableFontFamilies.filter { fam in
            guard !fam.hasPrefix("."), let f = NSFont(name: fam, size: 12)
                    ?? NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 12) else { return false }
            return f.coveredCharacterSet.isSuperset(of: hangul)
        }
    }
}
