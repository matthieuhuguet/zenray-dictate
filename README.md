# ZenRay Dictate

Fn fait apparaître ou disparaître une fenêtre ChatGPT. C'est tout ce que l'app
fait. La dictée elle-même, c'est la vraie page ChatGPT qui la gère : tu cliques
sur `Start Dictation`, tu parles, tu cliques sur `Stop Dictation`, et le texte
part automatiquement dans le presse-papier.

## Pourquoi si simple

Trois versions plus construites ont montré que reconstruire l'interface de
ChatGPT en SwiftUI, deviner ses libellés de boutons, ou distinguer les états
d'enregistrement, ajoutait de la fragilité sans rien apporter. La page fait
déjà tout ça correctement. L'app n'a qu'un rôle : la garder en fond, connectée,
et attraper le texte qui en sort.

## Comment ça marche

L'app embarque une page chatgpt.com dans une fenêtre normale. Elle ne
reconstruit pas la requête de transcription : elle **regarde passer la
réponse** de `POST /backend-api/transcribe`, dont le corps est
`{"text": …, "asset_format": "webm"}`, et copie ce texte dans le presse-papier.
Rien d'autre n'est injecté ni cliqué à sa place.

## Construire

```bash
./build.sh
open ZenRayDictate.app
```

## Premier lancement

**1.** La fenêtre s'ouvre toute seule. Connecte-toi normalement à ChatGPT. La
session persiste ensuite entre les lancements.

**2.** Accorde le micro à l'invite. Si Fn ne répond pas ailleurs que dans l'app,
accorde aussi l'accessibilité (Réglages Système, Confidentialité,
Accessibilité), et va dans Réglages Système, Clavier, « Appuyer sur la touche
🌐 pour » et choisis « Ne rien faire », sinon macOS capte la touche avant l'app.

## Utilisation

Fn ouvre la fenêtre. `Start Dictation`, tu parles, `Stop Dictation`. Le texte
est déjà dans le presse-papier, `Cmd+V` pour le coller. Fn de nouveau referme
la fenêtre.

## Structure

| Fichier | Rôle |
|---|---|
| `main.swift` | Démarrage, mode accessoire, aucun Dock |
| `AppDelegate.swift` | Barre de menus, permissions, câblage de Fn |
| `FnKeyMonitor.swift` | `CGEventTap` sur Fn, un déclenchement par appui |
| `ChatWindow.swift` | La fenêtre ChatGPT, montrer/cacher, pont JS |
| `Permissions.swift` | Micro et accessibilité |
| `Log.swift` | Journal sur disque, `~/Library/Logs/ZenRayDictate.log` |
| `Resources/bridge.js` | Écoute `/backend-api/transcribe`, rien d'autre |

## Le piège d'accessibilité à connaître

Une signature ad-hoc change à chaque reconstruction. L'accessibilité est
accordée contre cette signature, donc **elle se révoque toute seule à chaque
build**, même si la case reste cochée dans les Réglages. C'est sans
conséquence pour l'usage courant, Fn continue de fonctionner tant que l'app
n'est pas reconstruite ; ça compte seulement pendant le développement.

## Limites connues

L'accès automatisé à ChatGPT contrevient aux conditions d'usage d'OpenAI.
L'exposition porte sur le compte, décision prise en connaissance de cause.

La dictée s'ouvre dans une conversation temporaire, rien ne se dépose dans
l'historique ChatGPT.
