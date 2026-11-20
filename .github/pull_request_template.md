## Ticket

Ticket nº : <!-- ex. #23 -->
Jalon : <!-- J1 / J2 / J3 / J4 / J5 -->

## Ce que fait cette PR

<!-- 2 à 5 lignes. Ce qui change et pourquoi. -->

## Menaces visées (docs/stride.md)

<!-- IDs STRIDE couverts ou touchés, ex. S1, T1, E3. « Aucune » si docs ou outillage seuls. -->

## Preuves de test

- [ ] XCTest : <!-- tests ajoutés / lancés, résultat -->
- [ ] Sur appareils réels : <!-- iPhone 13 / Mac, versions, scénario, résultat -->
- [ ] Cas négatifs : <!-- paquet modifié, rejoué, clé inconnue, Face ID annulé… -->

## Usage de l'IA

- [ ] Aucune IA utilisée
- [ ] IA utilisée : entrée ajoutée dans `docs/journal-ia.md` (date, prompt expurgé, retenu/écarté)

## Checklist sécurité (auteur)

- [ ] Aucun secret, clé, mot de passe, jeton ni identifiant d'équipe Apple dans le diff
- [ ] Aucun profil de signature, certificat ni fichier `xcuserdata` ajouté
- [ ] Aucune donnée personnelle ni vraie capture d'écran (données fictives uniquement)
- [ ] Aucun log contenant secret, image, clé ou donnée personnelle
- [ ] Aucune dépendance externe ajoutée (sinon : justification écrite ci-dessous)
- [ ] Crypto uniquement via CryptoKit / Security, aucun algorithme maison
- [ ] Nonce unique par clé, aucun IV fixe, aléa issu de `SecRandomCopyBytes` ou CryptoKit
- [ ] Toute donnée réseau validée (taille, version, type, format) avant usage
- [ ] En cas d'erreur, le code refuse ou verrouille (échec sûr)
- [ ] Permissions et droits ajoutés justifiés (moindre privilège)
- [ ] Je sais expliquer chaque ligne de ce diff à l'oral

## Revue (relecteur)

- [ ] J'ai relu le diff ligne à ligne (ligne à ligne obligatoire pour le code crypto)
- [ ] J'ai lancé les tests ou rejoué le scénario
- [ ] Je saurais réexpliquer ce code avec mes mots
