import StrapontinCore
import SwiftUI

/// Premier lancement : un assistant court qui explique chaque étape. Tout est facultatif sauf de savoir où sont tes
/// vidéos ; « Passer » ferme l'assistant à tout moment, et il se rouvre depuis le menu Aide.
struct WelcomeView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var tracker = TrackerModel.shared
    @ObservedObject private var iptv = IPTVStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    static let doneKey = "welcomeDone"

    private let steps = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i <= step ? Theme.accent : Color.white.opacity(0.15)).frame(height: 4)
                }
            }
            .padding(.bottom, 28)
            Group {
                switch step {
                case 0: page("Bienvenue dans Strapontin", icon: "film.stack",
                             "Tes films et séries, ce que tu télécharges et ta TV en streaming, au même endroit, avec les fiches, les affiches et le suivi de ce que tu regardes.\n\nQuatre étapes rapides. Tout se change ensuite dans les Réglages (⌘,).") { EmptyView() }
                case 1: page("Où sont tes vidéos ?", icon: "folder",
                             "Strapontin surveille ces dossiers : un film ou un épisode qui y arrive apparaît tout seul, avec sa fiche. Les noms de fichiers habituels sont reconnus (Film.2019.1080p…, Série S02E03…).") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.folders, id: \.self) { f in
                            Label((f as NSString).abbreviatingWithTildeInPath, systemImage: "folder.fill").font(.system(size: 13))
                        }
                        Button("Ajouter un dossier…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { store.addFolder(u.path) }
                        }
                        .padding(.top, 4)
                    }
                }
                case 2: page("Télécharger (facultatif)", icon: "arrow.down.circle",
                             "Strapontin peut aussi chercher un film ou une série et le télécharger sur ce Mac (torrents). Il lui faut un service de recherche que tu utilises déjà (Jackett, Prowlarr…) : son adresse et sa clé, dans Réglages › Recherche.\n\nTu pourras alors choisir la version (qualité, langue, taille) sur chaque fiche, et les séries de Ma liste récupéreront seules leurs nouveaux épisodes.") {
                    HStack {
                        if tracker.configured { Label("Déjà configuré", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button("Configurer maintenant…") { SettingsOpener.open(.indexer) } }
                    }
                }
                case 3: page("TV et streaming (facultatif)", icon: "tv",
                             "Si tu as un abonnement TV en streaming, ajoute sa playlist ou ton compte (serveur, identifiant, mot de passe) : les chaînes arrivent dans « En direct », avec le guide des programmes, et les films et séries deviennent une source « Streaming » sur leur fiche. Tes identifiants restent sur ce Mac.") {
                    HStack {
                        if iptv.configured { Label("Déjà configuré", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button("Ajouter ma TV…") { SettingsOpener.open(.iptv) } }
                    }
                }
                default: page("C'est prêt", icon: "checkmark.seal",
                              "Quelques repères :\n• « À suivre » en haut de l'Accueil reprend là où tu t'es arrêté, quelle que soit la source.\n• Sur une fiche : « Lire ▾ » (choisir la source), « + » pour Ma liste, « ⋯ » pour le reste.\n• ⌘F : chercher un titre, un acteur, une chaîne.\n• Dans le lecteur, la touche ? montre tous les raccourcis.") { EmptyView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step < steps - 1 { Button("Passer") { finish() }.buttonStyle(.link) }
                Spacer()
                if step > 0 { Button("Retour") { withAnimation { step -= 1 } } }
                Button(step == steps - 1 ? "Commencer" : "Continuer") {
                    if step == steps - 1 { finish() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560, height: 440)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
    }

    private func page<Extra: View>(_ title: String, icon: String, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.accentText)
            Text(title).font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            extra()
        }
    }
}
