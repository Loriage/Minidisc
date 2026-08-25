#!/bin/sh

set -u

usage() {
    cat <<'EOF'
Usage: ./Scripts/doctor.sh [--strict] [--build]

Checks the release-critical project, Swift, privacy, transport, package, and
versioning contracts.

  --strict   Treat warnings as failures.
  --build    Also perform an unsigned generic-iOS Release build in a temporary path.
  -h, --help Show this help.
EOF
}

strict=false
run_build=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --strict) strict=true ;;
        --build) run_build=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
cd "$repository_root" || exit 1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    green=$(printf '\033[32m')
    yellow=$(printf '\033[33m')
    red=$(printf '\033[31m')
    reset=$(printf '\033[0m')
else
    green=
    yellow=
    red=
    reset=
fi

passes=0
warnings=0
failures=0

pass() {
    passes=$((passes + 1))
    printf '%sPASS%s  %s\n' "$green" "$reset" "$*"
}

warn() {
    warnings=$((warnings + 1))
    printf '%sWARN%s  %s\n' "$yellow" "$reset" "$*"
}

problem() {
    failures=$((failures + 1))
    printf '%sFAIL%s  %s\n' "$red" "$reset" "$*"
}

plist_value() {
    file=$1
    key_path=$2
    plutil -extract "$key_path" raw "$file" 2>/dev/null
}

manifest_has_reason() {
    category=$1
    reason=$2
    plutil -convert json -o - "$privacy_manifest" 2>/dev/null \
        | grep -Fq "\"NSPrivacyAccessedAPIType\":\"$category\"" \
        && plutil -convert json -o - "$privacy_manifest" 2>/dev/null \
        | grep -Fq "\"$reason\""
}

app_setting() {
    key=$1
    awk -v requested_key="$key" '
        /buildSettings = \{/ {
            in_settings = 1
            is_app = 0
            value = ""
            next
        }
        in_settings && $0 ~ "^[[:space:]]*" requested_key " = " {
            line = $0
            sub("^[[:space:]]*" requested_key " = ", "", line)
            sub(";[[:space:]]*$", "", line)
            value = line
        }
        in_settings && /PRODUCT_BUNDLE_IDENTIFIER = com\.nohitdev\.minidisc;/ {
            is_app = 1
        }
        in_settings && /^[[:space:]]*};[[:space:]]*$/ {
            if (is_app && value != "") {
                print value
                exit
            }
            in_settings = 0
        }
    ' "$project_file"
}

printf 'Minidisc Doctor\n\n'

for command_name in git plutil xcodebuild; do
    if command -v "$command_name" >/dev/null 2>&1; then
        pass "$command_name is installed"
    else
        problem "$command_name is required"
    fi
done

project='Minidisc.xcodeproj'
scheme='Minidisc'
info_plist='Minidisc/Info.plist'
privacy_manifest='Minidisc/PrivacyInfo.xcprivacy'
package_resolution='Minidisc.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
project_file="$project/project.pbxproj"

if [ -d "$project" ] && [ -f "$project_file" ]; then
    pass 'Xcode project is present'
else
    problem 'Minidisc.xcodeproj is missing or incomplete'
fi

if [ -f "$info_plist" ] && plutil -lint "$info_plist" >/dev/null 2>&1; then
    pass 'Info.plist is valid'
else
    problem 'Info.plist is missing or invalid'
fi

if [ -f "$privacy_manifest" ] && plutil -lint "$privacy_manifest" >/dev/null 2>&1; then
    pass 'Privacy manifest is present and valid'
else
    problem 'PrivacyInfo.xcprivacy is missing or invalid'
fi

if [ -f "$privacy_manifest" ]; then
    tracking=$(plist_value "$privacy_manifest" NSPrivacyTracking || printf missing)
    if [ "$tracking" = false ]; then
        pass 'Privacy manifest declares no tracking'
    else
        problem 'Privacy manifest must explicitly declare tracking as false'
    fi

    if manifest_has_reason NSPrivacyAccessedAPICategoryUserDefaults CA92.1; then
        pass 'UserDefaults required-reason declaration is present'
    else
        problem 'Privacy manifest is missing UserDefaults reason CA92.1'
    fi

    if manifest_has_reason NSPrivacyAccessedAPICategoryFileTimestamp C617.1; then
        pass 'App-container file metadata required-reason declaration is present'
    else
        problem 'Privacy manifest is missing file timestamp reason C617.1'
    fi

    manifest_json=$(plutil -convert json -o - "$privacy_manifest" 2>/dev/null || printf '')
    if printf '%s\n' "$manifest_json" | grep -Fq NSPrivacyCollectedDataTypeProductInteraction \
        && printf '%s\n' "$manifest_json" | grep -Fq NSPrivacyCollectedDataTypeUserID; then
        pass 'Optional ListenBrainz account and listening data are declared'
    else
        problem 'Privacy manifest does not cover the optional ListenBrainz integration'
    fi
fi

if [ -f "$info_plist" ]; then
    arbitrary_loads=$(plist_value "$info_plist" NSAppTransportSecurity.NSAllowsArbitraryLoads || printf missing)
    if [ "$arbitrary_loads" = true ]; then
        pass 'HTTP self-hosted servers remain supported by the documented ATS exception'
    else
        warn 'Global ATS exception changed; verify support for user-configured HTTP servers'
    fi
fi

if [ -f "$package_resolution" ]; then
    pass 'Swift package resolution is committed'
else
    problem 'Swift package resolution is missing'
fi

if grep -Eq 'SWIFT_VERSION = 6\.0;' "$project_file" \
    && grep -Eq 'SWIFT_STRICT_CONCURRENCY = complete;' "$project_file" \
    && grep -Eq 'SWIFT_APPROACHABLE_CONCURRENCY = YES;' "$project_file"; then
    pass 'Swift 6 strict concurrency settings are present'
else
    problem 'Swift 6 strict concurrency settings are incomplete'
fi

marketing_version=$(app_setting MARKETING_VERSION)
build_number=$(app_setting CURRENT_PROJECT_VERSION)
swift_version=$(app_setting SWIFT_VERSION)

if printf '%s\n' "$marketing_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    && printf '%s\n' "$build_number" | grep -Eq '^[1-9][0-9]*$'; then
    pass "Release version is $marketing_version ($build_number)"
else
    problem 'Release marketing version or build number is invalid'
fi

if [ "$swift_version" = 6.0 ]; then
    pass 'Effective Release Swift version is 6.0'
else
    problem "Effective Release Swift version is ${swift_version:-missing}"
fi

if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    warn 'Worktree has uncommitted changes; review them before release'
else
    pass 'Worktree is clean'
fi

if [ "$run_build" = true ]; then
    doctor_temp=$(mktemp -d "${TMPDIR:-/tmp}/minidisc-doctor.XXXXXX") || exit 1
    build_log="$doctor_temp/build.log"
    if xcodebuild \
        -project "$project" \
        -scheme "$scheme" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$doctor_temp/DerivedData" \
        CODE_SIGNING_ALLOWED=NO \
        build >"$build_log" 2>&1; then
        pass 'Unsigned generic-iOS Release build succeeds'
    else
        problem 'Unsigned generic-iOS Release build failed (last 40 lines follow)'
        tail -n 40 "$build_log"
    fi
    rm -rf "$doctor_temp"
fi

printf '\n%d passed, %d warnings, %d failures.\n' "$passes" "$warnings" "$failures"

if [ "$failures" -gt 0 ]; then
    exit 1
fi
if [ "$strict" = true ] && [ "$warnings" -gt 0 ]; then
    exit 2
fi
exit 0
