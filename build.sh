#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
mode=release
test_mode=none
selftest=0
leaks_check=0
dmg=0
for argument in "$@"; do
  case "$argument" in
    --release) mode=release ;;
    --dev) mode=debug ;;
    --test) test_mode=plain ;;
    --asan) test_mode=address ;;
    --tsan) test_mode=thread ;;
    --selftest) selftest=1 ;;
    --leaks) leaks_check=1 ;;
    --dmg) dmg=1 ;;
    --help) echo 'Usage: ./build.sh [--release|--dev] [--test|--asan|--tsan] [--selftest] [--leaks] [--dmg]'; exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 64 ;;
  esac
done
# Separate sanitizer builds to avoid accidentally packaging instrumented executables.
swift_args=(--disable-sandbox --cache-path "$PWD/.build/cache")
developer_dir=$(xcode-select -p)
clt_frameworks="$developer_dir/Library/Developer/Frameworks"
clt_testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Swift 6.4 CLT ships Testing outside the native backend's default search paths.
# The default backend currently misses its macro plugin; use native only on CLT.
if [[ "$developer_dir" == */CommandLineTools ]]; then swift_args+=(--build-system native); fi
if [[ "$test_mode" != none ]]; then
  test_args=(--scratch-path "$PWD/.build/tests-$test_mode" --disable-xctest --enable-swift-testing)
  if [[ "$developer_dir" == */CommandLineTools && -f "$clt_testing_plugin" ]]; then
    test_args+=(-Xswiftc -F -Xswiftc "$clt_frameworks"
      -Xswiftc -load-plugin-library -Xswiftc "$clt_testing_plugin"
      -Xlinker -rpath -Xlinker "$clt_frameworks")
  fi
  if [[ "$test_mode" != plain ]]; then test_args+=(--sanitize="$test_mode"); fi
  swift test "${swift_args[@]}" "${test_args[@]}"
  if [[ "$selftest" == 0 && "$leaks_check" == 0 && "$dmg" == 0 ]]; then exit 0; fi
fi
swift build "${swift_args[@]}" --configuration "$mode" --product hutchbar
binary_dir=$(swift build "${swift_args[@]}" --configuration "$mode" --show-bin-path)
name=Hutchbar
identifier=io.github.code-oclock.hutchbar
if [[ "$mode" == debug ]]; then name='Hutchbar Dev'; identifier+=.dev; fi
app="build/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/hutchbar" "$app/Contents/MacOS/hutchbar"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $identifier" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleName $name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleDisplayName $name" "$app/Contents/Info.plist"
identity=${HUTCHBAR_SIGN_IDENTITY:--}
sign_args=(--force --sign "$identity" --options runtime --entitlements Resources/hutchbar.entitlements)
# Only Developer ID distribution needs Apple's online secure timestamp service.
# Local self-signed certificates, like ad-hoc builds, also work offline.
if [[ "$identity" == 'Developer ID Application: '* ]]; then
  sign_args+=(--timestamp)
else
  sign_args+=(--timestamp=none)
fi
codesign "${sign_args[@]}" "$app"
./Tools/verify-app.sh "$app"
if [[ "$selftest" == 1 ]]; then "$app/Contents/MacOS/hutchbar" --selftest; fi
if [[ "$leaks_check" == 1 ]]; then
  work=$(mktemp -d)
  # task_for_pid is denied for a hardened process without get-task-allow, even
  # with ad-hoc signing. Temporarily enable debugging; restore the signed bundle
  # on success/failure so diagnostics can never be packaged as a release.
  ditto "$app" "$work/original.app"
  restore_bundle() {
    rm -rf "$app"
    ditto "$work/original.app" "$app"
    rm -rf "$work"
  }
  trap restore_bundle EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cat > "$work/diagnostic.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
  codesign --force --sign - --options runtime --timestamp=none --entitlements "$work/diagnostic.plist" "$app"
  codesign --verify --strict "$app"
  # A regular report file avoids hanging on an inherited pipe when task_for_pid
  # is denied and the target still holds stdout open. Bound the analyzer runtime.
  python3 - "$app/Contents/MacOS/hutchbar" "$work/report" <<'PYTHON'
import os, pathlib, re, subprocess, sys
report = pathlib.Path(sys.argv[2])
try:
    with report.open('w') as output:
        result = subprocess.run(
            ['leaks', '--atExit', '--', sys.argv[1], '--selftest'],
            stdout=output, stderr=subprocess.STDOUT, timeout=45,
            env={**os.environ, 'MallocStackLogging': '1'},
        )
except subprocess.TimeoutExpired:
    print(report.read_text(errors='replace'))
    raise SystemExit('Leak analysis timed out after 45 seconds.')
text = report.read_text(errors='replace')
print(text, end='')
summaries = re.findall(r'(\d+) leaks for (\d+) total leaked bytes', text)
if result.returncode != 0 or not summaries or any(int(count) or int(size) for count, size in summaries):
    raise SystemExit('Leak analysis failed or detected leaks.')
PYTHON
  restore_bundle
  trap - EXIT INT TERM
  ./Tools/verify-app.sh "$app"
fi
if [[ "$dmg" == 1 ]]; then ./Tools/make-dmg.sh "$app"; fi
printf 'Built %s\n' "$app"
