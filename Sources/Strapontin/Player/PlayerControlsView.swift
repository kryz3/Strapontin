import StrapontinCore
import SwiftUI

@MainActor
protocol PlayerActions: AnyObject {
    func togglePause()
    func seek(by s: Double)
    func seek(to s: Double)
    func setVolume(_ v: Double)
    func toggleMute()
    func toggleFullScreen()
    func playNext()
    func playPrevious()
    /// Lire un épisode précis de la série (panneau Épisodes).
    func playEpisode(_ file: MediaFile)
    /// Un épisode en streaming (panneau Épisodes), quand on ne l'a pas en fichier.
    func playStreamEpisode(_ key: EpisodeKey)
    func toggleEpisodes()
    func toggleMini()
    func zap(_ delta: Int)
    func zapBack()
    func toggleFavoriteChannel()
    func retryLive()
    /// Direct : changer de qualité (variante de la chaîne).
    func selectQuality(_ variantID: String)
    func select(_ track: Track?, type: String)
    func toggleInfo()
    func refreshTracks()
    func closePlayer()
    func playNextNow()
    func dismissNext()
    func skipMarker()
    func hoverTimeline(_ t: Double?)
    func thumbnail(at t: Double) -> NSImage?
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "--:--" }
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

/// Contrôles de lecture façon Apple TV : titre en bas à gauche, barre fine, gros boutons centrés,
/// panneau « Audio et sous-titres ».
struct PlayerControlsView: View {
    @ObservedObject var model: PlayerModel
    let actions: PlayerActions
    @State private var showTracks = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { actions.toggleFullScreen() }
                .onTapGesture { actions.togglePause() }

            if model.controlsVisible || showTracks {
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.22),
                                       .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottom
                }
                .transition(.opacity)
            }

            VStack(alignment: .trailing, spacing: 12) {
                if let offer = model.skip, model.next == nil {
                    SkipButton(offer: offer, action: actions.skipMarker).transition(.opacity)
                }
                if let card = model.next {
                    NextEpisodeCard(card: card, actions: actions)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 44)
            // au-dessus de la barre de temps quand les contrôles sont là
            .padding(.bottom, model.controlsVisible || showTracks ? 178 : 40)
            .animation(.easeInOut(duration: 0.25), value: model.next == nil)
            .animation(.easeInOut(duration: 0.25), value: model.skip)
            .opacity(model.scrubbing || model.episodesOpen ? 0 : 1)
            .allowsHitTesting(!model.scrubbing && !model.episodesOpen)
            .animation(.easeOut(duration: 0.15), value: model.scrubbing)

            // panneau Épisodes : par-dessus la vidéo, qui continue derrière, assombrie
            if model.episodesOpen, let id = model.seriesId {
                Color.black.opacity(0.45).contentShape(Rectangle())
                    .onTapGesture { actions.toggleEpisodes() }
                    .transition(.opacity)
                EpisodesPanel(series: SeriesModel.of(id), current: model.currentEpisode, actions: actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let n = model.live?.notice, !(model.live?.reconnecting ?? false) {
                Label(n, systemImage: "dial.medium")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20)
                    .transition(.opacity).allowsHitTesting(false)
            }
            if let live = model.live, live.reconnecting, !live.failed {
                Label("Reconnexion…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20)
                    .transition(.opacity).allowsHitTesting(false)
            }
            if let n = model.typedNumber {
                Text(n).font(.system(size: 54, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(30)
                    .allowsHitTesting(false)
            }
            if let live = model.live, live.failed {
                VStack(spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 40, weight: .light))
                    Text("\(live.name) ne répond pas").font(.system(size: 20, weight: .bold))
                    Text("Plusieurs reconnexions ont échoué. La chaîne est peut-être coupée chez le fournisseur.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 360)
                    HStack(spacing: 12) {
                        Button("Réessayer", action: actions.retryLive).buttonStyle(GlassCapsule())
                        Button("Chaîne suivante") { actions.zap(1) }.buttonStyle(GlassCapsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(30)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }

            if let info = model.info {
                Text(info)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 74).padding(.leading, 28)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.episodesOpen)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // fermer le lecteur, toujours visible avec les contrôles (plein écran compris)
            Button(action: actions.closePlayer) { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)) }
                .buttonStyle(GlassCircle(size: 36))
                .help("Fermer (Échap)")
            Spacer()
            Button(action: actions.toggleInfo) { Image(systemName: "info").font(.system(size: 14, weight: .bold)) }
                .buttonStyle(GlassCircle(size: 36))
                .help("Infos techniques (I)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    @ViewBuilder private var bottom: some View {
        if let live = model.live { liveBottom(live) } else { fileBottom }
    }

    /// Direct : la chaîne, ce qui passe maintenant et ensuite, le zapping.
    private func liveBottom(_ live: LiveDisplay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                if live.logo != nil {
                    ChannelLogo(logo: live.logo, name: live.name, collapsedSize: CGSize(width: 64, height: 40))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("EN DIRECT").font(.system(size: 10, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                        if let n = live.number { Text("\(n)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.7)) }
                        Text(live.group.uppercased()).font(.system(size: 10, weight: .heavy)).kerning(0.6).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(live.name).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                }
            }
            if let now = live.now {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(now.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(now.start.formatted(date: .omitted, time: .shortened) + " – " + now.stop.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                    ProgressView(value: min(1, max(0, Date().timeIntervalSince(now.start) / now.stop.timeIntervalSince(now.start))))
                        .tint(Theme.accent)
                    if let next = live.next {
                        Text("Ensuite : \(next.title) · \(next.start.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
            }
            ZStack {
                HStack(spacing: 30) {
                    transport("chevron.up", size: 20) { actions.zap(-1) }.help("Chaîne précédente (↑)")
                    Button(action: actions.togglePause) {
                        Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 30, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 64))
                    transport("chevron.down", size: 20) { actions.zap(1) }.help("Chaîne suivante (↓)")
                }
                HStack(spacing: 14) {
                    Button(action: actions.toggleFavoriteChannel) {
                        Image(systemName: live.favorite ? "star.fill" : "star").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(live.favorite ? Color.yellow : Color.white)
                    }
                    .buttonStyle(GlassCircle(size: 38))
                    .help(live.favorite ? "Retirer des favoris (*)" : "Ajouter aux favoris (*)")
                    Button(action: actions.zapBack) { Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .bold)) }
                        .buttonStyle(GlassCircle(size: 38)).help("Chaîne d'avant (⌫)")
                    Spacer()
                    Button { actions.refreshTracks(); showTracks.toggle() } label: {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                    .help(live.qualities.isEmpty ? "Audio et sous-titres" : "Qualité, audio et sous-titres")
                    .popover(isPresented: $showTracks, arrowEdge: .top) {
                        TracksPanel(audio: model.audioTracks, subs: model.subTracks, qualities: live.qualities,
                                    currentQuality: live.currentQuality, selectQuality: actions.selectQuality) { t, type in actions.select(t, type: type) }
                    }
                    VolumeControl(volume: model.volume, set: actions.setVolume, mute: actions.toggleMute)
                    Button(action: actions.toggleMini) {
                        Image(systemName: model.mini ? "pip.exit" : "pip.enter").font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                    .help(model.mini ? "Agrandir (⇧P)" : "Mini-lecteur, toujours devant (⇧P)")
                    Button(action: actions.toggleFullScreen) {
                        Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 30)
    }

    private var fileBottom: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.mini {
            VStack(alignment: .leading, spacing: 3) {
                if let s = model.subtitle {
                    Text(s.uppercased()).font(.system(size: 11, weight: .heavy)).kerning(0.8).foregroundStyle(.white.opacity(0.7))
                }
                Text(model.title).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            .opacity(model.scrubbing ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: model.scrubbing)
            }

            Scrubber(position: model.position, duration: model.duration, chapters: model.chapters,
                     forcedHover: model.forcedHover, thumbnail: actions.thumbnail(at:), onHoverTime: actions.hoverTimeline,
                     onSeek: { actions.seek(to: $0) })
                .zIndex(1)

            HStack {
                Text(formatTime(model.position))
                Spacer()
                Text("-" + formatTime(max(0, model.duration - model.position)))
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.top, -6)

            if model.mini {
                // mini-lecteur : l'essentiel seulement
                HStack(spacing: 16) {
                    transport("gobackward.10", size: 16) { actions.seek(by: -10) }
                    Button(action: actions.togglePause) {
                        Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 42))
                    transport("goforward.10", size: 16) { actions.seek(by: 10) }
                    Spacer()
                    Button(action: actions.toggleMini) { Image(systemName: "pip.exit").font(.system(size: 13, weight: .bold)) }
                        .buttonStyle(GlassCircle(size: 34)).help("Agrandir (⇧P)")
                }
            } else {
            ZStack {
                HStack(spacing: 30) {
                    transport("gobackward.10", size: 22) { actions.seek(by: -10) }
                    Button(action: actions.togglePause) {
                        Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 30, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 64))
                    transport("goforward.10", size: 22) { actions.seek(by: 10) }
                }

                HStack(spacing: 14) {
                    if model.seriesId != nil {
                        Button(action: actions.playPrevious) {
                            Image(systemName: "backward.end.fill").font(.system(size: 14, weight: .bold))
                        }
                        .buttonStyle(GlassCircle(size: 38))
                        .disabled(!model.hasPrevious)
                        .opacity(model.hasPrevious ? 1 : 0.4)
                        .help(model.hasPrevious ? "Épisode précédent (⇧N)" : "Premier épisode")
                        Button(action: actions.toggleEpisodes) {
                            Label("Épisodes", systemImage: "rectangle.stack.fill").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(GlassCapsule())
                        .help("Tous les épisodes de la saison (E)")
                    }
                    if model.hasNext {
                        Button(action: actions.playNext) {
                            Label("Épisode suivant", systemImage: "forward.end.fill").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(GlassCapsule())
                        .help("Épisode suivant (N)")
                    }
                    Spacer()
                    Button { actions.refreshTracks(); showTracks.toggle() } label: {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                    .help("Audio et sous-titres")
                    .popover(isPresented: $showTracks, arrowEdge: .top) {
                        TracksPanel(audio: model.audioTracks, subs: model.subTracks) { t, type in actions.select(t, type: type) }
                    }
                    VolumeControl(volume: model.volume, set: actions.setVolume, mute: actions.toggleMute)
                    Button(action: actions.toggleMini) {
                        Image(systemName: model.mini ? "pip.exit" : "pip.enter").font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                    .help(model.mini ? "Agrandir (⇧P)" : "Mini-lecteur, toujours devant (⇧P)")
                    Button(action: actions.toggleFullScreen) {
                        Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(GlassCircle(size: 38))
                }
            }
            }
        }
        .padding(.horizontal, model.mini ? 16 : 44)
        .padding(.bottom, model.mini ? 12 : 30)
    }

    private func transport(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: size, weight: .semibold)) }
            .buttonStyle(GlassCircle(size: 48, filled: false))
    }
}

/// Panneau deux colonnes : pistes audio | sous-titres.
struct TracksPanel: View {
    let audio: [Track]
    let subs: [Track]
    /// Direct : les qualités de la chaîne (4K, Full HD, HD, SD, secours).
    var qualities: [ChannelVariant] = []
    var currentQuality: String?
    var selectQuality: (String) -> Void = { _ in }
    let select: (Track?, String) -> Void

    init(audio: [Track], subs: [Track], qualities: [ChannelVariant] = [], currentQuality: String? = nil,
         selectQuality: @escaping (String) -> Void = { _ in }, select: @escaping (Track?, String) -> Void) {
        self.audio = audio; self.subs = subs; self.qualities = qualities; self.currentQuality = currentQuality
        self.selectQuality = selectQuality; self.select = select
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !qualities.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QUALITÉ").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                    ForEach(qualities) { q in
                        row(q.label, selected: q.id == currentQuality) { selectQuality(q.id) }
                            .help(q.rawName)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            column("Audio", audio, type: "audio", allowNone: false)
            Divider()
            column("Sous-titres", subs, type: "sub", allowNone: true)
        }
        .frame(width: qualities.isEmpty ? 520 : 720)
        .frame(minHeight: 160)
    }

    private func column(_ title: String, _ tracks: [Track], type: String, allowNone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if allowNone { row("Désactivés", selected: !tracks.contains(where: \.selected)) { select(nil, type) } }
                    ForEach(tracks) { t in row(t.label, selected: t.selected) { select(t, type) } }
                    if tracks.isEmpty && !allowNone { Text("Aucune piste").foregroundStyle(.secondary).padding(10) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(selected ? 1 : 0)
                Text(label).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VolumeControl: View {
    let volume: Double
    let set: (Double) -> Void
    let mute: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: mute) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(GlassCircle(size: 38))
            if hover {
                Slider(value: Binding(get: { volume }, set: set), in: 0...150)
                    .frame(width: 100).controlSize(.small).tint(.white)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
}

struct GlassCircle: ButtonStyle {
    var size: CGFloat = 40
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background { if filled { Circle().fill(.ultraThinMaterial) } }
            .overlay { if filled { Circle().stroke(.white.opacity(0.12)) } }
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(Circle())
    }
}

struct GlassCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

/// Barre de lecture fine qui s'épaissit au survol ; l'aperçu du temps suit la souris.
struct Scrubber: View {
    let position: Double
    let duration: Double
    let chapters: [Chapter]
    /// Copie d'essai : survol simulé.
    let forcedHover: Double?
    let thumbnail: (Double) -> NSImage?
    let onHoverTime: (Double?) -> Void
    let onSeek: (Double) -> Void
    @State private var dragValue: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let value = dragValue ?? position
            let frac = duration > 0 ? min(1, max(0, value / duration)) : 0
            let previewX: CGFloat? = dragValue != nil ? w * frac
                : hoverX ?? forcedHover.map { duration > 0 ? w * $0 / duration : 0 }
            let previewTime = previewX.map { Double($0 / w) * duration }
            let active = previewX != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: w * frac)
            }
            .frame(height: active ? 8 : 4)
            .overlay(alignment: .bottomLeading) {
                if let x = previewX, let t = previewTime, duration > 0 {
                    let pw = TimelinePreview.width
                    TimelinePreview(time: t, image: thumbnail(t), chapter: chapterTitle(at: t))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: pw)
                        .offset(x: min(max(0, x - pw / 2), max(0, w - pw)), y: -20)
                }
            }
            .onChange(of: previewTime) { _, t in onHoverTime(t) }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = min(max(0, p.x), w) } else { hoverX = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragValue = max(0, min(duration, Double(g.location.x / w) * duration)) }
                .onEnded { _ in
                    if let d = dragValue { onSeek(d) }
                    dragValue = nil
                })
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 18)
        .onDisappear { onHoverTime(nil) }
    }

    private func chapterTitle(at t: Double) -> String? {
        guard let title = chapters.last(where: { $0.start <= t })?.title.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              title.range(of: #"^[\d:.,]+$"#, options: .regularExpression) == nil else { return nil }
        return title
    }
}
