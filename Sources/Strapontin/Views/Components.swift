import AppKit
import StrapontinCore
import SwiftUI

/// Le thème de Strapontin, en un seul endroit : salle obscure et rouge velours des fauteuils.
enum Theme {
    /// Rouge velours : sélection, bouton principal, progression, pastilles. Texte blanc dessus : contraste 7:1.
    static let accent = Color(red: 0.70, green: 0.07, blue: 0.18)          // #B3122E
    /// Le même rouge, éclairci pour du texte ou une icône sur fond sombre (contraste AA ≥ 4.5:1).
    static let accentText = Color(red: 0.95, green: 0.36, blue: 0.43)      // #F25C6E
    /// Noir chaud de salle de cinéma (pas du noir pur).
    static let background = Color(red: 0.067, green: 0.055, blue: 0.063)   // #110E10
    /// Fond des pages : très léger dégradé, plus chaud en haut, comme la lumière de l'écran.
    static let backdrop = LinearGradient(colors: [Color(red: 0.11, green: 0.07, blue: 0.08), background],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
    static let margin: CGFloat = 48
    static let corner: CGFloat = 12
}

/// Cache mémoire des images locales (affiches, fonds).
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(at url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url.path as NSString) { return img }
        let img = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        if let img { cache.setObject(img, forKey: url.path as NSString) }
        return img
    }
}

struct LocalImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let img = await ImageCache.shared.image(at: url)
            withAnimation(.easeOut(duration: 0.3)) { image = img }
        }
    }
}

/// Image TMDb distante (logos, photos d'épisodes, acteurs).
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
            if case .success(let img) = phase {
                img.resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
    }
}

/// Logo du titre si TMDb en a un, sinon le titre en gros.
struct TitleLogo: View {
    let item: LibraryItem
    var maxWidth: CGFloat = 420
    var maxHeight: CGFloat = 140
    var fontSize: CGFloat = 46

    var body: some View {
        LogoOrTitle(logoPath: item.media?.logoPath, title: item.title, maxWidth: maxWidth, maxHeight: maxHeight, fontSize: fontSize)
    }
}

/// Le logo, ou le titre écrit s'il n'y en a pas ou s'il ne se charge pas (format non pris en charge, réseau…).
struct LogoOrTitle: View {
    let logoPath: String?
    let title: String
    var maxWidth: CGFloat = 420
    var maxHeight: CGFloat = 140
    var fontSize: CGFloat = 46

    var body: some View {
        if let logo = logoPath {
            AsyncImage(url: TMDbClient.imageURL(logo, size: "w500"), transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                case .failure: text
                default: text.hidden()
                }
            }
            .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.5), radius: 12)
        } else {
            text.shadow(color: .black.opacity(0.5), radius: 12)
        }
    }

    private var text: some View {
        Text(title).font(.system(size: fontSize, weight: .heavy)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PosterView: View {
    let item: LibraryItem
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            if let m = item.media, m.posterPath != nil {
                LocalImage(url: store.posterURL(m))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: item.kind == .tv ? "tv" : "film")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.35))
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 12)
                }
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Affiche verticale avec effet de survol (élévation + reflet), comme sur Apple TV.
struct PosterCard: View {
    let item: LibraryItem
    var fixedWidth: CGFloat?
    @State private var hover = false
    @State private var deleteRequest: DeleteRequest?

    init(item: LibraryItem, fixedWidth: CGFloat? = 168) {
        self.item = item
        self.fixedWidth = fixedWidth
    }

    var body: some View {
        NavigationLink(value: item.id) {
            VStack(alignment: .leading, spacing: 9) {
                PosterView(item: item)
                    .overlay { Sheen(active: hover) }
                    .overlay(alignment: .bottom) { ProgressStrip(item: item) }
                    .overlay { DownloadOverlay(mediaKey: item.id) }
                    .overlay(alignment: .topLeading) { badges }
                    .overlay(alignment: .topTrailing) {
                        if item.allWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18)).foregroundStyle(.white, Color.black.opacity(0.55)).padding(8)
                        }
                    }
                    .shadow(color: .black.opacity(hover ? 0.7 : 0.35), radius: hover ? 22 : 8, y: hover ? 14 : 4)
                    .scaleEffect(hover ? 1.06 : 1)
                    .zIndex(hover ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(hover ? 1 : 0.85)
            }
            .frame(width: fixedWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .contextMenu { ItemMenu(item: item, deleteRequest: $deleteRequest) }
        .deleteConfirmation($deleteRequest)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if item.kind == .tv { parts.append("\(item.files.count) épisode\(item.files.count > 1 ? "s" : "")") }
        else if let g = item.media?.genres.first { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if item.media == nil { Badge(text: "NON IDENTIFIÉ", color: .red.opacity(0.85)) }
            if item.bestQuality?.hasPrefix("4K") == true { Badge(text: "4K") }
        }
        .padding(8)
    }
}

/// Vignette horizontale (fond 16:9) pour « À suivre », avec la progression.
struct LandscapeCard: View {
    let item: LibraryItem
    @EnvironmentObject var store: LibraryStore
    @State private var hover = false
    @State private var deleteRequest: DeleteRequest?

    init(item: LibraryItem) { self.item = item }

    var body: some View {
        let target = item.resumeTarget ?? item.nextUp
        Button { play(item, resume: item.inProgress) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    Color(white: 0.15)
                    if let still = target?.stillPath {
                        RemoteImage(url: TMDbClient.imageURL(still, size: "w780"))
                    } else if let m = item.media, m.backdropPath != nil {
                        LocalImage(url: store.backdropURL(m))
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        TitleLogo(item: item, maxWidth: 150, maxHeight: 44, fontSize: 18)
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(.white, in: Circle())
                            .opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
                    }
                    .padding(12)
                    .padding(.bottom, 6)
                    if let t = target, t.duration > 0, t.position > 0 {
                        GeometryReader { g in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.3))
                                    Capsule().fill(.white).frame(width: g.size.width * min(1, t.position / t.duration))
                                }
                                .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 7)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Sheen(active: hover) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .shadow(color: .black.opacity(hover ? 0.7 : 0.35), radius: hover ? 22 : 8, y: hover ? 14 : 4)
                .scaleEffect(hover ? 1.05 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(caption(target)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let t = target, t.duration > 0 {
                        Text(t.position > 0 ? "Reste \(formatTime(t.duration - t.position))" : "Pas encore commencé")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 320)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .contextMenu { ItemMenu(item: item, deleteRequest: $deleteRequest) }
        .deleteConfirmation($deleteRequest)
    }

    private func caption(_ f: MediaFile?) -> String {
        guard let f, let s = f.season, let e = f.episode else { return item.title }
        return "S\(s), É\(e)" + (f.episodeTitle.map { " · \($0)" } ?? "")
    }
}

/// Reflet lumineux qui balaie la vignette au survol.
struct Sheen: View {
    let active: Bool
    var body: some View {
        LinearGradient(colors: [.white.opacity(active ? 0.18 : 0), .clear], startPoint: .topLeading, endPoint: .center)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct ProgressStrip: View {
    let item: LibraryItem
    var body: some View {
        if item.inProgress, let f = item.resumeTarget, f.duration > 0 {
            GeometryReader { g in
                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.5))
                        Capsule().fill(.white).frame(width: g.size.width * min(1, f.position / f.duration))
                    }
                    .frame(height: 4)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
}

/// Rangée horizontale avec titre, défilement et flèches au survol.
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 21, weight: .bold)).padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) { content() }
                    .padding(.horizontal, Theme.margin)
                    .padding(.vertical, 14)
            }
            .padding(.vertical, -14)
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black.opacity(0.6)
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Petit badge technique encadré (4K, HDR, Dolby Atmos…), comme sur les fiches Apple TV.
struct SpecBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6), lineWidth: 1))
    }
}

struct ItemMenu: View {
    let item: LibraryItem
    @Binding var deleteRequest: DeleteRequest?
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        Button("Lire") { play(item, resume: false) }
        if item.inProgress { Button("Reprendre") { play(item, resume: true) } }
        Divider()
        Button(item.allWatched ? "Marquer comme non vu" : "Marquer comme vu") {
            store.setWatched(item.files.map(\.path), !item.allWatched)
        }
        if let f = item.files.first {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
        }
        Divider()
        Button("Supprimer…", role: .destructive) { deleteRequest = .item(item) }
        if item.kind == .tv, item.files.contains(where: \.watched) {
            Button("Supprimer les épisodes vus…", role: .destructive) { deleteRequest = .watched(item) }
        }
    }
}

func humanSize(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// Lance la lecture d'une entrée (film, ou épisodes à partir de `start`).
@MainActor
func play(_ item: LibraryItem, from start: MediaFile? = nil, resume: Bool) {
    guard let first = start ?? (resume ? item.resumeTarget : item.nextUp) else { return }
    let files: [MediaFile]
    if item.kind == .tv, let idx = item.files.firstIndex(of: first) {
        files = Array(item.files[idx...])
    } else {
        files = [first]
    }
    let queue = files.enumerated().map { i, f in
        PlayItem(file: f, title: item.title, resume: i == 0 ? resume : true)
    }
    PlayerController.play(queue)
}
