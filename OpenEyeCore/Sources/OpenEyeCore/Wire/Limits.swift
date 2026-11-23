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

    // MARK: Vidéo (tâche 26)

    /// Nombre maximal de fragments d'une image : 64 × 16 Kio = 1 Mio (STRIDE D3).
    public static let maxFragmentsPerFrame = 64
    public static let maxFrameSize = 1_048_576
    /// Images en cours de réassemblage.
    public static let maxPendingFrames = 4
    /// Au-delà, une image incomplète est jetée.
    public static let assemblyTimeout: Duration = .seconds(1)
    /// PROPOSITION absente de la spec, à valider : largeur et hauteur maximales acceptées.
    public static let maxVideoDimension = 4_096

    // MARK: Connexion et liveness (tâches 24 et 28)

    /// Le Hello doit arriver dans ce délai après la connexion (STRIDE D2).
    public static let helloTimeout: Duration = .seconds(10)
    /// Période du Heartbeat (Mac → iPhone) et du Keepalive (iPhone → Mac).
    public static let heartbeatPeriod: Duration = .seconds(2)
    /// Sans paquet authentifié pendant ce délai, l'iPhone affiche « Mac injoignable » (3 heartbeats manqués).
    public static let unreachableAfter: Duration = .seconds(6)
    /// Sans Keepalive pendant ce délai, le Mac arrête la capture.
    public static let keepaliveTimeout: Duration = .seconds(10)
    /// Images encodées en attente d'envoi : au-delà, on jette jusqu'à la prochaine image clé.
    public static let maxQueuedFrames = 3

    // MARK: Journal (tâche 29)

    /// Conservation des entrées, en millisecondes : 30 jours (à valider par A, RGPD).
    public static let journalRetentionMilliseconds: UInt64 = 30 * 24 * 3_600 * 1_000
    /// Âge minimal d'une ancre pour qu'une réponse « purgée » soit normale : 29 jours.
    public static let minPurgedAnchorAgeMilliseconds: UInt64 = 29 * 24 * 3_600 * 1_000
    /// Délai de réponse à JournalAnchorRequest.
    public static let anchorReplyTimeout: Duration = .seconds(10)

    // MARK: Commandes Verrouiller / Déverrouiller (extension J4)

    /// Durée de vie du défi nC, entre CmdChallenge et la commande (STRIDE L7).
    public static let commandChallengeLifetime: Duration = .seconds(30)
    /// Délai minimal entre deux défis : une rafale de demandes reste sans effet (STRIDE L6).
    public static let minCommandInterval: Duration = .seconds(2)
    /// Plafond du verrouillage, imposé par le Mac quelle que soit la durée demandée (STRIDE L5).
    /// PROPOSITION à valider : 15 minutes, la valeur citée dans le STRIDE.
    public static let maxLockSeconds: UInt32 = 15 * 60
}
