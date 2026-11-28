# Changements

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions [SemVer](https://semver.org/lang/fr/).
La section d'une version sert de notes à sa release GitHub.

## [Non publié]

## [0.1.5] - 2026-11-28

- **Nouvelle organisation, façon Netflix** : onglets Accueil · Pour toi · Films · Séries · Ma liste · En direct.
  L'Accueil commence par « À suivre », puis Pour toi, Ma liste et les tendances ; ta bibliothèque ensuite.
- **Fiche plus simple** : « Lire ▾ » (avec le choix de la source), « + » pour Ma liste, et « ⋯ » pour le reste.
- **Ma liste** : un onglet, et le « + » partout, même sans téléchargements configurés.
- **Versions à télécharger lisibles** : la recommandée en tête, en mots simples (qualité, langue, taille, si ça
  ira vite) ; le nom technique au survol.
- **Lecteur** : vitesse de lecture (0,75× à 2×, touches [ ] =), « Reprise à … · Depuis le début », touche ? pour
  les raccourcis.
- **En direct** : guide des programmes en grille (chaînes × heures), clic pour regarder.
- **Réglages** : l'essentiel visible, le reste dans « Avancé ».
- **Assistant de démarrage** au premier lancement (rouvrable depuis Aide).

## [0.1.4] - 2026-11-26

- **Choisir la source** : le bouton dit ce qui va se passer (« Lire · Fichier », « Reprendre · Streaming ») et
  son menu ▾ propose toutes les sources d'un film ou d'un épisode (fichier téléchargé, versions en streaming).
- **Changer de source en pleine lecture** : colonne « Source » dans Audio et sous-titres ; on reprend au même
  endroit. Le secours quand un fichier bugge.
- **Sous-titres en ligne sans configuration** : « Chercher en ligne… » dans le lecteur fonctionne d'emblée (clé
  OpenSubtitles fournie avec l'app ; la tienne, dans les réglages, passe avant).
- **Son** : l'icône montre l'état réel (coupé, volume) ; curseur toujours visible, molette et ↑ ↓.
- **Mises à jour** : vérifiées discrètement à chaque lancement.
- **Plus clair partout** : des mots simples à la place du jargon, les mêmes étiquettes sur les affiches
  (Téléchargé, Disponible en streaming, Disponible au téléchargement), des écrans vides qui disent quoi faire.

## [0.1.3] - 2026-11-26

**Nouveau**
- **Pour toi** (⌘4) : un fil de programmes choisis d'après tes goûts, à faire défiler, avec affiche, résumé,
  distribution et « Parce que tu as aimé… ». Calculé sur ton Mac.
- **IPTV** : playlists M3U et comptes Xtream. Onglet **En direct** (chaînes par pays et par thème, noms nettoyés,
  qualités regroupées, recherche, favoris, zapping, programme en cours) ; films et séries du fournisseur proposés
  « en streaming » sur la fiche TMDb du titre, avec choix de la version.
- **Un titre, plusieurs sources** : fichier, streaming ou téléchargement ; progression, « vu », Historique et
  « À suivre » sont communs, et l'épisode suivant passe d'une source à l'autre.
- **Sous-titres en ligne** (OpenSubtitles.com) depuis le lecteur, ou un fichier à ajouter.
- Lecteur du direct qui se répare tout seul : reprise au bord du direct, réouverture, qualité plus basse, adresse
  de secours ; pastille « Reconnexion… ».

**Aussi**
- Lecteur : bouton « Épisode précédent » (⇧N), désactivé au premier épisode, qui passe à la saison d'avant si besoin.
- Lecteur : panneau « Épisodes » (E), façon Netflix : toute la saison par-dessus la vidéo, qui continue derrière,
  avec image, titre, durée, résumé, progression et disponibilité de chaque épisode ; un clic lit l'épisode ou lance
  son téléchargement. L'épisode en cours est mis en avant ; Échap ferme le panneau.
- Barre du haut toujours visible, sur toutes les pages, fiches comprises.
- Recherche par acteur : acteurs et équipe dans la recherche, page de chaque personne (photo, biographie,
  filmographie), distribution cliquable sur les fiches.
- Langues audio et sous-titres retenues par série, d'une séance à l'autre.
- Qualité des téléchargements (Réglages › Téléchargements) : 720p, 1080p, 4K si disponible ou la meilleure, taille
  maximale par épisode ; une série commencée garde la qualité de ses épisodes ; qualité propre à chaque série suivie.
- Notification quand un téléchargement est terminé (un clic ouvre la fiche).
- Mini-lecteur (⇧P) : petite fenêtre toujours devant, dans un coin de l'écran.
- Touches multimédia, Centre de contrôle et écran verrouillé : lecture/pause, ±10 s, épisode suivant/précédent.
- Historique (⌘Y) : ce qui a été regardé, par jour, avec reprise et « marquer comme non vu ».

**Amélioré**
- Contrôle du son façon QuickTime : icône qui suit l'état réel (coupé, volume), curseur toujours visible.
- Dégradé du lecteur sur toute la fenêtre ; images et noms des titres toujours tirés de TMDb.

## [0.1.2] - 2026-11-23

- Images de la bibliothèque de retour (Accueil, Films, Séries, fiches) : les affiches et fonds restés dans le cache de
  l'ancienne app sont repris, et tout visuel absent du disque est retéléchargé au lancement.
- Barre du haut : capsule en verre avec une ombre douce, plus de bande floue qui apparaît en faisant défiler ;
  elle s'efface et revient en douceur. Le champ de la page Recherche reste en haut.
- Réglages : roue dentée discrète dans la capsule (⌘,) ; nouveau menu Aller (⌘1 à ⌘4, Stockage, Indexeur).
- Une copie compilée sur sa machine reçoit aussi les mises à jour.

## [0.1.1] - 2026-11-23

- Navigation façon Apple TV : barre d'onglets translucide qui flotte sur les images et s'efface en défilant ;
  la barre latérale disparaît. Une page Recherche avec le seul champ de l'app (loupe ou ⌘F).
- Recherche : sections Bibliothèque, Films et Séries affichées tout de suite, chacune remplie dès que sa réponse
  arrive (squelettes d'affiches pendant l'attente), « Aucun résultat » ou erreur par section ; pastilles de l'indexeur
  chargées ensuite, sans bloquer les affiches.
- Plus rapide : réponses TMDb et images en cache (mémoire et disque), une seule connexion réutilisée, identification
  de la bibliothèque en parallèle, fiche préchargée au survol d'une affiche.
- Interface optimiste : lancer, mettre en pause, reprendre ou annuler un téléchargement, supprimer un titre, corriger
  une fiche se voit immédiatement, avec retour en arrière et message discret si l'action échoue.
- Nouvelle icône : un fauteuil de cinéma rouge.
- README.env.md : obtenir une clé TMDb et brancher un indexeur pas à pas.

## [0.1.0] - 2026-11-23

Première version publique. Strapontin s'appelait « Lecteur » : ses données et réglages sont repris au premier
lancement.

- Lecture libmpv sans perte : décodage matériel fiable, rendu `gpu-next`, pistes audio et sous-titres,
  passthrough, reprise de lecture.
- Bibliothèque surveillée, noms de release reconnus, fiches TMDb (et note IMDb via OMDb).
- Interface façon Apple TV, ambiance salle de cinéma : barre latérale repliable, recherche unique en haut
  de la fenêtre, accueil, films, séries, fiches immersives, Découvrir.
- Séries épisode par épisode, une fiche par épisode.
- Épisode suivant au générique sans couper une scène finale, « Passer l'intro / le récap » (chapitres ou
  empreinte audio), vignettes sur la barre de temps.
- Téléchargements : moteur intégré (Transmission) ou qBittorrent, progression sur l'affiche, indexeur Torznab
  générique avec suivi automatique.
- Mises à jour intégrées (Sparkle 2, signature EdDSA).
