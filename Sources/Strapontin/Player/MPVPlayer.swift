import Cmpv
import Foundation
import StrapontinCore

struct Track: Identifiable, Hashable {
    var id: Int
    var type: String
    var label: String
    var selected: Bool
    var traits: TrackTraits
}

/// Enveloppe de libmpv : le fichier est lu tel quel (pas de transcodage).
///
/// Avec le rendu gpu-next (libplacebo, indispensable pour le Dolby Vision profil 5), mpv crée et détruit sa
/// fenêtre en se synchronisant sur le fil principal. Aucun appel à mpv ne doit donc bloquer ce fil : toutes les
/// commandes, lectures de propriétés et la destruction passent par une file série, les résultats reviennent
/// sur le fil principal.
final class MPVPlayer {
    let handle: OpaquePointer
    /// Contexte de rendu OpenGL (secours vo=libmpv), créé et utilisé sur le fil principal.
    var renderContext: OpaquePointer?
    private let queue = DispatchQueue(label: "lecteur.mpv")
    private var destroyed = false // lu et écrit uniquement sur `queue`

    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onPause: ((Bool) -> Void)?
    /// Son coupé / volume, tels que mpv les a (touche M, menus, réglage) : l'icône suit l'état réel.
    var onMute: ((Bool) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onEndOfFile: (() -> Void)?
    /// (erreur, fin normale) : MPV_EVENT_END_FILE.
    var onEndFile: ((Bool, Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onLeftEndOfFile: (() -> Void)?
    var onFullscreen: ((Bool) -> Void)?
    /// La sortie vidéo vient d'être (re)configurée : la fenêtre de mpv existe.
    var onVideoReconfig: (() -> Void)?
    /// Message envoyé par une liaison de touche (`script-message …`), par ex. la fermeture de la fenêtre.
    var onClientMessage: (([String]) -> Void)?
    /// mpv s'est arrêté de lui-même.
    var onShutdown: (() -> Void)?

    /// `vo` : sortie vidéo (liste possible, ex. « gpu-next,libmpv »), `options` : options supplémentaires.
    init(settings: AppSettings, vo: String = "libmpv", options: [(String, String)] = []) {
        handle = mpv_create()
        func opt(_ name: String, _ value: String) { mpv_set_option_string(handle, name, value) }
        opt("vo", vo)
        opt("hwdec", settings.hwdec)           // auto-safe -> VideoToolbox, décodage exact
        opt("keep-open", "yes")
        opt("idle", "yes")
        opt("input-default-bindings", "no")
        opt("input-media-keys", "no")   // touches multimédia et Centre de contrôle : gérés par NowPlaying
        opt("osc", "no")
        opt("sub-auto", "fuzzy")
        opt("audio-file-auto", "fuzzy")
        opt("alang", settings.audioLangs)
        opt("slang", settings.subLangs)
        opt("volume", String(Int(settings.volume)))
        opt("volume-max", "150")
        opt("sub-font-size", "44")
        opt("sub-border-size", "2.5")
        opt("sub-shadow-offset", "1")
        opt("screenshot-directory", NSHomeDirectory() + "/Pictures")
        if settings.highQuality {
            opt("profile", "high-quality")
            // mise à l'échelle haut de gamme, rien qui retouche l'image (pas de deband ni de netteté)
            opt("scale", "ewa_lanczossharp")
            opt("cscale", "ewa_lanczossharp")
            opt("dscale", "mitchell")
            opt("deband", "no")
        }
        if settings.passthrough { opt("audio-spdif", "ac3,eac3,dts,dts-hd,truehd") }
        for (k, v) in options { opt(k, v) }
        // journal de mpv (vo, hwdec, erreurs), réécrit à chaque lecture
        let logs = NSHomeDirectory() + "/Library/Logs/Strapontin"
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        opt("log-file", logs + "/mpv.log")
        mpv_initialize(handle)

        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 5, "fullscreen", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 6, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 7, "volume", MPV_FORMAT_DOUBLE)

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let p = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            p.queue.async { p.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Arrête mpv (sa fenêtre éventuelle se ferme), puis appelle `done` sur le fil principal.
    func destroy(_ done: (() -> Void)? = nil) {
        queue.async {
            if !self.destroyed {
                self.destroyed = true
                mpv_set_wakeup_callback(self.handle, nil, nil)
                mpv_terminate_destroy(self.handle)
            }
            DispatchQueue.main.async { done?() }
        }
    }

    private func drainEvents() {
        while !destroyed {
            guard let ev = mpv_wait_event(handle, 0) else { return }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            if id == MPV_EVENT_SHUTDOWN {
                DispatchQueue.main.async { self.onShutdown?() }
                return
            }
            if id == MPV_EVENT_FILE_LOADED {
                DispatchQueue.main.async { self.onFileLoaded?() }
            } else if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                // fin d'un fichier ou d'un flux : erreur (réseau, HTTP…) ou fin normale
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                let error = end.reason == MPV_END_FILE_REASON_ERROR, eof = end.reason == MPV_END_FILE_REASON_EOF
                DispatchQueue.main.async { self.onEndFile?(error, eof) }
            } else if id == MPV_EVENT_VIDEO_RECONFIG {
                DispatchQueue.main.async { self.onVideoReconfig?() }
            } else if id == MPV_EVENT_CLIENT_MESSAGE, let data = ev.pointee.data {
                let msg = data.assumingMemoryBound(to: mpv_event_client_message.self).pointee
                let args = (0..<Int(msg.num_args)).compactMap { msg.args[$0].map { String(cString: $0) } }
                DispatchQueue.main.async { self.onClientMessage?(args) }
            } else if id == MPV_EVENT_PROPERTY_CHANGE, let data = ev.pointee.data {
                let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let ptr = prop.data else { continue }
                let name = String(cString: prop.name)
                if prop.format == MPV_FORMAT_DOUBLE {
                    let v = ptr.assumingMemoryBound(to: Double.self).pointee
                    DispatchQueue.main.async {
                        if name == "time-pos" { self.onTime?(v) } else if name == "duration" { self.onDuration?(v) }
                        else if name == "volume" { self.onVolume?(v) }
                    }
                } else if prop.format == MPV_FORMAT_FLAG {
                    let v = ptr.assumingMemoryBound(to: Int32.self).pointee != 0
                    DispatchQueue.main.async {
                        switch name {
                        case "pause": self.onPause?(v)
                        case "eof-reached": if v { self.onEndOfFile?() } else { self.onLeftEndOfFile?() }
                        case "fullscreen": self.onFullscreen?(v)
                        case "mute": self.onMute?(v)
                        default: break
                        }
                    }
                }
            }
        }
    }

    // MARK: - Accès à mpv (toujours sur `queue`)

    // après destroy(), le handle est libéré : un clic tardif sur les contrôles faisait planter l'app
    private func commandNow(_ args: [String]) {
        guard !destroyed else { return }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                _ = mpv_command(handle, p)
            }
        }
    }

    private func getNow(_ name: String) -> String? {
        guard !destroyed, let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    /// Exécute `work` sur la file de mpv et rend son résultat sur le fil principal.
    private func read<T>(_ work: @escaping () -> T, _ done: @escaping (T) -> Void) {
        queue.async {
            let v = work()
            DispatchQueue.main.async { done(v) }
        }
    }

    // MARK: - Commandes

    func command(_ args: [String]) { queue.async { self.commandNow(args) } }

    func set(_ name: String, _ value: String) {
        queue.async {
            guard !self.destroyed else { return }
            mpv_set_property_string(self.handle, name, value)
        }
    }

    func get(_ name: String, _ done: @escaping (String?) -> Void) { read({ self.getNow(name) }, done) }

    /// Fenêtre créée par mpv (rendu gpu-next) : pointeur vers son NSWindow, ou nil.
    func windowPointer(_ done: @escaping (UnsafeMutableRawPointer?) -> Void) {
        read({
            guard !self.destroyed else { return nil }
            var wid: Int64 = 0
            guard mpv_get_property(self.handle, "window-id", MPV_FORMAT_INT64, &wid) >= 0, wid != 0 else { return nil }
            return UnsafeMutableRawPointer(bitPattern: Int(wid))
        }, done)
    }

    func load(_ path: String, start: Double) {
        set("start", start > 5 ? String(format: "%.1f", start) : "none")
        command(["loadfile", path, "replace"])
        set("pause", "no")
    }

    func togglePause() { command(["cycle", "pause"]) }
    func seek(relative s: Double) { command(["seek", String(s), "relative"]) }
    func seek(absolute s: Double, exact: Bool = false) { command(["seek", String(s), exact ? "absolute+exact" : "absolute"]) }

    /// Chapitres du fichier ouvert et sa durée.
    func chapters(_ done: @escaping (_ chapters: [Chapter], _ duration: Double) -> Void) {
        read({
            let get = self.getNow
            let n = Int(get("chapter-list/count") ?? "0") ?? 0
            var out: [Chapter] = []
            for i in 0..<max(0, n) {
                guard let t = get("chapter-list/\(i)/time").flatMap(Double.init) else { continue }
                out.append(Chapter(title: get("chapter-list/\(i)/title") ?? "", start: t))
            }
            return (out, get("duration").flatMap(Double.init) ?? 0)
        }, { done($0.0, $0.1) })
    }
    func setVolume(_ v: Double) { set("volume", String(Int(v))) }
    func toggleMute() { command(["cycle", "mute"]) }
    func toggleStats() { command(["script-binding", "stats/display-stats-toggle"]) }

    func tracks(_ done: @escaping ([Track]) -> Void) {
        read({
            let get = self.getNow
            let n = Int(get("track-list/count") ?? "0") ?? 0
            var out: [Track] = []
            for i in 0..<n {
                let p = "track-list/\(i)/"
                guard let type = get(p + "type"), let id = Int(get(p + "id") ?? "") else { continue }
                var parts: [String] = []
                if let lang = get(p + "lang") { parts.append(Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang) }
                if let title = get(p + "title") { parts.append(title) }
                if let codec = get(p + "codec") { parts.append(codec.uppercased()) }
                if type == "audio", let ch = get(p + "demux-channel-count") { parts.append("\(ch) canaux") }
                if get(p + "forced") == "yes" { parts.append("forcé") }
                if get(p + "external") == "yes" { parts.append("externe") }
                let traits = TrackTraits(id: id, language: get(p + "lang"), title: get(p + "title"),
                                         forced: get(p + "forced") == "yes", external: get(p + "external") == "yes",
                                         channels: get(p + "demux-channel-count").flatMap { Int($0) })
                out.append(Track(id: id, type: type, label: parts.isEmpty ? "Piste \(id)" : parts.joined(separator: " · "),
                                 selected: get(p + "selected") == "yes", traits: traits))
            }
            return out
        }, done)
    }

    func select(_ track: Track?, type: String) {
        let prop = type == "audio" ? "aid" : "sid"
        set(prop, track.map { String($0.id) } ?? "no")
    }

    /// Résumé technique pour vérifier que la lecture est directe.
    func techInfo(_ done: @escaping (String) -> Void) {
        read({
            let get = self.getNow
            let codec = get("video-codec") ?? "?"
            let w = get("video-params/w") ?? "?", h = get("video-params/h") ?? "?"
            let pix = get("video-params/pixelformat") ?? "?"
            let hw = get("hwdec-current") ?? "no"
            let gamma = get("video-params/gamma") ?? "?"
            let vo = get("current-vo") ?? "?"
            return "\(codec) · \(w)×\(h) · \(pix) · \(gamma) · décodage \(hw == "no" ? "logiciel" : hw) · rendu \(vo)"
        }, done)
    }
}
