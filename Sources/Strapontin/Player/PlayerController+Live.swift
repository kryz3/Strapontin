import AppKit
import QuartzCore
import StrapontinCore

/// Lecture des chaînes en direct : options de flux, surveillance et réparation automatique, zapping.
extension PlayerController {
    var isLive: Bool { index < queue.count && queue[index].live != nil }

    /// Ouvre une chaîne (depuis « En direct » ou la recherche) dans le lecteur.
    static func playLive(_ e: IPTVEntry) {
        let store = IPTVStore.shared
        let p = store.playlist(of: e)
        let v = store.preferredVariant(e)
        let item = PlayItem(path: v?.url ?? e.url, title: e.name, subtitle: e.group, start: 0,
                            live: LiveInfo(entry: e, alternates: store.alternates(e), variants: store.variants(of: e), variantID: v?.id,
                                           userAgent: p?.userAgent ?? "", referer: p?.referer ?? ""))
        if let c = current, c.isLive { c.switchChannel(item); return }
        play([item])
    }

    /// Options du lecteur pour ce qu'on ouvre : réglages du direct, ou retour aux réglages normaux.
    func prepareStream(_ item: PlayItem) {
        if let live = item.live {
            for (k, v) in LiveOptions.mpv(userAgent: live.userAgent, referer: live.referer) { player.set(k, v) }
            liveURL = item.path
            alternateIndex = 0
            watchdog = LiveWatchdog()
            watchdog.hasLowerBitrate = item.path.lowercased().contains(".m3u8") || lowerVariant(than: live.variantID, in: live) != nil
            watchdog.hasAlternate = !live.alternates.isEmpty
            watchdog.opened(at: CACurrentMediaTime())
            liveEnded = false
            liveFailedFlag = false
            liveAtEnd = false
            IPTVStore.shared.played(live.entry)
            updateLiveDisplay()
        } else {
            for (k, v) in [("stream-lavf-o", ""), ("cache", "auto"), ("demuxer-readahead-secs", "1"), ("hls-bitrate", "max"),
                           ("referrer", ""), ("user-agent", LiveOptions.defaultUserAgent)] { player.set(k, v) }
            model.live = nil
        }
    }

    func updateLiveDisplay() {
        guard index < queue.count, let live = queue[index].live else { model.live = nil; return }
        let e = live.entry
        let nn = IPTVStore.shared.guide.nowNext(e.tvgId)
        var d = LiveDisplay(name: e.name, logo: e.logo, number: e.number, group: e.group, now: nn.now, next: nn.next,
                            favorite: IPTVStore.shared.isFavorite(e))
        d.reconnecting = watchdog.isRecovering
        d.failed = model.live?.failed ?? false
        d.qualities = live.variants.count > 1 ? live.variants : []
        d.currentQuality = live.variantID
        d.notice = liveNotice
        if model.live != d { model.live = d }
    }

    /// Deux fois par seconde : la surveillance du flux.
    func liveTick() {
        guard !closing else { return }
        player.get("demuxer-cache-duration") { [weak self] cache in
            guard let self, self.isLive, !(self.model.live?.failed ?? false) else { return }
            let o = LiveWatchdog.Observation(time: CACurrentMediaTime(), position: self.loaded ? self.model.position : nil,
                                             userPaused: self.model.paused && !self.liveAtEnd,
                                             cacheSeconds: cache.flatMap(Double.init),
                                             ended: self.liveEnded || self.liveAtEnd, failed: self.liveFailedFlag)
            self.liveEnded = false
            self.liveFailedFlag = false
            let wasRecovering = self.watchdog.isRecovering
            // copie d'essai « avant » : mesure sans la surveillance (mpv seul)
            let off = EssaiHarness.enabled && ProcessInfo.processInfo.environment["STRAPONTIN_ESSAI_SANS_SURVEILLANCE"] != nil
            if !off, let a = self.watchdog.observe(o) { self.recover(a) }
            if wasRecovering, !self.watchdog.isRecovering, let s = self.watchdog.lastRecovery {
                self.logIncident(String(format: "réparé en %.1f s", s))
                if EssaiHarness.enabled { print(String(format: "ESSAI direct réparé en %.1f s", s)); fflush(stdout) }
            }
            self.updateLiveDisplay()
        }
    }

    private func recover(_ a: LiveWatchdog.Action) {
        if EssaiHarness.enabled { print("ESSAI direct action \(a)"); fflush(stdout) }
        logIncident("\(a)")
        switch a {
        case .seekToLive:
            player.command(["seek", "100", "absolute-percent"])
        case .reload:
            reopen(liveURL)
        case .lowerBitrate:
            // une variante plus légère de la chaîne s'il y en a, sinon le débit le plus bas du flux HLS
            if let live = queue[index].live, let lower = lowerVariant(than: queue[index].live?.variantID, in: live) {
                queue[index].live?.variantID = lower.id
                showNotice("Qualité réduite : \(lower.label)")
                reopen(lower.url)
            } else {
                player.set("hls-bitrate", "min")
                reopen(liveURL)
            }
        case .alternateSource:
            guard let alts = queue[index].live?.alternates, !alts.isEmpty else { reopen(liveURL); return }
            alternateIndex = (alternateIndex + 1) % (alts.count + 1)
            reopen(alternateIndex == 0 ? queue[index].path : alts[alternateIndex - 1])
        case .giveUp:
            model.live?.failed = true
        }
    }

    /// Rouvre le flux sans rien demander : position, son et image repartent ensemble (pas de désynchronisation).
    private func reopen(_ url: String) {
        loaded = false
        liveAtEnd = false
        liveURL = url
        player.command(["loadfile", url, "replace"])
        player.set("pause", "no")
        watchdog.opened(at: CACurrentMediaTime())
    }

    /// Variante de qualité inférieure (hors secours) à celle qu'on lit.
    func lowerVariant(than id: String?, in live: LiveInfo) -> ChannelVariant? {
        let v = live.variants.filter { !$0.backup }
        guard let cur = v.first(where: { $0.id == id }) else { return nil }
        return v.first { $0.quality < cur.quality }
    }

    /// Changer de qualité sans quitter le lecteur ; retenu pour cette chaîne.
    func selectQuality(_ variantID: String) {
        guard index < queue.count, let live = queue[index].live, let v = live.variants.first(where: { $0.id == variantID }),
              variantID != live.variantID else { return }
        IPTVStore.shared.chooseQuality(variantID, for: live.entry)
        queue[index].live?.variantID = variantID
        queue[index].path = v.url
        watchdog.reset()
        model.live?.failed = false
        player.set("hls-bitrate", "max")
        showNotice(v.label)
        reopen(v.url)
        updateLiveDisplay()
    }

    func showNotice(_ text: String) {
        liveNotice = text
        updateLiveDisplay()
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveNotice = nil; self?.updateLiveDisplay() }
        }
    }

    func retryLive() {
        watchdog.reset()
        model.live?.failed = false
        player.set("hls-bitrate", "max")
        reopen(queue[index].path)
    }

    // MARK: zapping

    private func switchChannel(_ item: PlayItem) {
        if let cur = queue[index].live?.entry, cur.id != item.live?.entry.id { previousChannel = cur }
        queue = [item]
        index = 0
        loadCurrent()
        activity()
    }

    /// Chaîne suivante (+1) ou précédente (−1) : favoris d'abord s'il y en a, sinon toutes les chaînes par numéro.
    func zap(_ delta: Int) {
        guard let cur = queue[index].live?.entry else { return }
        let store = IPTVStore.shared
        let list = store.favoriteChannels.contains { $0.id == cur.id } ? store.favoriteChannels
            : store.channels.filter { store.inCountry($0) || $0.id == cur.id }.sorted { ($0.number ?? Int.max, $0.name) < ($1.number ?? Int.max, $1.name) }
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == cur.id } ?? 0
        Self.playLive(list[(i + delta + list.count) % list.count])
    }

    func zapBack() { if let p = previousChannel { Self.playLive(p) } }

    func toggleFavoriteChannel() {
        guard let e = queue[index].live?.entry else { return }
        IPTVStore.shared.toggleFavorite(e)
        updateLiveDisplay()
    }

    /// Saisie d'un numéro : la chaîne s'ouvre 1,5 s après le dernier chiffre.
    func typeDigit(_ d: Character) {
        let typed = (model.typedNumber ?? "") + String(d)
        model.typedNumber = String(typed.suffix(4))
        numberTimer?.invalidate()
        numberTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let n = Int(self.model.typedNumber ?? "") else { return }
                self.model.typedNumber = nil
                if let e = IPTVStore.shared.channels.first(where: { $0.number == n }) { Self.playLive(e) }
            }
        }
        activity()
    }

    /// Journal local des incidents : chaîne et action, jamais l'adresse ni les identifiants.
    private func logIncident(_ what: String) {
        guard let name = queue[index].live?.entry.name else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strapontin/iptv-incidents.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) · \(name) · \(what)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
