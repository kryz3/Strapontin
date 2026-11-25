import AppKit
import StrapontinCore
import SwiftUI

struct PlayItem: Hashable {
    var path: String
    var title: String
    var subtitle: String?
    var start: Double
    /// Chaîne en direct (IPTV) : options de flux, sources de secours, guide.
    var live: LiveInfo? = nil
    /// Film ou épisode à la demande (IPTV) : clé de reprise de lecture.
    var progressKey: String? = nil
}

struct LiveInfo: Hashable {
    var entry: IPTVEntry
    var alternates: [String]
    /// Qualités de la chaîne (4K, FHD, HD…), la meilleure d'abord ; celle qu'on lit.
    var variants: [ChannelVariant] = []
    var variantID: String?
    var userAgent: String
    var referer: String
}

/// Ce que montrent les contrôles pour une chaîne en direct.
struct LiveDisplay: Equatable {
    var name: String
    var logo: String?
    var number: Int?
    var group: String
    var now: ProgramGuide.Program?
    var next: ProgramGuide.Program?
    var favorite: Bool
    var reconnecting = false
    var failed = false
    var qualities: [ChannelVariant] = []
    var currentQuality: String?
    /// Message discret quelques secondes (« Qualité réduite : HD »).
    var notice: String?
}

extension PlayItem {
    /// Reprise : la position la plus récente du titre, qu'elle vienne de ce fichier ou du streaming.
    @MainActor
    init(file f: MediaFile, title: String, resume: Bool) {
        var subtitle: String?
        if let s = f.season, let e = f.episode {
            subtitle = "Saison \(s), épisode \(e)" + (f.episodeTitle.map { " · \($0)" } ?? "")
        }
        let start = resume ? (Watch.key(of: f).map(Watch.resume) ?? (f.watched ? 0 : f.position)) : 0
        self.init(path: f.path, title: title, subtitle: subtitle, start: start)
    }

    /// Un épisode en streaming, rattaché à son titre.
    @MainActor
    init(stream url: String, title: String, key: TitleKey) {
        // le nom de l'épisode vient de TMDb, comme pour un fichier
        let sub = key.episode.map { e in
            "Saison \(e.season), épisode \(e.episode)" + (SeriesModel.of(key.tmdbId).info(e.season, e.episode)?.name.map { " · \($0)" } ?? "")
        }
        self.init(path: url, title: title, subtitle: sub, start: Watch.resume(key), progressKey: Watch.streamKey(key))
    }
}

/// État affiché par les contrôles de lecture.
final class PlayerModel: ObservableObject {
    @Published var title = ""
    @Published var subtitle: String?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var volume: Double = 100
    @Published var controlsVisible = true
    @Published var hasNext = false
    @Published var hasPrevious = false
    /// Série en cours (nil pour un film) et épisode affiché : boutons Précédent / Épisodes.
    @Published var seriesId: Int?
    @Published var currentEpisode: EpisodeKey?
    @Published var episodesOpen = false
    /// Mini-lecteur (petite fenêtre flottante) : contrôles réduits.
    @Published var mini = false
    /// Chaîne en direct (nil pour un film ou un épisode).
    @Published var live: LiveDisplay?
    /// Saisie d'un numéro de chaîne en cours (« 1 », « 12 »…).
    @Published var typedNumber: String?
    @Published var audioTracks: [Track] = []
    @Published var subTracks: [Track] = []
    /// Streaming à la demande : versions du titre en cours, et celle qu'on lit.
    @Published var versions: [VersionOption] = []
    /// Sous-titres en ligne : recherche en cours, résultats, ou message.
    @Published var onlineSubs: OnlineSubs = .idle
    /// Volume affiché brièvement après un réglage (↑ ↓, molette, curseur).
    @Published var volumeShown: Double?
    @Published var currentVersion: String?
    @Published var info: String?
    @Published var isFullScreen = false
    @Published var chapters: [Chapter] = []
    @Published var skip: SkipOffer?
    @Published var next: NextCard?
    /// Avance quand une vignette arrive.
    @Published var thumbnailsReady = 0
    /// Copie d'essai : survol simulé de la barre de temps.
    @Published var forcedHover: Double?
    /// La souris est sur la barre de temps : la vignette prend la place du titre et de la carte.
    @Published var scrubbing = false
}

/// Fenêtre de lecture : vidéo mpv + contrôles SwiftUI par-dessus.
///
/// Rendu normal : gpu-next (libplacebo, via Vulkan/MoltenVK), seul moteur de mpv qui applique le Dolby Vision
/// profil 5. Sur Mac, mpv dessine alors dans sa propre fenêtre (pas d'incrustation possible dans une vue) :
/// on récupère cette fenêtre (propriété `window-id`) et on pose nos contrôles dedans.
/// Secours : si gpu-next ne démarre pas, mpv passe à vo=libmpv et on affiche l'ancien rendu OpenGL dans
/// notre propre fenêtre.
@MainActor
final class PlayerController: NSObject, NSWindowDelegate {
    private(set) static var current: PlayerController?

    let model = PlayerModel()
    let player: MPVPlayer
    private let videoView: MPVVideoView // rendu OpenGL de secours, prêt avant le premier loadfile
    private let overlay = PlayerContainerView()
    private(set) var window: NSWindow?
    private var ownsWindow = false
    var queue: [PlayItem]
    var index = 0
    private var finishedCurrent = false
    var closing = false
    private var idleTimer: Timer?
    private var saveTimer: Timer?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var lastActivity = Date()
    private let windowSize: NSSize

    /// Le fichier en cours est ouvert : sa position et sa durée sont les siennes, pas celles du précédent.
    var loaded = false
    private var changing = false
    private(set) var markers = PlaybackMarkers()
    private var endCard = EndCard()
    private enum Upcoming: Equatable {
        case item(PlayItem, MediaFile?)
        case missing(tmdbId: Int, EpisodeKey)
        case none
    }
    private var upcoming = Upcoming.none
    private var lastLookup = Date.distantPast
    /// Pistes choisies, à retrouver par langue dans le fichier suivant.
    private var carriedTracks: (audio: TrackTraits?, subtitle: TrackTraits?)?
    private var thumbnails: ThumbnailEngine?
    private var hoverTime: Double?
    private var hoverPending = false
    private var decoded: (slot: Int, image: NSImage)?
    /// Cadre d'avant le mini-lecteur.
    private var miniRestore: NSRect?
    // direct
    var watchdog = LiveWatchdog()
    var liveEnded = false
    var liveFailedFlag = false
    /// Le direct est arrivé au bout de ce qu'il avait (le lecteur s'est mis en pause tout seul) : à réparer.
    var liveAtEnd = false
    var liveURL = ""
    var alternateIndex = 0
    var previousChannel: IPTVEntry?
    var liveNotice: String?
    var volumeTimer: Timer?
    var noticeTimer: Timer?
    var numberTimer: Timer?

    static func play(_ items: [PlayItem]) {
        current?.close()
        guard !items.isEmpty else { return }
        let c = PlayerController(queue: items)
        current = c
        c.loadCurrent()
    }

    private init(queue: [PlayItem]) {
        self.queue = queue
        let settings = AppSettings.shared
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        windowSize = NSSize(width: min(1440, visible.width * 0.8), height: min(810, visible.width * 0.8 * 9 / 16))
        let scale = screen?.backingScaleFactor ?? 2
        // copie d'essai : pas de son, pas de premier plan, et pas de fenêtre vidéo sauf essai du vrai rendu
        let trial = EssaiHarness.enabled
        let vo = trial && !EssaiHarness.realRendering ? "null" : "gpu-next,libmpv"
        let mpv = MPVPlayer(settings: settings, vo: vo, options: (trial ? EssaiHarness.playerOptions : []) + [
            ("gpu-context", "macvk"),
            ("geometry", "\(Int(windowSize.width * scale))x\(Int(windowSize.height * scale))"), // pixels
            ("keepaspect-window", "no"),      // fenêtre libre, bandes noires comme avant
            ("auto-window-resize", "no"),     // même taille d'un épisode à l'autre
            ("cursor-autohide", "no"),        // le curseur est géré par nos contrôles
            ("title", queue.first?.title ?? "Strapontin"),
        ])
        player = mpv
        videoView = MPVVideoView(player: mpv)
        super.init()
        model.volume = settings.volume

        let hosting = NSHostingView(rootView: PlayerControlsView(model: model, actions: self))
        hosting.frame = overlay.bounds
        hosting.autoresizingMask = [.width, .height]
        overlay.addSubview(hosting)
        overlay.controller = self
        overlay.autoresizingMask = [.width, .height]

        bindPlayer()
        // le bouton de fermeture de la fenêtre de mpv envoie CLOSE_WIN : on le transforme en message pour nous
        player.command(["keybind", "CLOSE_WIN", "script-message lecteur-close"])
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self] e in
            if let self, e.window === self.window { self.activity() }
            return e
        }
        // raccourcis clavier, quel que soit le premier répondeur de la fenêtre de mpv
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return self.overlay.handle(e) ? nil : e
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
                self?.refresh()
            }
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress() }
        }
    }

    private func bindPlayer() {
        player.onTime = { [weak self] t in self?.timeChanged(t) }
        player.onDuration = { [weak self] d in self?.model.duration = d; self?.publishNowPlaying() }
        player.onPause = { [weak self] p in
            self?.model.paused = p
            self?.activity()
            self?.publishNowPlaying()
        }
        player.onEndOfFile = { [weak self] in self?.endOfFile() }
        player.onEndFile = { [weak self] error, eof in
            guard let self, self.isLive else { return }
            if error { self.liveFailedFlag = true } else if eof { self.liveEnded = true }
        }
        player.onLeftEndOfFile = { [weak self] in
            guard let self, self.endCard.ended else { return }
            self.endCard.leftEnd()
            self.advance()
        }
        player.onFileLoaded = { [weak self] in self?.fileLoaded() }
        player.onFullscreen = { [weak self] fs in
            guard let self, !self.ownsWindow else { return }
            self.model.isFullScreen = fs
        }
        player.onVideoReconfig = { [weak self] in self?.attachVideoWindow() }
        player.onClientMessage = { [weak self] args in
            if args.first == "lecteur-close" { self?.close() }
        }
        player.onShutdown = { [weak self] in self?.close() }
    }

    // MARK: - Fenêtre

    /// La sortie vidéo est prête : fenêtre de mpv (gpu-next) ou, en secours, notre fenêtre OpenGL.
    private func attachVideoWindow() {
        player.get("current-vo") { [weak self] vo in
            guard let self, !self.closing else { return }
            if vo == "libmpv" || (vo == "null" && EssaiHarness.enabled) {
                self.showOwnWindow()
            } else {
                self.player.windowPointer { [weak self] ptr in
                    guard let self, !self.closing, let ptr else { return }
                    self.adopt(Unmanaged<NSWindow>.fromOpaque(ptr).takeUnretainedValue())
                }
            }
        }
    }

    private func adopt(_ w: NSWindow) {
        guard w !== window else { return }
        window = w
        ownsWindow = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .black
        w.minSize = NSSize(width: 480, height: 270)
        w.acceptsMouseMovedEvents = true
        install(in: w)
        // en bibliothèque, mpv remplace l'icône du Dock par la sienne : on remet celle de l'app
        NSApp.applicationIconImage = nil
        updateTitle()
        if EssaiHarness.enabled { EssaiHarness.conceal(w); return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOwnWindow() {
        guard window == nil || !ownsWindow else { return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.minSize = NSSize(width: 480, height: 270)
        w.isReleasedWhenClosed = false
        w.center()
        let root = NSView(frame: NSRect(origin: .zero, size: windowSize))
        videoView.frame = root.bounds
        videoView.autoresizingMask = [.width, .height]
        root.addSubview(videoView)
        w.contentView = root
        w.delegate = self
        window = w
        ownsWindow = true
        install(in: w)
        updateTitle()
        if EssaiHarness.enabled {
            EssaiHarness.conceal(w)
            w.orderBack(nil)
            return
        }
        w.makeKeyAndOrderFront(nil)
    }

    private func install(in w: NSWindow) {
        guard let content = w.contentView else { return }
        overlay.removeFromSuperview()
        overlay.frame = content.bounds
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        w.makeFirstResponder(overlay)
    }

    private func updateTitle() {
        guard index < queue.count else { return }
        let item = queue[index]
        let title = item.subtitle.map { "\(item.title) · \($0)" } ?? item.title
        if ownsWindow { window?.title = title } else { player.set("title", title) }
    }

    /// Ramène la fenêtre de la bibliothèque devant.
    private func showLibrary() {
        if EssaiHarness.enabled { return }
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            main.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func loadCurrent() {
        let item = queue[index]
        finishedCurrent = false
        loaded = false
        changing = false
        markers = PlaybackMarkers()
        endCard = EndCard()
        upcoming = .none
        lastLookup = .distantPast
        model.chapters = []
        model.skip = nil
        model.next = nil
        model.title = item.title
        model.subtitle = item.subtitle
        model.position = 0
        model.duration = 0
        model.info = nil
        model.hasNext = false
        updateTitle()
        updateSeriesContext()
        model.versions = []
        model.currentVersion = nil
        model.onlineSubs = .idle
        if item.live == nil, item.progressKey != nil { Task { await loadVersions() } }
        startThumbnails(item.path)
        let file = currentFile
        IntroAnalyzer.shared.playbackStarted(file)
        if let f = file, let id = Self.seriesId(f), let s = f.season { SeriesModel.of(id).prepareNext(after: s) }
        if carriedTracks != nil {
            // mpv garderait le numéro de piste, pas la langue
            player.set("aid", "auto")
            player.set("sid", "auto")
        }
        prepareStream(item)
        player.load(item.path, start: item.start)
        NowPlaying.shared.attach(self)
        publishNowPlaying()
    }

    /// Centre de contrôle et touches multimédia : ce qui joue en ce moment.
    private func publishNowPlaying() {
        NowPlaying.shared.update(title: model.title, subtitle: model.subtitle, duration: model.duration,
                                 position: model.position, paused: model.paused)
    }

    /// Série, épisode en cours et épisode d'avant, pour les boutons et le panneau Épisodes.
    private func updateSeriesContext() {
        let t = currentTitle
        let id = t?.kind == .tv ? t?.tmdbId : nil
        model.seriesId = id
        model.currentEpisode = t?.episode
        model.hasPrevious = previousTarget != nil || previousFile != nil
        if let id, let s = t?.episode?.season {
            SeriesModel.of(id).show(season: s)
            // les épisodes en streaming de la série, pour enchaîner d'une source à l'autre
            let series = SeriesModel.of(id)
            let title = series.media?.title ?? queue[index].title, year = series.media?.year
            Task { await SeriesStreams.of(id).load(tmdbId: id, titles: [title, series.media?.originalTitle ?? ""], year: year) }
        }
    }

    // MARK: - D'une source à l'autre

    /// Le titre en cours (film ou épisode), qu'on lise un fichier ou du streaming.
    var currentTitle: TitleKey? {
        if let f = currentFile, let k = Watch.key(of: f) { return k }
        guard index < queue.count else { return nil }
        return queue[index].progressKey.flatMap(Watch.title(fromStreamKey:))
    }

    /// Sources de chaque épisode de la série : fichiers de la bibliothèque, épisodes en streaming.
    private func crossSources(_ id: Int) -> [EpisodeKey: CrossSource.Source] {
        let mk = Media.key(.tv, id)
        var files: [EpisodeKey: String] = [:]
        for f in LibraryStore.shared.files where f.mediaKey == mk {
            if let s = f.season, let e = f.episode, files[EpisodeKey(s, e)] == nil { files[EpisodeKey(s, e)] = f.path }
        }
        var streams: [EpisodeKey: String] = [:]
        if let r = SeriesStreams.of(id).ref {
            for e in IPTVStore.shared.episodes[r.id] ?? [] { streams[EpisodeKey(e.season, e.episode)] = e.url }
        }
        return CrossSource.sources(files: files, streams: streams)
    }

    /// Épisodes déjà diffusés que TMDb connaît (pour proposer de télécharger celui qui manque).
    private func knownEpisodes(_ id: Int) -> [EpisodeKey] {
        let series = SeriesModel.of(id), today = SeriesModel.today()
        return series.episodes.flatMap { s, eps in
            eps.compactMap { e, info in (info.airDate ?? "") <= today && info.airDate != nil ? EpisodeKey(s, e) : nil }
        }
    }

    private func crossItem(_ id: Int, _ key: EpisodeKey, _ source: CrossSource.Source) -> (PlayItem, MediaFile?) {
        let title = SeriesModel.of(id).media?.title ?? queue[index].title
        switch source {
        case .file(let path):
            let f = LibraryStore.shared.files.first { $0.path == path }!
            return (PlayItem(file: f, title: title, resume: true), f)
        case .stream(let url):
            return (PlayItem(stream: url, title: title, key: TitleKey(.tv, id, key)), nil)
        }
    }

    /// L'épisode d'avant, quelle que soit sa source.
    private var previousTarget: (PlayItem, MediaFile?)? {
        guard let t = currentTitle, t.kind == .tv, let cur = t.episode,
              let (k, src) = CrossSource.previous(before: cur, sources: crossSources(t.tmdbId)) else { return nil }
        return crossItem(t.tmdbId, k, src)
    }

    private var sameSeriesFiles: [MediaFile] {
        guard let file = currentFile, let key = file.mediaKey else { return [] }
        return LibraryStore.shared.files.filter { $0.mediaKey == key }
    }

    private var previousFile: MediaFile? {
        currentFile.flatMap { PreviousEpisode.before($0, files: sameSeriesFiles) }
    }

    /// Passe à un autre fichier tout de suite (épisode précédent, choix dans le panneau), pistes gardées.
    private func jump(to file: MediaFile) {
        jump(to: PlayItem(file: file, title: queue[index].title, resume: true))
    }

    private func jump(to item: PlayItem) {
        guard !changing, !closing, item.path != queue[index].path else { return }
        saveProgress(finished: false)
        changing = true
        model.next = nil
        player.tracks { [weak self] tracks in
            guard let self, !self.closing else { return }
            func selected(_ type: String) -> TrackTraits? { tracks.first { $0.type == type && $0.selected }?.traits }
            if tracks.contains(where: { $0.type == "audio" }) { self.carriedTracks = (selected("audio"), selected("sub")) }
            self.queue = Array(self.queue.prefix(self.index + 1)) + [item]
            self.index += 1
            self.loadCurrent()
        }
    }

    // MARK: - Intro, générique, épisode suivant

    private var currentFile: MediaFile? {
        guard index < queue.count else { return nil }
        let path = queue[index].path
        return LibraryStore.shared.files.first { $0.path == path }
    }

    private static func seriesId(_ f: MediaFile) -> Int? {
        guard let key = f.mediaKey, let (kind, id) = TMDbLink.parseKey(key), kind == .tv else { return nil }
        return id
    }

    private var creditsSpan: MediaSpan? { markers.credits?.span }

    private var nextState: EndCard.Next {
        switch upcoming {
        case .item: return .ready
        case .missing: return .notOwned
        case .none: return .none
        }
    }

    private func fileLoaded() {
        let path = index < queue.count ? queue[index].path : ""
        let seriesKey = currentFile.flatMap { Self.seriesId($0) != nil ? $0.mediaKey : nil }
        player.tracks { [weak self] tracks in
            guard let self, !self.closing else { return }
            if let wanted = self.carriedTracks {
                self.carriedTracks = nil
                self.apply(wanted, to: tracks)
            } else if let key = seriesKey, let saved = SeriesTracks.get(key), tracks.contains(where: { $0.type == "audio" }) {
                // pistes retenues pour cette série lors d'une séance précédente
                self.apply((saved.audio, saved.subtitle), to: tracks)
            }
            self.refreshTracks()
        }
        player.chapters { [weak self] chapters, duration in
            guard let self, !self.closing, self.index < self.queue.count, self.queue[self.index].path == path else { return }
            self.model.chapters = chapters
            if duration > 0 { self.model.duration = duration }
            self.loaded = true
            self.refresh()
        }
    }

    private func apply(_ wanted: (audio: TrackTraits?, subtitle: TrackTraits?), to tracks: [Track]) {
        func pool(_ type: String) -> [TrackTraits] { tracks.filter { $0.type == type }.map(\.traits) }
        if case let .track(id) = TrackChoice.matching(wanted.audio, in: pool("audio"), subtitles: false) {
            player.set("aid", String(id))
        }
        switch TrackChoice.matching(wanted.subtitle, in: pool("sub"), subtitles: true) {
        case .track(let id): player.set("sid", String(id))
        case .off: player.set("sid", "no")
        case .automatic: break
        }
    }

    private func timeChanged(_ t: Double) {
        guard loaded else { return }
        model.position = t
        thumbnails?.follow(t)
        advance()
    }

    /// Deux fois par seconde : un épisode qui arrive, une analyse qui finit, sont vus en cours de lecture.
    private func refresh() {
        if isLive { liveTick(); return }
        guard loaded, !closing, !changing else { return }
        let file = currentFile
        let episodic = file?.episode != nil
        let m = episodic
            ? PlaybackMarkers(chapters: model.chapters, detected: file.flatMap(IntroAnalyzer.shared.markers(for:)), duration: model.duration)
            : PlaybackMarkers()
        if m != markers { markers = m }
        // toutes les 2 s : relire les numéros d'une longue série coûte un peu
        if Date().timeIntervalSince(lastLookup) >= 1.9 {
            lastLookup = Date()
            upcoming = findUpcoming(after: file)
        }
        var ready = false
        if case .item = upcoming { ready = true }
        if model.hasNext != ready { model.hasNext = ready }
        if endCard.ended { advance() } else { publish() }
    }

    private func findUpcoming(after file: MediaFile?) -> Upcoming {
        let base = findUpcomingInLibrary(after: file)
        // d'une source à l'autre : l'épisode suivant peut être en streaming (ou en fichier après un épisode en streaming)
        guard let t = currentTitle, t.kind == .tv, let cur = t.episode,
              let (k, src) = CrossSource.next(after: cur, known: knownEpisodes(t.tmdbId), sources: crossSources(t.tmdbId))
        else { return base }
        let cross: Upcoming = src.map { s in let (i, f) = crossItem(t.tmdbId, k, s); return .item(i, f) } ?? .missing(tmdbId: t.tmdbId, k)
        if file == nil { return cross }   // on lit du streaming
        switch base {
        case .missing(_, let mk) where src != nil && k <= mk: return cross
        case let .item(_, f?) where src != nil:
            if let s = f.season, let e = f.episode, k < EpisodeKey(s, e) { return cross }
            return base
        case .none where src != nil: return cross
        default: return base
        }
    }

    private func findUpcomingInLibrary(after file: MediaFile?) -> Upcoming {
        guard let file, let season = file.season, file.episode != nil else {
            // fichiers sans numéro, ou ouverts directement : la file telle quelle
            guard index + 1 < queue.count else { return .none }
            let item = queue[index + 1]
            return .item(item, LibraryStore.shared.files.first { $0.path == item.path })
        }
        let store = LibraryStore.shared
        let same = store.files.filter { f in
            if let key = file.mediaKey { return f.mediaKey == key }
            return f.mediaKey == nil && f.isEpisode && f.guessTitle.lowercased() == file.guessTitle.lowercased()
        }
        let id = Self.seriesId(file)
        let series = id.map(SeriesModel.of)
        var known: [Int: [Int: EpisodeInfo]] = [:]
        if let series {
            for s in [season] + series.tmdbSeasons.filter({ $0 > season }).prefix(1) { known[s] = series.episodes[s] }
        }
        switch NextEpisode.after(file, files: same, seasons: series?.tmdbSeasons ?? [], episodes: known, today: SeriesModel.today()) {
        case .inLibrary(let f):
            return .item(PlayItem(file: f, title: queue[index].title, resume: true), f)
        case .missing(let key):
            return id.map { .missing(tmdbId: $0, key) } ?? .none
        case .none:
            return .none
        }
    }

    private func advance() {
        guard loaded, !changing, !closing else { return }
        let go = endCard.update(position: model.position, duration: model.duration, credits: creditsSpan,
                                certain: EndCard.endsWithCredits(markers.credits, duration: model.duration),
                                next: nextState, autoplay: AppSettings.shared.autoplayNext)
        publish()
        if go { moveToNext(finished: true) }
    }

    private func publish() {
        let offer = markers.skip(at: model.position)
        if model.skip != offer { model.skip = offer }
        let card = endCard.visible ? cardContent() : nil
        if model.next != card { model.next = card }
    }

    private func cardContent() -> NextCard? {
        let store = LibraryStore.shared
        let backdrop = currentFile?.mediaKey.flatMap { store.media[$0]?.backdropPath }
        func label(_ key: EpisodeKey) -> String { "Saison \(key.season), épisode \(key.episode)" }
        var card: NextCard
        switch upcoming {
        case .none:
            return nil
        case let .item(item, file):
            let streamTitle = item.progressKey.flatMap(Watch.title(fromStreamKey:))
            let key = file.flatMap { f -> EpisodeKey? in
                guard let s = f.season, let e = f.episode else { return nil }
                return EpisodeKey(s, e)
            } ?? streamTitle?.episode
            let sid = file.flatMap(Self.seriesId) ?? (streamTitle?.kind == .tv ? streamTitle?.tmdbId : nil)
            let info = sid.flatMap { id in key.flatMap { SeriesModel.of(id).info($0.season, $0.episode) } }
            let name = [file?.episodeTitle, info?.name].compactMap { $0 }.first { !$0.isEmpty }
            card = NextCard(kind: .ready, label: key.map(label) ?? "", title: name ?? key.map { "Épisode \($0.episode)" } ?? item.title,
                            still: file?.stillPath ?? info?.stillPath, backdrop: backdrop, ended: endCard.ended)
        case let .missing(id, key):
            let info = SeriesModel.of(id).info(key.season, key.episode)
            card = NextCard(kind: .missing(tmdbId: id, key), label: label(key),
                            title: EpisodeText.title(info, file: nil, episode: key.episode),
                            still: info?.stillPath, backdrop: backdrop, ended: endCard.ended)
        }
        card.secondsLeft = endCard.secondsLeft
        card.fraction = endCard.fraction
        card.sceneAfter = endCard.sceneAfter
        card.compact = endCard.compact
        return card
    }

    private func moveToNext(finished: Bool) {
        guard !changing, !closing, case let .item(item, _) = upcoming else { return }
        saveProgress(finished: finished)
        changing = true
        finishedCurrent = true
        model.next = nil
        // les pistes choisies, lues avant que le fichier parte
        player.tracks { [weak self] tracks in
            guard let self, !self.closing else { return }
            func selected(_ type: String) -> TrackTraits? { tracks.first { $0.type == type && $0.selected }?.traits }
            if tracks.contains(where: { $0.type == "audio" }) { self.carriedTracks = (selected("audio"), selected("sub")) }
            let following = self.index + 1 < self.queue.count ? self.queue[self.index + 1] : nil
            if following?.path != item.path {
                // la file du lancement est périmée : l'épisode calculé prend sa place
                self.queue = Array(self.queue.prefix(self.index + 1)) + [item]
            } else {
                self.queue[self.index + 1] = item
            }
            self.index += 1
            self.loadCurrent()
        }
    }

    // MARK: - Vignettes

    private func startThumbnails(_ path: String) {
        thumbnails?.stop()
        decoded = nil
        let engine = ThumbnailEngine(path: path, cacheDirectory: LibraryStore.shared.cacheDir.appendingPathComponent("vignettes", isDirectory: true))
        engine.onThumbnail = { [weak self] slot, _ in
            guard let self, let t = self.hoverTime, abs(ThumbnailEngine.slot(t) - slot) <= 3 else { return }
            self.model.thumbnailsReady &+= 1
        }
        thumbnails = engine
    }

    func refreshTracks() {
        player.tracks { [weak self] t in
            self?.model.audioTracks = t.filter { $0.type == "audio" }
            self?.model.subTracks = t.filter { $0.type == "sub" }
        }
    }

    private func saveProgress(finished: Bool = false) {
        guard !finishedCurrent, index < queue.count, model.position > 0 || finished else { return }
        if queue[index].live != nil { return }   // le direct n'a pas de progression
        if let key = queue[index].progressKey {
            if let t = Watch.title(fromStreamKey: key) {
                // un titre TMDb : streaming et fichiers de la bibliothèque à jour ensemble
                Watch.save(t, position: model.position, duration: model.duration, finished: finished || endCard.ended)
            } else {
                IPTVStore.shared.saveProgress(key, position: finished ? model.duration : model.position, duration: model.duration)
            }
            return
        }
        let path = queue[index].path
        LibraryStore.shared.saveProgress(path: path, position: model.position, duration: model.duration,
                                         finished: finished || endCard.ended, creditsStart: creditsSpan?.start)
        if let f = LibraryStore.shared.files.first(where: { $0.path == path }), let t = Watch.key(of: f) {
            Watch.save(t, position: f.watched ? model.duration : model.position, duration: model.duration, finished: f.watched,
                       playedPath: path)
        }
    }

    private func endOfFile() {
        if isLive { liveEnded = true; liveAtEnd = true; return }   // un direct ne finit pas : la surveillance s'en occupe
        guard !finishedCurrent, loaded, !changing else { return }
        upcoming = findUpcoming(after: currentFile)
        saveProgress(finished: true)
        switch endCard.reachedEnd(next: nextState, autoplay: AppSettings.shared.autoplayNext) {
        case .playNext:
            moveToNext(finished: true)
        case .close:
            finishedCurrent = true
            close()
        case .stay:
            activity()
            publish()
        }
    }

    /// Ferme la lecture : progression sauvegardée, mpv arrêté (sa fenêtre se ferme), retour à la bibliothèque.
    func close() {
        guard !closing else { return }
        closing = true
        saveProgress()
        finishedCurrent = true
        idleTimer?.invalidate()
        saveTimer?.invalidate()
        thumbnails?.stop()
        IntroAnalyzer.shared.playbackEnded()
        NowPlaying.shared.detach(self)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NSCursor.setHiddenUntilMouseMoves(false)
        AppSettings.shared.volume = model.volume
        overlay.removeFromSuperview()
        if ownsWindow {
            window?.delegate = nil
            window?.close()
        }
        videoView.videoLayer.teardown()
        if PlayerController.current === self { PlayerController.current = nil }
        // l'arrêt de mpv ferme sa fenêtre en passant par le fil principal : jamais d'attente bloquante ici
        player.destroy { [self] in
            window = nil
            showLibrary()
        }
    }

    // MARK: - Contrôles affichés / masqués

    func activity() {
        lastActivity = Date()
        if !model.controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { model.controlsVisible = true }
            setTitlebar(visible: true)
        }
    }

    private func checkIdle() {
        guard model.controlsVisible, !model.paused, !model.episodesOpen, hoverTime == nil, model.forcedHover == nil, Date().timeIntervalSince(lastActivity) > 2.5 else { return }
        withAnimation(.easeIn(duration: 0.4)) { model.controlsVisible = false }
        setTitlebar(visible: false)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func setTitlebar(visible: Bool) {
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(b)?.superview?.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - NSWindowDelegate (fenêtre OpenGL de secours uniquement)

    func windowDidEnterFullScreen(_ notification: Notification) { model.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { model.isFullScreen = false }
    func windowWillClose(_ notification: Notification) { close() }
}

// MARK: - Actions appelées par l'interface et le clavier

extension PlayerController: PlayerActions {
    func togglePause() { player.togglePause(); activity() }
    func seek(by s: Double) {
        player.seek(relative: s); activity()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.publishNowPlaying() }
    }

    /// Mini-lecteur : petite fenêtre toujours au premier plan dans un coin de l'écran, sur tous les bureaux ;
    /// la même touche la remet comme avant. (mpv dessine avec Metal/Vulkan : pas d'« image dans l'image » du système.)
    func toggleMini() {
        guard let w = window else { return }
        if model.isFullScreen { w.toggleFullScreen(nil) }
        if let frame = miniRestore {
            miniRestore = nil
            model.mini = false
            w.level = .normal
            w.collectionBehavior.remove(.canJoinAllSpaces)
            w.setFrame(frame, display: true, animate: true)
        } else {
            miniRestore = w.frame
            model.mini = true
            model.episodesOpen = false
            let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: 480, height: 270)
            w.level = .floating
            w.collectionBehavior.insert(.canJoinAllSpaces)
            w.setFrame(NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height),
                       display: true, animate: true)
        }
        activity()
    }
    func seek(to s: Double) {
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.publishNowPlaying() } }
        player.seek(absolute: s)
        model.position = s
        advance()
    }
    func setVolume(_ v: Double) {
        model.volume = v
        player.setVolume(v)
        model.volumeShown = v
        volumeTimer?.invalidate()
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.2)) { self?.model.volumeShown = nil } }
        }
    }
    func toggleMute() { player.toggleMute() }
    func toggleFullScreen() {
        if ownsWindow { window?.toggleFullScreen(nil) } else { player.command(["cycle", "fullscreen"]) }
    }
    func playNext() { moveToNext(finished: endCard.visible) }
    func playPrevious() {
        if let (item, _) = previousTarget { jump(to: item) } else if let f = previousFile { jump(to: f) }
        activity()
    }
    func playEpisode(_ file: MediaFile) {
        model.episodesOpen = false
        jump(to: file)
    }

    /// Panneau Épisodes : un épisode qu'on n'a pas en fichier, en streaming.
    func playStreamEpisode(_ key: EpisodeKey) {
        guard let id = model.seriesId, case let .stream(url)? = crossSources(id)[key] else { return }
        model.episodesOpen = false
        jump(to: crossItem(id, key, .stream(url)).0)
    }
    func toggleEpisodes() {
        guard model.seriesId != nil else { return }
        model.episodesOpen.toggle()
        activity()
    }
    func playNextNow() { moveToNext(finished: true) }
    func dismissNext() {
        if endCard.ended { close(); return }
        endCard.dismiss()
        publish()
    }
    func skipMarker() {
        guard let offer = markers.skip(at: model.position) else { return }
        player.seek(absolute: offer.target, exact: true)
        model.position = offer.target
        publish()
    }
    /// Entrée : le bouton affiché.
    func primaryOverlayAction() -> Bool {
        if model.skip != nil { skipMarker(); return true }
        if case .ready? = model.next?.kind { playNextNow(); return true }
        return false
    }
    func hoverTimeline(_ t: Double?) {
        if (t == nil) != (hoverTime == nil) { lastActivity = Date() }
        if model.scrubbing != (t != nil) { model.scrubbing = t != nil }
        hoverTime = t
        guard t != nil, !hoverPending else { return }
        hoverPending = true
        // au plus une demande toutes les 40 ms, toujours la dernière position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.hoverPending = false
            if let last = self.hoverTime { self.thumbnails?.request(last) }
        }
    }
    func thumbnail(at t: Double) -> NSImage? {
        guard let engine = thumbnails else { return nil }
        let wanted = ThumbnailEngine.slot(t)
        // en attendant la bonne, une voisine (30 s au plus)
        for d in [0, -1, 1, -2, 2, -3, 3] {
            let slot = wanted + d
            if let decoded, decoded.slot == slot { return decoded.image }
            if let data = engine.image(slot), let image = NSImage(data: data) {
                decoded = (slot, image)
                return image
            }
        }
        return nil
    }
    func select(_ track: Track?, type: String) {
        player.select(track, type: type)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refreshTracks(); self.rememberTracks() }
    }

    /// Le choix de pistes est retenu pour la série : il revient au prochain épisode, même un autre jour.
    private func rememberTracks() {
        guard let f = currentFile, Self.seriesId(f) != nil, let key = f.mediaKey else { return }
        player.tracks { tracks in
            guard tracks.contains(where: { $0.type == "audio" }) else { return }
            func selected(_ type: String) -> TrackTraits? { tracks.first { $0.type == type && $0.selected }?.traits }
            SeriesTracks.set(key, RememberedTracks(audio: selected("audio"), subtitle: selected("sub")))
        }
    }
    func toggleInfo() {
        if model.info != nil { model.info = nil; return }
        player.techInfo { [weak self] in self?.model.info = $0 }
    }
    func closePlayer() {
        if model.isFullScreen { toggleFullScreen() } else { close() }
    }
    func cycle(_ what: String) {
        player.command(["cycle", what])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refreshTracks(); self.rememberTracks() }
    }
}

final class PlayerContainerView: NSView {
    weak var controller: PlayerController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if !handle(e) { super.keyDown(with: e) }
    }

    /// Raccourcis clavier du lecteur ; false si la touche ne nous concerne pas.
    func handle(_ e: NSEvent) -> Bool {
        guard let c = controller else { return false }
        c.activity()
        switch e.keyCode {
        case 49: c.togglePause()                                  // espace
        case 123: c.seek(by: e.modifierFlags.contains(.shift) ? -60 : -5)   // ←
        case 124: c.seek(by: e.modifierFlags.contains(.shift) ? 60 : 5)     // →
        case 125 where c.isLive: c.zap(1)                         // direct : ↓ chaîne suivante
        case 126 where c.isLive: c.zap(-1)                        // ↑ chaîne précédente
        case 51 where c.isLive: c.zapBack()                       // ⌫ : la chaîne d'avant
        case 125: c.setVolume(max(0, c.model.volume - 5))         // ↓
        case 126: c.setVolume(min(150, c.model.volume + 5))       // ↑
        case 53:                                                  // échap : le panneau d'abord, puis le lecteur
            // d'abord ce qui est ouvert par-dessus : panneau Épisodes, carte « Épisode suivant »
            if c.model.episodesOpen { c.toggleEpisodes() } else if c.model.next != nil { c.dismissNext() } else { c.closePlayer() }
        case 36, 76: return c.primaryOverlayAction()              // entrée : Passer l'intro, Lire maintenant
        default:
            // les raccourcis avec ⌘ (⌘W, ⌘Q…) restent aux menus
            if e.modifierFlags.contains(.command) { return false }
            if c.isLive, let ch = e.charactersIgnoringModifiers?.first {
                if ch.isNumber { c.typeDigit(ch); return true }
                if ch == "*" { c.toggleFavoriteChannel(); return true }
            }
            switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "f": c.toggleFullScreen()
            case "m": c.toggleMute()
            case "n": if e.modifierFlags.contains(.shift) { c.playPrevious() } else { c.playNext() }
            case "e": c.toggleEpisodes()
            case "p" where e.modifierFlags.contains(.shift): c.toggleMini()
            case "a": c.cycle("audio")
            case "s": c.cycle("sub")
            case "i": c.toggleInfo()
            case "k", "p": c.togglePause()
            default: return false
            }
        }
        return true
    }
}

// MARK: - Copie d'essai

extension PlayerController {
    /// Commandes du harnais : mêmes fonctions que les boutons et les touches.
    func trial(_ raw: String) {
        guard EssaiHarness.enabled else { return }
        let p = raw.split(separator: "=", maxSplits: 1).map(String.init)
        let value = p.count > 1 ? p[1] : ""
        switch p.first ?? "" {
        case "seek": if let t = Double(value) { player.seek(absolute: t, exact: true) }
        case "seek-fin": if let t = Double(value) { player.seek(absolute: model.duration - t, exact: true) }
        case "pause": player.set("pause", value == "non" ? "no" : "yes")
        case "passer": skipMarker()
        case "entree": _ = primaryOverlayAction()
        case "suivant": playNext()
        case "precedent": playPrevious()
        case "episodes": toggleEpisodes()
        case "mini": toggleMini()
        case "zap": zap(Int(value) ?? 1)
        case "reessayer": retryLive()
        case "episode":   // episode=<nom du fichier> : comme un clic dans le panneau
            if let f = LibraryStore.shared.files.first(where: { $0.fileName == p.last }) { playEpisode(f) }
        case "maintenant": playNextNow()
        case "generique": dismissNext()
        case "aid", "sid":   // comme un choix dans le panneau Audio et sous-titres
            player.set(p[0], value)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshTracks(); self.rememberTracks() }
        case "survol":
            model.forcedHover = Double(value)
            hoverTimeline(Double(value))
        case "controles":
            model.controlsVisible = value != "non"
            lastActivity = value != "non" ? Date() : .distantPast
        case "fermer": close()
        case "versions":   // les versions proposées, et celle qu'on lit
            let all = model.versions.map { ($0.id == model.currentVersion ? "*" : "") + $0.label }
            print("ESSAI versions [\(all.joined(separator: " | "))] sous-titres=\(model.subTracks.count)"); fflush(stdout)
        case "version":   // version=<n> : comme un clic dans la colonne Version
            if let n = Int(value), n < model.versions.count { selectVersion(model.versions[n].id) }
        case "etat":
            player.tracks { [weak self] tracks in
                guard let self else { return }
                let chosen = tracks.filter(\.selected).map { "\($0.type)=\($0.id):\($0.traits.language ?? "-"):\($0.traits.title ?? "-")" }
                self.player.get("current-vo") { vo in
                    self.player.get("frame-drop-count") { drops in
                        func span(_ m: Marker?) -> String { m.map { String(format: "%.1f-%.1f/%@", $0.span.start, $0.span.end, $0.source.rawValue) } ?? "-" }
                        print("ESSAI \((self.queue[self.index].path as NSString).lastPathComponent)",
                              String(format: "pos=%.1f/%.1f", self.model.position, self.model.duration),
                              "pause=\(self.model.paused) vo=\(vo ?? "-") perdues=\(drops ?? "-")",
                              "recap=\(span(self.markers.recap)) intro=\(span(self.markers.intro)) generique=\(span(self.markers.credits))",
                              "skip=\(self.model.skip.map { "\($0.kind)" } ?? "-")",
                              "carte=\(self.model.next.map { "\($0.kind) \($0.title) reste=\($0.secondsLeft.map(String.init) ?? "-") fin=\($0.ended)" } ?? "-")",
                              "pistes=\(chosen.joined(separator: ","))",
                              "precedent=\(self.model.hasPrevious) episodes=\(self.model.episodesOpen)",
                              "direct=\(self.model.live.map { "\($0.name) reconnexion=\($0.reconnecting) panne=\($0.failed)" } ?? "-")",
                              "mini=\(self.model.mini) fenetre=\(self.window.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) niveau=\($0.level.rawValue)" } ?? "-")")
                        fflush(stdout)
                    }
                }
            }
        default: break
        }
    }

    /// La vidéo (capture de mpv) avec les contrôles par-dessus : cacheDisplay ne voit pas la couche Metal.
    func trialSnapshot(to path: String) {
        guard EssaiHarness.enabled, overlay.window != nil else { print("ESSAI pas de fenêtre"); fflush(stdout); return }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("lecteur-capture-\(UUID().uuidString).png")
        player.command(["screenshot-to-file", video.path, "video"])
        player.get("time-pos") { [weak self] _ in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: video) }
            let bounds = self.overlay.bounds
            guard let rep = self.overlay.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            self.overlay.cacheDisplay(in: bounds, to: rep)
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return }
            out.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let image = NSImage(contentsOf: video), image.size.width > 0 {
                let k = min(size.width / image.size.width, size.height / image.size.height)
                let w = image.size.width * k, h = image.size.height * k
                image.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }
            let controls = NSImage(size: size)
            controls.addRepresentation(rep)
            controls.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Pistes retenues par série (préférences de l'app).
enum SeriesTracks {
    private static let key = "seriesTracks"
    static func get(_ mediaKey: String) -> RememberedTracks? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: RememberedTracks].self, from: data) else { return nil }
        return all[mediaKey]
    }
    static func set(_ mediaKey: String, _ tracks: RememberedTracks) {
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: RememberedTracks].self, from: $0) } ?? [:]
        all[mediaKey] = tracks
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
