# Évaluation de Cassette 1.12.0 et d’AudioStreaming

Évaluation du 25 septembre 2026, sur le code de travail de Minidisc, y compris les modifications locales déjà présentes. Branche `feat/audiostreaming`, créée depuis `fix/playlist-consistency-and-library-isolation`, au commit `11b5925f2e99b316b4cdcced7ba783a7ed3d957d`.

## État de la branche après expérimentation

À la demande de l’utilisateur, **AudioStreaming 1.4.5 est désormais le moteur par défaut sur cette branche**. La dépendance est fixée à cette version dans SwiftPM. `AudioStreamingDriver` adapte la bibliothèque et `AudioStreamingEngine` préserve le contrat de `PlayerService` : tokens par chargement, file native, deux lecteurs pour le crossfade, ReplayGain séparé, pause, seek confirmé et reconstruction après reset.

Le moteur AVPlayer reste disponible pour les comparaisons : lancer l’application avec la variable d’environnement **`MINIDISC_AUDIO_ENGINE=avplayer`**. Ce choix n’est pas un réglage utilisateur et ne change ni les téléchargements, ni le cache audio, ni le scrobbling, ni la résolution des sources.

L’étude initiale recommandait un prototype avant toute migration générale. Cette prudence reste pertinente pour une mise en production : le build et les essais sur simulateur ne démontrent pas une amélioration des interruptions réseau, de la consommation ou de la fidélité audio. Le rendu intermédiaire de la bibliothèque reste limité au PCM stéréo 44,1 kHz.

### Corrections portées

- La purge manuelle et l’invalidation de version suppriment seulement les variantes `@thumb`/`@hero`. Le compteur de cache mesure ces mêmes variantes. Le sweep qui supprimait les pochettes permanentes a été retiré. Les écritures déjà engagées dans le cache sont drainées avant la purge et les vues sont invalidées.
- Après le nettoyage des orphelins, les pochettes de téléchargements absentes ou vides sont réparées par lots de trois, pour le serveur actif seulement. La réparation attend un état réseau observé, respecte les données mobiles et le réseau contraint, utilise les headers d’authentification et revérifie le serveur ainsi que la possession du téléchargement avant d’écrire.
- La liste des morceaux lit les favoris via une requête SwiftData par serveur et construit un ensemble d’IDs. La lecture des IDs téléchargés filtre le serveur dans la requête, hors du MainActor, et conserve la validation des fichiers.
- Le geste de retour possède un delegate restaurable, protège la racine et les transitions. Les détails album/playlist bloquent les doubles dismiss et n’inventent plus d’UUID serveur pour leurs lignes.
- Le délai de reprise des paroles est injectable ; le test attend la tâche de reprise, sans polling de dix secondes.
- Les timeouts de téléchargements et le tri local des playlists étaient déjà traités dans Minidisc ; leur implémentation est conservée.

### Particularités de l’adaptateur

Le seek s’effectue temporairement en silence, même depuis Pause. La confirmation exige deux observations avec une position et un compteur de frames rendues qui avancent, dans une fenêtre autour de la cible. La simple position synthétique exposée par la bibliothèque n’est pas acceptée. Une annulation ou un remplacement invalide la génération de la demande. Le préchargement est soumis à nouveau après un seek, car `flushQueueOnSeek` vide la file native.

À la fin exacte du fichier, l’événement EOF de l’entrée sert de confirmation, puisqu’aucune nouvelle frame ne peut avancer. Depuis Pause, cette fin reste en attente jusqu’à Reprendre. Une pause pendant un crossfade retire le second lecteur et conserve la piste à préparer à nouveau lors de la reprise. Le timer de surveillance est arrêté pendant Pause.

La méthode publique `removeFromQueue` de 1.4.5 ne retire pas les entrées déjà décodées. Annuler une telle piste reconstruit donc le lecteur courant au dernier temps connu, en silence jusqu’à confirmation du seek. **Une remise en tampon reste possible lors d’une modification du contenu de la file déjà préchargée.** Ce chemin perd le buffer de l’ancien lecteur. Les changements de réseau et les réglages qui conservent la même piste ne déclenchent plus cette annulation dans AudioStreaming. Une évolution amont de l’API d’annulation serait préférable avant une adoption générale.

`playNextInQueue` a une limite similaire : il ne passe à l’entrée suivante que si celle-ci se trouve encore dans `upcoming`. Pour un saut manuel vers une piste déjà préparée en file native, l’adaptateur ouvre donc sa source sur un nouveau lecteur. Cela peut ajouter un temps de chargement lors de « Suivant ». Une entrée dont le démarrage natif est déjà confirmé, notamment après EOF pendant Pause, est adoptée sans la relancer.

Le crossfade démarre un second lecteur à l’approche de la fin. Le volume sortant reste entier tant que l’entrant n’avance pas, puis les deux gains suivent un fondu à puissance constante. Ce chemin ne dispose pas d’un preroll public garanti : son délai de démarrage dépend encore du réseau. AirPlay utilise toujours la file séquentielle. Les erreurs et événements tardifs sont filtrés par lecteur physique et par identité d’entrée ; aucune URL authentifiée ne figure dans les nouveaux diagnostics.

### Validation

Le build et le lancement sur le simulateur iOS 27 dédié ont réussi. Les campagnes ciblées ont validé **141 méthodes de test distinctes**, dont les scénarios paramétrés du décodeur, et **trois parcours UI**, sans tests ignorés. Le cas EOF a d’abord échoué, puis a passé les scénarios lecture/pause après correction.

- **Décodeur réel** : fichiers WAV générés en test ; fixtures synthétiques MP3 CBR/VBR, AAC 48 kHz, FLAC 44,1/96 kHz. Pause, seek en pause, reprise, fin de fichier, reconstruction, répétition de la même URL, reconstitution/annulation du préchargement et chevauchement de deux décodeurs. `Scripts/Testing/generate-audio-fixtures.py` régénère les fichiers compressés avec FFmpeg.
- **Adaptateur et service** : callbacks périmés, fausse position de seek, gains, annulation concurrente, pause pendant crossfade et Pause/Next pendant une promotion native ; tests existants de récupération, routes simulées, reset, diagnostics et fallback AVPlayer.
- **Corrections annexes** : purge conservant les pochettes permanentes, réparation ciblée et politique réseau, téléchargement supprimé pendant une réparation, lectures hors ligne par serveur, delegate de navigation et reprise des paroles. Le coût des requêtes de favoris a été corrigé par lecture du code, sans benchmark de liste.
- **Interface avec serveur synthétique** : `testFixtureDownloadAndPlayback`, `testFixturePlaylistMenuAndRowPlayback` et `testFixtureSearchPlaylistNavigation`. Ils confirment notamment l’avancée du temps de lecture locale lorsque le serveur refuse le streaming et sa stabilité pendant Pause.

Les mesures de progression et de frames ne sont pas des mesures de précision acoustique. Les licences AudioStreaming/Ogg/Vorbis sont embarquées et accessibles dans les remerciements de l’application.

À valider sur appareil avant diffusion : formats compressés du serveur réel, précision acoustique des seeks et jonctions, AirPlay, Bluetooth, interruptions, écran verrouillé, changements Wi-Fi/cellulaire et lecture longue. Aucun benchmark CPU/énergie ni enregistrement de sortie audio n’a été réalisé.

### Correction de la durée affichée

Un décalage léger entre la fin de la barre et la fin du son a été signalé après la migration. L’adaptateur gardait systématiquement la durée entière du catalogue, même quand le décodeur connaissait celle du fichier. Le service ne permettait par ailleurs que les corrections à la hausse, supérieures à une demi-seconde.

Le moteur privilégie désormais la durée du fichier dès qu’elle est disponible et la conserve par entrée pendant les états transitoires. La durée du catalogue reste le repli initial. Les positions synthétiques de seek et le `max(duration, progress)` interne d’AudioStreaming ne deviennent pas de nouvelles durées totales. Le service accepte les affinements dans les deux sens, avec une tolérance de 50 ms, pour la barre, le temps restant, Now Playing et le crossfade.

Le test de régression reproduit l’ancien défaut sur les cinq fixtures compressées de six secondes : le décodeur annonçait environ 6,006 à 6,037 s, mais l’adaptateur renvoyait encore 3 s. La vérification couvre aussi des métadonnées surestimées, des différences inférieures à trois secondes et une durée temporairement indisponible.

Après correction, les 23 méthodes des suites décodeur réel, adaptateur et synchronisation de durée passent sur simulateur, y compris leurs cas paramétrés. La durée parsée est disponible même si le callback de démarrage arrive plus tard ; pause, seek, file native et crossfade restent couverts.

### Correction du chargement affiché pendant la lecture

Le message « Loading… » pouvait rester affiché après un enchaînement alors que la position avançait. Le défaut a été reproduit avec le décodeur réel, avec et sans crossfade : la piste préchargée jouait déjà et aucun nouveau changement d’état natif ne venait effacer l’attente au moment où `PlayerService` adoptait son token.

L’adaptateur republie maintenant l’état du lecteur lors de cette adoption, d’un démarrage d’entrée et d’une reprise déjà en lecture. L’attente initiale est annoncée avant le lancement du décodeur, pour éviter qu’elle ne remplace un signal de lecture immédiat. Les tests vérifient le message exposé à l’interface après son délai d’affichage, ainsi que les passages automatiques et manuels vers une piste préchargée.

La campagne après correction valide 60 méthodes de test sur simulateur, sans échec ni test ignoré : décodeur réel, adaptateur, présentation, durée et récupération. Les deux cas réels d’enchaînement qui conservaient « Loading… » passent désormais.

### Correction de « Suivant » après préchargement et seek

Des logs montraient le titre de la piste suivante avec la durée de 187,153 s et la position de fin de la piste précédente. Le saut via `playNextInQueue` pouvait ne rien faire lorsque l’entrée avait déjà quitté `upcoming` pour le buffer décodé, alors que l’adaptateur avait déjà changé son identité logique.

Le défaut a été reproduit sur le décodeur réel après quatre seeks suivis d’un préchargement local, en lecture et depuis Pause. Le correctif isole le nouveau lecteur lors du saut manuel ; les événements tardifs de l’ancien sont rejetés. Les régressions contrôlent le retour à zéro, la durée propre au fichier cible, pause/seek/reprise, la fin de cette piste et la cohérence de la file jusqu’au morceau suivant. Les enchaînements natifs et les promotions déjà confirmées restent couverts.

Cette séquence a aussi révélé un ordre de callbacks différent après un seek en pause : le démarrage de l’entrée suivante peut précéder la fin de la précédente lorsqu’elle est décodée tardivement. L’adaptateur conserve désormais les deux identités jusqu’à la réception de cette fin, au lieu d’écraser celle du morceau courant et d’ignorer ensuite son EOF.

Les campagnes ciblées valident 32 méthodes distinctes après ces corrections, dont le parcours réel complet « seeks répétés → Suivant → Pause → seek à zéro → Reprendre → troisième morceau ». La vérification attend explicitement les préchargements et laisse une marge au rafraîchissement de position de l’interface. Aucun échec ne subsiste dans ces suites.

### Continuité pendant un état de buffering

Le 26 septembre, des microcoupures suivies d’un léger retour arrière ont été signalées pendant une piste, sans action utilisateur. Deux relances inutiles ont été reproduites dans le service : une position qui avance était malgré tout traitée comme bloquée tant que le dernier état était `buffering`, et une reprise spontanée pendant la résolution de la source de remplacement n’était pas revérifiée avant le redémarrage.

La récupération conserve maintenant le lecteur tant que son horloge avance. Si l’état reste `buffering`, elle poursuit les observations pour détecter un arrêt ultérieur, même sans nouveau callback. Une copie nouvellement disponible dans le cache ne supprime plus le délai d’observation d’un vrai blocage. Après la résolution et l’attente de la transition, le service revérifie la progression ; si le remplacement reste nécessaire, il utilise la position la plus récente, avant de toucher au lecteur.

Ces régressions sont vérifiées avec une horloge contrôlée, avec et sans cache, puis avec une vraie immobilisation et une résolution suspendue. Elles établissent deux causes possibles de coupure côté orchestration ; elles ne constituent pas une mesure acoustique des microcoupures signalées sur l’appareil.

Après correction, la campagne ciblée passe 50 méthodes de test, sans échec ni test ignoré : continuité, récupération et budget de reprise, politique réseau et enchaînements réels AudioStreaming.

### Audit des protections héritées du lecteur précédent

L’audit du 26 septembre examine les invalidations du préchargement, le seek, la restauration, les watchdogs, la validation des sources et les changements de route.

| Ancienne hypothèse | Effet avec AudioStreaming | Correction ou décision |
| --- | --- | --- |
| Tout changement réseau doit supprimer le standby, même local. | Une entrée native déjà décodée impose de recréer le lecteur actif ; ses buffers sont perdus. | Conserver la préparation locale pour les deux moteurs, et les préparations distantes pour AudioStreaming, dont `RemoteAudioSource` possède déjà une reprise réseau. Invalider les résolutions encore en cours ; garder la récupération bornée d’un vrai blocage. AVPlayer conserve l’invalidation de son standby distant. |
| Un changement de ReplayGain ou de crossfade impose une annulation puis un nouveau préchargement. | Une modification de gain provoque un redémarrage du morceau courant. | Réutiliser la source préparée et actualiser ses paramètres. Si AudioStreaming a déjà décodé la transition séquentielle, conserver cette transition ; le nouveau mode crossfade s’applique à la paire encore non préparée. Les gains sont actualisés sur les deux moteurs. |
| Le service doit annuler le standby avant de notifier AirPlay au moteur. | L’annulation empêche AudioStreaming d’adapter sa préparation et peut reconstruire le lecteur courant. | Laisser le moteur gérer sa préparation et conserver la correspondance logique quand il le permet. Un fondu entrant est arrêté au passage en AirPlay, puis sa piste est préparée en séquentiel. Sortir d’AirPlay ne reconstruit pas une entrée native déjà décodée. |
| Le seek doit retenir la plus grande durée connue. | Une durée de catalogue surestimée autorise une cible au-delà de la durée affinée du fichier. | Privilégier la durée du moteur lorsqu’elle est valide, puis les métadonnées en repli. |
| Une restauration sous une seconde peut repartir de zéro ; attendre encore 150 ms après le seek avant de pauser. | Retour arrière possible et consommation silencieuse de la piste après une confirmation déjà acquise. | Restaurer toute position strictement positive en silence, puis pauser immédiatement après le seek confirmé. Rejeter une continuation si une nouvelle intention de transport l’a remplacée. |

Les identités d’entrée, les générations de seek/transport, les délais de vrais blocages, la récupération des services audio et les protections de route personnelle restent utiles. La préparation d’un fichier complet pour le seek dans un transcodage MP3 répond aux limites HTTP/Range de la source serveur ; le changement de décodeur ne les supprime pas. La suspension du cache près d’une transition évite une concurrence réseau et reste conservée.

La validation `AVURLAsset.isPlayable` des fichiers importés reste une dépendance à AVFoundation, également présente dans l’extraction de leurs métadonnées. Elle peut limiter l’import de formats qu’AudioStreaming sait décoder, notamment Vorbis ; ce n’est pas une cause de coupure pendant un morceau déjà accepté. L’audit ne prétend pas élargir le catalogue de formats locaux sans adapter et tester l’import et les métadonnées.

Les nouvelles régressions reproduisent avant correction les invalidations réseau/local/ReplayGain/crossfade/AirPlay, la restauration de la première seconde et le dépassement de durée. Les tests contrôlent le nombre de lecteurs physiques, l’absence de seek induit, l’adoption de la piste suivante et le gain lors du passage natif. Un passage AirPlay pendant un fondu audible vérifie aussi la conservation du lecteur courant et la suppression de l’ancienne identité entrante.

Après correction, **105 méthodes distinctes passent sur simulateur**, sans échec ni test ignoré : 103 dans la campagne principale, puis six dans la vérification complémentaire, dont deux nouvelles. Cette dernière vérifie le préchargement avec la politique de reconnexion AVPlayer et le passage réel de deux fichiers AAC malgré une notification de changement réseau, avec un seul lecteur physique. Les campagnes couvrent aussi la file, les seeks répétés, les restaurations échouées, les resets audio, les transcodes et les fichiers locaux. Les événements réseau et AirPlay sont injectés ; ils ne mesurent ni une vraie bascule cellulaire ni les microcoupures acoustiques sur iPhone.

### Reprise après une pause prolongée et interruption sans fin

Le rapport fourni le 27 septembre montre une interruption liée à une déconnexion Bluetooth (`#500`), suivie d’un Play explicite (`#503`) puis de plusieurs minutes de lecture. Aucun événement de fin d’interruption n’est enregistré entre les deux. Après une pause prolongée, une nouvelle reprise (`#777`) échoue avant toute frame rendue (`#785`, erreur générique `-11800`) ; iOS annonce ensuite un reset des services audio (`#786`). La récupération abandonne environ dix secondes plus tard, sans aucun événement de tentative de lecture. Le code conservait `isAudioSessionInterrupted` depuis la déconnexion et attendait sa fin avant même de réactiver la session.

Les tests reproduisent cette attente puis l’échec, sans simuler artificiellement 24 heures : le défaut dépend de la séquence d’événements, pas d’un seuil d’âge. Une réactivation réussie pour un nouveau Play lève désormais l’interruption connue au début de cette demande. Un échec d’activation conserve la protection. Une génération d’interruption et l’annulation des retries empêchent une ancienne tentative différée de réactiver la session pendant une interruption plus récente. Une notification de fin retardée, sans autorisation de reprise automatique, ne peut pas arrêter une récupération engagée après le nouveau Play.

Le rapport montre également que la catégorie et le mode réels de la session avaient changé durant la suspension. `SystemAudioSessionController` revérifie donc catégorie, mode et politique de partage à chaque activation, même si son indicateur interne la disait déjà configurée. Les positions, la file et les protections contre une reprise sur le haut-parleur à la place d’écouteurs restent conservées.

L’en-tête du rapport affichait à tort `AVQueuePlayer`, alors que ses observations désignaient bien AudioStreaming 1.4.5. L’export et ses archives utilisent maintenant le moteur effectivement observé ; une nouvelle ligne indique lorsqu’un Play a levé une interruption après activation réussie. Le code `-11800` du rapport ne permet pas à lui seul de déterminer l’origine précise de la toute première erreur audio : le blocage de la récupération, lui, est reproduit.

La validation finale couvre **100 méthodes distinctes**, toutes passantes après correction d’une assertion de test sur le nombre de lecteurs avant pause. Elle inclut la reproduction sans notification de fin, le reset pendant Pause puis après Reprendre, une nouvelle file, l’échec d’activation, une interruption plus récente, une notification de fin retardée et la reprise avec le décodeur AAC réel. Un contrôle séparé sur `AVAudioSession` réelle vérifie le rétablissement de catégorie/mode/politique malgré l’ancien indicateur « configuré ». Les suites de récupération, routes, file AudioStreaming et diagnostics restent passantes. La durée d’attente de 24 heures et une vraie interruption Bluetooth sur l’iPhone ne sont pas reproduites par ces tests.

## Ce que change réellement Cassette 1.12.0

La [release](https://github.com/CassetteLab/cassette/releases/tag/v1.12.0) et la [comparaison avec 1.11.1](https://github.com/CassetteLab/cassette/compare/v1.11.1...v1.12.0) ne contiennent pas de migration audio : `PlayerService` et `Package.resolved` ne changent pas. Cassette utilise déjà AudioStreaming. Son [verrou de dépendances au tag](https://github.com/CassetteLab/cassette/blob/v1.12.0/Cassette.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) fixe **1.4.4**, révision `a729ee28fece29d80a749419d96df0693200f124`.

Le tableau suivant décrit l’état de Minidisc **avant les corrections de cette branche**.

| Changement de Cassette | Situation constatée dans Minidisc | Pertinence |
| --- | --- | --- |
| [Purge sélective des pochettes, #82](https://github.com/CassetteLab/cassette/pull/82), et [réparation, #86](https://github.com/CassetteLab/cassette/pull/86) | Le bouton existe, mais `clearAllCovers()` supprime le répertoire entier. L’invalidation de version fait de même. Le sweep de démarrage supprime les fichiers sans suffixe de taille, qui comprennent les pochettes conservées pour les téléchargements. | **Priorité haute** : distinguer cache régénérable et pochettes des téléchargements, puis réparer les fichiers manquants. |
| [Coûts de la liste Songs, #78](https://github.com/CassetteLab/cassette/pull/78) | `SongsListView.isFavorite` appelle encore un `mainContext.fetchCount` par ligne. `OfflineLibraryReader.downloadedSongIds` charge toutes les pistes sur le MainActor avant de filtrer par serveur. | **Priorité haute** : ensemble de favoris et prédicat serveur dans la requête. Conserver notre validation des fichiers sur disque. |
| [Navigation, #79](https://github.com/CassetteLab/cassette/pull/79) | `SwipeBackEnabler` efface encore le delegate du geste de retour à chaque mise à jour. Des détails album/playlist utilisent encore `activeServer?.id ?? UUID()`. | **Priorité haute** : reprendre les principes de garde de transition, restauration du delegate et identité serveur stable. Auditer séparément les routes de zoom. |
| [Téléchargements longs, #81](https://github.com/CassetteLab/cassette/pull/81) | Notre session de téléchargement autorise déjà une heure par ressource ; le transport en arrière-plan autorise 24 heures. Les échecs sont persistés et peuvent être relancés. | **Déjà traité pour le problème des 30 secondes**. Garder un test de transfert lent ; pas de portage direct nécessaire. |
| [Tri local des playlists, #84](https://github.com/CassetteLab/cassette/pull/84) | Déjà présent avec titre/artiste/album/ordre original. `PlaylistEntry.sourceIndex` permet de supprimer la bonne occurrence après tri, même avec des doublons. | **Faible gain immédiat**. La mémorisation du tri par playlist reste intéressante ; ne pas remplacer nos identités d’occurrences par une simple recherche d’ID de chanson. |
| [Test des paroles, #87](https://github.com/CassetteLab/cassette/pull/87) | Le délai de reprise est encore fixé à trois secondes, et le test attend par polling jusqu’à dix secondes. | **Pertinent et limité** : délai injectable et attente de la tâche réelle. |
| Corrections de hauteur et raccourcis macOS, #80/#83 | Le projet examiné cible iOS. | Pas de bénéfice direct pour cette branche. |
| Maintenance des tests, documentation et version, #85/#91/#92/#93 | Changements liés au dépôt Cassette. | Pas de fonctionnalité à importer. |

Les chiffres de performance et résultats de tests cités dans les PR de Cassette ne sont pas des mesures de Minidisc.

### Pochettes : un défaut partagé, pas seulement un bouton manquant

Les trois chemins sont actifs dans notre code :

- `Minidisc/App/AppContainer.swift:397` : invalidation complète du répertoire de pochettes ;
- `Minidisc/App/AppContainer.swift:418` : sweep des fichiers sans `@thumb`/`@hero`, appelé depuis `MinidiscApp.swift:212` ;
- `Minidisc/Views/Settings/SettingsView.swift:446` : le bouton appelle `DownloadService.clearAllCovers`, qui supprime aussi les pochettes persistantes.

Une correction doit conserver les fichiers possédés par les téléchargements, supprimer seulement les variantes régénérables, invalider les vues affichées et réparer les pochettes déjà perdues. La réparation doit utiliser le bon serveur et ses headers, attendre un état réseau connu et respecter la préférence de données mobiles. Ajouter seulement le bouton de Cassette n’aurait aucun intérêt : nous avons déjà ce bouton et le problème se situe dans la suppression.

## Ce que nous avons déjà côté lecture

Le point de substitution existe : `AppContainer.swift:190` injecte un `AudioEngine` dans `PlayerService`. Un prototype peut donc ajouter `AudioStreamingEngine: AudioEngine` sans déplacer la file, le scrobbling ou la résolution des sources dans la bibliothèque.

Le contrat actuel est toutefois plus riche que play/pause/seek :

- `AVPlayerEngine` utilise une file native pour l’enchaînement séquentiel et une seconde platine pour un vrai chevauchement. AirPlay force le séquentiel.
- Chaque chargement possède un token monotone ; les callbacks tardifs ne peuvent pas modifier la nouvelle lecture.
- La promotion de la piste préchargée transmet sa source, sa position et le temps déjà entendu pendant le fondu. Le service adopte cette lecture sans re-résoudre l’URL.
- Le seek est asynchrone et confirme sa réussite. La restauration garde le son coupé tant que la position n’est pas rétablie.
- Le ReplayGain positif passe par un `MTAudioProcessingTap`, séparément du volume utilisateur.
- Le service distingue erreur réseau, chanson absente et reset des services audio. Il reconstruit les lecteurs, rétablit la session, respecte Pause/Next et attend le retour de la sortie personnelle attendue.
- Les fichiers locaux, téléchargements permanents et cache restent gérés hors du moteur. Le cache automatique est alimenté par un transfert distinct après trente secondes d’écoute.

Sources locales principales : `Services/Audio/AudioEngine.swift`, `Services/Audio/AVPlayerEngine.swift`, `Services/Implementations/PlayerService.swift`, `Models/Domain/MediaSource.swift` et [PlaybackContinuity.md](PlaybackContinuity.md).

## Ce qu’AudioStreaming apporterait

La bibliothèque utilise AVAudioEngine et CoreAudio, avec une file audio, des buffers configurables, des sources locales/distantes, des headers HTTP et des flux ICY. Elle expose l’ajout d’Audio Units et des filtres de frames. Voir le [README de la version utilisée par Cassette](https://github.com/dimitris-c/AudioStreaming/blob/a729ee28fece29d80a749419d96df0693200f124/README.md).

| Sujet | Gain potentiel pour Minidisc | Limite ou travail nécessaire |
| --- | --- | --- |
| ReplayGain, égaliseur, effets | Un `AVAudioUnitEQ` permettrait un gain positif et un futur égaliseur avec moins de code de tap. Cassette applique déjà cette approche. | Le calcul de gain et la prévention de clipping restent notre responsabilité, avec un gain propre à chaque piste pendant un chevauchement. |
| Buffering | Seuils explicites de démarrage et de reprise après sous-alimentation. | Aucun gain de latence ou de stabilité n’est mesuré ici. Le réseau, le transcodage et la session iOS restent déterminants. |
| Enchaînement | File conçue pour la lecture sans interruption ; correction dédiée dans 1.4.4. | Nous avons déjà un enchaînement natif. Il faut mesurer les jonctions, dont MP3/AAC avec délai d’encodage, et conserver nos callbacks de promotion. |
| Formats | MP3/AAC/M4A, prise en charge FLAC dans le code, Ogg Vorbis supplémentaire. | Pas de seek Ogg Vorbis ; Opus n’est pas une capacité établie. Ne pas confondre Ogg Vorbis et Ogg Opus. |
| Réseau | Headers publics dans `play`/`queue`, traitement des ranges et reconnexion interne. | Évaluer le comportement des proxies, des flux sans longueur fiable et l’interaction entre ses reprises et notre watchdog. |
| Cache | Sources personnalisables et accès aux frames. | Pas de remplacement direct de notre cache LRU de fichiers compressés ni des téléchargements durables. Un filtre PCM ne constitue pas ce cache. |

La [configuration](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/AudioStreaming/Streaming/AudioPlayer/AudioPlayerConfiguration.swift) doit être explicite : `.default` et l’initialiseur sans arguments n’ont pas les mêmes valeurs pour plusieurs options, notamment le seuil de reprise et les logs. Cassette choisit vingt secondes de buffer et une seconde de seuil de démarrage/reprise ; cela reste un choix à mesurer, pas une configuration optimale démontrée pour nous.

## Obstacles à une migration complète

### 1. Le seek est le principal point de compatibilité

L’[API 1.4.5](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/AudioStreaming/Streaming/AudioPlayer/AudioPlayer.swift#L468) expose `seek(to:)` sans confirmation de fin ni résultat. Le [delegate](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/AudioStreaming/Streaming/AudioPlayer/AudioPlayerDelegate.swift) ne fournit pas de callback spécifique confirmant un seek réussi. Notre `async -> Bool` ne peut donc pas être implémenté honnêtement en retournant immédiatement `true`.

Il faudrait une confirmation fiable de la position effectivement rendue, avec annulation et délai borné, ou une évolution de la bibliothèque. La progression déclarée seule doit être étudiée : elle peut intégrer l’offset demandé avant que du son ait été rendu.

Un [signalement ouvert sur le seek FLAC 44,1 kHz](https://github.com/dimitris-c/AudioStreaming/issues/133) décrit un décalage de plusieurs secondes. Un [autre concerne le seek MP3 après Pause](https://github.com/dimitris-c/AudioStreaming/issues/126). Ces signalements justifient des scénarios de reproduction ; ils ne prouvent pas que tous les fichiers échouent en 1.4.5.

Changer de lecteur ne donne pas au serveur la capacité de servir une position arbitraire dans un transcodage en cours. Notre `TranscodedSeekFile` et ses validations ne doivent pas être supprimés avant d’avoir vérifié les MP3 transcodés, sans Content-Length fiable et avec ou sans support Range.

### 2. Le crossfade de Cassette ne démontre pas la parité

Le [PlayerService au tag 1.12.0](https://github.com/CassetteLab/cassette/blob/v1.12.0/Cassette/Services/Implementations/PlayerService.swift) possède un seul AudioPlayer. Il abaisse son volume en fin de piste, lance la suivante avec `play`, puis remonte le volume. Il n’utilise pas `queue` dans ce service. C’est un fondu successif, sans deux pistes jouées simultanément.

Pour conserver notre comportement, il faudrait gérer deux lecteurs AudioStreaming ou adapter le mélange en amont. Ce travail comprend le préchargement, les gains séparés, les pauses pendant le fondu et les changements AirPlay. La bibliothèque ne fait pas disparaître cette orchestration.

### 3. Les identités et erreurs doivent rester fiables

L’[AudioEntryProvider](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/AudioStreaming/Streaming/Audio%20Entry/AudioEntryProvider.swift) expose `url.absoluteString` dans le champ public `AudioEntryId.id`, mais **l’égalité du type inclut aussi un UUID privé** : deux occurrences de la même URL restent distinctes. L’adaptateur utilise cette égalité, sans recopier le champ URL dans les diagnostics. Les callbacks de changement d’état et d’erreur ne portent toutefois pas d’entryId.

L’adaptateur devra corréler les callbacks à la bonne génération, y compris pendant les remplacements et les transitions. Affecter simplement le token courant à chaque événement serait incorrect. Les URL Subsonic pouvant contenir des paramètres d’authentification, ces identifiants bruts ne doivent pas entrer dans nos diagnostics.

### 4. Le reset audio et les routes ne disparaissent pas

AVAudioEngine dépend toujours des services audio iOS. L’API examinée ne fournit pas l’équivalent de notre reconstruction complète après reset. L’adaptateur devra pouvoir jeter et recréer ses AudioPlayer et leurs nœuds, puis laisser PlayerService restaurer session, route, source et position.

AirPlay, Bluetooth, écoute verrouillée, interruption téléphonique et CarPlay demandent des essais physiques. L’emploi de la bibliothèque par Cassette ne valide pas notre cycle de vie et nos invariants.

### 5. Le chemin URL impose un format PCM interne

Le [lecteur 1.4.5](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/AudioStreaming/Streaming/AudioPlayer/AudioPlayer.swift#L148) initialise un format privé **Float32 stéréo à 44 100 Hz**, utilisé par le convertisseur et le rendu. Pour le chemin URL standard, l’API de configuration n’expose pas de sélection de cette fréquence.

J’en déduis qu’il ne faut pas présenter cette migration comme une amélioration de la fidélité des originaux 48/96/192 kHz : ils traverseraient ce format intermédiaire. Cela ne prouve pas un défaut audible et ne signifie pas qu’AVPlayer est toujours bit-perfect. C’est une contrainte de conception à décider explicitement.

### 6. Dépendance et maintenance

La [version 1.4.5 du 14 septembre 2026](https://github.com/dimitris-c/AudioStreaming/releases/tag/1.4.5) est la plus récente publiée lors de l’étude. Elle corrige un crash de destruction de timer et ajoute mTLS. Un prototype devrait fixer cette version, plutôt que copier le verrou 1.4.4 de Cassette.

Le [package](https://github.com/dimitris-c/AudioStreaming/blob/1.4.5/Package.swift) demande Swift tools 5.10 et iOS 15 minimum, compatibles avec notre cible iOS 26.1. Il ajoute des dépendances binaires Ogg et Vorbis, ainsi qu’un pont C. Le build dans notre projet Swift 6 a réussi ; la frontière vers cette bibliothèque utilise `@preconcurrency` et une sérialisation explicite. La licence annoncée par AudioStreaming est MIT.

## Prototype recommandé et critères de décision

1. **Figer la référence AVPlayer.** Mesurer sur le même appareil, serveur, corpus et réseau : délai jusqu’au son audible, interruptions, erreur réelle de seek, jonctions, CPU/mémoire/énergie. Les diagnostics actuels mesurent la progression à intervalles de 0,5 s ; compléter par une capture audio pour juger le silence et la précision acoustique.
2. **Comparer les deux adaptateurs dans AppContainer.** Cette branche utilise AudioStreaming par défaut, avec le retour à AVPlayer par variable d’environnement. PlayerService, MediaResolver, NowPlaying, les caches et les téléchargements restent indépendants du moteur.
3. **Prouver la parité avant de basculer.** Réutiliser les tests de récupération et d’intention, ajouter des essais du moteur réel, puis vérifier le chevauchement, les transitions et les routes sur appareil. Les tests du service avec un moteur simulé ne suffisent pas à valider le décodage et le rendu.

Corpus minimal : MP3 CBR/VBR, AAC/M4A avec métadonnées au début et à la fin, FLAC 44,1/48/96 kHz, fichiers téléchargés, fichiers locaux et radios ; Ogg seulement si retenu comme fonctionnalité. Inclure un album continu, deux occurrences du même morceau, des URL authentifiées, un proxy, un transfert lent et un transcodage en cours.

Scénarios éliminatoires : seek après Pause et reprise à froid, Pause/Next pendant récupération, callbacks tardifs, reset des services audio, changement Wi-Fi/cellulaire, perte/reconnexion AirPods, AirPlay et lecture longue en arrière-plan.

**Décision de migration uniquement si** un bénéfice mesuré ou une fonctionnalité produit prioritaire justifie la dépendance, sans régression des scénarios ci-dessus, et après décision explicite sur le rendu à 44,1 kHz. Sans cela, améliorer l’implémentation AVPlayer existante est le choix le mieux étayé.
