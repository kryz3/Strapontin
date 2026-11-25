import Foundation

/// Clés fournies au moment de la compilation, jamais écrites dans le code.
///
/// `scripts/bundle.sh` lit le fichier `.env` (non versionné, voir `.env.example`) et place la clé TMDb dans
/// l'Info.plist de l'app (`StrapontinTMDbKey`). Pendant le développement (`swift run`), la variable d'environnement
/// `TMDB_API_KEY` sert de repli. Une clé saisie dans Réglages › Fiches passe toujours avant.
enum Secrets {
    static var tmdbKey: String {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "StrapontinTMDbKey") as? String
        let value = (bundled?.isEmpty == false ? bundled : nil) ?? ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clé OpenSubtitles (sous-titres en ligne) : Info.plist (`StrapontinOpenSubtitlesKey`), sinon la variable
    /// d'environnement `OPENSUBTITLES_API_KEY`. Une clé saisie dans Réglages › Lecture passe avant.
    static var openSubtitlesKey: String {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "StrapontinOpenSubtitlesKey") as? String
        let value = (bundled?.isEmpty == false ? bundled : nil) ?? ProcessInfo.processInfo.environment["OPENSUBTITLES_API_KEY"] ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
