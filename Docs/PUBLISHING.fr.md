# Publier Music Filter sur GitHub

Ce guide accompagne la V1 préparée localement. Il ne crée aucun compte, dépôt ni publication.

## Le compte et le nom du dépôt

Conservez votre compte personnel. Pour regrouper les créations du studio, une organisation **Antigone** est adaptée : elle pourra héberger deux dépôts distincts, `music-filter` et, plus tard, `sensitive-icon-dock-music`. Le nom public du studio peut être **Antigone, a very small creative studio.** ; l’identifiant court dépendra des disponibilités.

Une organisation se gère depuis les comptes personnels de ses membres, sans créer un compte de connexion par logiciel. **GitHub Free** suffit à ce projet public. Voir les [types de comptes](https://docs.github.com/en/get-started/learning-about-github/types-of-github-accounts) et la [création d’une organisation](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/creating-a-new-organization-from-scratch).

L’organisation est facultative : un dépôt `music-filter` sur votre compte existant convient aussi. Aucun site web supplémentaire n’est nécessaire pour commencer ; le dépôt et ses versions téléchargeables peuvent servir de page officielle du projet.

## Ce que contiennent les deux packs

- **Music-Filter-1.0.0.zip** : application Mac déjà compilée, signée Developer ID et notarisée, avec notices d’installation française et anglaise. À décompresser puis à glisser dans Applications. Chaque Mac accorde lui-même les autorisations nécessaires au premier usage.
- **Music-Filter-1.0.0-sources.zip** : code, projet Xcode, ressources nécessaires, tests, présentations anglaise et française, licence MIT, notices des ressources tierces, illustrations et notes de version.
- Les fichiers **.sha256** permettent de vérifier que les téléchargements n’ont pas été altérés.

Les listes personnelles d’exclusions, préférences, clés de signature et mots de passe ne font pas partie des packs. Les contrôles réalisés et les limites des essais sont décrits dans [TESTING.md](../TESTING.md). L’installation sur un Mac ou compte utilisateur vierge reste à tester.

## Mettre les sources en ligne

1. Choisissez le compte ou l’organisation qui possédera le dépôt.
2. Créez un dépôt nommé **music-filter**. Vous pouvez le préparer en privé, vérifier son contenu, puis le rendre public au lancement.
3. Dans GitHub Desktop, utilisez **File → Clone Repository** pour récupérer ce dépôt sur le Mac. Décompressez le pack de sources et copiez son **contenu** dans ce dossier local : `README.md`, `LICENSE`, `Sources`, etc. Le ZIP seul ne constitue pas un dépôt de code pratique à consulter et modifier.
4. Dans GitHub Desktop, relisez la liste des fichiers, saisissez **Initial release — Music Filter 1.0.0**, puis cliquez sur **Commit to main** et **Push origin**. Le premier bouton enregistre l’état sur votre Mac ; le second l’envoie sur GitHub. Les fichiers README, licence et `.gitignore` sont déjà fournis : il n’est pas nécessaire d’en générer d’autres à la création du dépôt.
5. Vérifiez l’affichage du README anglais, du lien français et des images. Renseignez la description, les sujets et le site du studio dans le bloc **About** du dépôt. Activez **Issues** pour recueillir les problèmes et propositions.

La documentation officielle présente [GitHub Desktop](https://docs.github.com/en/desktop/overview/creating-your-first-repository-using-github-desktop) et [l’ajout de code existant](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github).

## Présentation proposée

**Nom :** Music Filter  
**Signature :** For serious listeners.  
**Description courte :** A personal exclusion list for Apple Music on Mac. Skip songs, albums and artists you choose to exclude. French and English.  
**Studio :** Antigone, a very small creative studio.  
**Sujets proposés :** `macos`, `apple-music`, `menu-bar`, `swift`, `music`, `open-source`.

Le README anglais sert de page d’accueil internationale, avec un lien vers la version française. Il présente le besoin, les fonctions, l’installation, les autorisations, les limites du filtrage anticipé, les sauvegardes locales et les contributions. Les deux fichiers sont prêts à relire dans le pack. Un [manuel français](GUIDE-UTILISATION.fr.md) et un [manuel anglais](USER-GUIDE.md) détaillent les premières étapes, les sauvegardes et le fonctionnement du mode anticipé. La V1 est la version de l’application ; le filtrage anticipé reste une fonction expérimentale facultative.

Quatre illustrations françaises sont préparées : menu principal, réglages, gestion des exclusions et dernier morceau exclu. Elles utilisent des noms fictifs et ont été retouchées pour retirer les éléments personnels du bureau ; elles sont identifiées comme des illustrations retouchées. Les captures anglaises de l’interface native restent disponibles en complément. [Origine des visuels](Images/README.md). Une courte vidéo montrant un retrait automatique pourra être ajoutée après un essai réel enregistré, sans promettre que le filtrage anticipé évite tout début de son dans toutes les situations.

## Publier la version téléchargeable

Une fois les sources définitives enregistrées dans le dépôt, ouvrez **Releases**, puis **Draft a new release**. Choisissez le tag **v1.0.0** sur cette version du code et le titre **Music Filter 1.0.0**.

Utilisez la section anglaise des [notes de version](RELEASE-v1.0.0.md), puis éventuellement la française. Joignez le ZIP de l’application et son `.sha256`. Le ZIP de sources préparé peut aussi être joint ; GitHub proposera en plus ses propres archives du code associé au tag. Vérifiez tous les fichiers dans le brouillon avant de publier. Voir [la gestion des releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

Le téléchargement principal pour les utilisateurs doit être clairement nommé **Music-Filter-1.0.0.zip**. Les archives « Source code » servent aux personnes qui veulent lire, modifier ou compiler le projet. La notarisation Apple est un contrôle de sécurité pour la distribution hors App Store, pas une validation fonctionnelle ni une publication sur l’App Store.

## Les mises à jour

Pour une correction, préparez par exemple **1.0.1** ; pour de nouvelles fonctions, **1.1.0**. Enregistrez les changements, compilez, testez, signez et faites notariser la nouvelle application, puis publiez un nouveau tag et une nouvelle release avec quelques lignes expliquant les changements. Conservez les anciennes versions pour permettre le retour à une version précédente.

La V1 ne télécharge pas automatiquement ses mises à jour. Les utilisateurs quittent l’application et remplacent sa copie dans Applications ; les exclusions sont stockées séparément. Ils peuvent exporter leur liste avant l’opération. GitHub permet de s’abonner uniquement aux nouvelles releases via **Watch → Custom → Releases** ; voir les [notifications personnalisées](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications).

## Comment fonctionne l’open source

Les utilisateurs peuvent signaler un problème dans **Issues**, créer leur propre copie du code (*fork*) et proposer une modification par une **pull request**. Vous décidez des propositions intégrées dans la version officielle. Le guide [Contributing](../CONTRIBUTING.md) précise comment contribuer.

Le code utilise la licence **MIT** : elle autorise notamment la copie, la modification et la redistribution, y compris commerciale, avec conservation de la notice de licence et de copyright. Les symboles et autres ressources tierces gardent leurs propres conditions ; la licence du code ne les transforme pas en ressources MIT. Voir la [licence du projet](../LICENSE), les [notices tierces](../THIRD_PARTY_NOTICES.md) et le [texte MIT](https://opensource.org/license/mit).
