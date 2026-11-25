import Combine
import StrapontinCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore

    private var featured: [LibraryItem] {
        let withArt = store.items.filter { $0.media?.backdropPath != nil }
        let fresh = withArt.sorted { $0.added > $1.added }.prefix(4)
        let best = withArt.filter { !$0.allWatched }.sorted { ($0.media?.rating ?? 0) > ($1.media?.rating ?? 0) }.prefix(4)
        var seen = Set<String>()
        return (Array(fresh) + Array(best)).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                if store.items.isEmpty {
                    DownloadingShelf().padding(.top, 90)
                    ContinueShelf()
                    EmptyLibrary(compact: !DownloadsModel.shared.visibleEntries(store: store).isEmpty)
                } else {
                    HeroCarousel(items: featured)
                    DownloadingShelf()
                    ContinueShelf()
                    Shelf(title: "Ajoutés récemment") {
                        ForEach(SortOrder.added.sort(store.items).prefix(20)) { PosterCard(item: $0) }
                    }
                    let movies = store.items.filter { $0.kind == .movie && !$0.allWatched }
                    if !movies.isEmpty {
                        Shelf(title: "Films à voir") { ForEach(SortOrder.rating.sort(movies).prefix(20)) { PosterCard(item: $0) } }
                    }
                    let shows = store.items.filter { $0.kind == .tv }
                    if !shows.isEmpty {
                        Shelf(title: "Séries") { ForEach(SortOrder.played.sort(shows)) { PosterCard(item: $0) } }
                    }
                    let unmatched = store.items.filter { $0.media == nil }
                    if !unmatched.isEmpty {
                        Shelf(title: "À identifier") { ForEach(unmatched) { PosterCard(item: $0) } }
                    }
                }
            }
            .padding(.bottom, 50)
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// Grand visuel plein cadre qui défile tout seul, avec logo du titre et bouton Lire.
struct HeroCarousel: View {
    let items: [LibraryItem]
    @EnvironmentObject var store: LibraryStore
    @State private var index = 0
    @State private var hover = false
    private let timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        if items.isEmpty {
            Color.clear.frame(height: 90)
        } else {
            let item = items[min(index, items.count - 1)]
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        if let m = it.media {
                            LocalImage(url: store.backdropURL(m))
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(i == index ? 1 : 0)
                                .scaleEffect(i == index ? 1.0 : 1.04)
                        }
                    }
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5))
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background.opacity(0.85), location: 0.85),
                                           .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 14) {
                        TitleLogo(item: item, maxWidth: 460, maxHeight: 150, fontSize: 50)
                            .id(item.id)
                            .transition(.opacity)
                        MetaLine(item: item)
                        if let o = item.media?.overview, !o.isEmpty {
                            Text(o).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(3).frame(maxWidth: 520, alignment: .leading)
                        }
                        HStack(spacing: 12) {
                            PlayPill(title: item.inProgress ? "Reprendre" : "Lire") { play(item, resume: item.inProgress) }
                            NavigationLink(value: item.id) {
                                Image(systemName: "info").font(.system(size: 15, weight: .bold))
                            }
                            .buttonStyle(CircleButtonStyle())
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 46)
                    .animation(.easeInOut(duration: 0.5), value: index)

                    if items.count > 1 {
                        HStack(spacing: 7) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule().fill(.white.opacity(i == index ? 0.95 : 0.35))
                                    .frame(width: i == index ? 20 : 7, height: 7)
                                    .onTapGesture { withAnimation(.easeInOut(duration: 0.8)) { index = i } }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, Theme.margin)
                        .padding(.bottom, 52)

                        HStack {
                            arrow("chevron.left") { step(-1) }
                            Spacer()
                            arrow("chevron.right") { step(1) }
                        }
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 14)
                        .opacity(hover ? 1 : 0)
                    }
                }
            }
            .frame(height: 560)
            .onHover { hover = $0 }
            .onReceive(timer) { _ in if !hover { step(1) } }
        }
    }

    private func step(_ d: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 1.0)) { index = (index + d + items.count) % items.count }
    }

    private func arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18, weight: .bold))
        }
        .buttonStyle(CircleButtonStyle(size: 44))
    }
}

/// « Film · 2024 · Science-fiction · 2 h 46 » + badges techniques.
struct MetaLine: View {
    let item: LibraryItem
    var body: some View {
        HStack(spacing: 8) {
            Text(parts.joined(separator: " · ")).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            if let c = item.media?.certification { SpecBadge(text: c) }
            ForEach(specs, id: \.self) { SpecBadge(text: $0) }
        }
    }

    private var parts: [String] {
        var p = [item.kind == .tv ? "Série" : "Film"]
        if let y = item.year { p.append(String(y)) }
        if let g = item.media?.genres.first { p.append(g) }
        if item.kind == .movie, let r = item.media?.runtime, r > 0 { p.append(r >= 60 ? "\(r / 60) h \(String(format: "%02d", r % 60))" : "\(r) min") }
        if let r = item.media?.imdbRating { p.append("IMDb \(r)") } else if let r = item.media?.rating, r > 0 { p.append("★ \(String(format: "%.1f", r))") }
        return p
    }

    private var specs: [String] {
        let q = item.bestQuality ?? ""
        return ["4K", "Dolby Vision", "HDR10+", "HDR", "Atmos"].filter { q.contains($0) }
            .map { $0 == "Atmos" ? "Dolby Atmos" : $0 }
    }
}

/// Bouton blanc en pilule, comme « Lire » sur Apple TV.
struct PlayPill: View {
    let title: String
    var icon = "play.fill"
    let action: () -> Void
    @State private var hover = false

    init(title: String, icon: String = "play.fill", action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 11)
                .background(Theme.accent, in: Capsule())
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(0.3), radius: hover ? 12 : 4, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
    }
}

/// Bouton rond translucide.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 42
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.15)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(Circle())
    }
}
