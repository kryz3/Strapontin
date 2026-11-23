import Cmpv
import Foundation

/// Un libmpv à part, sans fenêtre, sans son et sans touche au lecteur : il sert à l'empreinte audio des épisodes
/// et aux vignettes de la barre de temps. Synchrone : à n'utiliser que depuis un fil de travail.
final class HeadlessMPV {
    private let handle: OpaquePointer

    init?(options: [(String, String)]) {
        guard let h = mpv_create() else { return nil }
        let base: [(String, String)] = [
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("terminal", "no"),
            ("input-media-keys", "no"), ("input-default-bindings", "no"), ("osc", "no"), ("idle", "yes"),
            ("audio-display", "no"), ("sub-auto", "no"), ("sid", "no"), ("audio-file-auto", "no"),
            ("macos-app-activation-policy", "accessory"), ("focus-on", "never"),
        ]
        for (k, v) in base + options { mpv_set_option_string(h, k, v) }
        guard mpv_initialize(h) >= 0 else { mpv_terminate_destroy(h); return nil }
        handle = h
    }

    deinit { mpv_terminate_destroy(handle) }

    @discardableResult
    func command(_ args: [String]) -> Bool {
        withArguments(args) { mpv_command(handle, $0) >= 0 }
    }

    func set(_ name: String, _ value: String) { mpv_set_property_string(handle, name, value) }

    func get(_ name: String) -> String? {
        guard let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    enum Event {
        case loaded, restarted, ended, failed, timeout
    }

    /// Attend l'un des événements demandés (ou l'échec du fichier).
    func wait(for wanted: Set<Event>, timeout: TimeInterval, cancelled: () -> Bool = { false }) -> Event {
        let limit = Date().addingTimeInterval(timeout)
        while Date() < limit, !cancelled() {
            guard let ev = mpv_wait_event(handle, 0.05) else { continue }
            switch ev.pointee.event_id {
            case MPV_EVENT_FILE_LOADED where wanted.contains(.loaded): return .loaded
            case MPV_EVENT_PLAYBACK_RESTART where wanted.contains(.restarted): return .restarted
            case MPV_EVENT_END_FILE:
                guard let data = ev.pointee.data else { return .failed }
                let reason = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                if reason == MPV_END_FILE_REASON_ERROR { return .failed }
                if wanted.contains(.ended) { return .ended }
            case MPV_EVENT_SHUTDOWN: return .failed
            default: break
            }
        }
        return .timeout
    }

    struct Frame {
        var width: Int
        var height: Int
        var stride: Int
        var bgr0: Data
    }

    /// L'image décodée, après les filtres (`screenshot-raw`).
    func frame() -> Frame? {
        var node = mpv_node()
        guard withArguments(["screenshot-raw", "video"], { mpv_command_ret(handle, $0, &node) >= 0 }) else { return nil }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else { return nil }
        var w = 0, h = 0, stride = 0, format = ""
        var pixels: Data?
        for i in 0..<Int(list.pointee.num) {
            guard let key = list.pointee.keys[i], let values = list.pointee.values else { continue }
            let v = values[i]
            switch String(cString: key) {
            case "w": w = Int(v.u.int64)
            case "h": h = Int(v.u.int64)
            case "stride": stride = Int(v.u.int64)
            case "format": if v.format == MPV_FORMAT_STRING, let s = v.u.string { format = String(cString: s) }
            case "data":
                if v.format == MPV_FORMAT_BYTE_ARRAY, let ba = v.u.ba {
                    pixels = Data(bytes: ba.pointee.data, count: ba.pointee.size)
                }
            default: break
            }
        }
        guard format == "bgr0", w > 0, h > 0, let pixels, pixels.count >= stride * h else { return nil }
        return Frame(width: w, height: h, stride: stride, bgr0: pixels)
    }

    private func withArguments<T>(_ args: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        return cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count, body)
        }
    }
}
