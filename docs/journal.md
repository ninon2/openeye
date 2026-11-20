# Journal d'événements signé et chaîné (J2, tâche 18)

Statut : **brouillon B, à relire par A** (A valide la partie conservation et RGPD)

## 1. But

Pouvoir prouver **qui a regardé, quand**, et **quand la supervision a été coupée**, et rendre toute modification détectable (STRIDE R1, R2, T4). L'enfant peut lire ce journal : c'est aussi un outil de **transparence** (A7).

## 2. Ce qui est journalisé (et rien d'autre)

| Code | Événement | Données complémentaires |
|---|---|---|
| 0x01 | APP_STARTED | — |
| 0x02 | PAIRED | Empreinte de `P_pub` (32) |
| 0x03 | REVOKED | Empreinte de `P_pub` (32) |
| 0x04 | SESSION_OPENED | sessionID (8), `TH` (32), `sigP` (64) : preuve signée par le parent |
| 0x05 | SESSION_CLOSED | sessionID (8), raison (1) |
| 0x06 | CAPTURE_STARTED / 0x07 CAPTURE_STOPPED | sessionID (8) |
| 0x08 | PERMISSION_DENIED | — |
| 0x09 | AUTH_FAILURES | Nombre (2), regroupé sur 10 s |
| 0x0A | PURGE_CHECKPOINT | seq et hash de la dernière entrée purgée |
| 0x20 / 0x21 | LOCK / UNLOCK (extension) | Durée (4), `nC` (32), `sigP` (64) |

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
5. pour `SESSION_OPENED` et `LOCK` : `sigP` est valide avec `P_pub` sur le contexte signé (voir [protocole.md](protocole.md)).

Premier échec → « Journal altéré à l'entrée n ».

## 5. Ce que le chaînage détecte, et ce qu'il ne détecte pas

| Attaque | Détectée ? | Par quoi |
|---|---|---|
| Modifier une entrée | ✅ | Hash et signature |
| Supprimer ou insérer au milieu | ✅ | `seq` et `prevHash` |
| Inventer une entrée « le parent a regardé » | ✅ | `sigP` impossible à produire sans Face ID et la Secure Enclave du parent |
| Supprimer **les dernières** entrées (troncature) | ⚠️ Partiellement | **Ancre côté iPhone** : chaque heartbeat transmet `seq` et le hash de tête. L'iPhone garde le maximum vu. Une troncature **après** la dernière connexion de l'iPhone reste indétectable. |
| Enfant administrateur qui efface tout le journal et la clé du Mac | ⚠️ | L'iPhone détecte la clé du Mac changée ou le journal plus court que l'ancre. On ne peut pas l'empêcher (limite assumée). |

**Pourquoi le dire :** le dossier initial affirmait « toute suppression est détectable ». C'est faux pour la fin du journal sans ancre externe. Le jury appréciera qu'on connaisse la limite exacte.

## 6. Conservation et purge

- **Durée proposée :** 30 jours (A valide dans l'analyse RGPD).
- **Purge :** on supprime les entrées trop anciennes, puis on ajoute `PURGE_CHECKPOINT` avec le `seq` et le hash de la dernière entrée supprimée. La chaîne reste vérifiable à partir de ce point.
- **Stockage :** un fichier dans le conteneur sandbox de l'app Mac. Il est lisible par l'enfant via l'interface de l'app.
