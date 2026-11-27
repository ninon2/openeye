import Foundation

/// Image encodée complète, prête à décoder.
public struct VideoFrame: Equatable, Sendable {
    public let id: UInt32
    public let isKeyFrame: Bool
    public let data: Data
}

/// Côté iPhone : recompose les images, en mémoire bornée (STRIDE D3).
/// Seules des images décodables sortent : une image clé, ou la suite immédiate de la précédente.
public struct FrameAssembler {
    private struct Pending {
        let count: Int
        let isKeyFrame: Bool
        let startedAt: ContinuousClock.Instant
        var parts: [Int: Data]
    }

    private var pending: [UInt32: Pending] = [:]
    /// Toute image de numéro inférieur ou égal est terminée ou jetée.
    private var closedUpTo: UInt32 = 0
    /// Dernière image rendue : la suivante n'est décodable que si elle la suit, ou si elle est clé.
    private var lastDelivered: UInt32?

    var pendingCount: Int { pending.count }
    var pendingBytes: Int { pending.values.reduce(0) { $0 + $1.parts.values.reduce(0) { $0 + $1.count } } }

    public init() {}

    /// Vide la mémoire : fin de session ou passage en arrière-plan.
    public mutating func reset() {
        self = FrameAssembler()
    }

    /// Jette les images incomplètes trop anciennes. À appeler aussi régulièrement sans paquet reçu.
    public mutating func purge(now: ContinuousClock.Instant) {
        let expired = pending.filter { $0.value.startedAt.duration(to: now) >= Limits.assemblyTimeout }
        if let newest = expired.keys.max() { close(newest) }
    }

    /// Renvoie une image quand elle est complète ET décodable, sinon nil.
    public mutating func add(_ payload: Data, now: ContinuousClock.Instant) throws -> VideoFrame? {
        purge(now: now)
        let fragment = try VideoFragment(payload: payload)
        let id = fragment.frameID

        // Reste d'une image déjà rendue ou jetée : sans intérêt, mais pas hostile.
        guard id > closedUpTo else { return nil }

        if let existing = pending[id] {
            guard existing.count == fragment.count, existing.isKeyFrame == fragment.isKeyFrame,
                  existing.parts[fragment.index] == nil
            else {
                close(id)
                throw VideoError.inconsistentFragment
            }
            pending[id]?.parts[fragment.index] = fragment.data
        } else {
            if pending.count >= Limits.maxPendingFrames, let oldest = pending.keys.min() {
                close(oldest)
                // L'image reçue peut être encore plus ancienne que celle qu'on vient de jeter.
                guard id > closedUpTo else { return nil }
            }
            pending[id] = Pending(
                count: fragment.count, isKeyFrame: fragment.isKeyFrame, startedAt: now,
                parts: [fragment.index: fragment.data]
            )
        }

        guard let complete = pending[id], complete.parts.count == complete.count else { return nil }
        close(id)

        // Après une perte, on attend la prochaine image clé.
        let followsLast = lastDelivered.map { $0 < id && id - $0 == 1 } ?? false
        guard complete.isKeyFrame || followsLast else { return nil }
        lastDelivered = id

        let data = (0..<complete.count).reduce(into: Data()) { $0 += complete.parts[$1] ?? Data() }
        return VideoFrame(id: id, isKeyFrame: complete.isKeyFrame, data: data)
    }

    /// Termine `id` et toutes les images plus anciennes encore incomplètes.
    private mutating func close(_ id: UInt32) {
        closedUpTo = max(closedUpTo, id)
        pending = pending.filter { $0.key > closedUpTo }
    }
}
