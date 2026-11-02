#!/usr/bin/env bash
# Resolve an existing identity. Never create certificates or silently fall back.
: "${CODE_SIGN_IDENTITY:=Moa Local Development Code Signing}"

resolve_signing_identity() {
    SIGNING_FINGERPRINT="-"
    SIGNING_TIMESTAMP="--timestamp=none"
    [[ "$CODE_SIGN_IDENTITY" == "-" ]] && return 0
    local fingerprint name count=0
    while read -r fingerprint name; do
        if [[ "$name" == "$CODE_SIGN_IDENTITY" || "$fingerprint" == "$CODE_SIGN_IDENTITY" ]]; then
            count=$((count + 1))
            SIGNING_FINGERPRINT="$fingerprint"
            [[ "$name" == "Developer ID Application: "* ]] && SIGNING_TIMESTAMP="--timestamp"
        fi
    done < <(/usr/bin/security find-identity -v -p codesigning |
        sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "(.*)"$/\1 \2/p')
    if [[ "$count" != 1 ]]; then
        echo "Expected exactly one signing identity: $CODE_SIGN_IDENTITY (found $count)." >&2
        echo "Restore the existing certificate, or explicitly set CODE_SIGN_IDENTITY=- for an ad-hoc build." >&2
        return 1
    fi
}

sign_artifact() {
    /usr/bin/codesign --force "$SIGNING_TIMESTAMP" --options runtime --sign "$SIGNING_FINGERPRINT" "$1"
}
