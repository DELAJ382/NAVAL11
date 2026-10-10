# Outland

Outland is a browser game hosted as a static site. Firebase Authentication handles email/password accounts, and Firebase Realtime Database handles room presence and player-state sync. The game does not need a PHP, PowerShell, WebSocket, or localhost server.

## Firebase configuration

1. In Firebase Console, enable **Authentication → Sign-in method → Email/Password**.
2. Create a **Realtime Database** in project `naval-27f95`. The configured URL is `https://naval-27f95-default-rtdb.firebaseio.com`.
3. In **Authentication → Settings → Authorized domains**, authorize the Firebase Hosting domain and any custom domain. Add `delaj382.github.io` only if you also serve the game from GitHub Pages.
4. `index.html` contains Firebase web-app client configuration. That configuration is intended to be public. Never add the Firebase Admin service-account JSON file to this repository.

The database rules are in `database.rules.json`. They require authentication to read room players and restrict each account to writing its own player record. These rules protect account identity and record ownership; they do **not** make browser-run combat authoritative. A determined player can manipulate their own client, position, health, or hit events. Do not use this client-only game for ranked or cheat-sensitive play without a trusted server.

## Deploy with Firebase Hosting

Install the Firebase CLI if needed, sign in, and deploy from this folder:

```powershell
npm install -g firebase-tools
firebase login
firebase deploy --only hosting,database
```

The CLI prints a public `https://<project-id>.web.app` URL. Open it in the Android phone browser to play; do not use a `localhost` URL. A custom domain can be connected in **Firebase Console → Hosting**. Configure each deployed domain as an authorized Firebase Authentication domain.

## Optional GitHub Pages hosting

The static page can also be served from GitHub Pages, with Firebase still providing authentication and room sync. Publish the repository root and authorize `delaj382.github.io` in Firebase Authentication. GitHub Pages does not run backend code, but this game does not require a separate backend server.

## Android wrapper

The optional Android Studio wrapper loads a hosted HTTPS page. See [android/README.md](./android/README.md) and set `GAME_URL` in `android/gradle.properties` to the Firebase Hosting or custom-domain URL.

## Gameplay trust limits

Realtime Database listeners sync player presence and state between signed-in users in a room. Firebase rules only permit a signed-in user to write their own UID path. Since this build has no trusted game server, clients still decide their own movement, health, and hit notifications; this is suitable for casual play/testing, not competitive anti-cheat gameplay.
