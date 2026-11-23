# Architecture

Strapontin est un paquet Swift avec trois cibles.

## `StrapontinCore` : la logique, sans interface

Tout ce qui se décide sans écran, et qui est testé (`Tests/StrapontinCoreTests`) :

| Fichier | Rôle |
|---|---|
| `FilenameParser`, `LibraryScanner` | noms de release → titre, année, saison, épisode, qualité ; parcours des dossiers |
| `TMDbClient`, `TMDbClient+Discover`, `CatalogSearch` | fiches, épisodes, tendances, recherche |
| `TorznabClient`, `ReleasePicker`, `AutoGrab` | indexeur Torznab, classement des versions, suivi automatique |
| `TransmissionClient`, `QbitClient`, `TorrentClient`, `Downloads` | moteurs de téléchargement et lien torrent ↔ fiche |
| `Episodes`, `NextEpisode` | état de chaque épisode, épisode suivant et pistes gardées |
| `AudioFingerprint`, `PlaybackMarkers` | intro / générique repérés au son, carte « Épisode suivant » |

## `Strapontin` : l'app

- `StrapontinApp`, `ContentView` : fenêtre, onglets, navigation (chaque page a une valeur de navigation).
- `LibraryStore`, `FolderWatcher` : bibliothèque surveillée et fiches en cache
  (`~/Library/Application Support/Strapontin`).
- `Player/` : `MPVPlayer` (libmpv), `PlayerController` (fenêtre de lecture), `HeadlessMPV` (lecture sans image pour
  l'analyse du son et les vignettes), `IntroAnalyzer`, `ThumbnailEngine`.
- `Tracker/` : `TorrentEngine` (démon Transmission embarqué, écoute 127.0.0.1 seulement), `TrackerModel` (indexeur),
  `SeriesModel`, `DiscoverView`.
- `AppUpdater` : Sparkle 2.
- `EssaiHarness` : pilotage d'une copie d'essai isolée pour les tests manuels et les captures ; inerte sans la
  variable d'environnement `STRAPONTIN_ESSAI`.

## `Cmpv`

Module système qui expose libmpv (installé par Homebrew, puis embarqué dans l'app par `scripts/bundle.sh`).

## Données sur le Mac

| Chemin | Contenu |
|---|---|
| `~/Library/Application Support/Strapontin/library.json` | fiches et fichiers de la bibliothèque |
| `…/downloads.json` | lien torrent ↔ fiche |
| `…/tracker.json` | suivis, historique, préférences de version |
| `…/indexer-key` | clé de l'indexeur (fichier 0600) |
| `…/Transmission/` | configuration et fichiers en cours du moteur intégré |
