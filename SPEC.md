# ZenRayDictate specification (3 October 2026)

J'aimerai surtout coder toutes les features dans ZenRayDictate de Wispr Flow go : L'application que tu décris est très probablement Wispr Flow. Sa pastille flottante s'affiche en bas de l'écran et sa touche par défaut est Fn sur Mac, à maintenir pour dicter et à relâcher pour arrêter. Superwhisper est l'autre référence, plus orientée modes et modèles locaux. La liste ci-dessous fusionne les deux et marque d'un (+) mes ajouts, pour que tu saches ce qui est observé chez eux et ce qui est suggéré.

**1. Déclenchement et retour visuel**

- Push-to-talk sur Fn : maintenir pour enregistrer, relâcher pour transcrire et insérer.
- Mains libres : double appui sur la touche, ou Fn+Espace, pour démarrer et arrêter sans la maintenir.
- Touche reconfigurable, car Fn n'existe pas sur les claviers externes.
- Micro actif seulement pendant la pression, avec l'indicateur jaune de macOS comme confirmation.
- Pastille flottante avec forme d'onde animée pendant l'enregistrement, qui ne prend jamais le focus de l'application active (+).

**2. Transcription**

- Moteurs interchangeables, locaux (Whisper, Parakeet) ou cloud. (+) Gemini 3.5 Transcribe, gpt-transcribe et Voxtral Realtime en options, pour comparer les moteurs dont on a parlé sur ta propre voix.
- Détection automatique de la langue.
- Dictionnaire personnel, alimenté automatiquement ou par import CSV.
- Remplacements de texte (« super whisper » devient « Superwhisper »), qui complètent le dictionnaire.
- Snippets vocaux : raccourcis pour des textes récurrents comme des mails, des liens ou des adresses.

**3. Intelligence après transcription**

- Nettoyage automatique des hésitations, des autocorrections, de la ponctuation et de la mise en forme.
- Modes personnalisés : tu écris le prompt, fixes les règles de format et choisis le modèle de langage qui fait le nettoyage. (+) Mode lié automatiquement à l'application active.
- Contrôle du ton pour les modes message, mail et notes.
- Reconnaissance de syntaxe : camelCase, snake_case et acronymes sans les épeler.
- Lecture du contexte à l'écran pour orthographier noms de fichiers et termes visibles.
- Command Mode : sélectionner un texte, maintenir le raccourci, dire l'instruction, et le texte est remplacé sur place ; sans sélection, il génère au curseur.
- Mode chuchotement pour dicter à voix basse dans un espace partagé.

**4. Données et confidentialité**

- Historique des dictées, avec retraitement d'un enregistrement dans un autre mode sans changer le mode actif.
- Dépôt d'un fichier audio ou vidéo à la place de la voix.
- Historique, modes et vocabulaire dans un dossier unique à sauvegarder.
- Mode 100 % local. (+) Audio non conservé par défaut, alors que Superwhisper enregistre sur disque même en mode local.

**5. Agents de code**

- Dictée dans le terminal, Cursor et Claude Code. (+) Mode « prompt d'agent » qui transforme un monologue en tâche structurée, avec mentions de fichiers.

**6. Notes d'implémentation macOS** (de mémoire, à faire vérifier par Claude Code et Codex pendant la construction)

- Application de barre de menus en Swift. Fn se détecte via un event tap sur les changements de modificateurs, ce qui exige les permissions Accessibilité, Surveillance de l'entrée et Micro.
- Réglage système « Appuyer sur 🌐 pour » à mettre sur « Ne rien faire », sinon macOS déclenche la dictée ou les emojis en parallèle.
- Capture avec AVAudioEngine en 16 kHz mono. Insertion par presse-papiers puis Cmd+V simulé, avec restauration de l'ancien contenu du presse-papiers.
- Pastille dans un panneau flottant non activant.

Pour démarrer, FnKey est une petite application Rust de barre de menus qui fait exactement ton cycle, maintenir Fn, parler, relâcher, coller. Elle peut servir de référence à donner à tes agents avant qu'ils écrivent la première ligne. Colle cette liste telle quelle dans un SPEC.md à la racine du dépôt, et les deux agents auront le même cahier des charges.





LE BACKEND C'EST GEMINI.GOOGLE.COM TU AS COMPRIS GO [$dont-stop](/Users/zenray/.codex/skills/dont-stop/SKILL.md) 

