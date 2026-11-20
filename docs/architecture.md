# Architecture — OpenEye (J2, tâche 11)

Statut : **brouillon B, à relire par A** · Références : [stride.md](stride.md), [protocole.md](protocole.md), [journal.md](journal.md), [choix-crypto.md](choix-crypto.md)

## 1. Vue d'ensemble

```text
 ┌──────────────── Mac de l'enfant · OpenEyeMac ────────────────┐            ┌──────────────── iPhone du parent · OpenEyeIOS ───────────────┐
 │                                                              │            │                                                              │
 │  ScreenCapturer ──▶ VideoEncoder ──▶ ┐                       │            │                       ┌──▶ VideoDecoder ──▶ ViewerView            │
 │  (ScreenCaptureKit)  (VideoToolbox)  │                       │            │                       │    (VideoToolbox)    (SwiftUI)             │
 │                                      ▼                       │   réseau   │                       │                                          │
 │  SupervisionIndicator ◀── MacSession ──▶ SecureChannel ──────┼─NON FIABLE─┼──▶ SecureChannel ──▶ ParentSession ──▶ UnreachableAlert       │
 │  (barre des menus +      (machine     (OpenEyeCore)          │ Multipeer  │   (OpenEyeCore)        (machine                                  │
 │   fenêtre flottante)     d'états)                            │            │                        d'états) ◀── SecureEnclaveSigner ◀─ Face ID│
 │  JournalStore ◀──────────┘                                   │            │                                     (Secure Enclave + LA)     │
 │  IdentityStore (clé du Mac)  PairingView (QR + code)         │            │  KeychainStore  QRScanner (AVFoundation)  PrivacyShield       │
 └──────────────────────────────────────────────────────────────┘            └──────────────────────────────────────────────────────────────┘
                     ▲                                                                              ▲
                     └──────── OpenEyeCore (Swift Package partagé, sans UI, testé par XCTest) ──────┘
```

**Sens des flux :**

- Vidéo et heartbeat : Mac → iPhone.
- Autorisation de visionnage, keepalive et (extension) commandes : iPhone → Mac.
- Appairage : une seule fois, QR (canal visuel) puis échange réseau.

## 2. Découpage en trois parties

| Partie | Contenu | Pourquoi ce découpage |
|---|---|---|
| **OpenEyeCore** | Format des paquets, validation, handshake, canal chiffré, anti-rejeu, appairage (QR, code de vérification), journal chaîné | Tout le code de sécurité est **au même endroit**, partagé par les deux apps et **testable par XCTest sans appareil**. Le même code chiffre côté Mac et déchiffre côté iPhone : pas de divergence possible. |
| **OpenEyeMac** | Capture, encodage, indicateur, transport côté Mac, stockage de la clé du Mac, journal, interface d'appairage et de révocation | Tout ce qui dépend de macOS (ScreenCaptureKit, AppKit). |
| **OpenEyeIOS** | Lecture du QR, Face ID et Secure Enclave, Keychain, transport côté iPhone, décodage et affichage, alerte | Tout ce qui dépend d'iOS (LocalAuthentication, AVFoundation). |

**Règle de dépendance :** les apps dépendent d'OpenEyeCore, jamais l'inverse. OpenEyeCore n'importe que `Foundation` et `CryptoKit`. Pas d'UI, pas de Multipeer, pas de Secure Enclave directement.

**Pourquoi :** si OpenEyeCore n'importe pas Multipeer ni la Secure Enclave, on peut remplacer le transport (Multipeer est déprécié dans Xcode 27, voir §6) ou simuler la Secure Enclave dans les tests sans toucher au code crypto.

## 3. Modules d'OpenEyeCore

| Module | Rôle | Testé par |
|---|---|---|
| `Wire/Limits` | Toutes les bornes (tailles, délais, compteurs) en un seul endroit | Revue |
| `Wire/FrameHeader`, `Wire/FrameCodec` | Encodage et décodage binaire de l'en-tête, validation avant tout traitement | XCTest : version, type, taille, longueur incohérente |
| `Crypto/Signer` (protocole) | Interface « signe ces octets » | Implémentée par la Secure Enclave (iPhone), par la clé du Mac, et par une clé logicielle **dans les tests uniquement** |
| `Crypto/Transcript` | Encodage canonique et hash du transcript du handshake | XCTest : vecteurs connus |
| `Crypto/Handshake` | Machines d'états initiateur (iPhone) et répondeur (Mac) | XCTest : mauvaise clé, mauvais défi, rejeu, substitution d'une clé éphémère |
| `Crypto/SecureChannel` | Scellement et ouverture AES-GCM, compteurs, anti-rejeu | XCTest : altération, rejeu, ancienne session, compteur épuisé |
| `Pairing/QRPayload`, `Pairing/PairingProtocol` | Contenu du QR, engagement, code de vérification, messages d'appairage | XCTest : QR expiré ou réutilisé, MAC invalide, engagement faux |
| `Video/FrameAssembler` | Découpage et réassemblage borné des images | XCTest : fragments orphelins, dépassement de bornes |
| `Journal/JournalChain` | Ajout, signature, vérification du chaînage | XCTest : modification, suppression au milieu, ancre de troncature |
| `Transport` (protocole) | `send(Data)`, réception de `Data`, événements de connexion | Implémenté par Multipeer dans chaque app, et par un faux transport en mémoire dans les tests |

## 4. Machines d'états

### Mac (`MacSession`)

```text
 NonAppairé ──QR affiché──▶ Appairage ──code confirmé──▶ EnAttente ◀────────────────────────────┐
                                                           │ Hello reçu                         │
                                                           ▼                                    │
                                                       Handshake ──échec / délai 30 s─────────▶ │
                                                           │ Auth valide                        │
                                                           ▼                                    │
                                                   IndicateurAffiché ──échec indicateur──────▶ │
                                                           │ indicateur confirmé visible        │
                                                           ▼                                    │
                                                       Diffusion ──Close / keepalive perdu / ──▶ Arrêt ─┘
                                                                     erreur / permission retirée   (capture arrêtée
                                                                                                     PUIS indicateur
                                                                                                     masqué, clés effacées)
```

**Règles d'échec sûr (transparence) :**

1. L'indicateur s'affiche **avant** le démarrage de la capture. Si l'indicateur échoue, la capture ne démarre pas.
2. À l'arrêt, la capture est stoppée **avant** que l'indicateur disparaisse.
3. Toute erreur (déchiffrement en rafale, transport perdu, keepalive de l'iPhone absent, permission retirée) mène à l'état **Arrêt** : la capture est coupée et les clés de session sont effacées.

**Pourquoi :** avec cet ordre, il n'existe aucun instant où l'écran est capturé sans indicateur visible (STRIDE A7). Et si l'iPhone disparaît, le Mac arrête de diffuser au lieu d'envoyer l'écran dans le vide (minimisation).

### iPhone (`ParentSession`)

```text
 NonAppairé ──QR scanné + code confirmé + Face ID──▶ Appairé ──« Voir »──▶ Connexion ──Challenge valide──▶ AttenteFaceID
                                                        ▲                      │ délai 10 s                   │ Face ID OK → Auth
                                                        │                      ▼                              ▼
                                                        └──────── Fermé ◀── Injoignable ◀──heartbeat absent── Visionnage
                                                                    ▲                                         │
                                                                    └──app en arrière-plan / bouton Arrêter──┘
```

- **Face ID annulé** → retour à **Appairé**. Aucune signature n'est produite et aucun flux n'est ouvert.
- **App en arrière-plan** → la session est fermée (paquet `Close`) et les clés sont effacées.
  **Pourquoi :** sans notifications push, iOS suspend l'app de toute façon. Fermer proprement est plus sûr que de laisser une session à moitié vivante, et le Mac arrête alors sa capture.

## 5. Stockage

| Donnée | Où | Protection | Pourquoi |
|---|---|---|---|
| Clé de signature du parent | Secure Enclave de l'iPhone. Seul le blob chiffré est stocké dans le Keychain. | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.privateKeyUsage` + `.biometryCurrentSet` | La clé ne sort jamais de la puce. Face ID est exigé à chaque usage. La clé est invalidée si un nouveau visage est enrôlé. |
| Clé publique du Mac appairé | Keychain de l'iPhone | `WhenPasscodeSetThisDeviceOnly` | Liée à l'appareil, non synchronisée, illisible sur un téléphone sans code. |
| Clé d'identité du Mac | Secure Enclave du Mac si disponible, sinon Keychain | Sans biométrie : le Mac doit signer sans personne devant | **À vérifier au prototype J2 :** modèle du Mac, accès au Keychain « data protection » depuis la sandbox. |
| Clé publique du parent (côté Mac) | Keychain du Mac | Idem | |
| Clés de session, clés éphémères | **Mémoire uniquement** | Effacées à la fin de la session | Jamais écrites sur disque : la confidentialité persistante est préservée. |
| Journal | Fichier dans le conteneur sandbox du Mac, plus une ancre côté iPhone | Signé et chaîné, voir [journal.md](journal.md) | |
| Images de l'écran | **Nulle part** | — | Direct uniquement, aucun enregistrement. |

## 6. Transport : Multipeer Connectivity

- **Type de service :** `openeye`, déclaré en `_openeye._tcp` et `_openeye._udp` dans les deux `Info.plist`.
- **Rôles :** le Mac **annonce** (`MCNearbyServiceAdvertiser`), sans `discoveryInfo`. L'iPhone **cherche** (`MCNearbyServiceBrowser`).
  **Pourquoi :** le Mac est l'appareil qui attend. On n'annonce rien d'identifiant dans la découverte.
- **Nom affiché (`MCPeerID`) :** `OpenEye-` suivi de 4 caractères aléatoires fixés à l'installation. **Jamais le nom de l'ordinateur.**
  **Pourquoi :** le nom d'un Mac contient souvent le prénom de l'enfant (« MacBook de Léa »), une donnée personnelle diffusée à tout le voisinage radio (STRIDE I).
- **Chiffrement Multipeer :** `.required`, en défense en profondeur. **On ne compte pas dessus :** il n'authentifie personne (pas d'identité). Toute la sécurité repose sur notre propre canal.
- **Mode d'envoi :** `.reliable` (ordonné, sans perte) pour tous les messages au MVP.
  **Pourquoi :** cela permet un anti-rejeu strict, où chaque compteur vaut exactement le précédent + 1, ce qui est le plus simple à prouver. En cas d'engorgement, c'est l'émetteur qui jette des images (file bornée). Le mode `.unreliable` avec fenêtre glissante est une extension (débit adaptatif).
- **Connexions :** le Mac accepte une seule connexion à la fois. Le `Hello` doit arriver dans les **10 s** qui suivent la connexion, puis l'`Auth` dans les **30 s** qui suivent l'envoi du `Challenge`. Sinon, déconnexion.
  **Pourquoi deux délais :** le Mac ne peut pas savoir *avant* le handshake qui l'invite. Il borne donc le coût d'un intrus (STRIDE D2). Envoyer `Hello` est automatique, d'où un délai court de 10 s. Entre `Challenge` et `Auth`, un humain doit passer Face ID, éventuellement après un échec, d'où 30 s. C'est aussi la durée de vie du défi `nM` (E2).

**Dépréciation :** Multipeer est déprécié depuis Xcode 27 ([TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)). Grâce au protocole `Transport`, le passer à `Network.framework` ne touche ni au protocole ni à la crypto. On garde Multipeer au MVP parce que le dossier le prévoit et qu'il fonctionne sans box.

## 7. Vidéo

| Paramètre | Valeur initiale | Pourquoi |
|---|---|---|
| Source | Écran principal entier (`SCContentFilter` sur l'écran), **sans audio**, sans curseur caché | Minimisation : pas d'audio. Un écran entier, c'est ce que l'enfant sait être partagé. |
| Résolution | Largeur 960 px, proportions conservées | Lisible sur un iPhone, débit modéré. **À recalibrer** avec les mesures d'A (tâche 17). |
| Cadence | 10 images/s | Suffisant pour « voir ce qu'il fait », et divise le débit par 3 par rapport à 30 images/s. |
| Codec | H.264 matériel (`VTCompressionSession`), temps réel, sans images B, image clé toutes les 2 s | Matériel = rapide et sans dépendance externe. Sans images B = latence faible. L'image clé régulière permet de reprendre après une perte. |
| Débit cible | ~1 Mbit/s | À recalibrer. |
| File d'envoi | 3 images au maximum. Au-delà, on jette les plus anciennes jusqu'à la prochaine image clé. | Mémoire bornée (STRIDE D3), latence maîtrisée. |
| Affichage iPhone | `AVSampleBufferDisplayLayer` ou `VTDecompressionSession` | Décodage matériel. |
| Protection iPhone | Vue masquée si l'app devient inactive (aperçu multitâche) ou si l'écran est enregistré ou recopié | STRIDE I4 et I5. |

## 8. Paramètres globaux

Toutes ces valeurs vivent dans `OpenEyeCore/Wire/Limits`. Elles sont **initiales, à recalibrer après mesures**.

| Paramètre | Valeur | Raison |
|---|---|---|
| Validité du QR d'appairage | 120 s | Laisse le temps de scanner, mais limite l'intérêt d'une photo du QR (S4). |
| Délai connexion → `Hello` | 10 s | Étape automatique : un intrus ne garde pas la connexion unique du Mac (D2). |
| Délai `Challenge` → `Auth` (validité de `nM`) | 30 s | Le temps de passer Face ID, puis le défi expire (E2). |
| Période du heartbeat (Mac → iPhone) | 2 s | |
| Alerte « Mac injoignable » | 3 heartbeats manqués = 6 s | Un raté isolé ne déclenche pas d'alerte, une coupure réelle est vue vite (D1). |
| Période du keepalive (iPhone → Mac) | 2 s | |
| Arrêt de la capture sans keepalive | 10 s | Le Mac arrête de diffuser si personne ne regarde. |
| Taille maximale d'un paquet | 65 536 octets | Rejet immédiat au-delà (D2). |
| Taille maximale d'un fragment vidéo | 16 384 octets | |
| Taille maximale d'une image réassemblée | 1 Mio, 64 fragments au maximum | D3 |
| Images en cours de réassemblage | 4 au maximum, purge après 1 s | D3 |
| Tolérance d'horloge | ± 30 s | Au-delà, le paquet est refusé et l'erreur « horloges désynchronisées » est affichée. |
| Échecs d'authentification avant fermeture | 20 en 10 s | Au-delà, la session est fermée (échec sûr) et l'incident est journalisé une seule fois. |
| Durée maximale d'une session | 60 min, puis nouveau handshake avec Face ID | Limite l'usage d'une même clé. La rotation toutes les 5 min est une extension. |
