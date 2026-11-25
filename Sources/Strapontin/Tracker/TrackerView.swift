import StrapontinCore
import SwiftUI

/// Onglet « Indexeur » : recherche, liste de suivi et journal.
struct TrackerView: View {
    @StateObject private var model = TrackerModel.shared
    @EnvironmentObject var settings: AppSettings
    @State private var query = ""
    @State private var kind: MediaKind? = nil
    @State private var selection: TorznabItem.ID?
    @State private var pane = 0

    var body: some View {
        VStack(spacing: 0) {
            if !model.configured {
                ContentUnavailableView {
                    Label("Aucun indexeur branché", systemImage: "magnifyingglass")
                } description: {
                    Text("Renseigne l'adresse de l'API Torznab de ton indexeur (Jackett, Prowlarr…) et ta clé API dans les réglages.")
                } actions: {
                    SettingsLink { Text("Ouvrir les réglages") }
                }
            } else {
                Picker("", selection: $pane) {
                    Text("Recherche").tag(0)
                    Text("Suivis (\(model.follows.count))").tag(1)
                    Text("Journal").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360).padding(10)
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch pane {
                case 0: searchPane
                case 1: followsPane
                default: logPane
                }
            }
        }
        .navigationTitle(model.searchContext.map { "Indexeur · \($0.title)" } ?? "Indexeur")
        .background(Theme.background)
        .onAppear {
            model.start()
            if let m = model.searchContext, model.configured {
                // ouvert depuis une fiche (« Chercher autrement ») : on part de son titre original
                query = m.originalTitle ?? m.title
                kind = m.kind
                model.search(query, kind: kind)
            } else if model.configured, model.results.isEmpty, !model.searching {
                // tableau vide à l'ouverture sinon : on montre les nouveautés
                model.search("", kind: nil)
            }
        }
        .onDisappear { model.searchContext = nil }
    }

    // MARK: recherche

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Titre, ou vide pour les nouveautés", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit { model.search(query, kind: kind) }
                Picker("", selection: $kind) {
                    Text("Tout").tag(MediaKind?.none)
                    Text("Films").tag(MediaKind?.some(.movie))
                    Text("Séries").tag(MediaKind?.some(.tv))
                }
                .labelsHidden().frame(width: 110)
                Button("Chercher") { model.search(query, kind: kind) }.keyboardShortcut(.defaultAction)
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            ResultsTable(items: model.results, selection: $selection, download: { item in
                model.grabManually(item, to: model.destination(for: ReleaseInfo.parse(item.releaseName).season != nil ? .tv : .movie))
            }, sent: model.sent)
        }
    }

    // MARK: suivis

    private var followsPane: some View {
        List {
            Section {
                ForEach(model.follows) { f in
                    HStack {
                        Image(systemName: f.kind == .tv ? "tv" : "film").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(f.title).font(.headline)
                            Text(f.kind == .tv ? "Nouveaux épisodes à partir de la saison \(f.fromSeason)" : "Dès qu'une version correspond à tes préférences")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ne plus suivre") { model.unfollow(f.id) }.buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text(model.lastCheck.map { "Dernier passage : \($0.formatted(date: .omitted, time: .shortened))" } ?? "Pas encore de passage")
                    Spacer()
                    Button("Vérifier maintenant") { Task { await model.checkNew() } }.buttonStyle(.borderless)
                }
            } footer: {
                Text("Pour suivre un film ou une série, ouvre sa fiche et touche la cloche (ou le bouton ↓ sur une fiche de ta bibliothèque).").foregroundStyle(.secondary)
            }
        }
    }

    private var logPane: some View {
        List(model.log, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
    }
}

/// Tableau de résultats Torznab, réutilisé dans la fiche.
struct ResultsTable: View {
    let items: [TorznabItem]
    @Binding var selection: TorznabItem.ID?
    let download: (TorznabItem) -> Void
    /// Déjà envoyés pendant cette session : coche verte à la place du bouton (pas de doublon par double-clic).
    var sent: Set<String> = []

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Nom") { it in
                Text(it.releaseName).lineLimit(1).help(it.siteTitle ?? it.title)
            }
            TableColumn("Langue") { it in Text(ReleaseInfo.parse(it.releaseName).language?.rawValue ?? "?").foregroundStyle(.secondary) }
                .width(70)
            TableColumn("Qualité") { it in Text(ReleaseInfo.parse(it.releaseName).quality ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 90, ideal: 150)
            TableColumn("Taille") { it in Text(humanSize(it.size)).monospacedDigit() }.width(75)
            TableColumn("S") { it in Text(it.seeders.map(String.init) ?? "").monospacedDigit().foregroundStyle((it.seeders ?? 0) > 0 ? Color.green : Color.secondary) }
                .width(40)
            TableColumn("Date") { it in Text(it.published?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary) }
                .width(90)
            TableColumn("") { it in
                if sent.contains(it.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Envoyé au téléchargement")
                } else {
                    Button { download(it) } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless).help(it.isFreeleech ? "Télécharger (freeleech)" : "Télécharger")
                }
            }
            .width(30)
        }
        .contextMenu(forSelectionType: TorznabItem.ID.self) { ids in
            if let it = items.first(where: { ids.contains($0.id) }) {
                Button("Télécharger") { download(it) }
                if let u = it.detailsURL.flatMap(URL.init(string:)) { Link("Voir sur l'indexeur", destination: u) }
            }
        } primaryAction: { ids in
            if let it = items.first(where: { ids.contains($0.id) }), !sent.contains(it.id) { download(it) }
        }
    }
}

/// Bouton rond à mettre dans l'en-tête de DetailView, à côté de « Vu / Pas vu » :
/// autres versions sur l'indexeur, et suivi de la série / du film.
struct TrackerButtons: View {
    let media: Media
    @StateObject private var model = TrackerModel.shared
    @State private var showResults = false

    var body: some View {
        if model.configured {
            Menu {
                Button("Versions disponibles…") { showResults = true }
                Divider()
                if model.isFollowed(media) {
                    Button("Ne plus suivre") { model.unfollow(media.key) }
                } else if media.kind == .tv {
                    Button("Suivre les nouveaux épisodes") { model.follow(media, backfill: false) }
                    Button("Récupérer les saisons manquantes et suivre") { model.follow(media, backfill: true) }
                }
            } label: {
                Image(systemName: model.isFollowed(media) ? "bell.fill" : "arrow.down").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white).frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.15)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Indexeur")
            .sheet(isPresented: $showResults) { TrackerResultsSheet(media: media, isPresented: $showResults) }
        }
    }
}

/// Onglet de réglages « Indexeur ».
struct TrackerSettings: View {
    @StateObject private var model = TrackerModel.shared
    @State private var test: String?

    var body: some View {
        Form {
            Section {
                TextField("Adresse de l'API Torznab", text: $model.endpoint, prompt: Text("https://indexeur.exemple/api"))
                SecureField("Clé API", text: $model.apiKey)
                HStack {
                    Button("Tester") {
                        Task {
                            do {
                                let caps = try await model.makeClient().caps()
                                test = "✓ Connecté (\(caps.categories.count) catégories)"
                            } catch { test = error.localizedDescription }
                        }
                    }
                    if let test { Text(test).foregroundStyle(.secondary).lineLimit(2) }
                }
            } footer: {
                if model.fromBuild {
                    Text("Fourni par la configuration de build (.env). Modifie un champ pour utiliser tes propres réglages.")
                        .foregroundStyle(.secondary)
                }
                Text("L'adresse complète de l'API Torznab : celle de ton indexeur, ou celle que donne Jackett / Prowlarr pour lui. La clé API (pas une passkey) reste sur ce Mac, dans un fichier que toi seul peux lire.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Films", text: $model.movieCategories, prompt: Text("2000"))
                TextField("Séries", text: $model.tvCategories, prompt: Text("5000"))
            } header: {
                Text("Catégories")
            } footer: {
                Text("Numéros de catégories Newznab, séparés par des virgules. Vide = catégories standard.").foregroundStyle(.secondary)
            }
            Section("Suivi automatique") {
                Toggle("Télécharger tout seul les films et séries suivis", isOn: $model.autoEnabled)
                Stepper("Vérifier toutes les \(model.checkMinutes) min", value: $model.checkMinutes, in: 5...240, step: 5)
            }
            Section("Versions préférées") {
                Picker("Langue", selection: Binding(get: { model.prefs.languages.first ?? .multi },
                                                    set: { l in model.prefs.languages = [l] + ReleaseLanguage.allCases.filter { $0 != l && $0 != .vo } })) {
                    ForEach(ReleaseLanguage.allCases.filter { $0 != .vo }, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Seeders minimum : \(model.prefs.minSeeders)", value: $model.prefs.minSeeders, in: 0...50)
            }
        }
        .formStyle(.grouped)
    }
}
