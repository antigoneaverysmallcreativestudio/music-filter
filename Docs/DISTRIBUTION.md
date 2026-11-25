# Distribution de Music Filter hors App Store

État au **25 novembre 2026** : version **1.0.0**, build **62**. Les sources, les notices et le [guide de publication GitHub](PUBLISHING.fr.md) sont préparés pour une diffusion open source. Aucun dépôt ni fichier n'est publié par cette préparation. L’application de distribution est signée Developer ID, notarisée par Apple et munie de son ticket. La signature, le ticket et l’acceptation Gatekeeper ont été vérifiés après extraction du ZIP de cette première version de production. La mise à jour locale a conservé les exclusions et les préférences ; l’installation sur un Mac ou compte utilisateur vierge reste à vérifier.

## Code source

Le code est fourni sous [licence MIT](../LICENSE). Le dépôt peut contenir les sources, le projet Xcode, les tests, les scripts de compilation et de préparation des paquets, les ressources nécessaires et les notices. Le [README anglais](../README.md), le [README français](../README.fr.md), le [guide de contribution](../CONTRIBUTING.md) et les [vérifications](../TESTING.md) accompagnent le projet.

Un dépôt public GitHub peut suffire : aucun site dédié n'est nécessaire pour héberger le code, recevoir les signalements et publier des versions. La publication du code ne nécessite pas de distribuer immédiatement une application prête à installer. Les personnes qui le souhaitent peuvent compiler leur propre copie avec Xcode et la modifier conformément à la licence.

Pour créer une archive de sources et son empreinte SHA-256, sans publier :

```sh
python3 Scripts/package-sources.py --output 'Deliverables/OpenSource-1.0.0'
```

Le paramètre facultatif `--root <dossier>` permet d’utiliser une autre copie du projet. Le script sélectionne les fichiers utiles à partir d’une liste autorisée et garde les scripts exécutables. Les ressources nécessaires à l’app sont séparées des sources graphiques modifiables dans [Artwork](../Artwork/README.md). Les aperçus obsolètes, anciennes variantes d’icônes et ancienne extension de partage sont retirés du paquet de sources.

Les archives de sources doivent conserver les scripts exécutables et exclure les applications compilées, données personnelles, exclusions, préférences, caches, journaux privés, identités de signature et clés. Les droits et notices des marques et ressources tierces restent distincts de la licence MIT du code ; voir [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Une application pour les deux langues

Le même paquet contient le français et l'anglais. Une langue principale française sélectionne l'interface française. Toute autre langue principale, y compris l'arabe, sélectionne l'anglais, même si le français est une préférence secondaire. Le nom **Music Filter** reste identique dans toutes les langues. L'application ne modifie pas les préférences de langue du Mac. Il n'y a donc pas deux applications à choisir ou à installer.

Le ZIP de distribution contient l’application et des notices d’installation française et anglaise. Décompressez-le puis glissez l’application dans Applications. Les anciennes notices [française](INSTALL.fr.txt) et [anglaise](INSTALL.en.txt) accompagnent uniquement les DMG d’essai non notarisés. Le nom physique du fichier reste `Music Filter.app`, ce qui permet de remplacer la même application lors d'une mise à jour ; son nom affiché reste également Music Filter.

## Préparer le paquet notarisé

Après archivage dans Xcode, utilisez la distribution **Developer ID → Upload**, attendez l’acceptation d’Apple, puis exportez l’application notarisée. Le même export est possible avec `xcodebuild -exportNotarizedApp`. La signature et le ticket de cette application sont vérifiés avant sa préparation en ZIP :

```sh
python3 Scripts/package-release.py \
  --app '/chemin/export-notarise/Music Filter.app' \
  --output 'Deliverables/Release-1.0.0' \
  --notarized-app
```

Le script conserve la signature et le ticket, inclut les notices bilingues et la licence, extrait à nouveau le ZIP et vérifie signature, ticket et acceptation Gatekeeper. Il fournit un SHA-256 et un rapport de vérification sans publier de fichier. Un ZIP ne porte pas lui-même de ticket agrafé : c’est l’application qu’il contient qui le conserve.

Le script propose aussi un flux DMG avec `--identity` et `--keychain-profile`, pour un profil `notarytool` déjà enregistré dans le Trousseau. Il notarie d’abord l’app, puis le disque ; `--resume` reprend les soumissions existantes. Aucun mot de passe ni clé privée ne doit être placé dans les sources.

## Préparer un paquet d'essai

Après compilation avec `./Scripts/build.sh`, le script suivant crée un DMG de test avec votre propre identité de développement :

```sh
python3 Scripts/package-beta.py \
  --app 'build/Build/Products/Release/Music Filter.app' \
  --output 'Deliverables/Beta-1.0.0' \
  --identity 'Apple Development: VOTRE IDENTITÉ'
```

Le script signe une copie temporaire, conserve le hardened runtime et l'horodatage sécurisé, retire le droit de débogage `get-task-allow`, vérifie les architectures Intel et Apple Silicon, puis produit un DMG et son SHA-256. Il monte ensuite l'image en lecture seule pour contrôler son contenu et sa signature. Il refuse d'écraser un livrable existant et ne lance pas l'application. Il ne publie rien, ne modifie aucune autorisation et n'inclut pas les exclusions ou préférences de l'utilisateur.

Ce script accepte uniquement une identité **Apple Development** : son résultat est volontairement étiqueté comme bêta non notarisée. Une signature de développement ne remplace pas une signature **Developer ID Application**. Les contrôles de signature et d'intégrité ne prouvent pas que Gatekeeper acceptera un téléchargement sur un autre Mac.

## Avant une diffusion publique de l'application

Pour proposer une installation standard hors App Store :

1. Utiliser une adhésion au programme Apple Developer et un certificat **Developer ID Application** avec sa clé privée. Ne pas inclure ces éléments dans le dépôt.
2. Signer la copie de distribution avec Developer ID, conserver le hardened runtime et l'horodatage sécurisé, sans droit de débogage.
3. Faire notariser la distribution par Apple, agrafer le ticket, puis vérifier la signature, le ticket et l'acceptation par Gatekeeper sur le fichier effectivement téléchargé.
4. Effectuer les essais d'installation et de mise à jour sur un Mac ou compte utilisateur vierge, en suivant [TESTING.md](../TESTING.md).

La notarisation est un contrôle de sécurité d’Apple pour une distribution hors App Store. Elle ne constitue ni un examen App Store, ni une recommandation d’Apple, et ne publie pas l’application dans ce store. Références Apple : [Developer ID](https://developer.apple.com/developer-id/) et [notarisation des logiciels macOS](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

La compilation cible macOS 14 ou ultérieur et les architectures Intel et Apple Silicon. Les essais réels documentés concernent macOS 27.2.1 sur Apple Silicon ; aucune validation réelle sur toutes les autres configurations ou sur un Mac vierge n'est annoncée.

## Limites à annoncer

- Après un refus de l'autorisation **Automatisation**, l'utilisateur doit actuellement relancer l'application ou basculer le filtrage après avoir accordé l'autorisation dans Réglages Système. Les notices expliquent cette reprise.
- Le filtrage anticipé est **expérimental** et désactivé par défaut. Il reconnaît les files de Musique en français et en anglais uniquement. L'interface anglaise de Music Filter ne traduit pas l'application Musique. Sa fenêtre doit rester ouverte, non réduite, avec la file affichée ; elle peut être en arrière-plan. Un retrait incertain peut mettre l'anticipation en pause. Le filtrage normal n'a pas cette dépendance à la langue de la file.
- Il n'y a pas encore de mise à jour automatique intégrée. Pour une mise à jour manuelle, quitter l'application et remplacer sa copie dans Applications conserve les données stockées séparément. Les versions téléchargeables doivent porter un numéro, des notes de version et un moyen de signaler les problèmes.

## English summary

Music Filter 1.0.0 has English and French source documentation. A single application selects French only for a French primary system language, and English for every other primary language, including Arabic. Source publication and public binary distribution are separate steps; nothing is published by the local preparation workflow.

Version 1.0.0 is the first production release. Its distribution app is Developer ID signed, notarized by Apple and stapled. Signature, ticket and Gatekeeper acceptance were checked again after extracting the release ZIP. The local update preserved exclusions and preferences. Notarization is a security check, not an App Store review or Apple endorsement. Fresh-Mac or clean-user installation remains untested. The separate beta script still produces explicitly unnotarized test DMGs. MIT covers the project code, not third-party trademarks or artwork. See [TESTING.md](../TESTING.md) for the current evidence and remaining checks.
