# Ma checklist — cheffe de projet et red team (A)

Je suis ici mes actions dans OpenEye. Cette checklist complète le [plan détaillé du projet](plan-projet.md), qui reste ma référence pour les critères d’acceptation, les dépendances et les détails techniques. Je mets à jour l’état, la date et la preuve au fil du projet, puis je reporte les décisions durables dans les documents concernés.

## Légende et règle de mise à jour

- ⬜ À faire
- 🟠 Commencé
- 🟡 Fait, en attente de revue ou validation
- ✅ Fait et validé

Pour chaque ligne, j’ajoute une date et un lien vers la preuve (document, PR, ticket, résultat ou compte rendu). Je marque ✅ quand le critère vérifiable est satisfait. Si une tâche est bloquée, je note le blocage, la personne à relancer et la prochaine date de suivi. Les états initiaux ci-dessous reprennent mes captures de suivi du 23/11/2026 ; je les confirme au fur et à mesure, car ils peuvent différer de l’état actuel du dépôt.

## J1 — Cadrage et pilotage

| État | Nº | Action de A | Preuve / prochaine étape |
|---|---:|---|---|
| ⬜ | 02 | Je fixe les dates, les échéances école et les créneaux Mac/iPhone, puis je fais valider le calendrier par ma camarade. | Capture : backlog prêt, mais aucune trace des dates. J’ajoute le calendrier et son lien ici. |
| 🟠 | 03 | Je complète et remets la fiche sujet avec le scénario, le périmètre MVP et l’inversion des rôles. | Capture : ma camarade a préparé la trame (PR #2). Je complète, fais relire et archive la fiche. |
| 🟠 | 04 | J’obtiens et archive l’accord écrit de l’enseignant sur les rôles inversés et le MVP. | Capture : accord oral seulement. Je demande la confirmation écrite et note la date de relance. |
| ⬜ | 06 | Je documente les données, la notice destinée à l’enfant, la durée de conservation et le besoin éventuel d’AIPD. | Capture : aucune trace. Je distingue la démo sur données fictives d’un usage réel. |
| 🟠 | 07 | Je tiens le journal IA et vérifie le flux Git/revue autour de `main`. | Capture : entrées du 23/11 manquantes. Je complète le journal et vérifie les règles réellement disponibles sur la forge. |
| 🟠 | 10 | Je vérifie les livrables J1, réexplique le STRIDE et consigne la démonstration sur iPhone. | Capture : à faire après les tâches 03–09 ; je lie les preuves et réserves. |

## J2 — Architecture, faisabilité et revue

| État | Nº | Action de A | Preuve / prochaine étape |
|---|---:|---|---|
| 🟡 | 11 | Je relis l’architecture (PR #3), vérifie les flux et note les questions ou risques à clarifier. | Capture : fait, en attente de revue. Je lie la revue et les commentaires résolus. |
| 🟡 | 12 | Je relis l’appairage et la session : QR, handshake, identité, clés et révocation ; je cherche les contournements. | Capture : fait, en attente de revue. Je conserve les scénarios et résultats de vérification. |
| 🟡 | 13 | Je relis le format des paquets et les rejets : tailles, bornes, ordre de validation et entrées malformées. | Capture : fait, en attente de revue. Je lie la spécification et mes remarques. |
| ⬜ | 14 | Je teste le refus de permission et vérifie qu’aucune capture ne démarre sans signal visible. | Capture : signalé « Risque nº 1 », test non tracé. Je teste sur le Mac autorisé et consigne le résultat. |
| ⬜ | 15 | Je teste la connexion et la reconnexion Mac/iPhone sur les appareils disponibles. | Capture : à faire. Je note le transport et les conditions observées. |
| ⬜ | 16 | Je teste l’annulation Face ID et vérifie qu’elle n’autorise ni signature ni commande. | Capture : à faire. Je note modèle/versions sans identifiant personnel. |
| ⬜ | 17 | Je mesure débit, latence, pertes et stabilité selon des scénarios reproductibles. | Capture : dépend du prototype 15. J’ajoute les mesures et les seuils retenus. |
| 🟡 | 18 | Je relis le journal signé : conservation, chaîne, purge et limites de détection. | Capture : fait, en attente de revue. Je documente les limites résiduelles. |
| ⬜ | 19 | Je valide la clôture J2 : menaces, seuils, permissions, choix techniques et décisions ouvertes. | Capture : à faire. Je lie le compte rendu et les décisions acceptées par le binôme. |

## J3 — Tests d’attaque à chaque livraison

Pour chaque liaison livrée, je conserve le build/commit testé, le scénario, le résultat attendu, le résultat observé et la preuve expurgée. Je crée un ticket pour chaque anomalie et je n’y inclus aucune donnée personnelle ni aucun secret.

| État | Nº | Action de A | Preuve / prochaine étape |
|---|---:|---|---|
| 🟠 | 20 | J’attaque le codec : mauvais type, version, taille, longueur, troncature et données incohérentes. | Capture : tests annoncés non exécutés. Je complète la recette négative et crée un ticket par défaut. |
| ⬜ | 21 | Je teste les QR expirés, réutilisés ou photographiés, les mauvais codes et les empreintes/appareils différents. | Je consigne acceptation/refus, expiration et révocation. |
| ⬜ | 22 | Je vérifie que clés et sauvegardes n’exposent pas de secrets et teste les refus Face ID. | Je consigne mes observations sans extraire ni publier de clés. |
| ⬜ | 23 | Je teste le rejeu, le paquet modifié, le mauvais tag, le compteur invalide, l’ancienne session et le faux pair. | Je relie chaque test à la menace, au résultat et au ticket éventuel. |
| ⬜ | 24 | Je teste la coupure réseau, la reconnexion, le second appareil et la surcharge contrôlée. | Je vérifie la réauthentification et l’état visible après perte de connexion. |
| ⬜ | 25 | Je cherche une capture sans indicateur et vérifie l’arrêt au refus et à l’arrêt explicite. | Je note les transitions observées sur Mac. |
| ⬜ | 26 | Je vérifie le flux vidéo et confirme qu’aucune image n’est enregistrée ou affichée après l’arrêt. | J’utilise un écran de test et des données fictives, puis je note les limites. |
| ⬜ | 27 | Je teste Face ID annulé, autorisation ancienne et rejeu d’une commande signée. | Je vérifie qu’aucune commande ne s’exécute sans autorisation fraîche. |
| ⬜ | 28 | Je ferme l’app ou coupe le réseau et mesure le délai et le texte de l’alerte heartbeat. | Je distingue la perte de contact de sa cause, qui n’est pas toujours connue. |
| ⬜ | 29 | Je tente la modification, la suppression, le réordonnancement et la troncature du journal. | Je vérifie ce qui est détecté et consigne les limites de la chaîne. |
| ⬜ | 30 | Je tiens la matrice de recette, ouvre un ticket par faille et reteste les corrections livrées. | Je relie chaque résultat à la PR, au ticket et au build testé. |
| ⬜ | 31 | Je rejoue le parcours complet sur le build de référence après stabilisation. | J’archive commit/version, appareils, conditions et résultats. |
| ⬜ | 32 | Je prépare et vérifie la démonstration filmée avec données fictives et scénario de secours. | Je confirme que les preuves ne contiennent aucune donnée sensible. |

## J4 — Audit croisé et rapport

| État | Nº | Action de A | Preuve / prochaine étape |
|---|---:|---|---|
| ⬜ | 33 | Je m’accorde avec l’autre groupe sur le périmètre autorisé, les dates, la version et la grille MASVS. | J’ajoute le nom/version audités et l’accord de périmètre. |
| ⬜ | 34 | J’audite l’application attribuée sur les huit domaines MASVS et rédige des constats étayés. | Pour chaque constat, je note l’ID, le domaine, la preuve, l’impact, la gravité, la reproductibilité et la recommandation. |
| ⬜ | 35 | J’intègre les apports techniques de ma camarade à l’audit et au rapport. | Je distingue les constats confirmés des points à vérifier. |
| ⬜ | 36 | Je trie les failles OpenEye par gravité, priorité, responsable et ticket. | J’inclus les failles non corrigées avec leur statut et leur risque résiduel. |
| ⬜ | 37 | Je relis les PR correctives et vérifie qu’un test de régression couvre chaque faille. | J’ajoute les résultats de retest, y compris les échecs et reports. |
| ⬜ | 38 | Je finalise le rapport, le bilan des risques résiduels et la clôture de l’audit. | Je relie constat → ticket → correction éventuelle → preuve de retest. |
| ⬜ | Ext. | Je teste les commandes de verrouillage (L1–L9) dans le cadre autorisé et vérifie l’écran de blocage. | Je le fais seulement si le MVP est stable et auditable ; je consigne le périmètre et les résultats. |

## J5 — Soutenance et remise

| État | Nº | Action de A | Preuve / prochaine étape |
|---|---:|---|---|
| ⬜ | 39 | J’écris le scénario de démonstration, prévois le rejeu refusé et une vidéo de secours. | Je répète et chronomètre le parcours. |
| ⬜ | 41 | J’assemble le dépôt, les revues, le STRIDE, le journal IA, le rapport d’audit et les correctifs. | Je vérifie les liens, l’accès et la cohérence de version. |
| ⬜ | 42 | Je répète mon oral individuel et me prépare à expliquer tout le code et les choix RGPD/sécurité. | Je prépare les questions et fais une répétition chronométrée. |
| ⬜ | 44 | Je fais la démonstration, mon oral et la remise des livrables. | Je lie la version présentée et les preuves de remise. |

## Journal des mises à jour

| Date | Tâches modifiées | Décision, preuve ou blocage | Prochaine action |
|---|---|---|---|
| 23/11/2026 | États initiaux reportés de mes captures | État de départ à confirmer ; tâches 03/04/06/07 prioritaires selon mon bilan. | Je renseigne les dates, complète les preuves manquantes et mets à jour chaque tâche après revue/test. |

## Sources et distinction des consignes

- Le dossier de projet attribue à A le pilotage, le journal IA, le RGPD, les tests d’attaque des liaisons, le rapport d’audit croisé, les revues et les livrables de soutenance. Il fixe les jalons et le périmètre du travail.
- La seconde fiche OpenEye précise les livrables techniques et critères du projet ; le plan du dépôt développe ces tâches et leurs dépendances.
- Mes captures `afaire1.png` à `afaire3.png` montrent mon suivi de progression ; ce ne sont pas des consignes supplémentaires du sujet. J’ai repris leurs états comme point de départ, sans les considérer comme vérifiés dans le dépôt.
