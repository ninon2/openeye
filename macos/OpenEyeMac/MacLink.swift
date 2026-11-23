import Foundation
import MultipeerConnectivity

/// Transport côté Mac (docs/architecture.md §6). Il ne fait que transporter des octets :
/// toute la sécurité repose sur le handshake et le canal d'OpenEyeCore.
/// Les rappels sont toujours livrés sur le fil principal.
final class MacLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onAdvertisingFailed: (() -> Void)?

    private let peer: MCPeerID
    private var session: MCSession
    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        // Aucune information de découverte : rien d'identifiant n'est diffusé.
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "openeye")
        advertiser.delegate = self
        return advertiser
    }()
    /// Pair connecté. Lu et écrit sur le fil principal uniquement.
    private var connectedPeer: MCPeerID?

    override init() {
        peer = MCPeerID(displayName: Self.displayName())
        session = Self.makeSession(peer: peer)
        super.init()
        session.delegate = self
    }

    var isConnected: Bool { connectedPeer != nil }

    func start() {
        advertiser.startAdvertisingPeer()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        disconnect()
    }

    /// Coupe la connexion et prépare une session Multipeer neuve pour la suivante.
    func disconnect() {
        let old = session
        old.delegate = nil
        old.disconnect()
        session = Self.makeSession(peer: peer)
        session.delegate = self
        if connectedPeer != nil {
            connectedPeer = nil
            onDisconnected?()
        }
    }

    /// Envoi ordonné et sans perte : l'anti-rejeu exige exactement le compteur précédent + 1.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let connectedPeer else { return false }
        do {
            try session.send(data, toPeers: [connectedPeer], with: .reliable)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Aides

    private static func makeSession(peer: MCPeerID) -> MCSession {
        MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    }

    /// « OpenEye- » et 4 caractères fixés à l'installation, jamais le nom de l'ordinateur
    /// (il contient souvent le prénom de l'enfant, STRIDE I).
    private static func displayName() -> String {
        let key = "peerSuffix"
        if let suffix = UserDefaults.standard.string(forKey: key) { return "OpenEye-\(suffix)" }
        let suffix = String(UUID().uuidString.prefix(4))
        UserDefaults.standard.set(suffix, forKey: key)
        return "OpenEye-\(suffix)"
    }

    // MARK: - Délégués (appelés hors du fil principal)

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        DispatchQueue.main.async {
            // Une seule connexion à la fois (STRIDE D2).
            let accept = self.connectedPeer == nil && self.session.connectedPeers.isEmpty
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.onAdvertisingFailed?() }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch state {
            case .connected:
                guard self.connectedPeer == nil else {
                    // Un second pair n'a rien à faire ici.
                    session.cancelConnectPeer(peerID)
                    return
                }
                self.connectedPeer = peerID
                self.onConnected?()
            case .notConnected:
                if peerID == self.connectedPeer { self.disconnect() }
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            guard session === self.session, peerID == self.connectedPeer else { return }
            self.onData?(data)
        }
    }

    // Flux et ressources : jamais utilisés par le protocole, donc refusés.
    func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID
    ) {
        stream.close()
    }

    func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {
        progress.cancel()
    }

    func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
}
