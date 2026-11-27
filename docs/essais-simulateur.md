# Essais sur simulateur (sans iPhone ni droits administrateur)

Fiche de répétition. **La démo finale se fait sur le vrai iPhone 13** : vrai Face ID, vraie Secure Enclave, aucune commande à taper.
Sur simulateur, il n'y a ni Secure Enclave (clé logicielle de repli) ni visage : ces essais vérifient le parcours, pas la sécurité matérielle.

## 1. Face ID sur le simulateur

Le simulateur n'a pas de caméra. Il attend un signal « visage reconnu » ou « refusé », envoyé depuis le **Terminal** (icône `>_` dans le Dock).
`booted` désigne le simulateur allumé.

Une seule fois par simulateur neuf, **inscrire un visage** :

```sh
xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.enrollmentChanged
```

À chaque carré gris « Face ID » sur l'iPhone, **visage reconnu** :

```sh
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.match
```

Pour montrer un **refus** (mauvais visage) :

```sh
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.nomatch
```

Astuce : collez la commande dans le Terminal sans appuyer sur Entrée ; au moment du Face ID, cliquez dans le Terminal puis Entrée. La flèche ↑ rappelle la dernière commande.
Cette commande ne fonctionne que sur le simulateur : elle ne contourne pas le Face ID d'un vrai iPhone.

## 2. Appairage

| Étape | Où | Action |
|---|---|---|
| 1 | Mac | « Appairer l'iPhone du parent », puis « Copier le texte du QR (debug) ». **120 s pour scanner.** |
| 2 | iPhone | « Scanner le QR », clic dans le champ, ⌘V, « Valider » |
| 3 | Terminal | Commande « visage reconnu » au carré gris Face ID |
| 4 | Les deux | Comparer les 6 chiffres, puis « Les codes correspondent » sur chaque appareil, dans l'ordre voulu. **5 min** à partir du « Valider ». |

## 3. Visionnage

| Étape | Où | Action | Attendu |
|---|---|---|---|
| 1 | iPhone | « Voir l'écran (Face ID) » | Carré gris Face ID |
| 2 | Terminal | Commande « visage reconnu » | Bandeau rouge en haut du Mac |
| 3 | iPhone | — | **Écran réel** si macOS autorise la capture ; sinon, en Debug, **mire de test** (« MIRE DE TEST — ce n'est pas l'écran du Mac ») |
| 4 | Mac | La 1re fois, macOS demande l'accès à la caméra | Bandeau « Écran ET caméra partagés avec le parent » |
| 5 | iPhone | — | **Caméra en vignette en bas à droite**, en direct, pendant tout le visionnage ; sinon, en Debug, « MIRE CAMÉRA — accès caméra refusé » |

Sans droits administrateur, macOS refuse la capture : le refus est inscrit au journal, puis la mire prend le relais (Debug uniquement ; en Release, rien n'est partagé).

## 4. Commandes signées (Face ID à chaque fois)

| Commande | Durées | Plafond imposé par le Mac | Attendu sur le Mac |
|---|---|---|---|
| Verrouiller | 30 s, 5, 10, 15 min | 15 min | Écran noir « Verrouillé par ton parent », bandeau rouge au-dessus, fin automatique |
| Déverrouiller | — | — | Écran de blocage retiré |

La caméra fait partie du visionnage : elle démarre avec lui, sans bouton ni durée, et s'arrête avec lui (bouton « Arrêter », app en arrière-plan, coupure, fin de session).
Caméra refusée par macOS : en Debug, vignette « MIRE CAMÉRA — accès caméra refusé » ; en Release, écran seul.

## 5. Attaques à montrer

| Attaque | Comment | Attendu |
|---|---|---|
| Mauvais visage | Commande `nomatch` au Face ID | Aucune commande envoyée, aucun visionnage ouvert |
| Mac injoignable | Quitter l'app Mac pendant le visionnage | « Mac injoignable » sur l'iPhone en 6 s environ |
| iPhone révoqué | « Révoquer l'iPhone » sur le Mac, puis « Voir l'écran » | Visionnage refusé, aucune ligne « Visionnage ouvert » au journal |
| Journal modifié | « Vérifier le journal » sur le Mac | « Journal intact » ; toute modification du fichier est détectée |

## 6. Problèmes connus sur le Mac de l'école (session Invité)

- **Fenêtre « OpenEye wants to use your confidential information… keychain »** après chaque recompilation de l'app Mac : cliquer « Deny ». L'app crée une nouvelle clé (empreinte « Ce Mac » différente) : sur l'iPhone, « ⋯ → Oublier ce Mac », puis réappairer.
- **Capture d'écran** : demande un administrateur ; sans lui, mire de test (Debug).
- Tout est effacé à la déconnexion de la session Invité : clés, appairage, journal.
