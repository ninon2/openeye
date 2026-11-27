import Foundation
import OpenEyeCore

/// Journal signé et chaîné, dans le conteneur sandbox de l'app (docs/journal.md).
/// Lisible par l'enfant depuis l'interface : c'est aussi un outil de transparence.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    /// Message affiché si l'ancien fichier était illisible.
    @Published private(set) var warning: String?

    private var chain = JournalChain()
    private let signer: MacSigner
    private let fileURL: URL

    init(signer: MacSigner) {
        self.signer = signer
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenEye", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("journal.bin")

        if let data = try? Data(contentsOf: fileURL) {
            do {
                chain = try JournalChain(encoded: data)
            } catch {
                // On ne réécrit jamais par-dessus une preuve : l'ancien fichier est mis de côté.
                let aside = folder.appendingPathComponent("journal-illisible-\(wallClockMilliseconds()).bin")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                warning = "L'ancien journal était illisible : il a été mis de côté et un nouveau a commencé."
            }
        }
        // Purge des entrées de plus de 30 jours, écrite en un remplacement atomique.
        try? chain.purge(now: wallClockMilliseconds(), signer: signer)
        entries = chain.entries
        persist()
    }

    var head: (seq: UInt64, hash: Data) { chain.head }

    func append(_ event: JournalEvent, data: Data = Data()) {
        do {
            try chain.append(event, data: data, timestamp: wallClockMilliseconds(), signer: signer)
            entries = chain.entries
            persist()
        } catch {
            warning = "Impossible d'écrire dans le journal."
        }
    }

    func anchorProof(seq: UInt64) -> JournalAnchorProof { chain.anchorProof(seq: seq) }

    func verify() -> JournalVerification {
        JournalChain.verify(chain.entries, macIdentity: signer.publicKey)
    }

    /// Écriture atomique : une coupure laisse l'ancien fichier complet.
    private func persist() {
        do {
            try chain.encoded.write(to: fileURL, options: [.atomic])
        } catch {
            warning = "Impossible d'enregistrer le journal."
        }
    }
}

extension JournalEvent {
    var label: String {
        switch self {
        case .appStarted: return "App démarrée"
        case .paired: return "iPhone appairé"
        case .revoked: return "iPhone révoqué"
        case .sessionOpened: return "Visionnage ouvert (preuve Face ID)"
        case .sessionClosed: return "Visionnage fermé"
        case .captureStarted: return "Capture démarrée"
        case .captureStopped: return "Capture arrêtée"
        case .permissionDenied: return "Autorisation de capture refusée"
        case .authFailures: return "Paquets invalides en rafale"
        case .purgeCheckpoint: return "Purge des entrées de plus de 30 jours"
        case .lock: return "Écran verrouillé par le parent (preuve Face ID)"
        case .unlock: return "Écran déverrouillé par le parent (preuve Face ID)"
        }
    }
}
