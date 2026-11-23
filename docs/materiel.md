# Fiche matériel (J1, tâche 01)

Statut : **brouillon B** · Date : 2026-11-23 · Aucun numéro de série ni identifiant d'appareil

| Élément | Valeur | Source |
|---|---|---|
| Mac | Puce Apple M5 | PR #4 |
| macOS | 27.2.1 | PR #4 |
| Xcode | 27.2 | PR #4 |
| iPhone | iPhone 13, Face ID et Secure Enclave | Relevé par B |
| iOS | 27.2.1 | Relevé par B |
| CI | Xcode 27.2, Swift 6.4.2, macOS 27.0.1 | Première exécution du 2026-11-23, PR #5 (app Mac rouge, correctif dans la PR #4) |
| Câble de données reconnu | À COMPLÉTER | B, sur le Mac |
| Compte Apple en Personal Team | À COMPLÉTER | B, sur le Mac |
| App installée sur l'iPhone, date d'expiration | À COMPLÉTER (tâche 09) | B, sur le Mac |

## Contrainte : session Invité (Guest)

Aucun compte macOS permanent n'est possible. Le dossier de la session est effacé à la déconnexion.

| Effacé à chaque déconnexion | Conséquence |
|---|---|
| Code non poussé | Tout pousser avant de partir |
| Compte Apple dans Xcode, certificat | À reconfigurer à chaque séance |
| Clé du Mac, clé publique du parent | L'iPhone refuse le Mac (S2) : réappairage |
| Journal des visionnages | Ne vaut preuve que pendant une séance |

**À vérifier en premier (prototype 14) :** l'autorisation de capture d'écran demande-t-elle un mot de passe administrateur ?

**Démo :** préparer le Mac le jour même et ne plus se déconnecter avant la fin.
