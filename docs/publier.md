# Publier une version

Les releases sont construites par GitHub Actions (`.github/workflows/release.yml`) quand on pousse un tag.

## Une fois

1. **Clé EdDSA des mises à jour** : la clé publique est dans `Resources/Info.plist` (`SUPublicEDKey`). La clé privée
   n'est jamais dans le dépôt ; ajoute-la comme secret du dépôt **`SPARKLE_PRIVATE_KEY`** (Settings › Secrets and
   variables › Actions) et garde-en une sauvegarde hors de ce Mac (gestionnaire de mots de passe).
   **Sans elle, les apps déjà installées ne pourront plus être mises à jour.**
2. Facultatif : secret **`TMDB_API_KEY`**, la clé TMDb fournie avec l'app.

Nouvelle clé (si tu repars de zéro) : `.build/artifacts/sparkle/Sparkle/bin/generate_keys` (après `swift build`),
puis remplace `SUPublicEDKey`.

## À chaque version

1. Ajoute la section `## [x.y.z] - date` en tête de `CHANGELOG.md` (elle devient les notes de la release).
2. `git tag vx.y.z && git push origin vx.y.z`.

La CI teste, construit, vérifie l'app (lecture d'une vidéo de test, signature), signe l'archive, écrit
`appcast.xml` et publie la release : `Strapontin-x.y.z.dmg`, `Strapontin-x.y.z.zip`, `appcast.xml`.
Les apps installées lisent `…/releases/latest/download/appcast.xml` : elles voient la nouvelle version dès que la
release est publiée (pas en pré-release).

Numéro de build (`CFBundleVersion`) = nombre de commits : il augmente toujours.
