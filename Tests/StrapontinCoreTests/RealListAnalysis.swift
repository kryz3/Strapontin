import XCTest
@testable import StrapontinCore

/// Analyse d'un vrai export de noms (Réglages > IPTV > Exporter), hors dépôt : STRAPONTIN_EXPORT=<fichier.tsv> swift test
/// --filter RealListAnalysis. Rapport dans STRAPONTIN_EXPORT_REPORT (ou à côté de l'export). Sans la variable : rien.
final class RealListAnalysis: XCTestCase {
    func testRealExport() throws {
        guard let path = ProcessInfo.processInfo.environment["STRAPONTIN_EXPORT"] else { throw XCTSkip("pas d'export") }
        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count == 3 }
        var out: [String] = []
        func say(_ s: String) { out.append(s) }

        // --- chaînes
        let live = rows.filter { $0[0] == "direct" }
        let entries = live.enumerated().map { i, r in
            IPTVEntry(id: "e\(i)", name: r[2], url: "", tvgId: nil, logo: nil, group: r[1], number: nil, kind: .live, playlist: "p",
                      country: IPTVCountry.detect(group: r[1], name: r[2]))
        }
        let decorative = entries.filter { ChannelName.isDecorative($0.name) }.count
        var t0 = Date()
        let g = ChannelGrouping.group(entries)
        let groupTime = Date().timeIntervalSince(t0)
        let noCountry = g.channels.filter { $0.country == nil }.count
        // « reconnu proprement » : un pays, un nom sans reste technique ni décoration
        let residue = Set(["HD", "FHD", "UHD", "4K", "SD", "HEVC", "VIP", "|", "[", "]", "BK", "BACKUP", "RAW", "H265", "50FPS"])
        func clean(_ e: IPTVEntry) -> Bool {
            e.country != nil && !e.name.isEmpty && !e.name.uppercased().split(separator: " ").contains { residue.contains(String($0)) }
                && !e.name.unicodeScalars.contains { $0.value > 0x2000 && $0.properties.generalCategory == .otherSymbol }
        }
        let cleanCount = g.channels.filter(clean).count
        say("CHAÎNES : \(live.count) noms bruts, \(decorative) intertitres masqués, \(g.channels.count) chaînes (variantes regroupées), regroupement en \(String(format: "%.2f", groupTime)) s")
        say("  reconnues proprement (pays + nom propre) : \(cleanCount) (\(cleanCount * 100 / max(1, g.channels.count)) %), sans pays : \(noCountry)")
        var byCountry: [String: Int] = [:]
        for c in g.channels { byCountry[c.country ?? "—", default: 0] += 1 }
        say("  pays : " + byCountry.sorted { $0.value > $1.value }.prefix(25).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        // mots restants les plus fréquents dans les noms propres (pour repérer le bruit oublié)
        var words: [String: Int] = [:]
        for c in g.channels { for w in c.name.uppercased().split(separator: " ") { words[String(w), default: 0] += 1 } }
        say("  mots les plus fréquents après nettoyage : " + words.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let fr = g.channels.filter { $0.country == "FR" }
        let frNames = Set(fr.map(\.name))
        let must = ["Canal+", "Canal+ Cinéma", "Canal+ Sport", "TF1", "France 2", "M6", "BFM TV", "beIN Sports 1", "beIN Sports 2", "beIN Sports 3"]
            + (1...19).map { "Canal+ Live \($0)" }
        say("  France : \(fr.count) chaînes ; attendues absentes : " + must.filter { !frNames.contains($0) }.joined(separator: ", "))
        let canalNotFR = g.channels.filter { $0.name.hasPrefix("Canal+") && $0.country != "FR" }.map { "\($0.name) [\($0.country ?? "—")]" }
        say("  Canal+ hors France : " + canalNotFR.prefix(15).joined(separator: ", "))
        let sansPays = g.channels.filter { $0.country == nil }.prefix(30).map { "\($0.group) ⟶ \($0.name)" }
        say("  exemples sans pays : " + sansPays.joined(separator: " ; "))
        let dirty = g.channels.filter { $0.country != nil && !clean($0) }.prefix(30).map(\.name)
        say("  exemples encore sales : " + dirty.joined(separator: " ; "))

        // --- films et séries
        let vod = rows.filter { $0[0] != "direct" }
        t0 = Date()
        let refs = vod.enumerated().map { i, r in VODRef(id: "v\(i)", kind: r[0] == "serie" ? .series : .movie, name: r[2]) }
        let refTime = Date().timeIntervalSince(t0)
        t0 = Date()
        let lookup = VODLookup(refs)
        let lookupTime = Date().timeIntervalSince(t0)
        let withYear = refs.filter { $0.year != nil }.count
        let empty = refs.filter { $0.key.isEmpty }.count
        say("FILMS/SÉRIES : \(vod.count) titres, clés en \(String(format: "%.2f", refTime)) s, index en \(String(format: "%.2f", lookupTime)) s ; avec année : \(withYear * 100 / max(1, refs.count)) %, clé vide : \(empty)")
        var vw: [String: Int] = [:]
        for r in refs { for w in r.key.split(separator: " ") { vw[String(w), default: 0] += 1 } }
        say("  mots les plus fréquents dans les clés : " + vw.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        say("  exemples nom → clé (année) : " + refs.shuffled().prefix(25).map { "\($0.name) → \($0.key) (\($0.year.map(String.init) ?? "–"))" }.joined(separator: " ; "))
        t0 = Date()
        let probes = ["Dune", "Inception", "Le Parrain", "Intouchables", "Breaking Bad", "Lupin", "La Casa de Papel", "Avatar", "Titanic", "Oppenheimer"]
        let found = probes.map { p in "\(p): \(lookup.find(kind: .movie, tmdbId: nil, titles: [p], year: nil).count + lookup.find(kind: .series, tmdbId: nil, titles: [p], year: nil).count)" }
        say("  recherche depuis une fiche (versions trouvées) : " + found.joined(separator: ", ") + String(format: " — %.1f ms en tout", Date().timeIntervalSince(t0) * 1000))

        let report = ProcessInfo.processInfo.environment["STRAPONTIN_EXPORT_REPORT"] ?? (path + ".rapport.txt")
        try out.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
}
