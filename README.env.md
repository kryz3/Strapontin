# Configurer ses clés (`.env` ou Réglages)

Strapontin a besoin d'une clé **TMDb** pour les fiches (affiches, résumés, épisodes). Pour télécharger, il peut aussi
se brancher sur un **indexeur Torznab** de ton choix. Ce guide explique où trouver chaque valeur et où la mettre.

## Deux façons de configurer

1. **Les Réglages de l'app** (rien à compiler) : Réglages › Fiches pour TMDb, Réglages › Indexeur pour l'indexeur.
   **Ce qui est saisi dans les Réglages passe toujours avant le `.env`.**
2. **Le fichier `.env`**, pour qui compile sa propre copie avec `scripts/bundle.sh` : les valeurs sont intégrées à
   l'app au moment de la construction, il n'y a plus rien à saisir. Les valeurs de l'indexeur sont ensuite recopiées
   dans les réglages au premier lancement (Réglages › Indexeur affiche alors « Fourni par la configuration de build »).

Les versions publiées sur GitHub contiennent une clé TMDb, mais **jamais d'indexeur** : la CI ignore les variables
`INDEXER_*`.

## Le fichier `.env`

Il se place **à la racine du dépôt**, à côté de `Package.swift`. Il n'est jamais versionné (il est dans `.gitignore`).
Pars du modèle :

```sh
cp .env.example .env
```

puis remplis ce dont tu as besoin. Exemple avec des valeurs **factices** :

```sh
TMDB_API_KEY=0123456789abcdef0123456789abcdef
OPENSUBTITLES_API_KEY=cle-opensubtitles-factice
INDEXER_URL=https://indexeur.exemple
INDEXER_API_PATH=/api
INDEXER_API_KEY=ma-cle-api-factice
```

| Variable | Rôle |
|---|---|
| `TMDB_API_KEY` | clé TMDb : fiches, affiches, épisodes, Découvrir, recherche dans le catalogue |
| `OPENSUBTITLES_API_KEY` | clé OpenSubtitles.com (gratuite, compte puis « API consumers ») : sous-titres en ligne dans le lecteur. Facultative : chacun peut aussi la saisir dans Réglages › Lecture |
| `INDEXER_URL` | adresse de base de l'indexeur (`https://…`) |
| `INDEXER_API_PATH` | chemin de son API Torznab (souvent `/api`) ; l'app appelle `INDEXER_URL` + `INDEXER_API_PATH` |
| `INDEXER_API_KEY` | ta clé API sur cet indexeur |

`scripts/bundle.sh` lit ce fichier ligne à ligne, sans l'exécuter, et seulement ces variables (plus `STRAPONTIN_VERSION`,
`STRAPONTIN_BUILD` et `STRAPONTIN_FEED_URL`, utiles pour publier). Pendant le développement (`swift run`), les mêmes
variables peuvent être passées dans l'environnement.

## Obtenir une clé TMDb

D'après la documentation de TMDb ([Getting Started](https://developer.themoviedb.org/docs/getting-started),
consultée le 23/11/2026) :

1. Crée un compte sur [themoviedb.org](https://www.themoviedb.org) (de préférence depuis un ordinateur : l'inscription à
   l'API n'est pas adaptée au mobile).
2. Dans les paramètres de ton compte, ouvre la section **API** ([lien direct](https://www.themoviedb.org/settings/api)).
3. Demande une clé et accepte les [conditions d'utilisation de l'API](https://www.themoviedb.org/documentation/api/terms-of-use).
   L'usage gratuit est un usage **non commercial**.
4. La page API affiche alors deux valeurs :
   - la **clé API** (« API Key », v3) : une suite de 32 caractères hexadécimaux ;
   - le **jeton d'accès en lecture** (« API Read Access Token », v4), qui commence par `eyJ`.

**Strapontin accepte les deux** : la clé v3 est envoyée en paramètre `api_key`, un jeton qui commence par `eyJ` est
envoyé en `Authorization: Bearer`. Le plus simple est de copier la **clé API (v3)**.

Vérifier une clé : Réglages › Fiches › « Tester la clé », ou dans un terminal :

```sh
curl "https://api.themoviedb.org/3/configuration?api_key=TA_CLE"
```

Une réponse JSON = c'est bon ; `401` = clé invalide ou mal copiée (espace en trop, jeton tronqué).

## Brancher un indexeur Torznab

Torznab est une API standard de recherche de torrents. Strapontin peut l'interroger de deux façons.

**Directement sur l'indexeur**, s'il expose une API Torznab : l'adresse, le chemin de l'API et ta clé se trouvent en
général dans ton profil ou tes paramètres sur le site (rubrique API ou Torznab). Prends bien la **clé API**, pas une
passkey (l'identifiant qui apparaît dans les liens de téléchargement).

**Via Prowlarr ou Jackett**, qui exposent un flux Torznab pour chaque indexeur configuré chez eux :

- **Prowlarr** : chaque indexeur a son flux, de la forme `http://localhost:9696/<n°>/api` ; la clé est dans
  Settings › General › API Key.
- **Jackett** : sur la ligne de l'indexeur, « Copy Torznab Feed » donne une adresse de la forme
  `http://localhost:9117/api/v2.0/indexers/<nom>/results/torznab/`. La clé API est affichée en haut de la page.

Dans Réglages › Indexeur, l'**adresse de l'API** est l'adresse complète (base + chemin). Dans le `.env`, sépare la base
(`INDEXER_URL`) et le chemin (`INDEXER_API_PATH`).

Les catégories standard (2000 pour les films, 5000 pour les séries) conviennent presque toujours. Change-les dans les
réglages seulement si ton indexeur en utilise d'autres.

### Vérifier que ça marche

Bouton « Tester » dans Réglages › Indexeur, ou dans un terminal (`t=caps` demande à l'indexeur ce qu'il sait faire) :

```sh
curl "https://indexeur.exemple/api?t=caps&apikey=TA_CLE"
```

- Un document XML qui commence par `<caps>` : c'est bon.
- `401`, `403` ou une erreur `100` : la clé est refusée (mauvaise clé, ou passkey au lieu de la clé API).
- Une page HTML : le chemin de l'API n'est pas le bon.
- Pas de réponse : adresse erronée, ou DNS de ton fournisseur d'accès qui bloque le site (essaie un autre DNS).

## Dépannage

| Symptôme | Piste |
|---|---|
| Les fiches ne se chargent pas, « Clé TMDb refusée » | clé mal copiée ; réessaie avec la clé API (v3) de la page API de TMDb |
| Les valeurs du `.env` ne sont pas prises | le `.env` doit être à la racine du dépôt, une variable par ligne, sans espaces autour du `=` ; relance `scripts/bundle.sh` |
| Une valeur du `.env` semble ignorée | une valeur saisie dans les Réglages passe avant : vide le champ pour revenir à celle du `.env` |
| « Aucun indexeur branché » | il faut l'adresse **et** la clé ; la version téléchargée sur GitHub n'en contient jamais |
| L'indexeur répond mais rien ne sort | vérifie les catégories (Réglages › Indexeur) |
