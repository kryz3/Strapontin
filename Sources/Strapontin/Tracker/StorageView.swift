import AppKit
import StrapontinCore
import SwiftUI

// MARK: - Suppression

/// Supprime des vidéos de la bibliothèque : retire le torrent des téléchargements (sinon le moteur signale des
/// fichiers manquants), puis met à la corbeille ou efface. Le dossier de la release (puis de la saison, de la série)
/// part avec s'il ne contient plus que des fichiers annexes (.nfo, sous-titres, images).
@MainActor
enum MediaDeleter {
    nonisolated static let sidecars: Set<String> = ["nfo", "srt", "ass", "ssa", "sub", "idx", "vtt", "txt", "jpg", "jpeg", "png", "sfv", "md5", "url"]

    /// Renvoie la place libérée (en octets).
    @discardableResult
    static func delete(_ files: [MediaFile], permanently: Bool) async throws -> Int64 {
        // interface optimiste : le titre ou l'épisode disparaît tout de suite ; il revient si la suppression échoue
        await LibraryStore.shared.hide(files.map(\.path))
        do {
            return try await deleteNow(files, permanently: permanently)
        } catch {
            await LibraryStore.shared.unhide(files.map(\.path))
            throw error
        }
    }

    private static func deleteNow(_ files: [MediaFile], permanently: Bool) async throws -> Int64 {
        let fm = FileManager.default
        let paths = Set(files.map(\.path))
        let targets = targets(for: files.map(\.path), roots: AppSettings.shared.folders)

        // le moteur de téléchargement d'abord
        if TorrentEngine.shared.available, let engine = try? await TorrentEngine.shared.client() {
            if let torrents = try? await engine.torrents() {
                let hashes = torrents.filter { t in
                    let c = t.contentPath
                    return !c.isEmpty && (paths.contains(c) || targets.contains(c)
                        || paths.contains { $0.hasPrefix(c + "/") } || targets.contains { c.hasPrefix($0 + "/") })
                }.map(\.hash)
                if !hashes.isEmpty { try await engine.delete(hashes, deleteFiles: false) }
            }
        }

        var freed: Int64 = 0
        for t in targets {
            let url = URL(fileURLWithPath: t)
            freed += size(of: url)
            if permanently { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
        }
        LibraryStore.shared.rescan()
        return freed
    }

    /// Ce qu'on enlève vraiment : le fichier, ou le plus haut dossier (release, puis saison, puis série) qui ne
    /// contient plus rien d'utile. Seulement à l'intérieur d'un dossier de la bibliothèque, jamais ce dossier
    /// lui-même ; un fichier hors de la bibliothèque part seul.
    nonisolated static func targets(for paths: [String], roots: [String]) -> Set<String> {
        let roots = Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let deleting = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var targets = Set<String>()
        for p in deleting {
            var target = p
            var dir = URL(fileURLWithPath: p).deletingLastPathComponent().standardizedFileURL
            while !roots.contains(dir.path), roots.contains(where: { dir.path.hasPrefix($0 + "/") }),
                  onlyLeftovers(in: dir, besides: deleting) {
                target = dir.path
                dir = dir.deletingLastPathComponent().standardizedFileURL
            }
            targets.insert(target)
        }
        // un dossier qui en contient un autre de la liste suffit
        return targets.filter { t in !targets.contains { t.hasPrefix($0 + "/") } }
    }

    nonisolated static func onlyLeftovers(in dir: URL, besides deleting: Set<String>) -> Bool {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let u as URL in en {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if deleting.contains(u.standardizedFileURL.path) { continue }
            // .DS_Store (le Finder en crée dans tout dossier ouvert) et autres fichiers cachés : ne comptent pas
            if u.lastPathComponent.hasPrefix(".") { continue }
            if !sidecars.contains(u.pathExtension.lowercased()) { return false }
        }
        return true
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0) }
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let u = en?.nextObject() as? URL {
            if let r = try? u.resourceValues(forKeys: keys), r.isDirectory != true { total += Int64(r.totalFileAllocatedSize ?? r.fileSize ?? 0) }
        }
        return total
    }
}

/// Demande de confirmation partagée (Stockage, fiche, menus). `request` = fichiers à supprimer.
struct DeleteConfirmation: ViewModifier {
    @Binding var request: DeleteRequest?
    @State private var result: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                                titleVisibility: .visible, presenting: request) { r in
                Button("Supprimer définitivement (\(humanSize(r.size)) libérés)", role: .destructive) { run(r, permanently: true) }
                Button("Mettre à la corbeille") { run(r, permanently: false) }
                Button("Annuler", role: .cancel) {}
            } message: { r in
                Text(r.files.count > 1 ? "\(r.files.count) fichiers. " : "" )
                    + Text("Le torrent est retiré des téléchargements, il ne sera plus partagé. La corbeille ne libère la place qu'une fois vidée.")
            }
            .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {}
    }

    private func run(_ r: DeleteRequest, permanently: Bool) {
        Task {
            do {
                let freed = try await MediaDeleter.delete(r.files, permanently: permanently)
                result = permanently ? "Supprimé : \(humanSize(freed)) libérés." : "Mis à la corbeille (\(humanSize(freed)) à récupérer en la vidant)."
            } catch {
                result = "Suppression impossible : \(error.localizedDescription)"
            }
        }
    }
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    var title: String
    var files: [MediaFile]
    var size: Int64 { files.reduce(0) { $0 + $1.size } }

    static func item(_ i: LibraryItem) -> DeleteRequest { DeleteRequest(title: "Supprimer « \(i.title) » ?", files: i.files) }
    static func watched(_ i: LibraryItem) -> DeleteRequest {
        DeleteRequest(title: "Supprimer les épisodes déjà vus de « \(i.title) » ?", files: i.files.filter(\.watched))
    }
}

extension View {
    func deleteConfirmation(_ request: Binding<DeleteRequest?>) -> some View { modifier(DeleteConfirmation(request: request)) }
}

// MARK: - Écran Stockage

struct StorageView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @State private var volumes: [VolumeInfo] = []
    @State private var request: DeleteRequest?
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 26)]

    private var bySize: [LibraryItem] { store.items.sorted { size($0) > size($1) } }
    private var watched: [LibraryItem] { store.items.filter { $0.files.contains(where: \.watched) } }
    private var watchedSize: Int64 { watched.reduce(0) { $0 + $1.files.filter(\.watched).reduce(0) { $0 + $1.size } } }
    private var librarySize: Int64 { store.files.reduce(0) { $0 + $1.size } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Stockage").font(.system(size: 30, weight: .bold))
                ForEach(volumes) { VolumeCard(volume: $0, librarySize: librarySize) }

                if watchedSize > 0 {
                    HStack(spacing: 16) {
                        Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Déjà vus : \(humanSize(watchedSize))").font(.system(size: 16, weight: .semibold))
                            Text("Films et épisodes que tu as terminés.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Tout supprimer…") {
                            request = DeleteRequest(title: "Supprimer tout ce qui est déjà vu ?",
                                                    files: watched.flatMap { $0.files.filter(\.watched) })
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text("Ce qui prend le plus de place").font(.system(size: 21, weight: .bold))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(bySize) { item in
                            StorageCard(item: item, size: size(item))
                                .contextMenu {
                                    Button("Supprimer…") { request = .item(item) }
                                    if item.kind == .tv, item.files.contains(where: \.watched), !item.allWatched {
                                        Button("Supprimer les épisodes vus…") { request = .watched(item) }
                                    }
                                    if let f = item.files.first {
                                        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                                    }
                                }
                        }
                    }
                }
            }
            .padding(Theme.margin)
        }
        .background(Theme.background)
        .deleteConfirmation($request)
        .task(id: store.files.count) { volumes = VolumeInfo.load(settings.folders) }
    }

    private func size(_ i: LibraryItem) -> Int64 { i.files.reduce(0) { $0 + $1.size } }
}

private struct StorageCard: View {
    let item: LibraryItem
    let size: Int64
    @State private var hover = false

    var body: some View {
        NavigationLink(value: item.id) {
            VStack(alignment: .leading, spacing: 8) {
                PosterView(item: item)
                    .overlay(alignment: .bottomLeading) {
                        Text(humanSize(size)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule()).padding(8)
                    }
                    .scaleEffect(hover ? 1.04 : 1)
                    .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.kind == .tv ? "\(item.files.count) épisode\(item.files.count > 1 ? "s" : "")" + (item.allWatched ? " · vus" : "")
                                      : (item.allWatched ? "Vu" : "Pas encore vu"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

struct VolumeInfo: Identifiable {
    var id: String { name }
    var name: String
    var total: Int64
    var free: Int64

    static func load(_ folders: [String]) -> [VolumeInfo] {
        var seen = Set<String>()
        return folders.compactMap { f in
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                            .volumeAvailableCapacityKey]
            guard let v = try? URL(fileURLWithPath: f).resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
            let name = v.volumeName ?? "Disque"
            guard seen.insert(name).inserted else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(name: name, total: Int64(total), free: free)
        }
    }
}

private struct VolumeCard: View {
    let volume: VolumeInfo
    let librarySize: Int64

    var body: some View {
        let used = max(0, volume.total - volume.free)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume.name, systemImage: "internaldrive").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(humanSize(volume.free)) libres sur \(humanSize(volume.total))").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                let w = g.size.width
                let lib = CGFloat(min(librarySize, used)) / CGFloat(max(1, volume.total)) * w
                let other = CGFloat(used) / CGFloat(max(1, volume.total)) * w - lib
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.accent).frame(width: lib)
                    Rectangle().fill(.white.opacity(0.35)).frame(width: max(0, other))
                    Spacer(minLength: 0)
                }
                .frame(height: 14)
                .background(.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack(spacing: 18) {
                legend(Theme.accent, "Films et séries : \(humanSize(librarySize))")
                legend(.white.opacity(0.35), "Autres : \(humanSize(max(0, used - librarySize)))")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if Double(volume.free) / Double(max(1, volume.total)) < 0.1 {
                Label("Il reste moins de 10 % de place : le téléchargement risque de s'arrêter en plein milieu.",
                      systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }
}
