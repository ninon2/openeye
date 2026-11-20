# Initialiser OpenEye sur le Mac

## 1. Préparer le Mac et l’iPhone

1. Note les versions de macOS et iOS, le modèle d’iPhone, la disponibilité de Face ID et celle de la Secure Enclave sur le Mac si vous envisagez de l’utiliser pour son identité. L’iPhone physique est indispensable pour valider Face ID et la protection matérielle des clés.
2. Installe une version de Xcode compatible avec les deux appareils, ouvre-la et termine l’installation des composants iOS et macOS. Dans **Xcode > Settings > Locations**, sélectionne les Command Line Tools de ce Xcode. Vérifie avec `xcodebuild -version` et `swift --version`. Le socle utilise un manifeste Swift 5.9 et des cibles provisoires iOS 17 et macOS 14, à confirmer avec les appareils.
3. Dans **Xcode > Settings > Accounts**, ajoute ton compte Apple. Une fois l’inscription gratuite acceptée, ce compte apparaît comme **Personal Team**. Les profils de provisionnement gratuit expirent après sept jours. La veille de la soutenance, reconstruis puis réinstalle et relance l’app sur l’iPhone. [Compte développeur Apple](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## 2. Ouvrir le workspace fourni

Sur le Mac, place-toi dans le dossier `openeye` et ouvre `OpenEye.xcworkspace` depuis Finder ou avec `open OpenEye.xcworkspace`. Le workspace contient deux projets et les deux cibles référencent le même package local. Sélectionne successivement `OpenEyeMac` avec **My Mac**, puis `OpenEyeIOS` avec un simulateur compatible. Pour chacun, lance **Product > Build**, puis **Product > Run** quand la destination est prête. Le texte « OpenEye » est fourni par le package dans les deux apps.

```text
openeye/
├── .gitignore
├── OpenEye.xcworkspace/
├── OpenEyeCore/
│   ├── Package.swift
│   ├── Sources/OpenEyeCore/OpenEyeCore.swift
│   └── Tests/OpenEyeCoreTests/OpenEyeCoreTests.swift
├── ios/
│   ├── OpenEyeIOS.xcodeproj/
│   └── OpenEyeIOS/
└── macos/
    ├── OpenEyeMac.xcodeproj/
    └── OpenEyeMac/
```

### Recréer la structure dans un dossier vide

1. **File > New > Workspace**. Nomme-le `OpenEye` et enregistre-le à la racine d’`openeye`.
2. Crée `ios/` et `macos/`. Avec le workspace ouvert, fais **File > New > Project > iOS > App**. Choisis `OpenEyeIOS`, **SwiftUI**, **Swift**, sans stockage additionnel et sans tests d’app pour ce socle. Enregistre dans `ios/`. Décoche la création d’un dépôt Git imbriqué. Utilise **Add to** pour ajouter le projet au workspace si Xcode le propose, ou glisse le fichier `OpenEyeIOS.xcodeproj` dans son navigateur avec la copie désactivée.
3. Répète via **File > New > Project > macOS > App** avec `OpenEyeMac` dans `macos/`. Sélectionne les cibles et règle les versions minimales dans **General** ou **Build Settings**.
4. Crée le dossier `OpenEyeCore/` et ses trois fichiers Swift comme dans l’arborescence. Tu peux aussi partir de **File > New > Package > Library** si ce modèle est proposé et remplacer ses sources et son manifeste par les fichiers fournis. Le projet iOS, puis le projet macOS, doivent chacun référencer ce dossier. Pour chaque projet, ouvre-le individuellement si nécessaire, choisis **File > Add Package Dependencies > Add Local**, sélectionne `openeye/OpenEyeCore`, et lie le produit `OpenEyeCore` à la cible de l’app. Vérifie dans **General > Frameworks, Libraries, and Embedded Content** ou **Build Phases > Link Binary With Libraries**. Ferme les projets individuels et rouvre le workspace. [Dépendance locale dans Xcode](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)
5. Copie le `Info.plist` de chaque app dans son dossier source, règle **Generate Info.plist File** sur **Yes** et **Info.plist File** sur le chemin relatif du fichier (`OpenEyeIOS/Info.plist` ou `OpenEyeMac/Info.plist`). Vérifie que le fichier est absent de **Copy Bundle Resources**. Garde **App Sandbox** actif sur la cible Mac. Dans **Product > Scheme > Manage Schemes**, partage les schémas des deux apps. Versionne le workspace, les deux projets, les schémas partagés, les plists et les sources. Le `.gitignore` exclut les caches, réglages utilisateur et fichiers de signature locaux.

## 3. Installer l’app sur l’iPhone par câble

1. Branche l’iPhone avec un câble capable de transférer des données. Déverrouille-le et accepte **Faire confiance à cet ordinateur** si iOS le demande.
2. Dans Xcode, vérifie son état dans le gestionnaire des appareils (**Window > Devices and Simulators** selon la version de Xcode), puis attends que l’appareil soit prêt. Sur l’iPhone, ouvre **Réglages > Confidentialité et sécurité > Mode développeur**, active-le, redémarre et confirme avec le code de l’appareil. L’option apparaît après l’amorce du jumelage. [Mode développeur](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
3. Dans la cible `OpenEyeIOS`, ouvre **Signing & Capabilities**, coche **Automatically manage signing** et sélectionne **Personal Team**. Si l’identifiant `fr.openeye.m2.ios` est déjà pris, sélectionne un identifiant unique pour le projet et garde-le stable lors des réinstallations. Le nom d’équipe personnel sert à la configuration locale. Avant une PR, vérifie le diff de `project.pbxproj` et retire toute valeur personnelle de `DEVELOPMENT_TEAM` introduite par Xcode. Pour compiler sur **My Mac**, utilise la signature locale de développement proposée par Xcode et garde l’identifiant macOS stable pour les permissions.
4. Choisis **OpenEyeIOS > [ton iPhone]** et fais **Product > Run**. Si iOS demande de faire confiance au profil développeur, fais-le dans **Réglages > Général > VPN et gestion de l’appareil**, puis relance. Vérifie que l’app affiche « OpenEye » et « iPhone du parent ». Pour valider J1, consigne les versions, le résultat et la date de la prochaine réinstallation, sans identifiant de l’iPhone.
5. En cas d’échec, lis le premier message de signature. Vérifie l’état du câble, du jumelage, du mode développeur, du compte et du provisionnement, puis la compatibilité de la version iOS et l’unicité du bundle ID. Sur le Mac, lance aussi `OpenEyeMac` avec **My Mac**.

## 4. Déclarer et vérifier les permissions

Les chaînes `Info.plist` expliquent l’accès. Le système demande l’autorisation au moment où le code appelle la fonctionnalité. Les écrans du socle n’appellent aucune de ces API.

| Où | Clé ou réglage | Accès et moindre privilège |
|---|---|---|
| iPhone | `NSCameraUsageDescription` | Lire le QR affiché par le Mac dans l’écran d’appairage seulement. Arrêter la caméra après lecture ou annulation. La lecture QR n’utilise pas le micro. |
| iPhone | `NSFaceIDUsageDescription` | Autoriser la signature d’une commande sensible via LocalAuthentication et le contrôle d’accès de la clé. Demander l’autorisation au moment du geste, et traiter l’annulation ou l’indisponibilité par un refus de la commande. |
| iPhone et Mac | `NSLocalNetworkUsageDescription` et `NSBonjourServices` | Découvrir l’autre appareil et établir la connexion au moment de l’appairage ou d’une séance. Pour `serviceType = "openeye"` avec Multipeer, l’entrée exacte est `_openeye._tcp`, dans un tableau. Tester sur l’iPhone physique et sur le macOS de l’équipe, y compris le refus. |
| Mac | `NSScreenCaptureUsageDescription` et autorisation système | Expliquer la capture sur les SDK qui documentent cette clé. Avec ScreenCaptureKit, démarrer depuis une action locale visible. Selon la version de macOS et le parcours ScreenCaptureKit, suivre l’invite ou le sélecteur système. Si le système demande un réglage, ouvrir **Réglages Système > Confidentialité et sécurité > Enregistrement de l’écran** ou **Enregistrement de l’écran et de l’audio du système**, autoriser OpenEye si nécessaire et relancer à la demande de macOS. Limiter la source et désactiver l’audio dans la configuration de capture. |
| Mac | **Signing & Capabilities > App Sandbox > Network** | Lorsque le transport est branché, ouvrir **Incoming Connections** si le Mac écoute et **Outgoing Connections** si le Mac initie des connexions, selon le mode validé au J2. Ces droits sandbox et l’autorisation de confidentialité réseau servent des contrôles distincts. |
| Bluetooth | `NSBluetoothAlwaysUsageDescription` si une API Bluetooth directe le requiert | Multipeer gère ses supports. Tester son comportement sur les appareils sans introduire Core Bluetooth. Si un ajout autorisé utilise directement une API Bluetooth, ajouter la chaîne « OpenEye utilise le Bluetooth pour trouver un appareil OpenEye proche lors de l’appairage », et, si nécessaire, le droit App Sandbox Bluetooth sur le Mac. Valider d’abord la nécessité et la compatibilité avec les frameworks imposés. |
| Mac, extension webcam | `NSCameraUsageDescription` et droit **Camera** dans **App Sandbox** | Ajouter ces déclarations lors de l’extension. Demander l’accès au premier usage depuis une action visible et laisser la webcam désactivée par défaut. |

Sources Apple pour les déclarations et l’autorisation système. [Ressources protégées](https://developer.apple.com/documentation/bundleresources/protected-resources), [Confidentialité réseau et Bonjour](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [Sandbox macOS](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

## 5. Lire et vérifier le code minimal

- `Package.swift` fixe la version des outils, les plateformes, le produit bibliothèque et la cible XCTest qui dépend de la bibliothèque.
- `OpenEyeCore.swift` expose le nom du projet, que les deux apps utilisent pour vérifier le lien au package.
- Les deux fichiers `*App.swift` importent SwiftUI et le package. `@main` désigne leur point d’entrée, `WindowGroup` crée la fenêtre et `VStack` empile le nom partagé et le rôle de l’appareil.
- `OpenEyeCoreTests.swift` importe XCTest et le module en mode test. La méthode `testBootstrap()` est volontairement vide. Elle permet de vérifier que le runner trouve et exécute un test.

Depuis la racine sur le Mac, lance `swift test --package-path OpenEyeCore`. Résultat attendu pour le socle initial : un test exécuté, zéro échec. Tu peux aussi ouvrir `OpenEyeCore/Package.swift` dans Xcode, choisir le schéma du package avec **My Mac**, puis faire **Product > Test**. Après la compilation, vérifie au besoin les clés de l’`Info.plist` du produit compilé : dans Xcode, repère l’app dans **Products**, ouvre son emplacement dans Finder, puis consulte le fichier avec `plutil -p` (`OpenEyeIOS.app/Info.plist` sur iOS et `OpenEyeMac.app/Contents/Info.plist` sur macOS).
