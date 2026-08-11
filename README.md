# ZenRay Dictate

Une pastille ChatGPT flottante, pilotée par la touche Fn, qui dépose la
transcription dans le presse-papier.

L'app tourne en arrière-plan, sans icône au Dock. Un appui sur Fn fait
apparaître la pastille au premier plan et lance la dictée. Un second appui
affiche `Transcribing…`, puis la pastille disparaît et le texte est déjà dans le
presse-papier. Un `Cmd+V` et c'est collé.

## Comment ça marche

L'app embarque une page chatgpt.com invisible, où ta session vit une fois pour
toutes. Elle ne reconstruit pas la requête de transcription : elle **clique sur
la dictée de la page et écoute la réponse**.

Cette décision vient d'une mesure faite le 11 août 2026, directement dans la
session Chrome de Matthieu. Le bouton micro de ChatGPT poste un WebM sur
`/backend-api/transcribe` et reçoit `{"text": …, "asset_format": "webm"}`. Aucun
WebSocket ni WebRTC n'est ouvert pendant le cycle, donc la dictée n'est pas du
Realtime, contrairement au gros bouton voix voisin. La page fait donc
l'enregistrement, l'encodage et l'envoi comme elle sait le faire, et `bridge.js`
n'intercepte que le texte qui revient. Rien à deviner, rien à maintenir sur le
format du corps de la requête.

## Construire

```bash
./build.sh
open ZenRayDictate.app
```

## Premier lancement, trois étapes

**1. Connexion.** Icône micro dans la barre de menus, `Sign in to ChatGPT…`,
tu te connectes normalement, puis `Hide the ChatGPT window`. La session persiste
entre les lancements, tu ne le refais pas.

**2. Accessibilité.** macOS la demande au premier appui, elle sert uniquement à
observer la touche Fn. L'app se met à écouter dès que tu l'accordes, sans
redémarrage.

**3. Micro.** Accordé une fois, à l'app elle-même, au premier enregistrement.

## Le point qui casse tout si on l'oublie

macOS attribue Fn à sa propre fonction. Va dans **Réglages Système > Clavier >
« Appuyer sur la touche 🌐 pour »** et choisis **« Ne rien faire »**, sinon Fn
ouvre le sélecteur d'emoji ou la dictée d'Apple par-dessus la pastille.

L'app écoute la touche en mode `listenOnly`, donc elle ne l'intercepte jamais et
ne prive aucune autre application de Fn.

## Structure

| Fichier | Rôle |
|---|---|
| `main.swift` | Démarrage, mode accessoire, aucun Dock |
| `AppDelegate.swift` | Barre de menus, câblage, presse-papier |
| `FnKeyMonitor.swift` | `CGEventTap` sur Fn, un déclenchement par appui |
| `DictationEngine.swift` | WebView cachée, machine à trois états, pont JS |
| `PillWindow.swift` | La pastille flottante, sans vol de focus |
| `Resources/bridge.js` | Clique la dictée, écoute `/backend-api/transcribe` |

## Limites connues

La transcription abandonne au bout de 25 secondes si la réponse ne revient
jamais, et la pastille affiche l'erreur plutôt que de rester bloquée.

La dictée s'ouvre dans une conversation temporaire, si bien que rien ne se
dépose dans ton historique ChatGPT.

L'app dépend des libellés d'accessibilité `Start dictation` et
`Submit dictation` de la page. Si OpenAI les renomme, la pastille affichera
`Could not start dictation` et il faudra ajuster `bridge.js`.

L'accès automatisé à ChatGPT contrevient aux conditions d'usage d'OpenAI.
L'exposition porte sur le compte, décision prise en connaissance de cause.
