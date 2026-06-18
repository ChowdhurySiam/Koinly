# Koinly Flutter

A local-first personal finance tracker built in Flutter with a Material 3 mobile UI. Koinly helps users manage accounts, transactions, budgets, loans, reports, reminders, exports, local backups, and optional online sync from a single Android app.

![Koinly banner](assets/images/koinly-banner.png)

## Project status

This repository contains a Flutter Android app plus an optional Cloudflare Worker + Turso backend for online data sync and admin approval.

| Area | Current implementation |
| --- | --- |
| App framework | Flutter / Dart |
| Main platform | Android |
| Local database | SQLite via `sqflite` |
| State management | `provider` + `ChangeNotifier` |
| Analytics/crash reporting | Firebase Analytics + Crashlytics, wrapped in optional initialization |
| Online sync | Cloudflare Worker API + Turso sync snapshots |
| Sync approval | Admin panel with `ADMIN_KEY` login, approve/reject/block controls |
| Backup/restore | Local `.koinlybackup` files using file picker and app document storage |
| CI build | GitHub Actions workflow for ARM32, ARM64, and universal release APKs |
| License | Apache License 2.0 |

## Features

### Finance management

- Multiple account support, including regular accounts and credit accounts.
- Account creation, editing, deletion, reordering, icon selection, and color customization.
- Income, expense, and transfer transactions.
- Transaction filters by date range, account, category, and transaction type.
- Default account, default income category, and default expense category settings.

### Categories

- Income and expense category management.
- Custom icons and colors for category cards.
- Category-level transaction breakdown pages.
- Seeded default categories for first launch.

### Budgets

- Monthly budget creation.
- Budget scoping by all accounts/categories or selected accounts/categories.
- Budget progress indicators and budget detail screens.

### Loans

- Separate loan system for money given and money taken.
- Loan principal balance application to selected accounts.
- Repayment tracking with account selection.
- Open/completed loan status handling.
- Migration cleanup for older hidden loan transaction rows.

### Analysis and reports

- Dashboard summary for balance, income, expense, and savings.
- Analysis page using charts from `fl_chart`.
- Filter-aware CSV export.
- Filter-aware PDF export.
- Share support for generated export files.

### Settings and security

- Theme preferences: system, light, dark, and battery-saver/system mode.
- Currency customization with symbol, code, prefix/suffix placement, and separators.
- Daily reminder notification.
- App lock using biometric/device authentication where supported.
- Compact home summary setting.
- About, privacy policy placeholder, terms placeholder, and open-source license view.

### Online data sync

- Settings includes an **Online data sync** screen.
- Users enter a **Sync ID** and **Sync PIN**.
- The main action button is **Sync**.
- The Cloudflare Worker URL is not shown in the app UI. It is compiled into the APK using `KOINLY_SYNC_API_BASE_URL`.
- New Sync IDs require admin approval before upload/download is allowed.
- If a Sync ID is not approved, the app shows a popup asking the user to message the admin.
- The popup contains a **Telegram** button that opens:

```text
https://t.me/Ch0wdhury_Siam
```

- Existing users/snapshots already in the Turso database are treated as approved, so they do not need approval again.
- When automatic sync is enabled, local finance changes are uploaded after a short debounce.
- Synced payload includes accounts, categories, transactions, budgets, budget relationships, loans, loan repayments, and app preferences.
- Sync PINs are not stored as plain text by the backend. The Worker stores a salted hash using the `SYNC_SECRET` Worker secret.

### Backup and restore

- Backup files are generated as `.koinlybackup` files.
- The backup includes database rows and app preferences.
- Backups are saved through the platform file picker when available and also copied into app document storage under a `backups` folder.
- Restore opens local storage through the file picker and imports a selected backup file.

> Note: the current backup encoding uses a built-in app constant and lightweight XOR/Base64 obfuscation. Treat backups as private files and do not rely on this as strong cryptographic encryption.

## Screenshots

The repository includes polished README screenshots under `assets/images/readme/`.

<p align="center">
  <img src="assets/images/readme/home.png" width="180" alt="Koinly home dashboard" />
  <img src="assets/images/readme/analysis.png" width="180" alt="Koinly analysis dashboard" />
  <img src="assets/images/readme/loans.png" width="180" alt="Koinly loans page" />
  <img src="assets/images/readme/transactions.png" width="180" alt="Koinly transaction list" />
  <img src="assets/images/readme/categories.png" width="180" alt="Koinly categories breakdown" />
</p>

## Tech stack

- **Flutter SDK:** Dart SDK `>=3.4.0 <4.0.0`
- **Android:** compile SDK 36, target SDK 36, minimum SDK 23
- **Gradle:** wrapper configured for Gradle 8.14.1
- **Android Gradle Plugin:** 8.11.1
- **Kotlin plugin:** 2.2.20
- **Java:** 17
- **Database:** `sqflite`
- **Charts:** `fl_chart`
- **Exports:** `pdf`, `printing`, `share_plus`
- **File access:** `file_picker`, `path_provider`
- **Security:** `local_auth`
- **Notifications:** `flutter_local_notifications`, `timezone`
- **Firebase:** `firebase_core`, `firebase_analytics`, `firebase_crashlytics`
- **Online sync client:** `http`
- **Online sync backend:** Cloudflare Worker + Turso via `@libsql/client`

## Project structure

```text
.
├── .github/workflows/build-android-apks.yml # GitHub Actions APK build workflow
├── android/                                # Android native project
│   └── app/
│       ├── build.gradle                    # Android app build configuration
│       ├── google-services.json            # Firebase Android config
│       └── src/main/AndroidManifest.xml    # Android permissions and launcher setup
├── assets/images/                          # Banner, splash, and screenshots
├── backend/cloudflare-turso/               # Cloudflare Worker, Turso schema, admin panel
│   ├── src/index.js                        # Worker API and admin panel HTML
│   ├── package.json                        # Worker dependencies
│   └── wrangler.toml                       # Cloudflare Worker config
├── lib/main.dart                           # Main Flutter app, models, DB, UI, services
├── pubspec.yaml                            # Flutter dependencies and assets
├── analysis_options.yaml                   # Flutter lint rules
└── LICENSE                                 # Apache License 2.0
```

## Data model

The SQLite database is opened as `koinly_flutter.db` and currently uses schema version `5`.

Main local tables:

- `accounts`
- `categories`
- `transactions`
- `budgets`
- `budget_accounts`
- `budget_categories`
- `loans`
- `loan_repayments`

The app seeds new installations with default accounts: `Cash`, `Card`, and `Bank Account`, plus default income and expense categories.

Main Turso tables are created automatically by the Worker:

- `sync_snapshots`
- `sync_users`

Manual Turso schema import is not required because the Worker runs `CREATE TABLE IF NOT EXISTS` during requests.

## Android permissions

The app requests these Android permissions:

- `USE_BIOMETRIC`
- `USE_FINGERPRINT`
- `POST_NOTIFICATIONS`
- `SCHEDULE_EXACT_ALARM`
- `RECEIVE_BOOT_COMPLETED`
- `READ_EXTERNAL_STORAGE` for Android 12 and below
- `WRITE_EXTERNAL_STORAGE` for Android 9 and below
- `INTERNET`
- `ACCESS_NETWORK_STATE`

These permissions support app lock, reminders, backup/restore file access, notification behavior, and HTTPS online sync.

## Requirements

Install the following before building locally:

- Flutter stable channel with Dart 3.4 or newer.
- Android Studio or Android SDK command-line tools.
- Java 17.
- Android SDK Platform 36 and Build Tools 36.0.0.
- Android NDK 28.2.13676358 for matching the current Gradle configuration.
- A Cloudflare account for Worker deployment.
- A Turso account and database for online sync.

## Local Flutter setup

```bash
git clone <your-repository-url>
cd Koinly-Flutter-main
flutter pub get
flutter run
```

If you extracted this project from a ZIP instead of cloning from Git, run the same commands from the project root containing `pubspec.yaml`.

## Cloudflare + Turso backend setup

Backend files are included in:

```text
backend/cloudflare-turso
```

### 1. Create a Turso database

```bash
turso db create koinly-sync
```

Get the database URL:

```bash
turso db show koinly-sync --url
```

Create a database token:

```bash
turso db tokens create koinly-sync
```

Save these values for Cloudflare secrets:

```text
TURSO_DATABASE_URL=<your Turso database URL>
TURSO_AUTH_TOKEN=<your Turso database token>
```

### 2. Add Cloudflare Worker secrets

Required secrets:

```text
TURSO_DATABASE_URL
TURSO_AUTH_TOKEN
SYNC_SECRET
ADMIN_KEY
```

Recommended values:

```text
SYNC_SECRET=<long random private string>
ADMIN_KEY=<your private admin login key>
```

`ADMIN_KEY` is used to log in to the admin panel at `/admin`.

### 3. Deploy from Cloudflare website

In Cloudflare Dashboard, create a Worker connected to your GitHub repository and use this build configuration:

| Field | Value |
| --- | --- |
| **Path / Root directory** | `backend/cloudflare-turso` |
| **Build command** | `npm install` |
| **Deploy command** | `npx wrangler deploy --config wrangler.toml` |
| **Non-production branch deploy command** | `npx wrangler deploy --config wrangler.toml` |
| **Build output directory** | Leave empty |
| **Framework preset** | None / Worker |

Make sure this file exists in GitHub:

```text
backend/cloudflare-turso/wrangler.toml
```

Expected content:

```toml
name = "koinly-sync"
main = "src/index.js"
compatibility_date = "2026-06-01"
```

### 4. Deploy from terminal instead

```bash
cd backend/cloudflare-turso
npm install
npx wrangler secret put TURSO_DATABASE_URL
npx wrangler secret put TURSO_AUTH_TOKEN
npx wrangler secret put SYNC_SECRET
npx wrangler secret put ADMIN_KEY
npx wrangler deploy --config wrangler.toml
```

### 5. Test the Worker

Open:

```text
https://<your-worker>.workers.dev/
```

Expected response:

```json
{
  "ok": true,
  "service": "koinly-sync",
  "admin": "https://<your-worker>.workers.dev/admin"
}
```

## Admin panel

The admin panel is served by the Worker:

```text
https://<your-worker>.workers.dev/admin
```

Login with the value of the Cloudflare secret:

```text
ADMIN_KEY
```

After login, the panel shows Sync IDs and metadata. It does not show finance payload contents.

Admin actions:

| Action | Result |
| --- | --- |
| **Approve** | Allows the Sync ID to upload/download cloud data. |
| **Reject** | Denies the current request. User can message admin if needed. |
| **Block** | Prevents the Sync ID from syncing. |
| **Delete** | Removes the Sync ID approval record and stored snapshot. |

Existing users/snapshots already present in Turso are automatically migrated to approved status, so old users do not need approval again.

## Online sync user flow

1. Build the APK with `KOINLY_SYNC_API_BASE_URL`.
2. Open the app.
3. Go to:

```text
Settings → Online data sync
```

4. Enable automatic sync if desired.
5. Enter a Sync ID and Sync PIN.
6. Tap **Sync**.
7. If the Sync ID is new, the app creates a pending request and shows:

```text
Message admin to activate your online sync.
```

8. The user can tap **Telegram** to message:

```text
https://t.me/Ch0wdhury_Siam
```

9. Admin opens `/admin`, logs in with `ADMIN_KEY`, then approves the Sync ID.
10. User taps **Sync** again, or uses **Upload local data now**.
11. On another device, use the same Sync ID and PIN, then tap **Download cloud data to this device**.

> Conflict handling is last-upload-wins. For two-device use, download the latest cloud snapshot before editing on the second device.

## Build APK locally

The Worker URL is a build-time variable. The app does not show a field for it.

Run dependency resolution first:

```bash
flutter pub get
```

### Universal release APK

```bash
flutter build apk \
  --release \
  --target-platform android-arm,android-arm64 \
  --no-tree-shake-icons \
  --dart-define=KOINLY_SYNC_API_BASE_URL=https://<your-worker>.workers.dev
```

Output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

### ARM32 and ARM64 split APKs

```bash
flutter build apk \
  --release \
  --split-per-abi \
  --target-platform android-arm,android-arm64 \
  --no-tree-shake-icons \
  --dart-define=KOINLY_SYNC_API_BASE_URL=https://<your-worker>.workers.dev
```

Outputs:

```text
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Recommended APK choice:

| APK | Use case |
| --- | --- |
| `app-arm64-v8a-release.apk` | Modern 64-bit Android phones. Smallest recommended APK for most users. |
| `app-armeabi-v7a-release.apk` | Older 32-bit Android phones. |
| `app-release.apk` | Universal APK for broad compatibility. Larger file size. |

If you build without `KOINLY_SYNC_API_BASE_URL`, online sync will not work until the APK is rebuilt with a Worker URL.

## GitHub Actions APK build

The repository includes:

```text
.github/workflows/build-android-apks.yml
```

Add this repository variable before running the workflow:

```text
KOINLY_SYNC_API_BASE_URL=https://<yourworker>.workers.dev
```

Path:

```text
GitHub repo → Settings → Secrets and variables → Actions → Variables → New repository variable
```

The workflow builds three release APK artifacts:

| Artifact file | Target |
| --- | --- |
| `koinly-arm64-v8a-release.apk` | ARM64 / modern Android devices |
| `koinly-armeabi-v7a-release.apk` | ARM32 / older Android devices |
| `koinly-universal-release.apk` | Universal APK for broad compatibility |

The workflow:

1. Checks out the repository.
2. Sets up Java 17.
3. Installs Android SDK 36, Build Tools 36.0.0, and NDK 28.2.13676358.
4. Sets up Flutter stable.
5. Forces Gradle wrapper 8.14.1.
6. Runs `flutter pub get`.
7. Builds a universal release APK.
8. Builds ARM32 and ARM64 split release APKs.
9. Uploads all three APKs as a GitHub Actions artifact named `koinly-release-apks`.

The workflow runs on pushes to `main` or `master` when app files change, and it can also be started manually from the GitHub Actions tab. Manual runs can override `KOINLY_SYNC_API_BASE_URL` with the workflow input.

## Firebase configuration

The project contains Firebase dependencies and an Android `google-services.json` file for Analytics and Crashlytics. At runtime, Firebase initialization is wrapped in a `try/catch`, so the app code is designed to continue even if Firebase initialization fails.

For your own Firebase project:

1. Create or open a Firebase project.
2. Add an Android app with package name:

```text
com.siamapps.koinly
```

3. Download the new `google-services.json`.
4. Replace:

```text
android/app/google-services.json
```

5. Rebuild the app.

## API endpoints

The Worker exposes these endpoints:

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/` | Health check and admin URL. |
| `GET` | `/admin` | Admin panel UI. |
| `POST` | `/api/sync/push` | Upload a full encrypted/encoded finance snapshot. |
| `POST` | `/api/sync/pull` | Download the latest snapshot for a Sync ID. |
| `GET` | `/api/admin/overview` | Admin metadata list. Requires `ADMIN_KEY`. |
| `POST` | `/api/admin/user-status` | Approve/reject/block Sync ID. Requires `ADMIN_KEY`. |
| `POST` | `/api/admin/delete` | Delete Sync ID and snapshot. Requires `ADMIN_KEY`. |

## Troubleshooting

### `SQLITE_UNKNOWN: SQLite error: no such table: sync_snapshots`

Redeploy the latest Worker. The current Worker auto-creates both Turso tables:

```text
sync_snapshots
sync_users
```

If the error still appears, confirm that the Worker is connected to the correct Turso database and that these secrets are set:

```text
TURSO_DATABASE_URL
TURSO_AUTH_TOKEN
SYNC_SECRET
ADMIN_KEY
```

### `Cloud sync backend URL is not configured in this APK`

Rebuild the APK with:

```bash
flutter build apk --release --no-tree-shake-icons \
  --dart-define=KOINLY_SYNC_API_BASE_URL=https://<your-worker>.workers.dev
```

### Admin panel says unauthorized

Use the same value you stored in the Cloudflare secret:

```text
ADMIN_KEY
```

If you recently changed `ADMIN_KEY`, redeploy the Worker and log in again.

### User sees `Message admin to activate your online sync.`

This is expected for a new Sync ID. Open the admin panel and click **Approve**.

### User was approved before but now cannot sync

Check the user status in `/admin`:

- `approved` can sync.
- `rejected` cannot sync until approved.
- `blocked` cannot sync until approved again.
- `pending` needs approval.

### Cloudflare deploy says static files cannot be detected

Use a Worker deployment, not a Pages static-site deployment. Also confirm that this file exists:

```text
backend/cloudflare-turso/wrangler.toml
```

and use:

```bash
npx wrangler deploy --config wrangler.toml
```

### `flutter.sdk not set in local.properties`

This appears when Android Gradle is run before Flutter creates `android/local.properties`.

Run:

```bash
flutter pub get
flutter build apk --release
```

Flutter will generate `android/local.properties` automatically.

### Android SDK or NDK mismatch

The project expects:

```text
compileSdk = 36
targetSdk = 36
ndkVersion = 28.2.13676358
```

Install the matching Android SDK packages from Android Studio SDK Manager or `sdkmanager`.

### Firebase build errors

Confirm that this file exists:

```text
android/app/google-services.json
```

If you changed the package name, regenerate this file from Firebase using the new Android application ID.

### Release APK is signed with debug key

This is expected for the current CI workflow. Configure a release keystore before public distribution.

## Development notes

- The app is currently monolithic: most models, services, state controller, database logic, and UI screens live in `lib/main.dart`.
- There is no `pubspec.lock` in this package. Run `flutter pub get` to generate it.
- Firebase is optional for local-only use.
- Online sync requires a deployed Cloudflare Worker URL passed into the APK through `KOINLY_SYNC_API_BASE_URL` and a configured Turso database.
- Backup files are local files; online sync stores full JSON snapshots in the Turso `sync_snapshots` table.
- Placeholder legal text is present inside the app and should be replaced before production release.

## License

This project includes an Apache License 2.0 license file. See [`LICENSE`](LICENSE) for the full license text.
