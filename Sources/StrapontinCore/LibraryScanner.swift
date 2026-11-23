import Foundation

public struct FoundFile: Sendable {
    public var path: String
    public var size: Int64
    public var mtime: Double
}

public enum LibraryScanner {
    /// Liste les vidéos d'un dossier (récursif). Renvoie nil si le dossier est inaccessible
    /// (disque débranché), pour ne pas vider la bibliothèque par erreur.
    public static func scan(folder: String) -> [FoundFile]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var out: [FoundFile] = []
        for case let url as URL in en {
            guard FilenameParser.videoExtensions.contains(url.pathExtension.lowercased()),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            guard FilenameParser.isVideo(url, size: size) else { continue }
            out.append(FoundFile(path: url.path, size: size, mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return out
    }

    /// Fusionne un scan avec la liste connue. Renvoie la nouvelle liste et s'il y a eu des changements.
    public static func merge(known: [MediaFile], folder: String, found: [FoundFile]) -> ([MediaFile], Bool) {
        var byPath = Dictionary(uniqueKeysWithValues: known.filter { $0.folder == folder }.map { ($0.path, $0) })
        let others = known.filter { $0.folder != folder }
        var changed = false
        var result: [MediaFile] = []
        let root = URL(fileURLWithPath: folder)
        for f in found {
            if var old = byPath.removeValue(forKey: f.path) {
                if old.size != f.size || old.mtime != f.mtime {
                    old.size = f.size
                    old.mtime = f.mtime
                    changed = true
                }
                result.append(old)
            } else {
                let url = URL(fileURLWithPath: f.path)
                result.append(MediaFile(path: f.path, folder: folder, size: f.size, mtime: f.mtime,
                                        parsed: FilenameParser.parse(url, root: root)))
                changed = true
            }
        }
        if !byPath.isEmpty { changed = true }   // fichiers disparus
        return (others + result, changed)
    }
}
