# Contribuer

Merci de ton intérêt ! Quelques repères pour que ça reste simple.

## Mettre en place

```sh
brew install mpv dylibbundler pkg-config transmission-cli molten-vk
cp .env.example .env     # TMDB_API_KEY, facultatif
swift test
swift run Strapontin
```

## Règles

- **Logique dans `StrapontinCore`, testée** : tout ce qui se teste sans interface (noms de release, choix d'une
  version, épisodes, marqueurs de lecture…) va dans `Sources/StrapontinCore`, avec un test dans
  `Tests/StrapontinCoreTests`. Les tests ne touchent jamais le réseau (réponses simulées).
- **Aucun secret dans le dépôt** : clés dans `.env` (jamais versionné) ou dans les réglages de l'app.
  Pas de vraies adresses d'indexeur, de clés ni de passkeys dans les tests.
- **L'interface et les messages sont en français**, comme le code commenté.
- Un changement = un commit lisible ; `swift test` passe avant d'ouvrir une pull request.
- Interface : sobre, dans l'esprit d'Apple TV ; pas de page sans issue ni d'état vide sans explication.

## Signaler un problème

Ouvre une issue avec la version (Réglages › Bibliothèque › Mises à jour), le modèle de Mac, la version de macOS et,
pour un problème de lecture, la sortie de la touche **I** pendant la lecture.
