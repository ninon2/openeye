import AppKit
import SwiftUI

/// Bandeau de supervision : toujours au premier plan, sur tous les bureaux, impossible à masquer
/// depuis l'app (docs/architecture.md §4, STRIDE A7). Il s'affiche AVANT la capture et disparaît APRÈS.
@MainActor
final class Indicator {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Renvoie faux si le bandeau n'a pas pu être affiché : la capture ne doit alors pas démarrer.
    func show() -> Bool {
        if let panel, panel.isVisible { return true }
        guard let screen = NSScreen.main else { return false }
        let size = NSSize(width: 300, height: 30)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        // Au-dessus de l'écran de blocage (.screenSaver) : le partage reste visible même verrouillé.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: IndicatorBanner().frame(width: size.width, height: size.height))
        panel.orderFrontRegardless()
        self.panel = panel
        return panel.isVisible
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct IndicatorBanner: View {
    var body: some View {
        Label("Écran partagé avec le parent", systemImage: "eye.fill")
            .font(.callout.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.red, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Écran actuellement partagé avec le parent")
    }
}

// MARK: - Écran de blocage (extension J4)

/// Écran de blocage OpenEye (STRIDE §5 bis, option A) : plein écran, au-dessus de tout, sur tous les écrans.
/// Ce n'est PAS un verrouillage de session macOS : aucune API publique ne le permet (limite L9).
@MainActor
final class LockScreen {
    /// Lu par le délégué de l'app pour refuser « Quitter » pendant le blocage.
    static private(set) var isActive = false

    private var windows: [NSWindow] = []

    /// Options publiques d'AppKit : pas de Dock, pas de barre des menus, pas de changement d'app ni de « Forcer à quitter ».
    private static let kiosk: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
    ]

    func show(until end: Date) {
        hide()
        for screen in NSScreen.screens {
            let window = LockWindow(
                contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = NSHostingView(rootView: LockBanner(end: end))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate()
        NSApp.presentationOptions = Self.kiosk
        Self.isActive = true
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if Self.isActive { NSApp.presentationOptions = [] }
        Self.isActive = false
    }
}

/// Une fenêtre sans bordure ne devient pas clé par défaut : sans cela, le clavier irait aux autres fenêtres.
private final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// L4 : seulement qui a verrouillé et jusqu'à quand, rien d'autre.
private struct LockBanner: View {
    let end: Date

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 72))
            Text("Verrouillé par ton parent").font(.largeTitle.bold())
            Text("Jusqu'à \(end, format: .dateTime.hour().minute())").font(.title2)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement(children: .combine)
    }
}

/// Refuse « Quitter » (⌘Q) pendant le blocage. Tuer l'app reste possible pour un administrateur (L9) :
/// le parent le voit alors comme « Mac injoignable ».
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LockScreen.isActive ? .terminateCancel : .terminateNow
    }
}
