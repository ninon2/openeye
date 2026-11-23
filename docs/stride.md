# Modèle de menaces STRIDE — OpenEye (J1)

Statut : **brouillon B, à relire par A** · Base : section 6 du dossier OpenEye · Date : 2026-11-20

## 1. Périmètre retenu

OpenEye permet au parent de **voir** l'écran du Mac de l'enfant depuis son iPhone. Il n'y a **aucune commande d'action** : ni verrouillage, ni message. Le seul acte autorisé à distance est l'**ouverture d'une session de visionnage**. Elle exige Face ID sur l'iPhone et une signature par la Secure Enclave, que le Mac vérifie avant de démarrer la capture.

> Écart avec le dossier initial (MVP point 5 « une commande signée ») : au MVP, l'autorisation de visionnage signée remplace la commande. La commande « Verrouiller » devient une **extension J4**, traitée en section 5 bis, une fois le MVP stable. Ce changement, avec l'inversion des rôles (Mac = capteur, iPhone = centrale), doit être validé par écrit par l'enseignant (tâche 04). Le principe et l'inversion des rôles ont déjà été approuvés à l'oral.

Matériel de référence : iPhone 13 (Face ID, Secure Enclave) sous iOS 27.2.1, Mac sous macOS 27.2, Xcode 27.2, compte Apple gratuit.

## 2. Actifs à protéger

| ID | Actif | Pourquoi il compte |
|---|---|---|
| A1 | Flux de l'écran de l'enfant | Donnée personnelle d'un mineur, potentiellement sensible (messages, contenus de tiers) |
| A2 | Clé de signature du parent (Secure Enclave iPhone) | Elle seule autorise un visionnage |
| A3 | Clé d'identité du Mac | Elle prouve au parent que le flux vient du bon Mac |
| A4 | Clés de session (AES-GCM, une par sens) | Leur fuite expose le flux de la session |
| A5 | Journal d'événements | Preuve de qui a regardé, quand, et des coupures |
| A6 | Disponibilité de la supervision (heartbeat) | Le parent doit savoir si la supervision est coupée |
| A7 | Transparence envers l'enfant (indicateur) | Exigence éthique et CNIL : pas de supervision cachée |

## 3. Attaquants retenus

| ID | Attaquant | Capacités supposées |
|---|---|---|
| T1 | Tiers sur le même réseau ou à portée radio | Écoute, injection, rejeu, modification de paquets, faux appareil Multipeer, inondation |
| T2 | L'enfant | Utilise le Mac, peut fermer l'app ou couper le réseau, peut être administrateur du Mac |
| T3 | Personne avec un accès physique | Prend l'iPhone déverrouillé ou le Mac ouvert ; photographie le QR d'appairage |

**Hors périmètre, assumé à l'oral :**

- un Mac compromis au niveau root, ou un logiciel malveillant installé ;
- un iOS jailbreaké ;
- un parent qui détourne l'outil. Ce risque relève de la conception éthique (transparence, journal visible par l'enfant), pas de la crypto.

## 4. Flux et frontières de confiance

```text
 ┌──────── Mac de l'enfant (frontière 1) ────────┐        ┌──── iPhone du parent (frontière 2) ────┐
 │ ScreenCaptureKit → H.264 → AES-GCM ──────────┼─F1───▶│ déchiffrement → décodage → affichage   │
 │ heartbeat authentifié ───────────────────────┼─F2───▶│ minuterie → alerte « Mac injoignable » │
 │ vérif. signature ◀───────────────────────────┼─F3────│ Face ID → Secure Enclave → signature   │
 │ indicateur visible, journal chaîné           │        │ Keychain ThisDeviceOnly                │
 └──────────────────────────────────────────────┘        └────────────────────────────────────────┘
          ▲                    réseau NON fiable (Multipeer / Wi-Fi)                ▲
          └──────────── F0 : appairage par QR (canal visuel, une fois) ─────────────┘
```

- **F0 · Appairage :** le Mac affiche un QR (clé publique d'identité du Mac, jeton à usage unique, expiration). L'iPhone le lit, puis envoie sa clé publique Secure Enclave. Les deux écrans affichent une empreinte courte à comparer, et l'appairage est confirmé sur le Mac.
- **F3 · Ouverture de session :** le Mac envoie un défi aléatoire. Le parent passe Face ID, et la Secure Enclave signe le défi et la clé éphémère ECDH de l'iPhone. Le Mac vérifie la signature avec la clé enregistrée à l'appairage, signe à son tour, puis les deux dérivent les clés de session (HKDF).
- **F1 et F2 :** chaque paquet est chiffré en AES-GCM et porte une version, un type, un compteur et un horodatage, authentifiés.

## 5. Menaces et contre-mesures

Colonne « Vérification » : le test qui prouve la contre-mesure, en XCTest (X) ou sur les appareils réels (D).

### S — Usurpation

| ID | Menace | Flux | Contre-mesure | Vérification |
|---|---|---|---|---|
| S1 | Un autre téléphone se fait passer pour celui du parent et regarde l'écran | F3 | Seule la clé publique enregistrée à l'appairage est acceptée, et le défi-réponse signé par la Secure Enclave est exigé à chaque session. | X : signature d'une clé inconnue refusée. D : un second iPhone non appairé n'obtient aucun flux. |
| S2 | Un faux Mac envoie un flux truqué au parent | F0, F3 | La clé du Mac est fixée à l'appairage (lue par QR, canal visuel), et la réponse du Mac est signée par cette clé. Session refusée si la clé change. | X : réponse signée par une autre clé refusée. |
| S3 | Un appareil Multipeer reprend le nom affiché du Mac ou de l'iPhone | F0–F3 | Le nom affiché n'est jamais une preuve d'identité : seule la clé compte. | D : un pair au nom identique n'est pas accepté. |
| S4 | Le QR est photographié, par T3 ou par une caméra, et utilisé par un autre téléphone | F0 | Le jeton est à usage unique et expire vite. L'empreinte est comparée sur les deux écrans, et une confirmation explicite est demandée sur le Mac. | X : jeton expiré ou déjà utilisé refusé. D : un second appairage avec le même QR échoue. |
| S5 | Homme du milieu pendant l'échange ECDH | F3 | Les clés éphémères sont signées par les deux identités. HKDF est lié au transcript (identités, rôles, version, défi). | X : substitution d'une clé éphémère détectée. |

### T — Altération

| ID | Menace | Flux | Contre-mesure | Vérification |
|---|---|---|---|---|
| T1 | Un paquet vidéo ou heartbeat est modifié en transit | F1, F2 | AES-GCM : le tag d'authentification couvre le contenu, et l'en-tête (version, type, compteur, horodatage) passe en données associées (AAD). | X : un bit modifié dans le chiffré ou l'en-tête provoque un refus. |
| T2 | L'enfant modifie l'app Mac pour envoyer une image figée ou un autre écran | F1 | Indicateur de fraîcheur côté iPhone (horodatage, compteur, âge de la dernière image). **Limite :** un enfant administrateur qui modifie l'app reste hors de portée. | D : l'âge de l'image s'affiche, avec une alerte si le flux gèle. |
| T3 | Un paquet est supprimé ou réordonné pour masquer une période | F1, F2 | Le compteur révèle les trous. Un heartbeat manquant déclenche une alerte (voir D1). | X : un trou de compteur est signalé. |
| T4 | Le journal est modifié après coup | stockage | Les entrées sont signées et chaînées par SHA-256. **Limite :** la suppression de la fin du journal n'est détectable qu'avec un point d'ancrage externe (décision J2). | X : une entrée modifiée ou retirée au milieu casse la vérification. |

### R — Répudiation

| ID | Menace | Contre-mesure | Vérification |
|---|---|---|---|
| R1 | Le parent nie avoir regardé l'écran | Chaque ouverture et chaque fin de visionnage est inscrite au journal avec la signature Face ID et Secure Enclave du parent. L'enfant peut consulter ce journal. | X : l'entrée contient une signature vérifiable avec la clé du parent. |
| R2 | L'enfant nie avoir coupé la supervision | Les coupures (heartbeat perdu, arrêt de l'app, refus de permission) sont journalisées des deux côtés. | D : une fermeture de l'app Mac apparaît au journal de l'iPhone. |

### I — Divulgation

| ID | Menace | Contre-mesure | Vérification |
|---|---|---|---|
| I1 | Un tiers sur le réseau intercepte le flux | Chiffrement de bout en bout avec des clés de session issues d'ECDH éphémère, donc une confidentialité persistante par session. | D : une capture réseau ne contient aucun H.264 lisible. |
| I2 | La taille et le rythme des paquets révèlent l'activité à l'écran | Remplissage (padding) en extension. **Limite** acceptée au MVP. | Mesure en extension |
| I3 | Clés, images ou identifiants dans les logs | Aucun secret, aucune image ni identifiant d'appareil dans les logs. Seuls des événements typés sont journalisés. | Revue de code par A, recherche dans les logs système. |
| I4 | Le flux apparaît dans l'aperçu multitâche de l'iPhone | Masquer la vue dès que l'app passe en état inactif ou en arrière-plan. | D : l'aperçu multitâche reste noir. |
| I5 | Le parent enregistre l'écran de l'iPhone, ce qui contourne « pas d'enregistrement permanent » | Masquer le flux pendant un enregistrement ou une recopie d'écran iOS (état de capture de la scène). **Limite :** une simple capture d'écran ne peut pas être empêchée. | D : l'enregistrement de l'écran iOS affiche un écran masqué. |
| I6 | Un vol ou une sauvegarde de l'iPhone expose les clés | Clé de signature dans la Secure Enclave (non exportable). Clés et identités dans le Keychain `ThisDeviceOnly`, exclues des sauvegardes migrables. | D : après restauration sur un autre appareil, un nouvel appairage est exigé. |
| I7 | Le flux montre des données de tiers (mots de passe, messages d'amis, appels vidéo) | Minimisation : pas d'audio, pas de webcam, pas d'enregistrement. Option à étudier : exclure certaines apps de la capture (filtre ScreenCaptureKit). À traiter dans l'analyse RGPD (A). | Décision J2 |

### D — Déni de service

| ID | Menace | Contre-mesure | Vérification |
|---|---|---|---|
| D1 | L'enfant ferme l'app ou coupe le réseau | Heartbeat authentifié, et alerte « Mac injoignable » sur l'iPhone après le délai fixé au J2. **Limite :** sans notifications push (compte gratuit), l'alerte n'est garantie que si l'app iPhone est au premier plan. L'état est réévalué au retour au premier plan. | D : couper le Wi-Fi du Mac fait apparaître l'alerte dans le délai. |
| D2 | Inondation de faux paquets | Contrôles bon marché avant de déchiffrer : taille maximale, version, type, compteur déjà vu. Limitation de débit, puis journalisation agrégée sans un log par paquet. | X : un paquet surdimensionné ou de version inconnue est refusé sans déchiffrement. |
| D3 | Épuisement de la mémoire par des fragments vidéo jamais complétés | Réassemblage borné en taille, en nombre et en durée, avec suppression des images tardives. | X : un fragment orphelin est purgé après le délai. |
| D4 | Le refus ou le retrait de la permission de capture macOS bloque la démo | Échec visible et propre, et alerte au parent. Autorisation accordée avant la démo. | D : un retrait de la permission arrête le flux et le signale. |

### E — Élévation de privilèges

| ID | Menace | Contre-mesure | Vérification |
|---|---|---|---|
| E1 | Quelqu'un prend l'iPhone déverrouillé et ouvre un visionnage | Face ID exigé à **chaque** ouverture de session (pas de réutilisation de l'authentification). Clé liée à l'enrôlement biométrique courant. | D : annuler Face ID ne produit aucune signature, donc aucun flux. |
| E2 | Rejeu d'une ancienne autorisation de visionnage | Défi aléatoire à usage unique généré par le Mac, horodatage, et défi consommé après usage. | X : une signature valide sur un ancien défi est refusée. |
| E3 | Rejeu d'un paquet de session dans une autre session ou un autre sens | Clés distinctes par session et par sens (HKDF), compteur strictement croissant, nonce AES-GCM unique sous une même clé. | X : un paquet rejoué ou un paquet d'une ancienne session est refusé. |
| E4 | Un iPhone appairé conserve son accès après révocation | La révocation supprime la clé du parent côté Mac, et un nouvel appairage est exigé. | D : après révocation, aucune session ne s'ouvre. |

## 5 bis. Extension J4 : verrouillage de l'écran à distance

**Mécanisme retenu (option A) :** l'app Mac affiche un écran de blocage OpenEye en plein écran, au-dessus de tout, sur tous les écrans. Le changement d'app, le Dock et le menu « Forcer à quitter » sont désactivés par les options de présentation publiques d'AppKit. Ce n'est **pas** un verrouillage de session macOS : aucune API publique ne le permet.

**Écartés :**

- l'option B, la mise en veille de l'écran (`pmset`) : elle dépend d'un réglage modifiable par l'enfant, et l'appel depuis la sandbox n'est pas garanti. Elle reste un secours à tester au J2 ;
- la simulation du raccourci clavier : elle exige la permission Accessibilité, contraire au moindre privilège ;
- toute API privée : fragile et indéfendable.

**Règles :**

- une commande **Verrouiller(durée)**, avec une durée maximale (valeur à fixer, par exemple 15 minutes) ;
- une commande **Déverrouiller** ;
- les deux sont signées par la Secure Enclave après Face ID, sur un défi neuf ;
- l'enfant voit toujours qui a verrouillé et jusqu'à quand.

| ID | STRIDE | Menace | Contre-mesure | Vérification |
|---|---|---|---|---|
| L1 | S | Un appareil non appairé envoie « Verrouiller » | Signature vérifiée avec la clé du parent enregistrée à l'appairage, dans la session authentifiée. | X : commande signée par une clé inconnue refusée. |
| L2 | T | La durée ou le type de commande est modifié en transit | Les champs de la commande sont couverts par la signature **et** par AES-GCM. | X : durée modifiée → signature invalide → refus. |
| L3 | R | « Ce n'est pas moi qui ai verrouillé » | La commande signée est inscrite telle quelle au journal chaîné, et l'enfant peut la consulter. | X : l'entrée du journal contient la signature vérifiable. |
| L4 | I | L'écran de blocage révèle des informations sensibles | Il affiche seulement le message, l'heure de fin et « Verrouillé par ton parent ». | Revue de l'interface |
| L5 | D | L'iPhone devient injoignable et l'enfant reste bloqué indéfiniment | La durée maximale est imposée **par le Mac**, quelle que soit la valeur demandée. Le déverrouillage est automatique à l'échéance. | X et D : la durée est plafonnée, le déverrouillage se fait à l'heure. |
| L6 | D | Un attaquant verrouille l'écran en boucle | Seules les commandes signées par le parent passent (L1). Les commandes sont limitées en débit et journalisées. | X : rafale de commandes non signées sans effet. |
| L7 | E | Rejeu d'une ancienne commande « Verrouiller » ou « Déverrouiller » | Défi à usage unique émis par le Mac, compteur, horodatage, et commande déjà vue refusée. | **Démo J5** : rejouer une commande capturée → refus visible. |
| L8 | E | Quelqu'un prend l'iPhone déverrouillé et bloque le Mac | Face ID à **chaque** commande, sans réutilisation de l'authentification. | D : Face ID annulé → aucune commande envoyée. |
| L9 | T | L'enfant tue l'app pour sortir du blocage | **Limite :** non empêchable par un administrateur. La coupure est détectée par le heartbeat (D1) et journalisée. | D : app tuée → alerte « Mac injoignable ». |

## 6. Transparence (A7) : contrôles non cryptographiques

- L'indicateur est visible sur le Mac pendant **toute** la capture. Si l'indicateur ne peut pas s'afficher, la capture ne démarre pas (échec sûr).
- L'indicateur système de partage d'écran de macOS s'ajoute à celui de l'app (à vérifier sur macOS 27.2).
- L'enfant peut consulter le journal des visionnages.
- Il n'existe aucun mode caché, et la webcam est hors MVP.

## 7. Limites assumées à l'oral

1. Un enfant administrateur peut désinstaller ou modifier l'app Mac. Le système **détecte** la coupure (heartbeat) mais ne l'empêche pas.
2. Sans notifications push, l'alerte n'est fiable qu'avec l'app iPhone au premier plan.
3. Les captures d'écran iOS ne peuvent pas être empêchées.
4. La troncature de la fin du journal n'est pas détectable sans ancrage externe.
5. Le padding est absent du MVP : la taille des paquets peut révéler l'activité.
6. Extension J4 : l'écran de blocage n'est pas un verrouillage de session macOS. Un enfant administrateur peut en sortir en tuant l'app, mais c'est détecté.

## 8. Décisions à trancher au J2

- Où vit la clé d'identité du Mac : dans la Secure Enclave du Mac si elle est accessible avec un compte gratuit, sinon dans le Keychain. À vérifier par prototype.
- Le transport : Multipeer Connectivity est déprécié dans Xcode 27 ([TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)). Reste-t-on dessus ou passe-t-on à Network ?
- Le mode de transport vidéo (fiable ou non fiable), qui détermine la règle anti-rejeu : compteur strict ou fenêtre glissante.
- Le délai du heartbeat et la tolérance d'horloge pour l'horodatage.
- Le repli sur le code de l'iPhone si Face ID échoue : l'accepter ou non.
- L'exclusion d'apps de la capture (I7).
- La faisabilité de l'écran de blocage (option A) dans la sandbox, la durée maximale de verrouillage, et le test de l'option B en secours.
