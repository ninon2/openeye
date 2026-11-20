# Protocole OpenEye v1 — appairage, session, paquets (J2, tâches 12 et 13)

Statut : **brouillon B, à relire par A** · Toute primitive vient de **CryptoKit** · Notations en fin de document (§7)

## 1. Identités

| Nom | Où | Type CryptoKit | Usage |
|---|---|---|---|
| `P` (parent) | Secure Enclave de l'iPhone | `SecureEnclave.P256.Signing.PrivateKey`, contrôle d'accès `.privateKeyUsage` + `.biometryCurrentSet` | Signer l'appairage et chaque ouverture de session, après Face ID |
| `M` (Mac) | Secure Enclave du Mac si disponible, sinon Keychain (décision J2) | `P256.Signing.PrivateKey` ou version Secure Enclave | Signer le handshake et le journal |
| `eI`, `eM` | Mémoire, une paire par session | `P256.KeyAgreement.PrivateKey` | Échange ECDH éphémère |

- **Sur le réseau :** les clés publiques circulent en `x963Representation` (65 octets) et les signatures en `rawRepresentation` (64 octets).
  **Pourquoi :** des tailles **fixes** se valident trivialement (on refuse tout ce qui ne fait pas 65 ou 64 octets).
- **Validation des clés :** `P256.*.PublicKey(x963Representation:)` refuse un point hors de la courbe. On ne construit jamais une clé autrement.

## 2. Appairage (une fois, tâche 12)

**Objectif :** l'iPhone apprend `M_pub` de façon authentique, et le Mac apprend `P_pub` de façon authentique.

**Principe :**

- **iPhone → Mac :** le QR est un canal **visuel** que le réseau ne peut ni lire ni modifier. L'iPhone qui le scanne connaît donc le vrai `M_pub`.
- **Mac → iPhone :** il n'y a pas de canal visuel dans ce sens. On l'authentifie par trois mécanismes :
  1. un **secret du QR** : seul celui qui a vu le QR peut appairer ;
  2. un **code de vérification à 6 chiffres** comparé par l'humain sur les deux écrans ;
  3. une **signature Secure Enclave** : on prouve qu'on détient la clé, et Face ID est déjà exigé.

### 2.1 Contenu du QR (affiché par le Mac)

```text
version(1) = 0x01 | pairingID(16, aléatoire) | K_pair(32, aléatoire) | expiry(8, secondes Unix, BE) | M_pub(65)
→ 122 octets, encodés en base64url (~164 caractères)
```

- `pairingID` et `K_pair` sont générés par `SymmetricKey(size: .bits256)` / `SecRandomCopyBytes`. Ils sont **à usage unique** et le Mac les oublie dès la fin de la tentative (succès, échec ou expiration).
- `expiry` = maintenant + 120 s. Le QR disparaît de l'écran à l'expiration.
- **Pourquoi le secret `K_pair` :** sans lui, n'importe quel appareil à portée pourrait lancer un appairage (spam, D2). Avec lui, l'attaquant doit avoir **vu** le QR (S4), dans les 120 s.

### 2.2 Échanges (en clair sur le réseau, mais authentifiés)

Seules des clés publiques et des nonces circulent : la confidentialité n'est pas nécessaire, l'**authenticité** l'est.

`K_mac = HKDF<SHA256>(K_pair, salt: pairingID, info: "OpenEye/v1/pair-mac", 32 octets)`

`hmac = HMAC_Kmac("OpenEye/v1/pair-request" ‖ en-tête(24) ‖ lp(pairingID) ‖ lp(P_pub) ‖ lp(C))`, où l'en-tête est celui du paquet `PairRequest` lui-même (`typ = 0x01`, `sessionID = 0`, `counter = 0`, `len = 145`).

**Pourquoi cette forme exacte :**

- **le libellé** sépare ce HMAC de tout autre usage de `K_mac` (séparation de domaine, comme pour les signatures) ;
- **l'en-tête** lie la version et le type au HMAC : on ne peut pas faire passer ces octets pour un autre message ni pour une autre version du protocole ;
- **`lp`** reprend l'encodage de `TP` et `TH` : un seul encodeur (`Crypto/Transcript`), testé une fois par vecteurs connus, sert partout.

```text
 iPhone                                                                 Mac
   │ scan QR → M_pub, pairingID, K_pair (vérifie expiry, version)        │
   │ nI ← 32 octets aléatoires                                           │
   │ C = SHA256("OpenEye/v1/commit" ‖ P_pub ‖ nI)                        │
   │── PairRequest { pairingID, P_pub, C, HMAC_Kmac(tout ce qui précède) } ──▶ vérifie : pairingID en attente, non expiré,
   │                                                                     │  HMAC valide (comparaison à temps constant),
   │                                                                     │  P_pub valide sur la courbe
   │                                                                     │ nM ← 32 octets aléatoires
   │◀────────────────────────── PairNonce { pairingID, nM } ─────────────│
   │ Face ID → sigP = Sign_P("OpenEye/v1/pair" ‖ TP)                     │
   │── PairReveal { pairingID, nI, sigP } ──────────────────────────────▶│ vérifie : SHA256(… P_pub ‖ nI) == C,
   │                                                                     │  sigP valide avec P_pub sur TP
   │ affiche code = SAS(TP)                       affiche code = SAS(TP) │
   │                     ── l'humain compare les 6 chiffres ──           │
   │                                                                     │ clic « Les codes correspondent » sur le Mac
   │◀──────────── PairAccept { pairingID, sigM = Sign_M("OpenEye/v1/pair-accept" ‖ TP) } ─│ enregistre P_pub, journalise PAIRED,
   │ vérifie sigM avec M_pub (du QR) ; confirmation sur l'iPhone          │  oublie K_pair
   │ enregistre M_pub dans le Keychain                                   │
```

- `TP = SHA256("OpenEye/v1/pair-transcript" ‖ lp(pairingID) ‖ lp(M_pub) ‖ lp(P_pub) ‖ lp(nI) ‖ lp(nM))`
- `SAS(TP) = (UInt32 big-endian des 4 premiers octets de SHA256("OpenEye/v1/sas" ‖ TP)) mod 1 000 000`, affiché sur 6 chiffres.

**Pourquoi un engagement `C` avant de révéler `nI` :** sans lui, un attaquant placé au milieu, qui aurait aussi photographié le QR, pourrait essayer des millions de nonces hors ligne jusqu'à obtenir **le même code à 6 chiffres** des deux côtés : 10⁶ essais prennent quelques millisecondes. Avec l'engagement, chaque camp fixe son nonce **avant** de connaître celui de l'autre. L'attaquant n'a donc qu'**une** chance sur un million, et une seule tentative puisque le QR est à usage unique. C'est le principe de la « comparaison numérique » de Bluetooth.

**Pourquoi le Mac signe `PairAccept` :** l'iPhone vérifie que le Mac du QR a bien accepté **sa** clé `P_pub`. Si un intrus a appairé sa propre clé à la place, la signature porte sur une autre `P_pub` et l'iPhone affiche un échec : la tentative d'attaque devient visible.

**Règles :**

- **Un seul parent par Mac au MVP.** Un nouvel appairage confirmé remplace l'ancien et est journalisé.
- **Révocation :**
  - côté Mac (« Révoquer l'iPhone ») : suppression de `P_pub` et événement `REVOKED` ;
  - côté iPhone (« Oublier ce Mac ») : suppression de `M_pub` et de la clé Secure Enclave de cet appairage.
- **Tout écart** (délai, HMAC, engagement, signature, code refusé par l'humain) → abandon, `pairingID` brûlé, et il faut un nouveau QR.

## 3. Ouverture d'une session de visionnage (à chaque fois, tâche 12)

**Objectif :** prouver à chaque visionnage que c'est le parent (Face ID et Secure Enclave) et le bon Mac, puis dériver des **clés neuves**.

```text
 iPhone (initiateur)                                                     Mac (répondeur)
   │ eI ← nouvelle paire ECDH ; nI ← 32 octets aléatoires                │
   │── Hello { fpP = SHA256(P_pub), eI_pub, nI } ────────────────────────▶│ vérifie : fpP == empreinte du parent enregistré,
   │                                                                     │  eI_pub valide, aucune session déjà en cours
   │                                                                     │ eM ← nouvelle paire ECDH ; nM ← 32 octets aléatoires
   │                                                                     │ TH = SHA256(transcript, voir ci-dessous)
   │◀──────────── Challenge { eM_pub, nM, sigM = Sign_M("OpenEye/v1/sess-mac" ‖ TH) } ─│ démarre un minuteur de 30 s
   │ vérifie sigM avec M_pub enregistré → c'est le bon Mac (S2)          │
   │ Face ID → sigP = Sign_P("OpenEye/v1/sess-parent" ‖ TH)              │
   │── Auth { sigP } ───────────────────────────────────────────────────▶│ vérifie : sigP avec P_pub, nM encore en attente,
   │                                                                     │  minuteur non expiré → nM consommé (E2)
   │ clés ← HKDF(ECDH(eI, eM_pub), TH)        clés ← HKDF(ECDH(eM, eI_pub), TH) │
   │ efface eI                                                           │ efface eM
   │                                                                     │ affiche l'indicateur, PUIS démarre la capture
   │◀──────────── SessionReady (1er paquet chiffré, compteur 1) ─────────│ journalise SESSION_OPENED (avec sigP)
   │ déchiffrement OK = confirmation que les clés sont identiques         │
   │── Keepalive (1er paquet chiffré iPhone → Mac) ─────────────────────▶│
```

`TH = SHA256("OpenEye/v1/session" ‖ lp(M_pub) ‖ lp(P_pub) ‖ lp(eI_pub) ‖ lp(nI) ‖ lp(eM_pub) ‖ lp(nM))`

**Dérivation des clés (CryptoKit) :**

```text
secret   = eX.sharedSecretFromKeyAgreement(with: eY_pub)
K_m2i    = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: TH, sharedInfo: "OpenEye/v1/key/mac->iphone", outputByteCount: 32)
K_i2m    = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: TH, sharedInfo: "OpenEye/v1/key/iphone->mac", outputByteCount: 32)
sessionID = 8 premiers octets de SHA256("OpenEye/v1/sid" ‖ TH)
```

**Pourquoi chaque élément :**

| Élément | Menace couverte | Explication |
|---|---|---|
| Clés éphémères `eI`, `eM` neuves | I1 | Voler plus tard la clé du parent ou du Mac ne permet **pas** de déchiffrer une session passée : les clés de session ne dépendent que des éphémères, effacés (confidentialité persistante). |
| Le transcript `TH` contient **les deux identités et les deux éphémères** | S5 | Chaque signature « verrouille » toute la conversation. Un homme du milieu qui remplace `eI_pub` ou `eM_pub` change `TH`, et les signatures ne vérifient plus. Inclure les identités empêche aussi de faire croire à l'un qu'il parle à quelqu'un d'autre (mauvaise attribution d'identité). |
| Libellés distincts (`sess-mac`, `sess-parent`, `pair`…) | S1, S2 | Une signature produite dans un contexte ne peut pas être réutilisée dans un autre (séparation de domaine). |
| `nM` choisi par le Mac, consommé une seule fois, valable 30 s | E2 | C'est le **défi** du défi-réponse : une ancienne `sigP` capturée porte sur un ancien `nM`, déjà consommé, donc elle est refusée. |
| `nI` choisi par l'iPhone | S2 | Garantit à l'iPhone que la signature du Mac est **fraîche** (pas un ancien `Challenge` rejoué). |
| Face ID à chaque `Auth`, `.biometryCurrentSet` | E1 | Un iPhone volé déverrouillé ne suffit pas. Un visage ajouté après l'appairage invalide la clé. |
| `salt = TH` dans HKDF | S5, E3 | Les clés dépendent de toute la négociation authentifiée : deux sessions n'ont jamais les mêmes clés. |
| **Une clé par sens** (`K_m2i`, `K_i2m`) | E3 | Un paquet du Mac ne peut pas être renvoyé au Mac comme s'il venait de l'iPhone (attaque par réflexion). Et chaque sens peut démarrer son compteur à 1 sans risque de réutiliser un nonce. |
| `SessionReady` chiffré en premier | S5 | Confirme aux deux côtés qu'ils ont les mêmes clés avant d'envoyer la vidéo. |
| Indicateur affiché **avant** la capture | A7 | Voir [architecture.md](architecture.md) §4. |

**Échecs (fermeture, sans réponse détaillée à l'autre côté) :** empreinte inconnue, clé invalide, signature invalide, `nM` expiré ou déjà utilisé, Face ID annulé, délai dépassé, session déjà active.

- Le Mac répond au plus `Reject { code générique }` puis coupe la connexion.
- **Pourquoi un code générique :** ne pas indiquer à un attaquant *quelle* vérification a échoué.

## 4. Format des paquets (tâche 13)

### 4.1 En-tête commun (24 octets, tous les entiers en big-endian)

```text
 0      2   3   4               12              20      24
 ┌──────┬───┬───┬───────────────┬───────────────┬───────┐
 │magic │ver│typ│  sessionID    │   counter     │ len   │   puis  body(len)  puis  tag(16) si chiffré
 │"OE"  │01 │   │  (8 octets)   │  (UInt64)     │UInt32 │
 └──────┴───┴───┴───────────────┴───────────────┴───────┘
```

- **Messages d'appairage et de handshake** (`typ < 0x10`) : `sessionID = 0`, `counter = 0`, `body` en clair, pas de tag. Leur intégrité vient des signatures, du HMAC et de l'engagement.
- **Messages de session** (`typ ≥ 0x10`) : `body` chiffré par AES-GCM, **l'en-tête entier est la donnée associée (AAD)**, et le tag de 16 octets suit.

**Pourquoi l'en-tête en AAD :** il reste lisible (il faut lire le type et le compteur avant de déchiffrer), mais **toute modification** de l'en-tête (type, compteur, session) fait échouer le tag : il est authentifié sans être chiffré (T1).

### 4.2 Nonce AES-GCM

`nonce (12 octets) = 0x00000000 ‖ counter (8 octets)`. Le nonce **n'est pas transmis**, il est recalculé à partir du compteur.

**Pourquoi :**

- AES-GCM exige un nonce **jamais réutilisé avec la même clé** (sinon confidentialité et intégrité s'effondrent : c'est le piège n°1 du code généré par IA).
- Chaque (session, sens) a sa propre clé, et le compteur ne fait qu'augmenter : l'unicité est **garantie par construction**, sans dépendre du hasard.
- Ne pas transmettre le nonce économise 12 octets et empêche l'attaquant de le choisir.

**Surcoût par paquet :** 24 (en-tête) + 16 (tag) = **40 octets**. Pour un fragment de 16 Kio, cela fait moins de 0,3 %, bien en dessous des 10–15 % estimés à l'oral.

### 4.3 Types de messages

| typ | Nom | Sens | Corps (après déchiffrement pour typ ≥ 0x10) |
|---|---|---|---|
| 0x01 | PairRequest | I→M | pairingID(16) ‖ P_pub(65) ‖ C(32) ‖ hmac(32) |
| 0x02 | PairNonce | M→I | pairingID(16) ‖ nM(32) |
| 0x03 | PairReveal | I→M | pairingID(16) ‖ nI(32) ‖ sigP(64) |
| 0x04 | PairAccept | M→I | pairingID(16) ‖ sigM(64) |
| 0x05 | Hello | I→M | fpP(32) ‖ eI_pub(65) ‖ nI(32) |
| 0x06 | Challenge | M→I | eM_pub(65) ‖ nM(32) ‖ sigM(64) |
| 0x07 | Auth | I→M | sigP(64) |
| 0x08 | Reject | M→I | code(1) |
| 0x10 | SessionReady | M→I | ts(8) |
| 0x11 | Heartbeat | M→I | ts(8) ‖ captureState(1) ‖ journalSeq(8) ‖ journalHead(32) |
| 0x12 | VideoParams | M→I | ts(8) ‖ width(2) ‖ height(2) ‖ spsLen(2) ‖ sps ‖ ppsLen(2) ‖ pps |
| 0x13 | VideoFragment | M→I | ts(8) ‖ frameID(4) ‖ fragIndex(2) ‖ fragCount(2) ‖ flags(1) ‖ data |
| 0x14 | Keepalive | I→M | ts(8) |
| 0x15 | Close | les deux | ts(8) ‖ reason(1) |
| 0x16 | JournalAnchorRequest | I→M | ts(8) ‖ seq(8) |
| 0x17 | JournalAnchorProof | M→I | ts(8) ‖ seq(8) ‖ status(1) ‖ hash(32) |
| 0x20–0x23 | Lock / Unlock / CmdChallenge / CmdResult | extension J4 | voir §6 |

- Toutes les tailles fixes sont **exactes**. Tout autre valeur entraîne le rejet.
- `captureState` : 0 = arrêtée, 1 = en cours, 2 = permission refusée, 3 = indicateur indisponible.
- `ts` = millisecondes Unix (UInt64), **à l'intérieur** du corps chiffré : il est donc authentifié.
- **Pourquoi un format binaire à tailles fixes plutôt que JSON :** chaque champ a une taille connue, le parseur est minuscule et chaque borne se teste. Un parseur JSON sur des données hostiles ajoute de la surface d'attaque et de l'ambiguïté (clés dupliquées, nombres géants).

### 4.4 Ordre de validation à la réception (échec sûr, D2)

Chaque étape **jette** le paquet en cas d'échec. Rien n'est modifié dans l'état tant que l'étape 7 n'a pas réussi.

1. Taille totale ≥ 24 et ≤ 65 536.
2. `magic == "OE"`, `ver == 0x01`.
3. `typ` connu **et attendu dans l'état courant** (par exemple pas de `VideoFragment` avant `SessionReady`, pas de `Hello` pendant une session). Sens correct.
4. `len` == taille totale − 24 (− 16 si chiffré).
5. Pour typ ≥ 0x10 : `sessionID` == session courante.
6. Pour typ ≥ 0x10 : `counter == dernierAccepté + 1` (transport fiable et ordonné, voir architecture §6). Sinon, le paquet est jeté (pas de fermeture immédiate).
7. Pour typ ≥ 0x10 : `AES.GCM.open(sealedBox, using: clé_du_sens, authenticating: en-tête)`.
8. **Seulement maintenant** : `dernierAccepté = counter`.
9. Analyser le corps avec ses bornes de type. Vérifier `|maintenant − ts| ≤ 30 s` et `ts ≥ dernier ts reçu` de ce pair.

**Pourquoi cet ordre :**

- Les étapes 1 à 6 sont des comparaisons quasi gratuites : un flot de paquets invalides ne coûte presque rien.
- On ne met à jour le compteur **qu'après** l'authentification (étape 8). Sinon, un attaquant pourrait envoyer un faux paquet avec un compteur énorme et bloquer tous les vrais paquets suivants.

**Compteur d'échecs :** pendant une session établie, **tout rejet** (étapes 1 à 7 et 9) compte comme un échec. Au 20e échec en 10 s, la session est fermée (`Close`, clés effacées) et l'incident est journalisé une seule fois (`AUTH_FAILURES`).

**Pourquoi tout rejet compte :** sur un transport fiable et chiffré, un pair légitime n'envoie jamais de paquet malformé ni hors séquence. Tout rejet est donc une anomalie (attaque ou panne).

**Note sur la règle « exactement +1 » :** grâce à elle, un paquet supprimé en transit est détecté (T3). Tous les paquets suivants ont un compteur décalé, sont rejetés et comptés : la session se ferme au 20e échec, et l'iPhone passe en **Injoignable** au bout de 6 s sans paquet authentifié.

**Pourquoi ne pas fermer dès le premier compteur faux :** à l'étape 6, l'en-tête n'est **pas encore authentifié** (AES-GCM vient à l'étape 7). Fermer sur une donnée non authentifiée laisserait un seul faux paquet piloter l'état de la session. Règle générale : une donnée non authentifiée ne fait évoluer l'état que par le compteur d'échecs, qui est borné.

### 4.5 Vidéo : découpage et réassemblage (D3)

- Une image H.264 encodée (format AVCC) est découpée en fragments de 16 Kio au plus.
- `flags` bit 0 = image clé. `VideoParams` est envoyé avant chaque image clé.
- **Réassemblage :**
  - `fragCount ≤ 64` ;
  - `fragIndex < fragCount` ;
  - total ≤ 1 Mio ;
  - 4 images en cours au maximum ;
  - une image incomplète est purgée après 1 s ;
  - un fragment dupliqué ou incohérent (`fragCount` différent pour le même `frameID`) jette l'image entière.
- Après une image jetée, le décodeur attend la prochaine image clé.

### 4.6 Fin de session et défaillances

| Événement | Comportement |
|---|---|
| iPhone : aucun paquet authentifié depuis 6 s | État **Injoignable**, alerte « Mac injoignable » : perte de contact, plusieurs causes possibles |
| Mac : aucun `Keepalive` depuis 10 s | Arrêt de la capture **puis** de l'indicateur, clés effacées, `SESSION_CLOSED(keepalive)` |
| Bouton Arrêter ou app iPhone en arrière-plan | `Close`, puis clés effacées des deux côtés |
| Permission de capture retirée sur le Mac | `Heartbeat` avec `captureState = 2`, puis `Close` ; l'iPhone affiche la cause |
| Compteur ≥ 2³² ou session de plus de 60 min | `Close` puis nouveau handshake (Face ID) |
| Toute erreur inattendue | `Close` et arrêt : **jamais** de reprise silencieuse avec les mêmes clés |
| Reconnexion après coupure | **Toujours** un nouveau handshake complet : nouvelles clés, nouveaux compteurs, nouveau Face ID |

## 5. Heartbeat et ancre du journal

Le `Heartbeat` (toutes les 2 s) transporte `journalSeq` et `journalHead` (hash de la dernière entrée du journal du Mac).

- L'iPhone garde la plus grande paire (`seq`, `hash`) reçue dans son Keychain : c'est l'**ancre**.
- À la session suivante, juste après `SessionReady`, l'iPhone envoie **une seule fois** `JournalAnchorRequest { seq = seq de l'ancre }`. Le Mac répond `JournalAnchorProof` :
  - `status = 0` : l'entrée existe, `hash` est son hash ;
  - `status = 1` : l'entrée a été purgée (conservation de 30 jours), `hash` vaut 32 zéros.
- L'iPhone affiche « Journal du Mac altéré » si le premier `Heartbeat` donne un `journalSeq` inférieur à l'ancre, ou si `status = 0` avec un `hash` différent de l'ancre. Avec `status = 1`, il affiche « Vérification impossible : ancre purgée », ce qui n'est **pas** une alerte d'altération.
- Un second `JournalAnchorRequest` dans la même session est un type inattendu (étape 3) : rejeté et compté.

**Pourquoi un message dédié :** le heartbeat ne donne que la **tête** du journal. Or, après une troncature, de nouvelles entrées (au minimum `SESSION_OPENED`) font repasser `seq` au-dessus de l'ancre. Sans comparer le hash **à la position de l'ancre**, la troncature passerait inaperçue. La réponse voyage dans le canal chiffré et authentifié par la clé de session du Mac : pas besoin d'une signature en plus.

**Pourquoi « purgée » n'est pas une alerte :** l'entrée ancrée est la dernière vue à la session précédente. Elle n'est purgée que si le parent ne s'est pas connecté depuis plus de 30 jours. C'est une limite, à citer à l'oral.

**Pourquoi :** c'est le « point d'ancrage externe » qui manquait pour détecter une **troncature** du journal (STRIDE T4), voir [journal.md](journal.md).

## 6. Extension J4 : commandes Verrouiller / Déverrouiller

Une commande ne réutilise **pas** la signature de session : chaque commande a son propre défi et son propre Face ID (E1, L8).

```text
 iPhone ── CmdChallengeRequest (0x22, chiffré) ──▶ Mac   nC ← 32 octets aléatoires, valable 30 s, usage unique
 iPhone ◀── CmdChallenge (0x22, chiffré) { nC } ── Mac
 Face ID → sigP = Sign_P("OpenEye/v1/cmd" ‖ sessionID ‖ nC ‖ typ ‖ duréeSecondes(4))
 iPhone ── Lock (0x20) { nC, duréeSecondes, sigP } ──▶ Mac   vérifie sigP, nC en attente, puis
                                                             durée = min(demandée, plafond Mac) ; journalise LOCK avec sigP
 iPhone ◀── CmdResult (0x23) { résultat, heureFin } ── Mac
```

`Unlock (0x21)` suit le même schéma. Le **plafond de durée est appliqué par le Mac** (L5) : l'iPhone ne peut pas l'imposer.

## 7. Notations

- `‖` : concaténation d'octets.
- `lp(x)` : longueur de `x` sur 2 octets big-endian, suivie de `x`.
  **Pourquoi :** sans préfixe de longueur, `"ab" ‖ "c"` et `"a" ‖ "bc"` donneraient les mêmes octets, donc le même hash. C'est une ambiguïté classique.
- Les libellés `"OpenEye/v1/..."` sont en ASCII, sans terminateur.
- `Sign_X(m)` : `X.signature(for: m)` (ECDSA P-256, hash SHA-256 interne à CryptoKit), sérialisé en `rawRepresentation`.
- `HMAC_K(m)` : `HMAC<SHA256>.authenticationCode(for: m, using: K)`. La vérification utilise `HMAC<SHA256>.isValidAuthenticationCode` (temps constant).
- Aléa : uniquement `SecRandomCopyBytes` ou les générateurs de CryptoKit. **Jamais** `Int.random`, `arc4random` ou autre pour un secret.
