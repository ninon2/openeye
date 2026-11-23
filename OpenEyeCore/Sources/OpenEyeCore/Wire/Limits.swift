/// Bornes du protocole (docs/architecture.md §8). Toute borne vit ici, nulle part ailleurs.
public enum Limits {
    /// Taille fixe de l'en-tête (docs/protocole.md §4.1).
    public static let headerSize = 24
    /// Taille du tag AES-GCM.
    public static let tagSize = 16
    /// Taille maximale d'un paquet complet, en-tête et tag compris (STRIDE D2).
    public static let maxPacketSize = 65_536
    /// Taille maximale des données d'un fragment vidéo (STRIDE D3).
    public static let maxFragmentData = 16_384
    /// Taille maximale du corps de VideoParams. PROPOSITION absente de la spec, à valider :
    /// les paramètres SPS et PPS d'un flux H.264 tiennent normalement en une centaine d'octets.
    public static let maxVideoParamsBody = 1_024
}
