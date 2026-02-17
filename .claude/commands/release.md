# Push a Release

Tag and push a new release version. GitHub Actions will build the APK automatically.

## Arguments

The user may provide a version number (e.g. `0.5.0`). If not provided, ask what version to tag.

## Workflow

1. Run `git status` to check for uncommitted changes. If there are any, **stop** and tell the user to commit first (or offer to run `/commit`).
2. Read `pubspec.yaml` to get the current version.
3. Determine the new version:
   - If the user provided one, use it.
   - Otherwise, ask the user.
4. Update `version:` in `pubspec.yaml` to the new version (keep the `+1` build number).
5. Commit the version bump with message: `Bump version to <version>`.
6. Push the commit to the current branch.
7. Create the git tag (`v<version>`) and push it to origin.
8. Report the tag and remind the user to:
   - Export data from their phone before installing the new APK.
   - Test on their phone once the release build is ready.

## CHANGELOG

- Update `CHANGELOG.md` for **major and minor** releases (e.g. 1.1.0, 2.0.0) — add a new section at the top summarizing what changed since the last entry.
- **Skip** the changelog for patch releases (e.g. 1.0.1) — commit messages cover those.

## Rules

- Do NOT create the release with `gh release create` — GitHub Actions handles that on tag push.
- Do NOT force push.
- The tag must match the format `v<version>` (e.g. `v0.5.0`).
- The `pubspec.yaml` version must match the tag version.
