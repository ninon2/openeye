# Plan et backlog OpenEye

Les PDF de cadrage situent les responsabilités, les livrables et les jalons. La section 5 du dossier OpenEye attribue à B le STRIDE et la vérification matérielle au J1. A porte la fiche sujet et obtient la confirmation écrite de l’enseignant sur l’inversion des rôles Mac/iPhone. Le calendrier de la promotion et les versions des appareils sont à confirmer au J1.

Chaque ligne est à la fois une étape et une entrée de backlog. **US** désigne un récit utilisateur, **T** une tâche technique ou d’organisation. Les dépendances sont indiquées par numéro. La difficulté va de 1 à 5. La charge représente le temps de travail de la personne responsable en demi-journées, hors attente externe et hors extensions. Les charges sont des estimations à recalibrer après les prototypes J2. Le travail en parallèle se fait entre A et B, avec des créneaux alternés sur le matériel unique.

| Charge estimée en demi-journées | J1 | J2 | J3 | J4 | J5 | Total |
|---|---:|---:|---:|---:|---:|---:|
| A | 8 | 4 | 7 | 9 | 7 | 35 |
| B | 8 | 17 | 47 | 7 | 3 | 82 |

Le J3 concentre 47 demi-journées pour B. Au J1, comparer cette estimation à la capacité réelle du binôme. Si le calendrier ne couvre pas la charge, chiffrer d’abord les simplifications compatibles avec le MVP, puis soumettre tout changement de périmètre à l’encadrement.

## J1 · Cadrage

| Nº et étape | Jalon | Resp. | Livrable | Dép. | Diff. / charge | Acceptation vérifiable | Risque → réduction |
|---|---|---|---|---|---|---|---|
| 01 T · Inventorier et préparer le matériel | J1 | B | Fiche Mac/iPhone, OS, Xcode, câble de données, compte Apple gratuit | — | 2 / 2 | Xcode et les SDK démarrent, modèle iPhone avec Face ID confirmé, câble reconnu, Personal Team disponible | Incompatibilité → relever les versions avant de figer les cibles |
| 02 T · Planifier les jalons | J1 | A | Calendrier, backlog numéroté, créneaux Mac/iPhone, échéances école | — | 2 / 1 | Dates et responsables validés avec le binôme, marge démo réservée | Conflit matériel → réserver les créneaux dès J1 |
| 03 T · Rédiger la fiche sujet | J1 | A | Fiche de 1–2 pages avec scénario, acteurs, périmètre et limites | — | 2 / 2 | Le pitch, le sens du flux, le rôle de l’iPhone et la transparence sont explicites | MVP trop large → faire valider un périmètre d’une commande minimale |
| 04 T · Faire valider le sujet | J1 | A | Accord écrit de l’enseignant, archivé avec la fiche | 03 | 2 / 1 | L’accord mentionne explicitement Mac capteur et iPhone centrale | Retour tardif → demander l’accord dès 03, suivre l’échéance |
| 05 T · Modéliser les menaces | J1 | B | `docs/stride.md`, flux et frontières de confiance | 03 pour la revue | 4 / 3 | Les six familles STRIDE, actifs, attaquants, contrôles, tests et limites sont tracés à partir du §6 | Menaces génériques → les relier à des flux et critères observables |
| 06 T · Analyser la vie privée | J1 | A | Inventaire, notice enfant, fiche de proportionnalité et conservation | 03 | 3 / 2 | Données, finalités, base applicable à établir, accès, durée, purge et besoin d’AIPD évalués. Démo avec données fictives | Captures sensibles → démontrer avec un bureau de test, minimiser flux et journal |
| 07 T · Préparer Git et le journal IA | J1 | A | `main` protégée, modèles PR/ticket au besoin, journal IA | 02 | 2 / 1 | Une PR sans l’approbation de l’autre membre est bloquée, journal amorcé | Protection indisponible sur le plan choisi → demander une forge pédagogique privée compatible |
| 08 T · Initialiser le workspace | J1 | B | Workspace, deux projets SwiftUI, package local, plist, .gitignore, XCTest vide | 01 | 2 / 2 | Les deux builds résolvent le package et le runner exécute exactement un test initial | Divergence locale → chemins relatifs et schémas partagés |
| 09 T · Installer sur iPhone | J1 | B | Preuve d’installation et note de signature | 08 | 3 / 1 | Les deux écrans s’ouvrent, iPhone installé par câble via Personal Team, expiration relevée | Provisionnement → même bundle ID, vérifier confiance et mode développeur |
| 10 T · Revoir et clore J1 | J1 | A | Fiche livrée, preuves, revue croisée, démo de B à A | 04, 05, 06, 07, 09 | 2 / 1 | Livrable remis, A sait expliquer le STRIDE et le test sur iPhone | Validation implicite → tracer les réserves et leur responsable |

## J2 · Architecture et faisabilité

| Nº et étape | Jalon | Resp. | Livrable | Dép. | Diff. / charge | Acceptation vérifiable | Risque → réduction |
|---|---|---|---|---|---|---|---|
| 11 T · Dessiner l’architecture | J2 | B | Schéma des apps, du package, du transport, des flux et frontières | 05, 10 | 3 / 2 | Capture, commandes, heartbeat, appairage, Keychain et journal figurent avec leurs directions | Couplage → séparer transport, protocole et présentation |
| 12 T · Spécifier l’appairage et la session | J2 | B | Séquences, états, décision crypto liée au STRIDE | 11 | 5 / 3 | QR et empreintes vérifiés dans les deux sens par le parcours choisi, identité liée à l’échange éphémère P‑256 authentifié, HKDF et clés par sens spécifiées, révocation définie | Échange substituable → lier les identités, rôles et clés éphémères au transcript authentifié |
| 13 T · Spécifier paquets et défaillances | J2 | B | Format versionné, tailles, AAD, compteurs, délais, règles de rejet | 12 | 5 / 3 | Règles de nonce unique par clé, fraîcheur, reconnexion et rotation avant épuisement, bornes de réassemblage et état heartbeat explicites | Mémoire ou état incohérent → borner les entrées et ne valider l’état de réception qu’après authentification |
| 14 T · Prototyper capture et H.264 | J2 | B | Prototype local jetable, état des permissions, mesure élémentaire | 09, 11 | 4 / 2 | Une source de test est capturée et encodée, le refus ou l’arrêt interrompt la capture | Permissions macOS → vérifier sur le Mac de démo et sur le parcours réellement choisi |
| 15 T · Prototyper Multipeer | J2 | B | Prototype local jetable et relevé de compatibilité | 09, 11 | 4 / 2 | Connexion et reconnexion sur appareils réels, service Bonjour annoncé, refus réseau testé | Dépréciation et variabilité du lien → conserver le choix imposé au prototype et soumettre toute migration Network à validation |
| 16 T · Prototyper Face ID, clé et action Mac | J2 | B | Essai matériel et note de décision pour la commande du MVP | 09, 11 | 5 / 3 | Signature après Face ID sur iPhone réel, annulation sans signature, faisabilité du verrouillage vérifiée avec une API publique et les droits de l’app | Verrouillage impraticable → faire valider « Message à l’enfant », l’autre commande prévue dans le périmètre, avant de s’engager |
| 17 T · Mesurer la liaison | J2 | A | Tableau débit, latence, pertes et stabilité par scénario | 15 | 3 / 2 | Essais répétables sur Wi‑Fi local et pair à pair si disponible. Bluetooth mesuré seulement si le support est identifiable et exploitable. Profil vidéo initial assorti de seuils mesurables | Supposer quel support est utilisé → noter les conditions et qualifier les mesures incertaines |
| 18 T · Définir le journal et les preuves | J2 | B | Schéma des événements, clés de signature, conservation et vérification | 06, 11, 12 | 4 / 2 | Format minimal signé, chaînage SHA‑256, stockage et purge décrits. Limite de la troncature finale identifiée avec point d’ancrage si sa détection est exigée | Surpromesse du chaînage → distinguer modification interne et suppression d’une fin de journal |
| 19 T · Revoir l’architecture et clore J2 | J2 | A | STRIDE révisé, plan de validation, architecture et choix crypto remis | 13, 14, 16, 17, 18 | 4 / 2 | Chaque contrôle crypto pointe vers une menace et une vérification. Seuils heartbeat, performance et matrice de permissions validés par le binôme | Décisions ouvertes → fixer les seuils avant l’intégration, consigner l’incertitude restante |

Apple a déprécié Multipeer Connectivity à partir de Xcode 27. Le prototype reste sur le transport prévu par le dossier OpenEye. [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework).

## J3 · MVP

| Nº et étape | Jalon | Resp. | Livrable | Dép. | Diff. / charge | Acceptation vérifiable | Risque → réduction |
|---|---|---|---|---|---|---|---|
| 20 T · Créer le codec des paquets | J3 | B | Types, encodeur/décodeur et tests dans OpenEyeCore | 19 | 4 / 3 | Type, taille, version et longueur invalide sont refusés avant traitement du contenu | Format ambigu → spécification binaire et bornes communes |
| 21 US · En tant que parent, j’appaire seulement le bon Mac | J3 | B | Affichage/lecture QR, validation d’empreinte et UI d’appairage/révocation | 12, 19, 22 | 5 / 4 | Bon appareil accepté après confirmation. QR invalide, expiré ou empreinte différente refusés. Révocation impose un nouvel appairage | Appairage silencieux → confirmation explicite et expiration |
| 22 T · Stocker les clés et enregistrer les identités | J3 | B | Secure Enclave, contrôles d’accès et Keychain `ThisDeviceOnly` | 16, 19 | 5 / 4 | Clé de commande créée dans la Secure Enclave de l’iPhone, utilisable après Face ID, et persistance vérifiée après relance | Verrouillage ou changement biométrique → comportement de refus et parcours de récupération vérifié |
| 23 T · Protéger la session et les paquets | J3 | B | Handshake authentifié, ECDH, HKDF, AES‑GCM, anti-rejeu, tests crypto | 20, 22 | 5 / 6 | Vecteurs connus, clé ou identité erronée, contenu altéré, doublon, paquet périmé et ancienne session sont couverts par XCTest | Réutilisation de nonce → clés fraîches par session et sens, compteur géré sans réinitialisation sous la même clé |
| 24 T · Intégrer la connexion | J3 | B | Découverte, ouverture, transport et reconnexion | 15, 20, 21, 23 | 4 / 4 | Une session appairée se reconnecte proprement, le refus réseau donne un état lisible, toute nouvelle session se réauthentifie | États concurrents → borner files et connexions, réinitialiser les états de session |
| 25 US · En tant que personne supervisée, je vois quand l’écran est partagé | J3 | B | Démarrage local, source choisie, indicateur macOS et arrêt | 14, 19 | 5 / 4 | Indicateur visible dès le premier échantillon et jusqu’à l’arrêt. Refus ou indicateur indisponible empêche la capture. Audio et webcam éteints | Visibilité rompue avec changement d’état → nouer l’état de capture à l’indicateur et tester les transitions |
| 26 US · En tant que parent, je vois l’écran en direct | J3 | B | Encodage H.264, découpage borné, déchiffrement, décodage et rendu SwiftUI | 17, 24, 25 | 5 / 7 | Flux synthétique affiché dans les seuils J2. Aucune capture permanente. L’aperçu multitâche ne montre pas le flux | Blocage ou latence → profil fixe mesuré, bornes mémoire, suppression des images tardives |
| 27 US · En tant que parent, j’autorise une action depuis mon iPhone | J3 | B | Commande minimale avalisée, Face ID, signature, validation Mac et confirmation | 16, 24 | 5 / 4 | Une commande valide exécute une fois l’action prévue. Annulation, mauvaise signature ou répétition n’exécutent aucune action | Autorisation trop large → autoriser une action explicite par signature et afficher son résultat |
| 28 US · En tant que parent, je sais si le Mac devient injoignable | J3 | B | Heartbeat authentifié, minuterie et état d’alerte iOS | 24 | 3 / 3 | En iPhone au premier plan, coupure et fermeture Mac déclenchent « Mac injoignable » dans le délai J2. Un heartbeat neuf rétablit l’état après reconnexion | Faux positifs ou suspension iOS → seuil mesuré et resynchronisation au retour au premier plan |
| 29 US · En tant qu’auditeur, je peux vérifier le journal | J3 | B | Journal minimal signé, chaîné par SHA‑256 et vérification | 18, 22, 27, 28 | 5 / 4 | Le vérificateur accepte les entrées légitimes et signale une modification ou rupture de chaîne. Métadonnées minimales, aucun secret ni donnée personnelle dans les logs | Journal bavard → limiter types d’événements, durée et accès, vérifier la purge |
| 30 T · Valider les liaisons au fil des PR | J3 | A | Matrice négative, résultats, tickets et rapport de régression | 19, dès chaque livraison 20–29 | 4 / 5 | Les fixtures invalides, refus de permission, déconnexion et surcharge contrôlée sont couverts sur les builds autorisés. Chaque échec ouvre un ticket | Validation repoussée → réservation matérielle et exécution à chaque PR prête |
| 31 T · Stabiliser et livrer le MVP | J3 | B | Build de référence, résultats XCTest et recette sur les deux appareils | 26, 27, 28, 29, 30 | 4 / 4 | Parcours complet rejoué depuis une installation propre. Chaque critère strict est validé et les défauts bloquants sont résolus | Intégration tardive → assembler tôt des tranches end-to-end |
| 32 T · Enregistrer la démo du MVP | J3 | A | Vidéo de démo, version du code et preuve de remise | 31 | 2 / 2 | On voit le parcours sur les deux appareils avec des données fictives. La version correspond à la recette | Confondre vidéo et enregistrement du flux → filmer la démo isolée, contrôler les écrans et l’accès au fichier |

## J4 · Audit croisé et correctifs

| Nº et étape | Jalon | Resp. | Livrable | Dép. | Diff. / charge | Acceptation vérifiable | Risque → réduction |
|---|---|---|---|---|---|---|---|
| 33 T · Fixer le périmètre d’audit et l’échange | J4 | A | Accord des groupes, versions, cadre, créneaux et grille MASVS | 19, 32 pour l’échange final | 2 / 1 | Périmètre autorisé, jeux de données fictifs et dates confirmés | Attente de l’autre groupe → caler l’échange avant la fin de J3 |
| 34 T · Auditer le projet attribué | J4 | A | Revue, vérifications et rapport MASVS | 33 | 4 / 4 | STORAGE, CRYPTO, AUTH, NETWORK, PLATFORM, CODE, RESILIENCE, PRIVACY couverts ou justifiés. Constats étayés, gravité et correctifs consignés | Rapport vague → lier chaque constat à un contrôle et une preuve expurgée |
| 35 T · Participer à l’audit de l’autre groupe | J4 | B | Revue technique et contribution au rapport d’A | 33 | 4 / 2 | B explique ses constats, en particulier crypto et protocole, et A les intègre au rapport | B saturé → réserver un créneau délimité avant les correctifs |
| 36 T · Trier les constats sur OpenEye | J4 | A | Tickets, gravité et priorités | 33, retour externe | 3 / 2 | Chaque constat a une décision, un responsable, une preuve et une priorité | Retour incomplet → distinguer preuves confirmées et points à clarifier |
| 37 T · Corriger et tester les régressions | J4 | B | PR par correctif, tests et dossier de sécurité mis à jour | 36 | 5 / 5 | Correctifs bloquants approuvés par A, tests de régression et preuve associés au ticket | Correctif qui casse la démo → relancer recette complète sur appareils |
| 38 T · Clore l’audit | J4 | A | Rapport remis, retest des correctifs, bilan des risques résiduels | 34, 35, 37 | 3 / 2 | Dossier relu, résultats de retest joints, risques résiduels expliqués à B | Récidive ou preuve manquante → vérifier les tickets sur le build corrigé |

## J5 · Soutenance

| Nº et étape | Jalon | Resp. | Livrable | Dép. | Diff. / charge | Acceptation vérifiable | Risque → réduction |
|---|---|---|---|---|---|---|---|
| 39 T · Écrire le scénario de démo | J5 | A | Conducteur, supports hors ligne, vidéo de secours, rôles | 32, 38 | 3 / 2 | Appairage, flux, commande, heartbeat et refus d’une fixture de rejeu prévue sont chronométrés. Le repli est accessible | Réseau ou permission défaillante → essai sur place, secours reproductible |
| 40 T · Geler et documenter la version | J5 | B | Version identifiée, étapes de build et dossier crypto relu | 37, 38 | 3 / 2 | Workspace reproductible sur Mac, sources, tests et limites reliés à la version de démo | Régression de dernière minute → geler le build et tester le même état |
| 41 T · Préparer les livrables finaux | J5 | A | Dépôt et revues, STRIDE, choix crypto, journal IA, rapport et correctifs | 38, 40 | 2 / 2 | Liens ouverts depuis un compte autorisé, dossier et slides relus | Accès jury manquant → faire vérifier les droits avant remise |
| 42 T · Répéter les oraux individuels | J5 | A | Répétition chronométrée et questions techniques et éthiques | 39, 40 | 3 / 2 | A et B expliquent chacun les deux apps, la crypto, les limites d’usage et le projet RGPD | Savoir cloisonné → chacun présente la partie tenue par l’autre |
| 43 T · Reprovisionner et vérifier la veille | J5 | B | iPhone réinstallé, Mac préparé, checklist matériel et essai complet | 39, 40 | 3 / 1 | Build de démo installé et ouvert, permissions et charge vérifiées, câble et réseau testés | Expiration à sept jours → relancer sur iPhone physique et noter la date |
| 44 T · Soutenir et remettre | J5 | A | Démo en direct, oraux individuels A/B, preuves de remise | 41, 42, 43 | 3 / 1 | Les deux oraux et la démo sont effectués, les livrables référencent la version présentée | Temps trop court → répartition et plan de secours répétés |

## MVP strict et extensions

Le MVP J3 est validé sur le Mac et l’iPhone physiques avec données synthétiques.

- QR avec vérification d’empreinte, consentement local visible, identités persistées en Keychain `ThisDeviceOnly`, révocation testée.
- Clé iPhone dans la Secure Enclave. Face ID autorise chacune des commandes signées. Le plan J3 privilégie « Verrouiller ». Le dossier autorise une commande minimale parmi « Verrouiller » et « Message à l’enfant ». Le prototype J2 tranche la faisabilité et tout changement est validé avec l’encadrement.
- Session authentifiée, ECDH P‑256 éphémère avec HKDF, AES‑GCM par paquet, nonce unique sous une même clé, compteur et horodatage. Réception hostile traitée avec limites, validation et refus par défaut.
- Écran seul, H.264, chiffré et affiché sur l’iPhone en direct. Indicateur Mac visible pendant toute la capture et arrêt visible. Pas de flux enregistré, ni de micro ou de webcam. Aperçu multitâche protégé.
- Heartbeat authentifié et alerte locale « Mac injoignable » sur iPhone au premier plan. Au retour de l’arrière-plan, afficher l’état après réévaluation. Le timeout indique une perte de contact, avec plusieurs causes possibles.
- Journal minimal signé et chaîné par SHA‑256, tests XCTest et recette négative, démo J3 enregistrée avec données synthétiques.

| Extension après stabilisation et audit | Jalon / resp. | Livrable et vérification | Dép. | Diff. / charge | Risque → réduction |
|---|---|---|---|---|---|
| Seconde commande | J4–J5 / B | PR et test de consentement biométrique et de résultat | 38 | 3 / 2 | Surface accrue → valider un type explicite et borné |
| Webcam ponctuelle | J4–J5 / B | Opt-in local visible, droit caméra dédié, tests de refus et d’arrêt | 38 | 4 / 4 | Intrusion → durée bornée, désactivée par défaut et consentement visible |
| Débit adaptatif | J4–J5 / B | Réglage d’encodage et mesures avant/après | 38 | 4 / 3 | Oscillations → paliers et essais sur liaisons dégradées |
| Renouvellement périodique des clés | J4–J5 / B | Politique et tests de transition sans réemploi de nonce | 38 | 5 / 4 | Courses entre sessions → transition authentifiée et états séparés |
| Padding | J4–J5 / B | Profil de remplissage et mesure du coût | 38 | 4 / 3 | Débit trop élevé → budget et mesure avant adoption |
| Captures d’alerte chiffrées | J4–J5 / B | Prototype conditionné à une nouvelle décision de périmètre et de conservation | 38, 06 | 5 / 5 | Création de données persistantes → réexaminer la proportionnalité et minimiser ou écarter |
| Relais distant | J4–J5 / B | Étude, décision d’architecture et prototype si avalisé | 38, 06 | 5 / 6 | Exposition externe → réévaluer menaces et confidentialité avant tout changement |

La recommandation CNIL soutient la transparence envers l’enfant, la proportionnalité et la prise en compte de sa maturité. Dans le dossier RGPD, distinguer la démonstration scolaire sur données fictives d’un éventuel usage réel. [CNIL](https://www.cnil.fr/fr/recommandation-5-promouvoir-des-outils-de-controle-parental-respectueux-de-la-vie-privee-et-de).

## Git, revues et rythme du binôme

1. A vérifie les droits sur `origin`, initialise `main` avec un commit de démarrage si la forge est vide, et active la protection avant la première PR du projet. Dans GitHub, ouvrir **Settings > Branches** ou **Settings > Rules > Rulesets** et cibler `main`. Exiger une PR, une approbation de l’autre membre, la résolution des conversations et une nouvelle approbation après modification significative en utilisant l’invalidation des approbations obsolètes. Interdire push direct, force-push, suppression et contournement des règles. Activer les checks obligatoires quand leur exécution et leur disponibilité sont confirmées. Un dépôt privé GitHub nécessite un plan compatible pour la protection native. [Protection des branches GitHub](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
2. Une branche par ticket depuis `main` à jour. Exemples `docs/j1-05-stride`, `feat/j3-21-appairage`, `fix/j4-37-journal`, `test/j3-30-recette`. Commits atomiques au présent, par exemple `docs: rédiger le STRIDE (#5)` ou `test: couvrir le refus d’appairage (#21)`. Relire le diff avant push et vérifier qu’il ne contient ni secret, ni profil de signature, ni donnée personnelle.
3. Ouvrir une PR dès que le périmètre est lisible. Indiquer ticket, menace visée, changements, critères et preuves de test, et entrée du journal IA si applicable. L’autre membre commente puis approuve la dernière révision. L’auteur traite les retours. Garder l’approbation de la forge et le lien ticket → PR → version livrée. Un squash par PR est possible avec numéro de ticket et conservation de la PR.
4. Faire un point d’équipe hebdomadaire de 20 à 30 minutes pour les dépendances, le matériel et les décisions. Ajouter un court point au passage de chaque jalon. B fait la démo technique à A, puis A réexplique le code. Réserver une plage récurrente pour les essais d’A. Le rôle red team tourne à chaque jalon selon le dossier, avec responsabilité et participants tracés. A reste responsable de la matrice de recette et B participe au J4.
5. Quand B signale une liaison prête, A vérifie pendant la revue, idéalement dans le prochain créneau matériel. A trace le build, les scénarios de refus, les résultats et les défauts. B ajoute les XCTest crypto et les correctifs Swift. A prépare en parallèle les fixtures inoffensives, les checklists et les jeux de données synthétiques. A peut automatiser la collecte des mesures et l’exécution des tests existants avec des scripts système, préparer les tickets, notices, matrices, rapport, journal IA et conducteur, et gérer la remise à l’école.
6. À chaque jalon, archiver le livrable et référencer le commit ou le tag de démonstration. Les commentaires de revue, approbations, résultats et retests restent sur les PR et tickets. Pour les résultats obtenus sur appareil, noter versions et étapes sans numéro de série ni capture personnelle.

### Définition de terminé

- [ ] Le ticket a un livrable, des critères vérifiables et une PR liée.
- [ ] La branche est à jour et le diff a été vérifié, y compris les données d’exemple, les logs et la configuration de signature.
- [ ] Les tests pertinents passent. Les opérations qui dépendent de la biométrie, des permissions ou du réseau ont un résultat sur les appareils réels.
- [ ] Le comportement en refus et les cas négatifs applicables ont été vérifiés dans le périmètre autorisé. Pour une tâche sans surface de sécurité pertinente, le ticket indique pourquoi ce contrôle est sans objet.
- [ ] L’autre membre a relu et approuvé la version finale. Les opérations crypto ont fait l’objet d’une relecture humaine ligne par ligne.
- [ ] Les décisions, limites, permissions et menaces modifiées sont documentées. Si l’IA a été utilisée, le prompt expurgé et la validation humaine figurent dans le journal.
- [ ] Les défauts sont tracés et les bloquants corrigés. Le merge passe par la PR vers `main` protégée.

## Chemin critique

La séquence ci-dessous est le chemin critique prévisionnel. A et B recalculent les marges après confirmation des dates, des créneaux matériels et du retour d’audit. Les dépendances de personnel comptent aussi, puisque B porte les deux apps.

1. **J1** — **01 → 08 → 09 → 10**. En parallèle, **03 → 04** et **05–07 → 10**. Sans validation du sujet ou installation physique, les prototypes de J2 et la validation de l’architecture glissent.
2. **J2** — **10 → 11 → 12 → 13 → 19**. Les prototypes **14–16**, la mesure **15 → 17** et le journal **18** conditionnent aussi **19**. Prioriser Face ID et la commande, la capture, puis la capacité du lien sur le matériel disponible.
3. **J3** — **19 → 20/22 → 21/23 → 24 → 26 → 31 → 32**. La vidéo dépend aussi de l’indicateur **25**. La branche **24 → 27/28 → 29 → 31** et les validations continues **30** doivent converger avant la recette. Avec un seul développeur Swift, ces branches partagent la même capacité.
4. **J4/J5** — **32 → 33 → retour externe → 36 → 37 → 38 → 40 → 43 → 44**. Le rapport **34/35** est une condition de **38**. Les branches **39 → 42** et **41** doivent arriver avant **44**. Les marges prioritaires portent sur la réponse de l’enseignant, l’échange intergroupe et la vérification de la version reprovisionnée sur l’iPhone la veille.
