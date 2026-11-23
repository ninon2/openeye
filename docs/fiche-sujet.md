# Fiche sujet — OpenEye (J1)

<!-- TRAME préparée par B pour A (tâche 03). Les commentaires « A : » indiquent ce qu'A doit compléter ou vérifier, puis supprimer. Objectif : 1 à 2 pages une fois exportée. -->

**Binôme :** <!-- A : prénoms NOM, rôle (A chef de projet + red team, B dev iOS + architecte sécurité) -->
**Encadrant :** <!-- A -->
**Date :** <!-- A -->
**Version :** 0.1 (brouillon)

## 1. Le problème

Les enfants passent beaucoup de temps seuls sur l'ordinateur, et leurs parents ne savent pas sur quoi ils tombent. Temps d'écran (Apple) limite la durée et les apps, mais ne montre pas ce que l'enfant voit. Les logiciels de surveillance du commerce sont souvent intrusifs, parfois cachés, et certains ont déjà subi des fuites de données.

## 2. La solution en une phrase

**OpenEye** transforme l'iPhone du parent en écran et en clé de contrôle pour superviser **à découvert** le Mac de l'enfant. Le parent voit l'écran en direct à travers un canal chiffré de bout en bout, et seul son iPhone appairé, débloqué par Face ID, peut ouvrir ce visionnage.

## 3. Utilisateurs

| Acteur | Appareil | Ce qu'il fait |
|---|---|---|
| Parent | iPhone (app OpenEye iOS) | Il appaire le Mac, ouvre un visionnage après Face ID et reçoit l'alerte « Mac injoignable ». |
| Enfant | Mac (app OpenEye macOS) | Il est informé, voit l'indicateur de supervision et peut consulter le journal des visionnages. |

## 4. Scénario type

1. Le parent installe OpenEye sur le Mac **avec** l'enfant et lui explique ce qui est partagé.
2. Le Mac affiche un QR code. Le parent le scanne, les deux écrans affichent la même empreinte, et l'appairage est confirmé sur le Mac.
3. Plus tard, le parent ouvre l'app, passe Face ID et voit l'écran du Mac en direct. Sur le Mac, l'indicateur s'allume.
4. Si l'enfant ferme l'app ou coupe le réseau, l'iPhone affiche « Mac injoignable ».
5. Chaque visionnage est inscrit dans un journal signé que l'enfant peut lire.

## 5. Périmètre

**MVP (J3)**

1. Appairage par QR code avec vérification d'empreinte.
2. Clé du parent dans la Secure Enclave, utilisable seulement après Face ID.
3. Ouverture du visionnage par défi-réponse signé, avec Face ID à chaque fois.
4. Canal chiffré : ECDH P-256, HKDF, AES-GCM, protection anti-rejeu.
5. Écran du Mac en direct (H.264), chiffré, affiché sur l'iPhone.
6. Heartbeat et alerte « Mac injoignable ».
7. Indicateur visible sur le Mac pendant toute la capture.
8. Journal signé et chaîné par SHA-256.

**Extensions (J4–J5, si le MVP est stable)**

- Verrouillage de l'écran à distance (écran de blocage, durée maximale).
- Webcam, désactivée par défaut.
- Débit adaptatif.
- Rotation des clés de session.
- Remplissage (padding) des paquets.

**Hors périmètre**

- Notifications push, iCloud, NFC : impossibles avec un compte Apple gratuit.
- Tout enregistrement de l'écran ou de la webcam.
- Mode caché.
- Lecture des messages privés.
- Géolocalisation.
- Filtrage web.
- Accès hors du réseau local.

## 6. Écarts au cadre du sujet (à faire valider)

| Écart | Justification | Statut |
|---|---|---|
| Rôles inversés : le Mac capte, l'iPhone supervise (le sujet dit « iPhone = capteur, Mac = centrale ») | Ce qu'on protège, c'est l'usage du Mac par l'enfant. L'iPhone garde le rôle de clé de sécurité (Secure Enclave, Face ID). | Validé à l'oral. <!-- A : joindre la confirmation écrite --> |
| MVP sans commande d'action : le visionnage signé remplace « Verrouiller » ou « Message » | Le binôme veut observer, pas agir. La signature Secure Enclave et l'anti-rejeu restent démontrés à l'ouverture de chaque visionnage. Le verrouillage passe en extension J4. | <!-- A : à faire valider --> |

## 7. Contraintes

- **Matériel :** un Mac (macOS 27.2, Xcode 27.2), un iPhone 13 (iOS 27.2.1, Face ID).
- **Compte Apple gratuit :** l'app iPhone expire au bout de 7 jours et doit être réinstallée la veille de chaque démo.
- **Logiciel :** Swift et SwiftUI, frameworks Apple uniquement, aucune dépendance externe.
- **Liaison :** locale uniquement (Multipeer : découverte par Bluetooth, flux par Wi-Fi).

## 8. Sécurité en bref

- **Attaquants retenus :** un tiers sur le réseau, l'enfant, une personne avec un accès physique. Détail dans [stride.md](stride.md).
- **Garanties :**
  - seul l'iPhone appairé voit le flux ;
  - le réseau ne voit que du chiffré ;
  - un paquet modifié ou rejoué est refusé ;
  - chaque visionnage exige Face ID ;
  - une coupure est détectée.
- **Limite assumée :** un enfant administrateur de son Mac peut désinstaller l'app. OpenEye ne l'empêche pas, il le **détecte** et le signale.

## 9. Éthique et RGPD

- **Transparence :** l'enfant est informé, l'indicateur reste visible et le journal des visionnages lui est accessible. C'est l'esprit de la recommandation CNIL sur le contrôle parental.
- **Minimisation :** du direct uniquement, sans enregistrement, sans audio, sans webcam au MVP.
- **Démonstrations :** uniquement sur un bureau de test avec des données fictives.
- <!-- A : base légale, données traitées, durée de conservation du journal, besoin d'une AIPD → renvoyer vers docs/rgpd.md -->

## 10. Critères de réussite (à chiffrer au J2)

<!-- A et B : fixer les valeurs après les mesures de débit (tâche 17). -->

| Critère | Cible |
|---|---|
| Latence écran Mac → iPhone | < … s |
| Fluidité | ≥ … images/s, résolution … |
| Délai d'alerte « Mac injoignable » | ≤ … s |
| Paquet modifié, rejoué ou d'une clé inconnue | 100 % refusés (tests XCTest) |
| Face ID annulé | Aucun flux ouvert |
