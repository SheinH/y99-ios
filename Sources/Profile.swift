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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                avatar
                if let profile {
                    details(profile)
                } else if failed {
                    Text("Couldn't load the profile.").foregroundStyle(.secondary).padding(.top, 20)
                } else {
                    ProgressView().padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .task {
            if let p = await Profile.load(user, auth: auth, me: me) { profile = p } else { failed = true }
        }
        .task(id: profile?.avatar) {
            // Sharper than the thumb: the full size, cached per picture by Avatar.
            if picture == nil { picture = full }
            if picture == nil, let thumb { picture = await Avatar.cachedFull(thumb) }
            if picture == nil, let thumb, let big = profile?.avatar { picture = await Avatar.full(thumb: thumb, big: big) }
        }
    }

    var avatar: some View {
        Group {
            if let picture {
                Image(uiImage: picture).resizable().scaledToFill()
                    .frame(width: 140, height: 140).clipShape(Circle())
            } else {
                AvatarView(thumb: thumb, size: 140)
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    @ViewBuilder func details(_ p: Profile) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(p.username).font(.title2.weight(.bold))
                if p.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue) }
            }
            Label(p.level.map { "Level \($0)" } ?? "Level N/A", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
        }
        .multilineTextAlignment(.center)

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
