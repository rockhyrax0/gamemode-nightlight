#!/usr/bin/env bash
#
# install.sh — install gamemode-nightlight and show how to wire it into GameMode.
#
#   ./install.sh              install
#   ./install.sh --uninstall  remove
#
# Deliberately does not edit an existing gamemode.ini for you. It prints the
# block you need; you paste it. Your config, your call.

set -euo pipefail

SCRIPT_NAME="gamemode-nightlight"
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DEST="$BIN_DIR/$SCRIPT_NAME"
GAMEMODE_INI="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"

SB_SERVICE="org.kde.ScreenBrightness"
SB_PATH="/org/kde/ScreenBrightness"

if [ -t 1 ]; then
    B=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RED=$'\e[31m'; N=$'\e[0m'
else
    B='';       DIM='';      GRN='';        YLW='';        RED='';        N=''
fi

ok()      { printf '  %s✓%s %s\n' "$GRN" "$N" "$1"; }
warn()    { printf '  %s!%s %s\n' "$YLW" "$N" "$1"; }
die()     { printf '  %s✗%s %s\n' "$RED" "$N" "$1" >&2; exit 1; }
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Is the per-display brightness service actually on the bus?
sb_up() {
    busctl --user get-property "$SB_SERVICE" "$SB_PATH" "$SB_SERVICE" \
        DisplaysDBusNames >/dev/null 2>&1
}

# --------------------------------------------------------------- uninstall --
if [ "${1:-}" = "--uninstall" ]; then
    section "Uninstalling"
    if [ -e "$DEST" ]; then
        rm -f "$DEST"
        ok "removed $DEST"
    else
        warn "nothing at $DEST"
    fi
    if [ -e "$GAMEMODE_INI" ] && grep -q "$SCRIPT_NAME" "$GAMEMODE_INI" 2>/dev/null; then
        warn "$GAMEMODE_INI still references $SCRIPT_NAME — remove these by hand:"
        grep -n "$SCRIPT_NAME" "$GAMEMODE_INI" | sed 's/^/      /'
    fi
    printf '\n'
    exit 0
fi

if [ -n "${1:-}" ]; then
    die "unknown argument: $1  (use --uninstall, or no arguments to install)"
fi

# ------------------------------------------------------------ sanity checks --
section "Checking dependencies"

[ -e "$SRC_DIR/$SCRIPT_NAME" ] || die "$SCRIPT_NAME not found next to install.sh"

missing=0
for cmd in busctl setsid kde-inhibit awk grep; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd"
    else
        warn "$cmd — not found"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || die "install the missing commands and try again"

if command -v gamemoded >/dev/null 2>&1; then
    ok "gamemoded"
else
    warn "gamemoded not found — install GameMode, or this will never fire"
fi

# The brightness half needs a live Plasma session on the other end of the bus.
if sb_up; then
    ok "$SB_SERVICE is up"
else
    warn "$SB_SERVICE not reachable"
    warn "  needs Plasma 6.2+ and a running session. Installing anyway — the"
    warn "  Night Light half works with or without brightness support."
fi

# ---------------------------------------------------------------- install ---
section "Installing"
install -Dm755 "$SRC_DIR/$SCRIPT_NAME" "$DEST"
ok "$DEST"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your \$PATH — doesn't matter to GameMode, which"
       warn "  uses the absolute path below, but you can't run it by name" ;;
esac

# ----------------------------------------------------------- your displays --
if sb_up; then
    section "Displays PowerDevil can see"
    while read -r d; do
        [ -n "$d" ] || continue
        label=$(busctl --user get-property "$SB_SERVICE" "$SB_PATH/$d" \
                    "$SB_SERVICE.Display" Label 2>/dev/null \
                    | awk -F'"' 'NF>=2{print $2}')
        internal=$(busctl --user get-property "$SB_SERVICE" "$SB_PATH/$d" \
                    "$SB_SERVICE.Display" IsInternal 2>/dev/null | awk '{print $2}')
        if [ "$internal" = "true" ]; then kind="internal"; else kind="external"; fi
        printf '  %-10s %-24s %s%s%s\n' "$d" "${label:-<no label>}" "$DIM" "$kind" "$N"
    done < <(busctl --user get-property "$SB_SERVICE" "$SB_PATH" "$SB_SERVICE" \
                DisplaysDBusNames 2>/dev/null | grep -oP '"[^"]+"' | tr -d '"')
    printf '\n  %sTo dim just one of these, set TARGET_LABEL in the script to a\n' "$DIM"
    printf '  substring of its label. Otherwise every external display is dimmed.%s\n' "$N"
fi

# ------------------------------------------------------------ gamemode.ini --
BLOCK="[custom]
start=$DEST start
end=$DEST end"

section "Wiring it into GameMode"

if [ -e "$GAMEMODE_INI" ] && grep -q "$SCRIPT_NAME" "$GAMEMODE_INI" 2>/dev/null; then
    ok "$GAMEMODE_INI already references $SCRIPT_NAME — nothing to do"
elif [ -e "$GAMEMODE_INI" ]; then
    warn "$GAMEMODE_INI exists. Add these to its [custom] section"
    warn "  (add the two lines to the existing section — don't start a second one):"
    printf '\n%s\n\n' "$BLOCK" | sed 's/^/      /'
elif [ -t 0 ]; then
    printf '  No %s yet. It needs:\n\n' "$GAMEMODE_INI"
    printf '%s\n\n' "$BLOCK" | sed 's/^/      /'
    reply=""
    read -rp "  Write that file now? [y/N] " reply || true
    if [ "${reply,,}" = "y" ]; then
        mkdir -p "$(dirname "$GAMEMODE_INI")"
        printf '%s\n' "$BLOCK" > "$GAMEMODE_INI"
        ok "wrote $GAMEMODE_INI"
        if systemctl --user restart gamemoded 2>/dev/null; then
            ok "restarted gamemoded"
        else
            warn "couldn't restart gamemoded — do it yourself if it doesn't pick up"
        fi
    else
        warn "skipped — create it yourself when you're ready"
    fi
else
    warn "no $GAMEMODE_INI — create it with:"
    printf '\n%s\n\n' "$BLOCK" | sed 's/^/      /'
fi

# --------------------------------------------------------------------- fin --
section "Done"
printf '  Test it:  %s start    %s# Night Light off, display dims%s\n' "$SCRIPT_NAME" "$DIM" "$N"
printf '            %s end      %s# both restored%s\n' "$SCRIPT_NAME" "$DIM" "$N"
printf '\n  Then launch a game with %sgamemoderun %%command%%%s and watch:\n' "$B" "$N"
printf '            journalctl --user -u gamemoded -f\n\n'
