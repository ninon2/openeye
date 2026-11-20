# Choix cryptographiques justifiés (J2)

Statut : **brouillon B, à relire par A** · Règle : **aucune crypto maison**, uniquement CryptoKit et Security · Chaque choix est relié à une menace de [stride.md](stride.md)

| Besoin | Choix | API Apple | Menaces | Pourquoi ce choix | Alternatives écartées |
|---|---|---|---|---|---|
| Clé du parent | ECDSA P-256 dans la **Secure Enclave**, Face ID à chaque usage | `SecureEnclave.P256.Signing.PrivateKey`, `SecAccessControlCreateWithFlags(.privateKeyUsage, .biometryCurrentSet)` | S1, E1, R1 | La clé est générée **dans** la puce et ne peut pas en sortir, même pour l'app. Un voleur de l'iPhone ou un malware ne peut pas la copier. P-256 est la seule courbe que la Secure Enclave supporte. | RSA (non supporté par la Secure Enclave, signatures lourdes) ; mot de passe ou PIN (secret qui circule ou se devine) |
| Biométrie | `.biometryCurrentSet`, sans repli sur le code | LocalAuthentication | E1 | Si quelqu'un ajoute son visage dans l'iPhone, la clé devient inutilisable et il faut réappairer. Sans repli sur le code : un enfant qui connaît le code de l'iPhone du parent ne peut pas ouvrir le visionnage. | `.biometryAny` (accepte un visage ajouté plus tard) ; `.userPresence` (accepte le code) |
| Échange de clés | **ECDH P-256 éphémère** à chaque session | `P256.KeyAgreement` | I1, S5 | Des clés neuves à chaque session : voler une clé longue durée ne déchiffre pas le passé (confidentialité persistante). | Clé partagée fixe (une seule fuite compromet tout, passé compris) ; Curve25519 (valable, mais on garde une seule famille de courbes, P-256, cohérente avec la Secure Enclave) |
| Authentification du handshake | Les deux côtés **signent le hash du transcript** complet | `signature(for:)`, `SHA256` | S1, S2, S5 | Lie les identités aux clés éphémères : un homme du milieu ne peut substituer aucune clé sans casser une signature. | ECDH seul, non signé (vulnérable à l'homme du milieu, comme le rappelle le cours slide 17) |
| Dérivation des clés | **HKDF-SHA256**, sel = transcript, une clé par sens | `SharedSecret.hkdfDerivedSymmetricKey` | E3 | Le secret ECDH brut n'est pas uniforme et ne doit jamais servir directement de clé. HKDF en tire des clés propres et indépendantes, liées à cette session précise. | Utiliser le secret ECDH directement (non uniforme) ; SHA256(secret) maison (pas de séparation des usages) |
| Chiffrement du flux | **AES-256-GCM** | `AES.GCM.seal / open` | T1, I1 | Chiffre **et** authentifie en une seule opération : un paquet modifié est rejeté. Accéléré matériellement sur Mac et iPhone. Surcoût de 16 octets de tag. | AES-CBC + HMAC (deux opérations, risques d'erreur de composition) ; AES-ECB (motifs visibles, interdit par le cours) ; ChaCha20-Poly1305 (valable, mais AES est accéléré matériellement sur ce matériel) |
| Nonce GCM | **Compteur** sur 64 bits, unique par (session, sens) | `AES.GCM.Nonce(data:)` | T1, E3 | Unicité **garantie par construction**. Un nonce réutilisé avec la même clé casse GCM, c'est le piège n°1 cité par le cours. | Nonce aléatoire (sûr aussi, mais non vérifiable par un test simple) ; IV fixe (catastrophique, interdit) |
| Anti-rejeu | Compteur strict (+1), `sessionID`, horodatage, défis à usage unique | — | E2, E3, T3 | Le compteur bloque le rejeu dans une session, les clés neuves le bloquent entre sessions, et le défi bloque le rejeu d'une autorisation. | Horodatage seul (fenêtre de rejeu tant que l'horloge le permet) |
| Appairage | QR (secret à usage unique, clé du Mac) + **code à 6 chiffres avec engagement** + signatures | `HMAC<SHA256>`, `SHA256` | S4, S5 | Le QR authentifie le Mac auprès de l'iPhone. Le code avec engagement authentifie l'iPhone auprès du Mac avec une seule chance sur un million pour un attaquant. | Code sans engagement (cassable hors ligne en quelques millisecondes) ; QR dans les deux sens (exige la caméra du Mac : permission de plus, pas toujours de caméra) |
| Comparaison de secrets | Temps constant | `HMAC.isValidAuthenticationCode` | S4 | Une comparaison `==` naïve peut révéler, par son temps d'exécution, combien d'octets sont justes. | `Data ==` |
| Journal | Entrées signées par le Mac, **chaînées par SHA-256**, ancre côté iPhone | `SHA256`, `signature(for:)` | R1, R2, T4 | Toute modification ou suppression au milieu est détectable. L'ancre détecte la troncature. Voir [journal.md](journal.md). | Simple fichier de log (modifiable sans trace) |
| Stockage | Keychain `WhenPasscodeSetThisDeviceOnly` | Security | I6 | Pas de synchronisation iCloud, pas de restauration sur un autre appareil, rien sans code de déverrouillage. | `UserDefaults` ou fichier (lisibles, sauvegardés) |
| Aléa | `SecRandomCopyBytes` / générateurs de CryptoKit | Security, CryptoKit | Tous | Générateur cryptographique du système. | `Int.random`, `arc4random`, `Date()` comme graine (non cryptographiques ou prévisibles) |

## Ce qu'on ne fait volontairement pas

- **Signer chaque image avec la Secure Enclave :** trop lent (Face ID et la puce à chaque image). AES-GCM authentifie déjà chaque paquet. La signature sert au handshake et aux commandes.
- **TLS ou HTTPS :** il faudrait des certificats et une autorité. Entre deux appareils appairés par QR, notre handshake signé offre les mêmes garanties (authentification mutuelle, confidentialité persistante) sans infrastructure.
- **S'appuyer sur le chiffrement de Multipeer :** il est activé (`.required`), mais il n'authentifie personne. On le traite comme un réseau non fiable.

## Points à vérifier par prototype (J2)

1. La Secure Enclave du Mac est-elle disponible ? Cela dépend du **modèle de Mac** (puce Apple ou puce T2), à communiquer.
2. Le Keychain « data protection » est-il accessible depuis l'app Mac sandboxée avec un compte gratuit ?
3. Face ID refuse-t-il bien sans repli sur le code avec `.biometryCurrentSet` ? Test sur l'iPhone 13.
4. Le surcoût réel, en octets et en temps, du chiffrement par paquet, mesuré avec A.
