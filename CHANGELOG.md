# Changements

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions [SemVer](https://semver.org/lang/fr/).
La section d'une version sert de notes à sa release GitHub.

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
