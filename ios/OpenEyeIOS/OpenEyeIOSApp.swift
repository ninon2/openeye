// PROTOTYPE JETABLE (tâches 15 et 16) : ne jamais fusionner dans main.
// Aucune authentification ici : la liaison ne transporte que des octets synthétiques.

import CryptoKit
import LocalAuthentication
import MultipeerConnectivity
import Security
import SwiftUI

@main
struct OpenEyeIOSApp: App {
    @StateObject private var faceID = FaceIDModel()
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            List {
                Section("16 · Face ID et Secure Enclave") {
                    Button("1. Créer la clé") { faceID.create() }
                    Button("2. Signer (Face ID)") { faceID.sign() }.disabled(faceID.isBusy)
                    Button("3. Effacer la clé", role: .destructive) { faceID.delete() }
                    Text(faceID.status)
                }
                Section("15 · Liaison Multipeer") {
                    Button(link.isSearching ? "Arrêter la recherche" : "Chercher le Mac") { link.toggle() }
                    Text(link.status)
                    Text(link.measures).font(.system(.footnote, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - Tâche 16

@MainActor
final class FaceIDModel: ObservableObject {
    @Published var status = "Aucun essai"
    @Published var isBusy = false

    func create() { status = KeyLab.create() }
    func delete() { status = KeyLab.delete() }

    func sign() {
        isBusy = true
        status = "Face ID…"
        Task {
            // Hors du fil principal : l'appel attend Face ID.
            status = await Task.detached { KeyLab.sign() }.value
            isBusy = false
        }
    }
}

enum KeyLab {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "fr.openeye.m2.proto16",
        kSecAttrAccount: "parent",
    ]

    static func create() -> String {
        guard SecureEnclave.isAvailable else { return "Secure Enclave indisponible" }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], nil
        ) else { return "Contrôle d'accès impossible" }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            SecItemDelete(query as CFDictionary)
            var item = query
            // Blob chiffré par la Secure Enclave : ce n'est pas la clé, et il est inutilisable ailleurs.
            item[kSecValueData] = key.dataRepresentation
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            return result == errSecSuccess ? "Clé créée et enregistrée" : "Keychain : erreur \(result)"
        } catch {
            return "Création refusée : \(code(error))"
        }
    }

    static func sign() -> String {
        var search = query
        search[kSecReturnData] = true
        var found: CFTypeRef?
        let result = SecItemCopyMatching(search as CFDictionary, &found)
        guard result == errSecSuccess, let blob = found as? Data else { return "Aucune clé : erreur \(result)" }

        // Contexte neuf et durée nulle : Face ID est redemandé à chaque signature.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = "" // pas de bouton « saisir le code »
        context.localizedReason = "Autoriser le visionnage"
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            let message = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let signature = try key.signature(for: message)
            return key.publicKey.isValidSignature(signature, for: message)
                ? "Signature produite et valide" : "Signature INVALIDE"
        } catch {
            return "Aucune signature : \(code(error))"
        }
    }

    static func delete() -> String {
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess ? "Clé effacée" : "Rien à effacer (\(result))"
    }

    private static func code(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

// MARK: - Tâche 15

final class PhoneLink: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    @Published var status = "Arrêté"
    @Published var measures = ""
    @Published var isSearching = false

    // Jamais le nom de l'appareil : il contient souvent un prénom.
    private let peer = MCPeerID(displayName: "OpenEye-\(UUID().uuidString.prefix(4))")
    private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: "openeye")
        browser.delegate = self
        return browser
    }()
    private var timer: Timer?

    // Mesures, lues et écrites sur le fil principal uniquement.
    private var pings: [UInt64: ContinuousClock.Instant] = [:]
    private var nextPing: UInt64 = 0
    private var roundTrips: [Double] = []
    private var blocks = 0, bytes = 0, missing = 0
    private var expectedBlock: UInt32?
    private var firstBlock: ContinuousClock.Instant?
    private var lastBlock: ContinuousClock.Instant?
    private var longestGap = 0.0

    func toggle() {
        if isSearching {
            browser.stopBrowsingForPeers()
            session.disconnect()
            timer?.invalidate()
            isSearching = false
            status = "Arrêté"
        } else {
            resetMeasures()
            browser.startBrowsingForPeers()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            isSearching = true
            status = "Recherche…"
        }
    }

    private func resetMeasures() {
        pings = [:]; roundTrips = []; nextPing = 0
        blocks = 0; bytes = 0; missing = 0
        expectedBlock = nil; firstBlock = nil; lastBlock = nil; longestGap = 0
    }

    private func tick() {
        if !session.connectedPeers.isEmpty {
            nextPing += 1
            pings = pings.filter { $0.key + 30 > nextPing } // mémoire bornée
            pings[nextPing] = ContinuousClock().now
            let message = Data([1]) + withUnsafeBytes(of: nextPing.bigEndian) { Data($0) }
            try? session.send(message, toPeers: session.connectedPeers, with: .reliable)
        }
        let recent = roundTrips.suffix(30)
        let average = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
        var rate = 0.0
        if let firstBlock, let lastBlock {
            let duration = Self.seconds(firstBlock.duration(to: lastBlock))
            if duration > 0 { rate = Double(bytes) * 8 / duration / 1_000 }
        }
        measures = """
        aller-retour  \(String(format: "%.1f", average)) ms (max \(String(format: "%.1f", recent.max() ?? 0)))
        blocs         \(blocks) (manquants : \(missing))
        débit reçu    \(Int(rate)) kbit/s
        plus long trou \(String(format: "%.0f", longestGap * 1_000)) ms
        """
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Même pour un prototype, une donnée reçue est validée avant usage.
    private func handle(_ data: Data) {
        let bytes = [UInt8](data)
        switch bytes.first {
        case 2 where bytes.count == 9:
            let id = bytes[1...].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard let sent = pings.removeValue(forKey: id) else { return }
            roundTrips.append(Self.seconds(sent.duration(to: ContinuousClock().now)) * 1_000)
            if roundTrips.count > 1_000 { roundTrips.removeFirst(500) }
        case 3 where bytes.count == 16_384:
            let id = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let now = ContinuousClock().now
            if id == 0 { // nouvel envoi
                blocks = 0; self.bytes = 0; missing = 0; expectedBlock = nil
                firstBlock = now; lastBlock = nil; longestGap = 0
            }
            if let expectedBlock, id > expectedBlock { missing += Int(id - expectedBlock) }
            expectedBlock = id == .max ? nil : id + 1
            if let lastBlock { longestGap = max(longestGap, Self.seconds(lastBlock.duration(to: now))) }
            lastBlock = now
            blocks += 1
            self.bytes += bytes.count
        default:
            return
        }
    }

    // MARK: Délégués

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.status = "Recherche refusée (réseau local ?)" }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected: self.status = "Connecté"
            case .connecting: self.status = "Connexion…"
            default:
                self.status = "Déconnecté"
                // Relance la découverte pour mesurer la reconnexion.
                if self.isSearching {
                    self.browser.stopBrowsingForPeers()
                    self.browser.startBrowsingForPeers()
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 16_384 else { return }
        DispatchQueue.main.async { self.handle(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
