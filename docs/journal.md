# Journal d'événements signé et chaîné (J2, tâche 18)

Statut : **brouillon B, à relire par A** (A valide la partie conservation et RGPD)

## 1. But

Pouvoir prouver **qui a regardé, quand**, et **quand la supervision a été coupée**, et rendre toute modification détectable (STRIDE R1, R2, T4). L'enfant peut lire ce journal : c'est aussi un outil de **transparence** (A7).

## 2. Ce qui est journalisé (et rien d'autre)

| Code | Événement | Données complémentaires |
|---|---|---|
| 0x01 | APP_STARTED | — |
| 0x02 | PAIRED | `P_pub` complète en x963 (65) |
| 0x03 | REVOKED | Empreinte de `P_pub` (32) |
| 0x04 | SESSION_OPENED | sessionID (8), `TH` (32), `sigP` (64) : preuve signée par le parent |
| 0x05 | SESSION_CLOSED | sessionID (8), raison (1) |
| 0x06 | CAPTURE_STARTED / 0x07 CAPTURE_STOPPED | sessionID (8) |
| 0x08 | PERMISSION_DENIED | — |
| 0x09 | AUTH_FAILURES | Nombre (2), regroupé sur 10 s |
| 0x0A | PURGE_CHECKPOINT | seq (8) et hash (32) de la dernière entrée purgée, hasKey (1), `P_pub` en vigueur juste après elle (65, ou 65 zéros si hasKey = 0) |
| 0x20 / 0x21 | LOCK / UNLOCK (extension) | sessionID (8), durée (4), `nC` (32), `sigP` (64) |

**Jamais dans le journal :** images, noms, nom de l'ordinateur, adresses réseau, clés privées ou de session, contenu de l'écran.

**Pourquoi :** minimisation (RGPD). Un journal sert de preuve, pas de mouchard.

## 3. Format d'une entrée

```text
corps = seq(8) ‖ ts(8) ‖ code(1) ‖ dataLen(2) ‖ data ‖ prevHash(32)
hash  = SHA256("OpenEye/v1/journal" ‖ corps)
sig   = Sign_M(hash)                       // signée par la clé du Mac
entrée stockée = corps ‖ sig(64)
```

- `seq` commence à 1 et augmente de 1 à chaque entrée.
- `prevHash` est le `hash` de l'entrée précédente. La première entrée utilise 32 zéros.
- **Format binaire canonique :** le hash doit porter sur des octets uniques et non ambigus. Le JSON peut écrire la même donnée de plusieurs façons (ordre des clés, espaces). Un export JSON lisible est produit **à côté** pour l'affichage, et il n'est jamais utilisé pour vérifier.

## 4. Vérification

Pour chaque entrée, dans l'ordre :

1. `seq` == précédent + 1 ;
2. `prevHash` == hash de l'entrée précédente ;
3. le hash recalculé correspond ;
4. `sig` est valide avec `M_pub` ;
5. pour `SESSION_OPENED`, `LOCK` et `UNLOCK` : `sigP` est valide sur le contexte signé (voir [protocole.md](protocole.md)), avec la **`P_pub` en vigueur** à cette position.

**Point de départ :**

- **Journal jamais purgé :** la première entrée a `seq = 1` et un `prevHash` de 32 zéros. Aucune `P_pub` n'est en vigueur.
- **Journal purgé :** on prend le `PURGE_CHECKPOINT` **le plus récent** du fichier. La première entrée conservée doit avoir `seq` == seq du checkpoint + 1 et `prevHash` == hash du checkpoint. La `P_pub` de départ est celle du checkpoint (aucune si hasKey = 0).

**Évolution de la `P_pub` en vigueur :** `PAIRED` la remplace, `REVOKED` la supprime. Une entrée `SESSION_OPENED`, `LOCK` ou `UNLOCK` sans `P_pub` en vigueur est un échec.

Premier échec → « Journal altéré à l'entrée n ».

**Pourquoi `P_pub` complète dans `PAIRED`, et non son empreinte :** une empreinte (hash) ne permet pas de vérifier une signature. Or `REVOKED` et un nouvel appairage suppriment `P_pub` du Keychain du Mac. Sans copie dans le journal, les preuves `sigP` des visionnages passés deviendraient invérifiables, ce qui affaiblirait R1 exactement quand il compte (litige après révocation). Une clé **publique** n'est ni un secret ni une donnée personnelle directe : la minimisation est respectée.

**Pourquoi `sessionID` dans `LOCK` et `UNLOCK` :** il fait partie du contexte signé par le parent (`"OpenEye/v1/cmd" ‖ sessionID ‖ nC ‖ typ ‖ durée`). Sans lui, l'entrée seule ne permet pas de reconstituer les octets signés.

## 5. Ce que le chaînage détecte, et ce qu'il ne détecte pas

| Attaque | Détectée ? | Par quoi |
|---|---|---|
| Modifier une entrée | ✅ | Hash et signature |
| Supprimer ou insérer au milieu | ✅ | `seq` et `prevHash` |
| Inventer une entrée « le parent a regardé » | ✅ | `sigP` impossible à produire sans Face ID et la Secure Enclave du parent |
| Supprimer **les dernières** entrées (troncature) | ⚠️ Partiellement | **Ancre côté iPhone** : chaque heartbeat transmet `seq` et le hash de tête. L'iPhone garde le maximum vu, puis à la session suivante demande le hash à cette position (`JournalAnchorRequest`, voir [protocole.md](protocole.md) §5). Une troncature **après** la dernière connexion de l'iPhone reste indétectable. |
| Avancer l'horloge du Mac pour tout purger | ✅ si l'ancre a moins de 29 jours | Ancre datée par l'horloge de l'iPhone |
| **App Mac modifiée** qui garde l'ancien hash et le renvoie | ❌ | Limite assumée : la preuve est produite par le Mac lui-même |
| Enfant administrateur qui efface tout le journal et la clé du Mac | ⚠️ | L'iPhone détecte la clé du Mac changée ou le journal plus court que l'ancre. On ne peut pas l'empêcher (limite assumée). |

**Pourquoi le dire :** le dossier initial affirmait « toute suppression est détectable ». C'est faux pour la fin du journal sans ancre externe. Le jury appréciera qu'on connaisse la limite exacte.

## 6. Conservation et purge

- **Durée proposée :** 30 jours (A valide dans l'analyse RGPD).
- **Purge :** on retire les plus anciennes entrées, **sans trou**, jusqu'à la première qui a moins de 30 jours, et on ajoute `PURGE_CHECKPOINT` en fin de journal. Le tout est écrit en un **remplacement atomique** du fichier : une coupure pendant la purge laisse l'ancien journal complet.

  **Pourquoi copier `P_pub` dans le checkpoint :** si `PAIRED` est purgée, les signatures `sigP` des visionnages conservés deviendraient invérifiables (R1). Garder `PAIRED` seule au milieu d'une zone purgée casserait le chaînage.

  **Limite :** le checkpoint est signé par le Mac, comme `PAIRED`. Le parent doit comparer cette `P_pub` à celle de son iPhone.

  **RGPD (A) :** cette clé publique peut être conservée plus de 30 jours, tant que l'appairage dure ou qu'une entrée conservée en dépend.
- **Avancer l'horloge du Mac déclenche une purge anticipée.** Le Mac ne peut pas s'en rendre compte seul. C'est l'ancre datée de l'iPhone qui le révèle ([protocole.md](protocole.md) §5).
- **Stockage :** un fichier dans le conteneur sandbox de l'app Mac. Il est lisible par l'enfant via l'interface de l'app.
