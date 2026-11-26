/// L'icône du son selon l'état réel du lecteur : coupé (ou à 0), puis une, deux ou trois ondes selon le volume.
/// (Avant la 0.1.3, l'icône ne dépendait que du volume : couper le son ne la changeait pas.)
public enum VolumeIcon {
    public static func name(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 34 { return "speaker.wave.1.fill" }
        if volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
