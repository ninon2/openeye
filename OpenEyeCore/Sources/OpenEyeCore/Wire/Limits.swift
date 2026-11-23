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

    // MARK: Session (tâche 23)

    /// Durée de vie du défi nM, entre Challenge et Auth (STRIDE E2).
    public static let challengeLifetime: Duration = .seconds(30)
    /// Durée maximale d'une session : au-delà, nouveau handshake avec Face ID.
    public static let maxSessionDuration: Duration = .seconds(3_600)
    /// Compteur à partir duquel la session se ferme (docs/protocole.md §4.6).
    public static let counterLimit: UInt64 = 1 << 32
    /// Nombre de rejets, dans la fenêtre ci-dessous, qui ferme la session.
    public static let maxFailures = 20
    public static let failureWindow: Duration = .seconds(10)
    /// Tolérance entre les deux horloges, en millisecondes.
    public static let clockToleranceMilliseconds: UInt64 = 30_000

    // MARK: Appairage (tâche 21)

    /// Durée de vie d'un QR d'appairage, en secondes (STRIDE S4).
    public static let pairingLifetimeSeconds: UInt64 = 120
}
