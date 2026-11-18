#!/bin/bash
# Build the persistent, signed development app. --build-only installs without launching.
set -euo pipefail
cd "$(dirname "$0")"
RETRACE_BUILD_PATH="${RETRACE_BUILD_PATH:-$PWD/.build}"
RETRACE_DEV_APP="/Applications/Retrace Dev.app"
if [[ "${1:-}" != "" && "${1:-}" != "--build-only" ]]; then
    echo 'Usage: ./dev.sh [--build-only]' >&2
    exit 1
fi
RETRACE_DEV_IDENTITY="${RETRACE_DEV_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2; exit }')}"
if [[ -z "$RETRACE_DEV_IDENTITY" ]]; then
    echo 'A certificate-backed development signing identity is required. Set RETRACE_DEV_SIGNING_IDENTITY if needed.' >&2
    exit 1
fi
if lsof -t "$RETRACE_DEV_APP/Contents/MacOS/Retrace Dev" >/dev/null 2>&1; then
    echo 'Quit Retrace Dev before replacing its bundle. Production Retrace can stay open.' >&2
    exit 1
fi
swift build -c debug --disable-sandbox --product Retrace --scratch-path "$RETRACE_BUILD_PATH"
RETRACE_BIN_PATH="$(swift build -c debug --show-bin-path --scratch-path "$RETRACE_BUILD_PATH")"
RETRACE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/retrace-dev.XXXXXX")"
trap 'rm -rf "$RETRACE_STAGE"' EXIT
python3 - "$PWD" "$RETRACE_BIN_PATH" "$RETRACE_STAGE" "$RETRACE_BUILD_PATH" <<'PY'
import pathlib, plistlib, re, shutil, subprocess, sys
root, binaries, stage, build_root = map(pathlib.Path, sys.argv[1:])
contents = stage/'Retrace Dev.app'/'Contents'
(contents/'MacOS').mkdir(parents=True)
(contents/'Resources').mkdir()
(contents/'Frameworks').mkdir()
shutil.copy2(binaries/'Retrace', contents/'MacOS'/'Retrace Dev')
shutil.copytree(binaries/'Retrace_Retrace.bundle', contents/'Resources'/'Retrace_Retrace.bundle')
shutil.copy2(root/'AppIcon.icns', contents/'Resources'/'AppIcon.icns')
framework = next((build_root/'artifacts').rglob('Sparkle.framework'))
shutil.copytree(framework, contents/'Frameworks'/'Sparkle.framework', symlinks=True)
with (root/'UI'/'Info.plist').open('rb') as f: info=plistlib.load(f)
info={k:v for k,v in info.items() if not(isinstance(v,str) and '$(' in v)}
project = (root/'project.yml').read_text()
version = re.search(r'MARKETING_VERSION:\s*"?([^"\s]+)', project).group(1)
build = re.search(r'CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)', project).group(1)
info.update(CFBundleIdentifier='io.retrace.app.dev', CFBundleExecutable='Retrace Dev',
            CFBundleName='Retrace Dev', CFBundleDisplayName='Retrace Dev', CFBundlePackageType='APPL',
            CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleIconFile='AppIcon',
            RetraceIsDevBuild=True, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
            RetraceGitBranch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),
            RetraceGitCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
            CFBundleURLTypes=[{'CFBundleURLName':'io.retrace.app.dev','CFBundleURLSchemes':['retrace-dev']}])
with (contents/'Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
install_name_tool -add_rpath @executable_path/../Frameworks "$RETRACE_STAGE/Retrace Dev.app/Contents/MacOS/Retrace Dev"
codesign --force --deep --sign "$RETRACE_DEV_IDENTITY" "$RETRACE_STAGE/Retrace Dev.app"
codesign --verify --deep --strict "$RETRACE_STAGE/Retrace Dev.app"
# Replace the bundle rather than merging resources left by older build layouts.
python3 - "$RETRACE_STAGE/Retrace Dev.app" "$RETRACE_DEV_APP" <<'INSTALL'
import pathlib, shutil, subprocess, sys, uuid
source, destination = map(pathlib.Path, sys.argv[1:])
previous = destination.with_name('.retrace-dev-previous-' + uuid.uuid4().hex)
if destination.exists(): destination.rename(previous)
try:
    subprocess.run(['ditto', str(source), str(destination)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
except BaseException:
    if destination.exists(): shutil.rmtree(destination)
    if previous.exists(): previous.rename(destination)
    raise
else:
    if previous.exists(): shutil.rmtree(previous)
INSTALL
echo "Installed signed development app: $RETRACE_DEV_APP"
if [[ "${1:-}" != "--build-only" ]]; then
    open "$RETRACE_DEV_APP"
fi
