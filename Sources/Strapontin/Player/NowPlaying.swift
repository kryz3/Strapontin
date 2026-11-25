import AppKit
import MediaPlayer

/// Touches multimédia du clavier, Centre de contrôle et écran verrouillé : ce qui joue, et les commandes
/// lecture/pause, ±10 s, épisode suivant/précédent, déplacement dans la barre.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private weak var controller: PlayerController?
    private var targets: [(MPRemoteCommand, Any)] = []

    /// Prend les commandes pour ce lecteur (une seule lecture à la fois).
    func attach(_ c: PlayerController) {
        controller = c
        guard targets.isEmpty, !EssaiHarness.enabled else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ action: @escaping (PlayerController, MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { [weak self] e in
                MainActor.assumeIsolated {
                    guard let c = self?.controller else { return .noActionableNowPlayingItem }
                    action(c, e)
                    return .success
                }
            }
            targets.append((cmd, t))
        }
        on(center.togglePlayPauseCommand) { c, _ in c.togglePause() }
        on(center.playCommand) { c, _ in if c.model.paused { c.togglePause() } }
        on(center.pauseCommand) { c, _ in if !c.model.paused { c.togglePause() } }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipForwardCommand) { c, _ in c.seek(by: 10) }
        on(center.skipBackwardCommand) { c, _ in c.seek(by: -10) }
        on(center.nextTrackCommand) { c, _ in c.playNext() }
        on(center.previousTrackCommand) { c, _ in c.playPrevious() }
        on(center.changePlaybackPositionCommand) { c, e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { c.seek(to: e.positionTime) }
        }
    }

    func detach(_ c: PlayerController) {
        guard controller === c else { return }
        controller = nil
        for (cmd, t) in targets { cmd.removeTarget(t); cmd.isEnabled = false }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Titre, série, durée, position et état (le système fait avancer la position tout seul entre deux mises à jour).
    func update(title: String, subtitle: String?, duration: Double, position: Double, paused: Bool) {
        guard !EssaiHarness.enabled else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: subtitle ?? title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if subtitle != nil { info[MPMediaItemPropertyArtist] = title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }
}
