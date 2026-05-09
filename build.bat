@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM Wipe PSModulePath so the Windows PowerShell 5.1 we invoke below rebuilds
REM it from defaults. When build.bat is launched from a PowerShell 7 (pwsh)
REM parent, the pwsh-flavored PSModulePath inherits down through cmd, and
REM 5.1 then fails to auto-load Microsoft.PowerShell.Utility -- which is
REM what provides Get-FileHash. Empty string makes 5.1 reset to its own
REM defaults on startup. Harmless in plain-cmd invocations.
set "PSModulePath="

set "APP_NAME=InstallTheCli"
set "EXE_NAME=InstallTheCli.exe"
set "GITHUB_REPO_SLUG=serrebidev/InstallTheCli-s"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=build"

if /I "%MODE%"=="help" goto :usage
if /I not "%MODE%"=="build" if /I not "%MODE%"=="release" if /I not "%MODE%"=="dry-run" goto :usage

pushd "%~dp0"

if /I "%MODE%"=="build" (
    call "%~dp0build_exe.bat"
    set "RC=!ERRORLEVEL!"
    popd
    exit /b !RC!
)

where git >nul 2>&1 || (echo [release] Git not found in PATH.& goto :error)
where gh >nul 2>&1 || (echo [release] GitHub CLI ^(gh^) not found in PATH.& goto :error)

git fetch --tags >nul 2>&1
call :compute_next_version || goto :error

if /I "%MODE%"=="dry-run" (
    echo [dry-run] Next version: v%NEXT_VERSION%
    echo [dry-run] Would run build_exe.bat, package release assets, tag, push, publish the GitHub release as Latest, and delete draft releases.
    popd
    exit /b 0
)

call :ensure_clean || goto :error
echo [release] Building %APP_NAME% v%NEXT_VERSION%...
call "%~dp0build_exe.bat" || goto :error
call :stage_assets || goto :error
call :tag_and_push || goto :error
call :publish_release || goto :error

echo [release] Published v%NEXT_VERSION%.
popd
exit /b 0

:compute_next_version
set "NEXT_VERSION="
for /f "delims=" %%V in ('powershell -NoProfile -Command "$tags = git tag --list 'v*.*.*'; $versions = foreach ($tag in $tags) { try { [version]($tag -replace '^v','') } catch {} }; $latest = $versions | Sort-Object -Descending | Select-Object -First 1; if ($latest) { '{0}.{1}.{2}' -f $latest.Major, $latest.Minor, ($latest.Build + 1) } else { '1.0.0' }"') do set "NEXT_VERSION=%%V"
if "%NEXT_VERSION%"=="" (
    echo [release] Failed to compute next version.
    exit /b 1
)
exit /b 0

:ensure_clean
git diff --quiet
if errorlevel 1 (
    echo [release] Working tree has uncommitted tracked changes. Commit or stash them before release.
    exit /b 1
)
git diff --cached --quiet
if errorlevel 1 (
    echo [release] Index has staged changes. Commit or unstage them before release.
    exit /b 1
)
exit /b 0

:stage_assets
set "RELEASE_DIR=%CD%\dist\release"
if exist "%RELEASE_DIR%" rd /s /q "%RELEASE_DIR%"
mkdir "%RELEASE_DIR%" || exit /b 1
if not exist "dist\%EXE_NAME%" (
    echo [release] Expected build output not found: dist\%EXE_NAME%
    exit /b 1
)
copy /Y "dist\%EXE_NAME%" "%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%.exe" >nul || exit /b 1
powershell -NoProfile -Command "Compress-Archive -Path '%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%.exe' -DestinationPath '%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%.zip' -Force"
if errorlevel 1 exit /b 1
for %%F in (install_all_windows.ps1 install_all_macos.sh install_all_linux.sh) do (
    if exist "%%F" copy /Y "%%F" "%RELEASE_DIR%\%%F" >nul
)
set "SUMS_PATH=%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%-SHA256SUMS.txt"
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%RELEASE_DIR%' -File | Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $_.Name } | Set-Content -LiteralPath '%SUMS_PATH%' -Encoding ascii"
if errorlevel 1 exit /b 1
set "NOTES_PATH=%RELEASE_DIR%\release-notes-v%NEXT_VERSION%.md"
(
    echo ## %APP_NAME% v%NEXT_VERSION%
    echo.
    echo - Built with build.bat release.
) > "%NOTES_PATH%"
exit /b 0

:tag_and_push
git rev-parse "v%NEXT_VERSION%" >nul 2>&1
if not errorlevel 1 (
    echo [release] Tag v%NEXT_VERSION% already exists.
    exit /b 1
)
git tag "v%NEXT_VERSION%" || exit /b 1
git push origin HEAD || exit /b 1
git push origin "v%NEXT_VERSION%" || exit /b 1
exit /b 0

:publish_release
echo [release] Creating GitHub release v%NEXT_VERSION%...
gh release create "v%NEXT_VERSION%" ^
    "%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%.exe" ^
    "%RELEASE_DIR%\%APP_NAME%-v%NEXT_VERSION%.zip" ^
    "%SUMS_PATH%" ^
    "%RELEASE_DIR%\install_all_windows.ps1" ^
    "%RELEASE_DIR%\install_all_macos.sh" ^
    "%RELEASE_DIR%\install_all_linux.sh" ^
    --repo "%GITHUB_REPO_SLUG%" ^
    --title "%APP_NAME% v%NEXT_VERSION%" ^
    --notes-file "%NOTES_PATH%" ^
    --latest
if errorlevel 1 exit /b 1
gh release edit "v%NEXT_VERSION%" --repo "%GITHUB_REPO_SLUG%" --draft=false --latest
if errorlevel 1 (
    echo [release] Failed to publish v%NEXT_VERSION% as Latest.
    exit /b 1
)
call :delete_draft_releases || exit /b 1
exit /b 0

:delete_draft_releases
echo [release] Checking for draft releases in %GITHUB_REPO_SLUG%...
REM IMPORTANT: never delete the release we JUST published, even if the
REM GitHub API briefly reports it as draft (we have observed a window
REM right after `gh release create --latest` + `gh release edit
REM --draft=false` where listing still shows draft=true). Excluding the
REM current tag here is the failsafe that prevents the cleanup from
REM eating the freshly published release.
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $repo='%GITHUB_REPO_SLUG%'; $current='v%NEXT_VERSION%'; $drafts = gh release list --repo $repo --limit 100 --json tagName,isDraft | ConvertFrom-Json | Where-Object { $_.isDraft -and $_.tagName -ne $current }; foreach ($draft in $drafts) { Write-Host ('Deleting draft release ' + $draft.tagName + '...'); gh release delete $draft.tagName --repo $repo --yes }"
if errorlevel 1 (
    echo [release] Failed to remove draft releases.
    exit /b 1
)
REM Final guard: confirm v%NEXT_VERSION% is not in draft state. If it is,
REM force it to non-draft + Latest and re-emit the URL so the operator
REM can spot-check it.
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $repo='%GITHUB_REPO_SLUG%'; $current='v%NEXT_VERSION%'; $info = gh release view $current --repo $repo --json isDraft,url | ConvertFrom-Json; if ($info.isDraft) { Write-Host ('Re-publishing draft ' + $current + ' as Latest...'); gh release edit $current --repo $repo --draft=false --latest | Out-Null; $info = gh release view $current --repo $repo --json isDraft,url | ConvertFrom-Json; if ($info.isDraft) { throw ('release ' + $current + ' still marked draft after retry') } }; Write-Host ('Final release URL: ' + $info.url)"
if errorlevel 1 (
    echo [release] Failed to confirm v%NEXT_VERSION% is published as Latest.
    exit /b 1
)
exit /b 0

:usage
echo Usage:
echo   build.bat build
echo   build.bat dry-run
echo   build.bat release
exit /b 1

:error
echo [release] Failed.
popd
exit /b 1
