# InstallTheCli Build and Release

Use the checked-in batch files for Windows builds and official releases.

## Commands

```bat
build.bat build
build.bat dry-run
build.bat release
```

`build.bat build` delegates to `build_exe.bat`.

## Release Rules

- Release from `master`.
- Use `build.bat release` for official releases.
- GitHub releases must be published, never drafts.
- The release script explicitly marks the new release as latest and non-draft, and re-verifies that via `gh release view`.
- It never touches other releases; clean up old drafts manually by exact tag.
- Do not ship if the build shows unresolved warnings, errors, or dependency mismatches.

## Output

Release mode builds `dist\InstallTheCli.exe`, stages versioned EXE/ZIP assets plus SHA-256 sums and one-click install scripts under `dist\release`, tags and pushes Git, and publishes the GitHub release.

## Remote Linux Build

The tag push from `:tag_and_push` fires `.github/workflows/linux-build.yml`, which builds a Linux PyInstaller binary on `ubuntu-latest` and attaches it to the same GitHub release. After `:publish_release`, the script waits for that workflow to finish (up to 30 minutes) and verifies the Linux asset appears on the release before declaring the release done. If the Linux build fails or its asset is missing, the script exits non-zero — the GitHub release and Git tag remain in place so you can rerun the remote build manually from the Actions tab. The macOS workflow attaches its own binary in parallel but is not gated here.
