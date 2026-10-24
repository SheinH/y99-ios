import SwiftUI

// Someone's profile card (system/users/profile {target}), like the web's profile view (deob/app.deob.js ~880-1060):
// picture, name and level, bio, "Location Age Gender (LAG)", badges, views. Shown as a sheet from the chat header.
struct Profile {
    let username: String
    let level: Int?
    let verified: Bool
    let rank: Int?          // 0 guest, 1 registered, 2 VIP
    let bio: String
    let age: Int
    let gender: Int
    let country: String
    let badges: [(title: String, img: String)]
    let views: Int?
    let avatar: String?     // encrypted "../../yimv?big=…", relative to Avatar.path

    init?(_ any: Any?) {
        guard let d = any as? [String: Any], let name = d["username"] as? String else { return nil }
        func int(_ k: String) -> Int? {
            if let i = d[k] as? Int { return i }
            if let s = d[k] as? String { return Int(s) }
            return nil
        }
        username = name
        level = int("level")
        verified = int("verified") == 1
        rank = int("rank")
        bio = (d["description"] as? String) ?? ""
        age = int("age") ?? 0
        gender = int("gender") ?? 0
        country = (d["country"] as? String) ?? ""
        badges = ((d["badges"] as? [[String: Any]]) ?? []).compactMap {
            guard let img = $0["img"] as? String, !img.isEmpty else { return nil }
            return (((($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)), img)
        }
        views = int("views")
        avatar = (d["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func load(_ user: String, auth: String?, me: String) async -> Profile? {
        Profile(await API.post("system/users/profile", ["target": user], auth: auth, username: me))
    }

    /// The web's gender list (index = the profile's `gender`).
    static let genders = ["Person", "Male", "Female", "Agender", "Androgyne", "Androgynous", "Bigender", "Cis", "Cisgender", "Cis Female", "Cis Male", "Cis Man", "Cis Woman", "Cisgender Female", "Cisgender Male", "Cisgender Man", "Cisgender Woman", "Female to Male", "FTM", "Gender Fluid", "Gender Nonconforming", "Gender Questioning", "Gender Variant", "Genderqueer", "Intersex", "Male to Female", "MTF", "Neither", "Neutrois", "Non-binary", "Other", "Pangender", "Trans", "Trans*", "Trans Female", "Trans* Female", "Trans Male", "Trans* Male", "Trans Man", "Trans* Man", "Trans Person", "Trans* Person", "Trans Woman", "Trans* Woman", "Transfeminine", "Transgender", "Transgender Female", "Transgender Male", "Transgender Man", "Transgender Person", "Transgender Woman", "Transmasculine", "Transsexual", "Transsexual Female", "Transsexual Male", "Transsexual Man", "Transsexual Person", "Transsexual Woman", "Two-Spirit", "Demigirl", "Demiboy"]

    /// "I am a 18 year old female from United Kingdom", worded like the web.
    var lag: String {
        guard age > 0 || gender > 0 || !country.isEmpty else { return "Not available" }
        let g = gender < Self.genders.count ? Self.genders[gender].lowercased() : "person"
        var s = "I am "
        if age > 0 { s += "a \(age) year old " } else { s += ("aeiou".contains(g.first ?? "x") ? "an " : "a ") }
        s += g
        if !country.isEmpty { s += " from \(country)" }
        return s
    }

    static func badgeURL(_ img: String) -> URL? {
        URL(string: "https://meetyou.me/app/static/images/badges/")?.appendingPathComponent(img)
    }
}

struct ProfileCard: View {
    let user: String
    let thumb: String?
    var full: UIImage?        // the chat's full-size picture, if already fetched
    let auth: String?
    let me: String

    @State private var profile: Profile?
    @State private var failed = false
    @State private var picture: UIImage?
    @State private var viewingPicture = false
    @State private var pictureSource = SourceFrame(cornerRadius: 0)   // for the viewer's drag-close
    @Namespace private var zoom
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // No picture, no picture area: the card starts with the name.
                if let picture { avatar(picture) }
                Group {
                    if let profile {
                        details(profile)
                    } else if failed {
                        Text("Couldn't load the profile.").foregroundStyle(.secondary).padding(.top, 20)
                    } else {
                        ProgressView().padding(.top, 20)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, picture == nil ? 32 : 0)   // clear of the grabber when the name is on top
            .padding(.bottom, 32)
            .background(SheetScrollHandoff { dismiss() })
        }
        .ignoresSafeArea(edges: .top)   // the picture runs right up to the card's top edge
        .task {
            if let p = await Profile.load(user, auth: auth, me: me) { profile = p } else { failed = true }
        }
        .task(id: profile?.avatar) {
            // Sharper than the thumb: the full size, cached per picture by Avatar.
            if picture == nil { picture = full }
            if picture == nil, let thumb { picture = await Avatar.cachedFull(thumb) }
            if picture == nil, let thumb { picture = await Avatar.thumbImage(thumb) }   // blurry stand-in
            if let thumb, let big = profile?.avatar, let hd = await Avatar.full(thumb: thumb, big: big) { picture = hd }
        }
    }

    /// Full-width square across the top of the card (the sheet's own corners round it).
    func avatar(_ picture: UIImage) -> some View {
        Color(.systemGray4)
            .aspectRatio(1, contentMode: .fit)
            .overlay { Image(uiImage: picture).resizable().scaledToFill() }
            .clipped()
            .background(FrameProbe(frame: pictureSource))
            .contentShape(Rectangle())
            // Tap to view it full screen, zooming out of the card like the header's avatar does.
            .onTapGesture {
                pictureSource.freeze()   // before the sheet shrinks behind the viewer
                viewingPicture = true
            }
            .zoomSource("profilePicture", zoom)
            .fullScreenCover(isPresented: $viewingPicture) {
                if let picture = self.picture { ImageViewer(image: picture, source: pictureSource).zoomTransition("profilePicture", zoom) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Profile picture")
    }

    @ViewBuilder func details(_ p: Profile) -> some View {
        // Name on the left, level on the right, like the web.
        HStack(alignment: .center, spacing: 6) {
            Text(p.username).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            if p.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue) }
            Spacer(minLength: 12)
            // "★ 121" like the web: a small SF star beside the number.
            HStack(alignment: .center, spacing: 3) {
                Image(systemName: "star.fill").font(.footnote.weight(.semibold))
                Text(p.level.map(String.init) ?? "N/A").font(.body.weight(.semibold))
            }
            .foregroundStyle(.blue)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Level \(p.level.map(String.init) ?? "not available")")
        }

        VStack(alignment: .leading, spacing: 18) {
            section(nil) { bio(p) }
            section("Location Age Gender (LAG)") { Text(p.lag).foregroundStyle(.secondary) }
            if !p.badges.isEmpty || p.rank != nil {
                section("Badges") { badges(p) }
            }
            if let views = p.views, views > 0 {
                Label("\(views.formatted())+ views", systemImage: "eye.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func section(_ title: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.headline) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// The bio with its "———" separator lines drawn as dividers; links tappable, :emoji: rendered.
    @ViewBuilder func bio(_ p: Profile) -> some View {
        let text = p.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Text("\(p.username) has not set a profile description.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    if let block { MessageText(text: block).foregroundStyle(.secondary) } else { Divider() }
                }
            }
        }
    }

    /// Text runs split at separator lines (nil = a separator).
    static func blocks(_ text: String) -> [String?] {
        let dashes = CharacterSet(charactersIn: "—–-_─━=~·•. ")
        var out: [String?] = [], run: [String] = []
        func flush() {
            let s = run.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            run = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count >= 3, t.unicodeScalars.allSatisfy(dashes.contains) {
                flush()
                if !out.isEmpty, out.last! != nil { out.append(nil) }
            } else {
                run.append(line)
            }
        }
        flush()
        if out.last == .some(nil) { out.removeLast() }
        return out
    }

    func badges(_ p: Profile) -> some View {
        FlowLayout {
            switch p.rank {
            case 0: letterBadge("G")
            case 1: letterBadge("U")
            case 2: BadgeImage(img: "vip4.png")
            default: EmptyView()
            }
            ForEach(Array(p.badges.enumerated()), id: \.offset) { _, b in
                BadgeImage(img: b.img).accessibilityLabel(b.title)
            }
        }
    }

    func letterBadge(_ s: String) -> some View {
        Text(s).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(Circle().fill(Color.purple))
            .padding(3)
    }
}

/// One badge icon from the web's static folder; missing ones (some 404) take no space.
struct BadgeImage: View {
    let img: String
    @State private var image: UIImage?
    @State private var done = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 28, height: 28).padding(2)
            } else if !done {
                Color.clear.frame(width: 28, height: 28).padding(2)
            }
        }
        .task(id: img) {
            let data = await DiskCache.image(key: "badge:\(img)", url: Profile.badgeURL(img))
            image = data.flatMap(UIImage.init(data:))
            done = true
        }
    }
}

/// Makes the card's scroll view hand off to the sheet: no overscroll at the top, and a drag that
/// scrolls back up to the top keeps going by moving the sheet itself (UIKit's sheet only takes a drag
/// that starts at the top). Let go far or fast enough and it closes (or drops from large to the
/// smaller size); otherwise it springs back. The bottom keeps its bounce.
struct SheetScrollHandoff: UIViewRepresentable {
    let close: () -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.close = close }

    final class Probe: UIView {
        var close: () -> Void = {}
        private weak var scroll: UIScrollView?
        private var watch: NSKeyValueObservation?
        private var beganAtTop = false
        private var anchor: CGFloat?   // finger translation when the content reached the top

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scroll == nil else { return }
            var v = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let scroll = v as? UIScrollView else { return }
            self.scroll = scroll
            // Bounce only in the bottom half, so the top never overshoots.
            watch = scroll.observe(\.contentOffset, options: [.initial, .new]) { s, _ in
                let top = -s.adjustedContentInset.top
                let bottom = s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height
                let bounce = bottom > top && s.contentOffset.y > (top + bottom) / 2
                if s.bounces != bounce { s.bounces = bounce }
            }
            scroll.panGestureRecognizer.addTarget(self, action: #selector(pan))
        }

        private var sheet: UISheetPresentationController? {
            var r: UIResponder? = self
            while let n = r, !(n is UIViewController) { r = n.next }
            var vc = r as? UIViewController
            while let p = vc?.parent { vc = p }
            return vc?.sheetPresentationController
        }

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let s = scroll, let sheetView = sheet?.presentedView else { return }
            let top = -s.adjustedContentInset.top
            let t = g.translation(in: window).y
            switch g.state {
            case .began:
                // Starting at the top, UIKit's own sheet drag handles it.
                beganAtTop = s.contentOffset.y <= top + 0.5
                anchor = nil
            case .changed:
                guard !beganAtTop else { return }
                if anchor == nil, s.contentOffset.y <= top + 0.5, g.velocity(in: window).y > 0 { anchor = t }
                guard let a = anchor else { return }
                let extra = t - a
                if extra <= 0 {
                    anchor = nil
                    sheetView.transform = .identity
                } else {
                    s.contentOffset.y = top   // the content holds still while the sheet moves
                    sheetView.transform = CGAffineTransform(translationX: 0, y: extra)
                }
            case .ended, .cancelled, .failed:
                defer { anchor = nil }
                guard !beganAtTop, let a = anchor, t - a > 0 else { return }
                let extra = t - a
                let fling = g.state == .ended && (extra > 120 || g.velocity(in: window).y > 700)
                if fling, let sheet, sheet.selectedDetentIdentifier == .large, sheet.detents.count > 1 {
                    sheet.animateChanges {
                        sheet.selectedDetentIdentifier = sheet.detents.first?.identifier
                        sheetView.transform = .identity
                    }
                } else if fling {
                    close()
                } else {
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                        sheetView.transform = .identity
                    }
                }
            default: break
            }
        }
    }
}
