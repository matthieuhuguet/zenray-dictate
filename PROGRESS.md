# PROGRESS, ZenRayDictate

Journal append only du projet.

2026-08-20 20:45
- Fait : le dossier local `zenray-gpt-realtime-audio` est renommé `ZenRayDictate` pour aligner le chemin, la cible Swift, le bundle et le contexte du projet.
- Fait : ajout d’un effacement complet du composer par `⌘Q` dans la fenêtre compacte, avec détection du caractère produit par le clavier pour respecter l’AZERTY ; ajout d’un bouton `×` discret, affiché uniquement quand un texte existe ; le focus revient automatiquement au composer après affichage ou effacement ; la fenêtre disparaît en fondu lorsqu’elle perd le focus.
- Décision : `⌘Q` reste local à la fenêtre compacte et ne détourne pas le raccourci Quitter dans les autres applications.
- Échoué : la première compilation après le renommage a réutilisé un cache `.build` contenant l’ancien chemin absolu ; `swift package clean` a supprimé ces artefacts régénérables et la compilation suivante a réussi.
- Fait : `node --check`, `git diff --check`, compilation Swift arm64, assemblage, signature et lancement du bundle sous le nouveau chemin passent ; une capture visuelle confirme l’affichage du bar compact.
- Prochain : dans la fenêtre réelle, saisir un texte puis vérifier `⌘Q`, le bouton `×` et le fondu au clic extérieur ; si un détail visuel gêne, corriger uniquement ce détail.

2026-08-20 20:49
- Fait : les commits `5806722` et `13459fc` sont poussés sur `https://github.com/matthieuhuguet/zenray-dictate.git`, branche `main` ; le SHA local et le SHA distant correspondent à `13459fc6e7507ddb2a03d609d23b0ccf214502b5`.
- Prochain : effectuer le test manuel des trois interactions dans la fenêtre réelle.
