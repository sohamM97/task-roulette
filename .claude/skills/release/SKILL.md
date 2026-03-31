---
name: release
description: Push a Release. Use when the user wants to tag a release or push a new version.
---

# Push a Release

Tag and push a new release version. GitHub Actions will build the APK automatically.

## Arguments

The user may provide a version number (e.g. `0.5.0`). If not provided, recommend the next **patch** version (e.g. `1.0.3` → `1.0.4`) but let the user choose.

## Workflow

1. Check that you're on the `main` branch. If not, **stop** and tell the user.
2. Run `git status` to check for uncommitted changes. If there are any, **stop** and tell the user to commit first (or offer to run `/commit`).
3. Read `pubspec.yaml` to get the current version.
4. Determine the new version:
   - If the user provided one, use it.
   - Otherwise, use the `AskUserQuestion` tool to ask the user which version to release. Suggest the next patch version as the default. Patch releases are the norm — they're used to get APKs for phone testing. Minor/major releases are reserved for when the user is satisfied with overall stability. **Never assume a minor/major release — always use AskUserQuestion to confirm.**
5. **No-new-commits is normal for minor/major releases.** A minor/major release often "promotes" the latest patch to a stable version — the tag may point to the same commit as the last patch. Don't flag this as unusual.
6. **For minor/major releases only**: Remind the user to run `/full-code-review` and `/sec-review` before a minor/major release. Check for recent updates to `docs/CODE_REVIEW.md` and `docs/SECURITY_REVIEW.md` since the last **minor/major** tag (not the last patch tag). If reviews were run during the patch cycle leading up to this release, they count — don't ask the user to re-run them. If either looks stale, mention it — but if the user wants to proceed anyway, don't block the release.
7. Update `version:` in `pubspec.yaml` to the new version (keep the `+1` build number).
8. Commit the version bump with message: `Bump version to <version>`.
9. Push the commit to the current branch.
10. Create the git tag (`v<version>`) and push it to origin.
11. Report the tag and remind the user to:
    - Export data from their phone before installing the new APK.
    - Test on their phone once the release build is ready.

## CHANGELOG

- Update `CHANGELOG.md` for **major and minor** releases (e.g. 1.1.0, 2.0.0) — add a new section at the top summarizing what changed since the **last minor/major release** (not the last patch tag). For example, if releasing v1.3.0 and the last minor was v1.2.0, the changelog should cover all commits from v1.2.0 to HEAD — including all the patch releases in between.
- **Skip** the changelog for patch releases (e.g. 1.0.1) — commit messages cover those.
- Include the release date in the version header: `## vX.Y.Z — Title (YYYY-MM-DD)`.
- Avoid internal jargon (e.g. "Phase 2") — the changelog is user-facing.
- Don't duplicate entries across versions — if a feature was listed in a prior release, don't repeat it.
- Keep test counts precise, not approximate.
- **Linux desktop is dev-only** — never mention Linux as a supported platform. Only Android and Web are user-facing platforms.

## Rules

- Do NOT create the release with `gh release create` — GitHub Actions handles that on tag push.
- Do NOT force push.
- The tag must match the format `v<version>` (e.g. `v0.5.0`).
- The `pubspec.yaml` version must match the tag version.
- Releases must always be from the `main` branch.
