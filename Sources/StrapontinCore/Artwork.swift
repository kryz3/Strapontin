import Foundation

/// Visuels d'une fiche gardés sur le disque (affiche, grand fond) : ceux qui manquent sont retéléchargés.
/// Une fiche de la bibliothèque n'affiche que ses copies locales ; si elles manquent (cache vidé, dossier
/// d'une ancienne version…), rien ne les faisait revenir et la page restait sans image.
public enum Artwork {
    public struct Missing: Equatable, Sendable {
        public var path: String      // chemin TMDb (« /abc.jpg »)
        public var size: String      // taille TMDb (« w500 »)
        public var destination: URL
    }

    /// Ce qu'il faut télécharger pour que chaque fiche ait son affiche et son fond sur le disque.
    public static func missing(_ media: [Media], posterURL: (Media) -> URL, backdropURL: (Media) -> URL,
                               exists: (URL) -> Bool) -> [Missing] {
        var out: [Missing] = []
        for m in media {
            if let p = m.posterPath, !exists(posterURL(m)) { out.append(Missing(path: p, size: "w500", destination: posterURL(m))) }
            if let b = m.backdropPath, !exists(backdropURL(m)) { out.append(Missing(path: b, size: "w1280", destination: backdropURL(m))) }
        }
        return out
    }
}
