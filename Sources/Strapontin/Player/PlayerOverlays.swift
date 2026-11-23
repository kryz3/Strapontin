import StrapontinCore
import SwiftUI

/// Ce que montre la carte « Épisode suivant ».
struct NextCard: Equatable {
    enum Kind: Equatable {
        case ready
        /// Pas dans la bibliothèque : se télécharge d'ici, quand on connaît la série.
        case missing(tmdbId: Int, EpisodeKey)
    }
    var kind: Kind
    var label: String
    var title: String
    var still: String?
    var backdrop: String?
    var secondsLeft: Int?
    var fraction: Double?
    var sceneAfter: Double?
    var ended: Bool
    /// Une scène suit le générique : juste un petit bouton, la scène reste visible.
    var compact = false
}

/// Bouton « Passer l'intro », discret, en bas à droite.
struct SkipButton: View {
    let offer: SkipOffer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(offer.kind == .intro ? "Passer l'intro" : "Passer le récap").font(.system(size: 15, weight: .semibold))
                Image(systemName: "forward.end.fill").font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 20).padding(.vertical, 11)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassCapsule())
        .help("Entrée")
    }
}

/// La carte de fin d'épisode, en bas à droite, façon Apple TV.
struct NextEpisodeCard: View {
    let card: NextCard
    let actions: PlayerActions

    var body: some View {
        if card.compact, case .ready = card.kind {
            Button(action: actions.playNextNow) {
                HStack(spacing: 8) {
                    Text("Épisode suivant").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "forward.end.fill").font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .contentShape(Capsule())
            }
            .buttonStyle(GlassCapsule())
            .help(card.title)
        } else {
            full
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                picture
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading).font(.system(size: 10, weight: .heavy)).kerning(0.8).foregroundStyle(.white.opacity(0.65))
                    Text(card.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                switch card.kind {
                case .ready:
                    Button(action: actions.playNextNow) {
                        Label("Lire maintenant", systemImage: "play.fill").modifier(CardButton(primary: true, fill: card.fraction))
                    }
                    .buttonStyle(.plain)
                case let .missing(id, key):
                    MissingEpisodeAction(tmdbId: id, key: key)
                }
                Spacer(minLength: 0)
                if let target = card.sceneAfter {
                    Button { actions.seek(to: target) } label: { Text("Passer le générique").modifier(CardButton()) }
                        .buttonStyle(.plain)
                }
                Button(action: actions.dismissNext) {
                    Text(card.ended ? "Fermer" : "Regarder le générique").modifier(CardButton())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: card.sceneAfter == nil ? 410 : 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private var heading: String {
        card.secondsLeft.map { "ÉPISODE SUIVANT DANS \($0) S" } ?? "ÉPISODE SUIVANT"
    }

    private var subtitle: String {
        if case .missing = card.kind { return "\(card.label) · pas dans ta bibliothèque" }
        return card.label
    }

    private var picture: some View {
        ZStack {
            Color(white: 0.16)
            RemoteImage(url: TMDbClient.imageURL(card.still ?? card.backdrop, size: "w780"))
        }
        .frame(width: 152, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CardButton: ViewModifier {
    var primary = false
    /// Le compte à rebours remplit le bouton.
    var fill: Double? = nil

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background {
                if primary {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(fill == nil ? 1 : 0.62))
                            if let fill { Rectangle().fill(.white).frame(width: g.size.width * fill) }
                        }
                    }
                } else {
                    Color.white.opacity(0.14)
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

/// Épisode suivant absent : Télécharger, sa progression, ou pourquoi on ne peut pas. Ne lance jamais rien tout seul.
private struct MissingEpisodeAction: View {
    let tmdbId: Int
    let key: EpisodeKey
    @ObservedObject private var series: SeriesModel
    @ObservedObject private var downloads = DownloadsModel.shared
    @ObservedObject private var tracker = TrackerModel.shared

    init(tmdbId: Int, key: EpisodeKey) {
        self.tmdbId = tmdbId
        self.key = key
        series = SeriesModel.of(tmdbId)
    }

    var body: some View {
        let snap = series.snapshot(key.season)
        Group {
            if let e = tracker.grabErrors[series.key] {
                note("Échec du téléchargement").help(e)
            } else {
                action(snap)
            }
        }
        // l'indexeur n'est interrogé qu'au moment où la carte paraît
        .task(id: key) { series.show(season: key.season, episode: key.episode) }
    }

    @ViewBuilder
    private func action(_ snap: SeriesModel.Snapshot) -> some View {
        switch snap.statuses[key.episode] ?? .unknown {
        case .available:
            if series.recommended(key.episode, snap) != nil {
                Button { series.downloadEpisode(season: key.season, episode: key.episode) } label: {
                    Label("Télécharger", systemImage: "arrow.down").modifier(CardButton(primary: true))
                }
                .buttonStyle(.plain).help("Télécharger l'épisode suivant")
            } else {
                note("Version à choisir sur sa fiche")
            }
        case .inSeasonPack:
            if snap.plan.offerPack {
                Button { series.downloadSeason(key.season) } label: {
                    Label("Télécharger la saison", systemImage: "arrow.down").modifier(CardButton(primary: true))
                }
                .buttonStyle(.plain)
            } else {
                note("Seulement en saison complète")
            }
        case let .downloading(_, p, phase, _):
            HStack(spacing: 8) {
                ProgressRing(progress: p, phase: phase, size: 28)
                note(phase == .downloading ? "\(Int(p * 100)) %" : phase.label)
            }
        case .sending: note("Envoi…")
        case .arriving, .owned: note("Ajout à la bibliothèque…")
        case .unavailable: note("Rien sur l'indexeur")
        case .upcoming: note("Pas encore diffusé")
        case .unknown:
            if !tracker.configured { note("Indexeur non branché") }
            else if series.releaseErrors[key.season] != nil { note("Indexeur injoignable") }
            else { ProgressView().controlSize(.small) }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.8)).lineLimit(1)
    }
}

/// Au-dessus du curseur : l'image de ce moment-là, l'heure, le chapitre.
struct TimelinePreview: View {
    let time: Double
    let image: NSImage?
    let chapter: String?
    static let width: CGFloat = 240

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Color(white: 0.1)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: Self.width, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
            HStack(spacing: 6) {
                Text(formatTime(time)).font(.system(size: 12, weight: .bold).monospacedDigit())
                if let chapter { Text(chapter).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: Self.width)
        }
        .allowsHitTesting(false)
    }
}
