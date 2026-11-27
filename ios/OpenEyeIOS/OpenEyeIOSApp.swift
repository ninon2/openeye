import OpenEyeCore
import SwiftUI

@main
struct OpenEyeIOSApp: App {
    @StateObject private var session = ParentSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    // Arrière-plan : iOS suspendrait l'app de toute façon. On ferme proprement (Close),
                    // et le Mac arrête sa capture (docs/architecture.md §4).
                    if phase == .background { session.stopViewing(reason: .background) }
                }
        }
    }
}

struct RootView: View {
    @ObservedObject var session: ParentSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenCaptured = UIScreen.main.isCaptured

    /// Le flux est masqué dans l'aperçu multitâche et pendant un enregistrement ou une recopie (STRIDE I4, I5).
    private var shielded: Bool { scenePhase != .active || screenCaptured }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("OpenEye")
                .toolbar {
                    if session.macFingerprint != nil, session.phase == .paired {
                        Menu {
                            Button("Oublier ce Mac", role: .destructive) { session.forgetMac() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Options")
                    }
                }
        }
        .overlay {
            if shielded { PrivacyShield() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = UIScreen.main.isCaptured
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .unpaired:
            UnpairedView(session: session)
        case .scanning:
            ScanView(session: session)
        case .pairing, .connecting, .authorizing:
            ProgressStateView(message: session.status)
        case let .confirmCode(code):
            ConfirmCodeView(session: session, code: code)
        case .paired:
            PairedView(session: session)
        case .viewing, .unreachable:
            ViewerView(session: session)
        }
    }
}

// MARK: - Appairage

private struct UnpairedView: View {
    @ObservedObject var session: ParentSession

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Appairer le Mac").font(.title2.bold())
            Text("Sur le Mac, ouvrez OpenEye et choisissez « Appairer l'iPhone du parent », puis scannez le QR affiché.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if !session.status.isEmpty {
                Text(session.status).font(.callout).multilineTextAlignment(.center)
            }
            Button("Scanner le QR") { session.startScanning() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct ScanView: View {
    @ObservedObject var session: ParentSession
    @State private var denied = false
    @State private var pasted = ""

    var body: some View {
        VStack(spacing: 12) {
            #if targetEnvironment(simulator)
            // Le simulateur n'a pas de caméra : collage du texte copié depuis le Mac (build Debug).
            Text("Simulateur : collez le texte du QR copié sur le Mac.").font(.callout)
            TextField("Texte du QR", text: $pasted, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                .accessibilityIdentifier("qrTextField")
            Button("Valider") { session.scanned(pasted) }
                .buttonStyle(.borderedProminent).disabled(pasted.isEmpty)
            #else
            if denied {
                ContentUnavailableView(
                    "Caméra refusée", systemImage: "camera.fill",
                    description: Text("Autorisez la caméra dans Réglages pour scanner le QR.")
                )
            } else {
                QRScannerView(onCode: { session.scanned($0) }, onDenied: { denied = true })
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Viseur de la caméra")
            }
            #endif
            Button("Annuler") { session.cancelScanning() }
        }
        .padding()
    }
}

private struct ConfirmCodeView: View {
    @ObservedObject var session: ParentSession
    let code: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Code de vérification").font(.headline)
            Text(code.prefix(3) + " " + code.suffix(3))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            Text("Le Mac doit afficher exactement le même code.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(session.status).font(.callout).multilineTextAlignment(.center)
            Button("Les codes correspondent") { session.confirmCode(true) }
                .buttonStyle(.borderedProminent)
            Button("Les codes sont différents", role: .destructive) { session.confirmCode(false) }
        }
        .padding()
    }
}

private struct ProgressStateView: View {
    let message: String

    var body: some View {
        ProgressView(message).padding()
    }
}

// MARK: - Visionnage

private struct PairedView: View {
    @ObservedObject var session: ParentSession

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer").font(.system(size: 64)).foregroundStyle(.tint)
            if let fingerprint = session.macFingerprint {
                Text("Mac appairé · \(fingerprint)").font(.callout.monospaced())
            }
            if !session.status.isEmpty {
                Text(session.status).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            JournalNoticeView(session: session)
            Button {
                session.startViewing()
            } label: {
                Label("Voir l'écran (Face ID)", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
            Text("Vous voyez l'écran et la caméra du Mac en direct. L'enfant voit un bandeau rouge pendant tout le visionnage. Rien n'est enregistré.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ViewerView: View {
    @ObservedObject var session: ParentSession

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                VideoView(renderer: session.renderer)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Écran du Mac en direct")
                if !session.hasVideo {
                    ProgressView(session.captureNotice ?? "En attente de la première image…").tint(.white)
                        .foregroundStyle(.white)
                }
                if session.phase == .unreachable {
                    Color.black.opacity(0.7).clipShape(RoundedRectangle(cornerRadius: 12))
                    Label("Mac injoignable", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.bold()).foregroundStyle(.yellow)
                }
            }
            if session.phase == .unreachable {
                Text(session.status).font(.callout).multilineTextAlignment(.center)
                Button("Relancer le visionnage (Face ID)") { session.startViewing() }
                    .buttonStyle(.borderedProminent)
            } else if let notice = session.captureNotice, session.hasVideo {
                Label(notice, systemImage: "info.circle").font(.callout)
            } else {
                Label("En direct · écran et caméra, rien n'est enregistré", systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LockControls(session: session)
            JournalNoticeView(session: session)
            Button("Arrêter", role: .destructive) { session.stopViewing(reason: .userStop) }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Verrouiller / Déverrouiller : Face ID à chaque commande, plafond de durée appliqué par le Mac.
private struct LockControls: View {
    @ObservedObject var session: ParentSession

    /// 30 s pour les essais et la démo ; le Mac plafonne à 15 min.
    private let lockDurations: [UInt32] = [30, 5 * 60, 10 * 60, 15 * 60]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(lockDurations, id: \.self) { seconds in
                        Button(ParentSession.describe(seconds: seconds)) { session.send(.lock, seconds: seconds) }
                    }
                } label: {
                    Label("Verrouiller", systemImage: "lock.fill")
                }
                .buttonStyle(.bordered)
                Button {
                    session.send(.unlock)
                } label: {
                    Label("Déverrouiller", systemImage: "lock.open.fill")
                }
                .buttonStyle(.bordered)
            }
            .disabled(session.commandInFlight || session.phase != .viewing)
            if session.commandInFlight {
                ProgressView(session.commandStepText).font(.callout)
            } else if let notice = session.commandNotice {
                Text(notice).font(.callout).multilineTextAlignment(.center)
            }
        }
    }
}

private struct JournalNoticeView: View {
    @ObservedObject var session: ParentSession

    var body: some View {
        if let notice = session.journalNotice {
            VStack(spacing: 8) {
                Label(notice, systemImage: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Button("J'ai lu ce message") { session.acknowledgeJournalNotice() }.font(.callout)
            }
            .padding()
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Recouvre tout : l'aperçu multitâche et les enregistrements d'écran ne montrent jamais le flux.
private struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Label("OpenEye", systemImage: "eye.slash").font(.title2)
        }
        .ignoresSafeArea()
        .accessibilityLabel("Contenu masqué")
    }
}
