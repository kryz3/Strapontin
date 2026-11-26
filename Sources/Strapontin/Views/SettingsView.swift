import StrapontinCore
import SwiftUI

/// Onglets des réglages : un lien « Brancher un indexeur » ouvre directement le bon.
enum SettingsTab: String {
    case library, metadata, playback, downloads, indexer, iptv
    static let key = "settingsTab"
}

/// Ouvre les réglages sur un onglet donné.
struct SettingsButton<Label: View>: View {
    let tab: SettingsTab
    @ViewBuilder var label: () -> Label
    var body: some View {
        SettingsLink { label() }
            .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key) })
    }
}

/// Ouvrir les réglages sur un onglet depuis un menu (là où SettingsLink ne s'emploie pas).
@MainActor
enum SettingsOpener {
    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.library.rawValue
    var body: some View {
        TabView(selection: $tab) {
            LibrarySettings().tabItem { Label("Bibliothèque", systemImage: "folder") }.tag(SettingsTab.library.rawValue)
            MetadataSettings().tabItem { Label("Fiches", systemImage: "info.square") }.tag(SettingsTab.metadata.rawValue)
            PlaybackSettings().tabItem { Label("Lecture", systemImage: "play.rectangle") }.tag(SettingsTab.playback.rawValue)
            QbitSettings().tabItem { Label("Téléchargements", systemImage: "arrow.down.circle") }.tag(SettingsTab.downloads.rawValue)
            TrackerSettings().tabItem { Label("Recherche", systemImage: "antenna.radiowaves.left.and.right") }.tag(SettingsTab.indexer.rawValue)
            IPTVSettings().tabItem { Label("TV et streaming", systemImage: "tv.and.mediabox") }.tag(SettingsTab.iptv.rawValue)
        }
        .frame(width: 560, height: 600)
    }
}

private struct LibrarySettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LibraryStore
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(settings.folders, id: \.self, selection: $selection) { f in
                    Label(f, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                }
                .frame(height: 150)
                HStack {
                    Button("Ajouter…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { store.addFolder(u.path) }
                    }
                    Button("Retirer") { if let s = selection { store.removeFolder(s) } }.disabled(selection == nil)
                }
            } header: {
                Text("Dossiers surveillés")
            } footer: {
                Text("Les nouveaux fichiers apparaissent tout seuls. Un rescan complet tourne aussi régulièrement.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Avancé") {
                Picker("Rescan complet", selection: $settings.rescanMinutes) {
                    Text("Jamais").tag(0)
                    Text("Toutes les 5 min").tag(5)
                    Text("Toutes les 15 min").tag(15)
                    Text("Toutes les heures").tag(60)
                }
                .onChange(of: settings.rescanMinutes) { _, _ in store.foldersChanged() }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }
}

private struct MetadataSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LibraryStore
    @State private var test: String?

    var body: some View {
        Form {
            Section {
                Picker("Langue des fiches", selection: $settings.tmdbLanguage) {
                    Text("Français").tag("fr-FR")
                    Text("Français (Canada)").tag("fr-CA")
                    Text("Anglais").tag("en-US")
                }
                Button("Ré-identifier les vidéos non reconnues") { store.rescan(retryNotFound: true) }
                // les clés sont fournies avec l'app : on n'y touche que pour mettre la sienne
                DisclosureGroup("Avancé") {
                    SecureField("Clé TMDb", text: $settings.tmdbKey,
                                prompt: Text(Secrets.tmdbKey.isEmpty ? "Obligatoire (gratuite sur themoviedb.org)" : "Clé fournie avec l'app"))
                    SecureField("Clé OMDb (note IMDb, facultatif)", text: $settings.omdbKey)
                    HStack {
                        Button("Tester la clé") {
                            let c = TMDbClient(key: settings.effectiveTMDbKey, language: settings.tmdbLanguage)
                            Task {
                                do { try await c.check(); test = "✓ Clé valide" } catch { test = error.localizedDescription }
                            }
                        }
                        if let test { Text(test).foregroundStyle(.secondary) }
                    }
                }
            } footer: {
                Text("Les fiches viennent de TMDb, qui fournit aussi le lien IMDb. Une clé saisie ici remplace celle fournie avec l'app. IMDb n'a pas d'API publique : la note IMDb passe par OMDb (clé gratuite sur omdbapi.com).\n\nThis product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Enchaîner l'épisode suivant", isOn: $settings.autoplayNext)
                Toggle("Repérer les intros et génériques au son", isOn: $settings.detectIntros)
                    .onChange(of: settings.detectIntros) { _, _ in IntroAnalyzer.shared.schedule() }
            } header: {
                Text("Séries")
            } footer: {
                Text("Les chapitres du fichier passent d'abord. Sinon Strapontin compare le son des épisodes d'une même saison, en arrière-plan, sur ce Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Langues audio préférées", text: $settings.audioLangs)
                TextField("Langues de sous-titres", text: $settings.subLangs)
                DisclosureGroup("Avancé") {
                    Picker("Décodage", selection: $settings.hwdec) {
                        Text("Matériel si fiable (recommandé)").tag("auto-safe")
                        Text("Matériel (VideoToolbox)").tag("videotoolbox")
                        Text("Logiciel uniquement").tag("no")
                    }
                    Toggle("Mise à l'échelle haute qualité", isOn: $settings.highQuality)
                    Toggle("Audio en passthrough vers l'ampli (TrueHD, DTS-HD…)", isOn: $settings.passthrough)
                }
            } footer: {
                Text("Lecture directe par mpv : le fichier est décodé tel quel, sans transcodage ni recompression. Les réglages s'appliquent à la prochaine vidéo ouverte.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Langues cherchées", text: $settings.onlineSubLangs, prompt: Text("fr,en"))
                DisclosureGroup("Avancé") {
                    SecureField("Ta clé API OpenSubtitles", text: $settings.openSubtitlesKey,
                                prompt: Text(Secrets.openSubtitlesKey.isEmpty ? "à créer sur opensubtitles.com" : "facultative : une clé est fournie avec l'app"))
                }
            } header: {
                Text("Sous-titres en ligne")
            } footer: {
                Text("Dans le lecteur, panneau Audio et sous-titres › « Chercher en ligne » : les sous-titres du film ou de l'épisode, quelle que soit la source. Clé gratuite : compte sur opensubtitles.com, puis « API consumers ». Sans compte, 5 téléchargements par jour.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct QbitSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LibraryStore
    @State private var test: String?

    /// Onglet « Téléchargements » : choix du moteur ; ces champs ne servent que pour « Mon qBittorrent ».
    var body: some View {
        EngineSettings {
            QualitySection()
            Section {
                Toggle("Brancher qBittorrent", isOn: $settings.qbitEnabled)
                TextField("Adresse", text: $settings.qbitURL)
                TextField("Utilisateur", text: $settings.qbitUser)
                SecureField("Mot de passe", text: $settings.qbitPassword)
                HStack {
                    Button("Tester") {
                        let c = QbitClient(url: settings.qbitURL, username: settings.qbitUser, password: settings.qbitPassword)
                        Task {
                            do { test = "✓ qBittorrent \(try await c.version())" } catch { test = error.localizedDescription }
                        }
                    }
                    Button("Ajouter son dossier à la bibliothèque") {
                        let c = QbitClient(url: settings.qbitURL, username: settings.qbitUser, password: settings.qbitPassword)
                        Task {
                            do { store.addFolder(try await c.defaultSavePath()); test = "✓ Dossier ajouté" } catch { test = error.localizedDescription }
                        }
                    }
                    if let test { Text(test).foregroundStyle(.secondary).lineLimit(2) }
                }
            } footer: {
                Text("Dans qBittorrent : Réglages › Interface Web, coche « Interface utilisateur Web » et choisis un mot de passe.")
                    .foregroundStyle(.secondary)
            }
        }
        // le client du moteur est gardé en cache : on le recrée avec les nouveaux réglages
        .onChange(of: "\(settings.qbitEnabled)|\(settings.qbitURL)|\(settings.qbitUser)|\(settings.qbitPassword)") { _, _ in
            TorrentEngine.shared.reset()
        }
    }
}

/// Qualité des téléchargements : un réglage global simple, que chaque série suivie peut changer depuis sa fiche.
struct QualitySection: View {
    @ObservedObject private var tracker = TrackerModel.shared

    var body: some View {
        Section {
            Picker("Qualité préférée", selection: $tracker.prefs.quality) {
                ForEach(QualityChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Garder la qualité et la source des épisodes déjà téléchargés", isOn: $tracker.prefs.matchExisting)
            Picker("Taille maximale d'un épisode", selection: $tracker.prefs.maxEpisodeGB) {
                Text("Sans limite").tag(0.0)
                ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { Text("\(Int($0)) Go").tag($0) }
            }
        } header: {
            Text("Qualité")
        } footer: {
            Text("Pour les téléchargements et le suivi automatique. Une série déjà commencée continue dans la même qualité (1080p WEB, 4K BluRay…) ; chaque série suivie peut avoir sa propre qualité, depuis la cloche de sa fiche. « 4K si disponible » prend du 1080p quand il n'y a pas de 4K.")
                .foregroundStyle(.secondary)
        }
    }
}
