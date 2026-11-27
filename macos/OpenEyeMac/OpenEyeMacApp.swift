import CoreImage.CIFilterBuiltins
import OpenEyeCore
import SwiftUI

@main
struct OpenEyeMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.state {
                case let .ready(session):
                    MacRootView(session: session, journal: session.journal)
                case let .failed(message):
                    ContentUnavailableView("Clé du Mac indisponible", systemImage: "key.slash", description: Text(message))
                }
            }
            .frame(minWidth: 520, minHeight: 560)
        }
    }
}

/// Crée la clé du Mac une seule fois, au lancement.
@MainActor
final class AppModel {
    enum State {
        case ready(MacSession)
        case failed(String)
    }

    let state: State

    init() {
        do {
            state = .ready(MacSession(signer: try MacSigner.loadOrCreate()))
        } catch {
            state = .failed("Impossible de créer ou de lire la clé d'identité de ce Mac.")
        }
    }
}

struct MacRootView: View {
    @ObservedObject var session: MacSession
    @ObservedObject var journal: JournalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch session.phase {
            case .pairing:
                PairingPanel(session: session)
            case .streaming, .stopping, .handshake:
                SharingPanel(session: session)
            case .waiting:
                IdlePanel(session: session)
            }
            Divider()
            JournalPanel(journal: journal)
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenEye · Mac supervisé").font(.title2.bold())
                Text(session.status).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(session.isConnected ? "iPhone connecté" : "Aucune connexion",
                      systemImage: session.isConnected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                Text("Ce Mac : \(session.macFingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Clé : \(session.signer.storageDescription)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Repos

private struct IdlePanel: View {
    @ObservedObject var session: MacSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parent = session.parent {
                Label("iPhone appairé : \(parent.shortFingerprint)", systemImage: "checkmark.shield")
                Text("Quand le parent ouvre le visionnage, il voit votre écran et votre caméra en direct. Un bandeau rouge s'affiche en haut de l'écran pendant tout le partage.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Appairer un autre iPhone") { session.startPairing() }
                    Button("Révoquer l'iPhone", role: .destructive) { Task { await session.revoke() } }
                }
            } else {
                Label("Aucun iPhone appairé", systemImage: "iphone.slash")
                Button("Appairer l'iPhone du parent") { session.startPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Appairage

private struct PairingPanel: View {
    @ObservedObject var session: MacSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let code = session.pairingCode {
                Text("Code de vérification").font(.headline)
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                Text("Vérifiez que l'iPhone affiche exactement le même code.").foregroundStyle(.secondary)
                HStack {
                    Button("Les codes correspondent") { session.confirmPairing(codesMatch: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Les codes sont différents", role: .destructive) { session.confirmPairing(codesMatch: false) }
                }
            } else if let text = session.qrText {
                HStack(alignment: .top, spacing: 16) {
                    QRCodeView(text: text).frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scannez ce QR avec l'app OpenEye de l'iPhone du parent.")
                        if let deadline = session.pairingDeadline {
                            Text("Expire \(deadline, style: .relative)").foregroundStyle(.secondary)
                        }
                        #if DEBUG
                        // Essai sur simulateur iOS uniquement (pas de caméra). Absent des builds Release.
                        Button("Copier le texte du QR (debug)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .font(.caption)
                        #endif
                    }
                }
            } else {
                ProgressView("Demande reçue, Face ID sur l'iPhone…")
            }
            Button("Annuler") { session.cancelPairing() }
        }
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR d'appairage")
        } else {
            Text("QR impossible à générer")
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

// MARK: - Partage

private struct SharingPanel: View {
    @ObservedObject var session: MacSession

    #if DEBUG
    private var sendsTestPattern: Bool { session.sendsTestPattern }
    #else
    private var sendsTestPattern: Bool { false }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.isCapturing && sendsTestPattern {
                Label("Mire de test envoyée au parent : votre écran n'est pas partagé", systemImage: "testtube.2")
                    .font(.headline).foregroundStyle(.orange)
                Text("Image générée, rien n'est lu à l'écran. Images envoyées : \(session.framesSent)")
                    .font(.callout).foregroundStyle(.secondary)
            } else if session.isCapturing {
                Label("Votre écran est partagé avec le parent", systemImage: "eye.fill")
                    .font(.headline).foregroundStyle(.red)
                Text("Sans micro, rien n'est enregistré. Images envoyées : \(session.framesSent)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView(session.status)
            }
            if session.cameraActive {
                Label(
                    session.cameraIsTestPattern
                        ? "Caméra : accès refusé, une mire caméra est envoyée à la place"
                        : "Votre caméra est partagée avec le parent pendant tout le visionnage",
                    systemImage: "video.fill"
                )
                .font(.headline).foregroundStyle(.red)
            }
            Button("Arrêter le partage", role: .destructive) { Task { await session.stopSharing() } }
                .disabled(session.phase == .stopping)
        }
    }
}

// MARK: - Journal

private struct JournalPanel: View {
    @ObservedObject var journal: JournalStore
    @State private var verification: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Journal des visionnages").font(.headline)
                Spacer()
                if let verification { Text(verification).font(.callout) }
                Button("Vérifier le journal") { verification = Self.describe(journal.verify()) }
            }
            if let warning = journal.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            List(journal.entries.reversed(), id: \.seq) { entry in
                HStack {
                    Text("#\(entry.seq)").font(.caption.monospaced()).frame(width: 44, alignment: .leading)
                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1_000),
                         format: .dateTime.day().month().hour().minute().second())
                        .font(.caption.monospaced())
                    Text(entry.event.label)
                }
            }
            .frame(minHeight: 160)
        }
    }

    private static func describe(_ result: JournalVerification) -> String {
        switch result {
        case let .valid(count): return "✅ Journal intact (\(count) entrées)"
        case let .altered(position): return "❌ Journal altéré à l'entrée \(position)"
        }
    }
}
