import Foundation
import MultipeerConnectivity

/// Transport côté iPhone (docs/architecture.md §6) : cherche le Mac, ne transporte que des octets.
/// Les rappels sont toujours livrés sur le fil principal.
final class PhoneLink: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onBrowsingFailed: (() -> Void)?

    // Jamais le nom de l'appareil : il contient souvent un prénom.
    private let peer = MCPeerID(displayName: "OpenEye-\(UUID().uuidString.prefix(4))")
    private var session: MCSession
    private lazy var browser: MCNearbyServiceBrowser = {
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: "openeye")
        browser.delegate = self
        return browser
    }()
    /// Lus et écrits sur le fil principal uniquement.
    private var connectedPeer: MCPeerID?
    private var invitedPeer: MCPeerID?
    private var wantsConnection = false

    override init() {
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    var isConnected: Bool { connectedPeer != nil }

    /// Cherche un Mac OpenEye et s'y connecte. L'identité est vérifiée ensuite par le protocole.
    func connect() {
        disconnect()
        wantsConnection = true
        browser.startBrowsingForPeers()
    }

    func disconnect() {
        wantsConnection = false
        browser.stopBrowsingForPeers()
        let old = session
        old.delegate = nil
        old.disconnect()
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        invitedPeer = nil
        if connectedPeer != nil {
            connectedPeer = nil
            onDisconnected?()
        }
    }

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

    // MARK: - Délégués (appelés hors du fil principal)

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard self.wantsConnection, self.invitedPeer == nil, self.connectedPeer == nil else { return }
            self.invitedPeer = peerID
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.onBrowsingFailed?() }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch state {
            case .connected:
                guard self.connectedPeer == nil else { return }
                self.browser.stopBrowsingForPeers()
                self.connectedPeer = peerID
                self.onConnected?()
            case .notConnected:
                if peerID == self.connectedPeer {
                    self.disconnect()
                } else if peerID == self.invitedPeer {
                    // Invitation refusée ou expirée : on retente avec le prochain Mac trouvé.
                    self.invitedPeer = nil
                    if self.wantsConnection {
                        self.browser.stopBrowsingForPeers()
                        self.browser.startBrowsingForPeers()
                    }
                }
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
