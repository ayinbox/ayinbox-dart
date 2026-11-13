# Publishing to pub.dev

The package name is `ayinbox`. Releases publish from GitHub Actions through pub.dev automated publishing (OIDC), so no token is stored anywhere. pub.dev only allows automated publishing for a package that already exists, so the first version is published once by a person.

## One-time setup

1. Sign in to https://pub.dev with the Google account that will own the package.
2. Create a verified publisher for `ayinbox.com` (pub.dev, "Create publisher"), which proves the domain through a DNS TXT record in Google Search Console.
3. Make the repository public (pub.dev and its users need the `repository` URL to resolve).
4. From a clean checkout of `main` at the release commit, with Dart 3.3 or later:

   ```sh
   dart pub get
   dart test
   dart pub publish --dry-run
   dart pub publish
   ```

   This publishes `0.1.0` under the signed-in account.
5. On https://pub.dev/packages/ayinbox/admin, transfer the package to the `ayinbox.com` publisher.
6. On the same admin page, under "Automated publishing", enable "Publishing from GitHub Actions" with repository `ayinbox/ayinbox-dart` and tag pattern `v{{version}}`. Optionally require the GitHub environment `pub.dev` and create that environment in the repository settings.
7. Update the README install section to `dart pub add ayinbox` once the package is live.

## Every release after that

1. Bump `version` in `pubspec.yaml` and `sdkVersion` in `lib/src/version.dart`, and add a `CHANGELOG.md` entry.
2. Commit, then tag and push:

   ```sh
   git tag v0.1.1
   git push origin v0.1.1
   ```

`.github/workflows/release.yml` runs on the tag and publishes with the reusable `dart-lang/setup-dart` publish workflow. The tag must match the `pubspec.yaml` version.
