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
- The release script explicitly marks the new release as latest and non-draft.
- The release script removes any remaining draft releases after publishing.
- Do not ship if the build shows unresolved warnings, errors, or dependency mismatches.

## Output

Release mode builds `dist\InstallTheCli.exe`, stages versioned EXE/ZIP assets plus SHA-256 sums and one-click install scripts under `dist\release`, tags and pushes Git, and publishes the GitHub release.
