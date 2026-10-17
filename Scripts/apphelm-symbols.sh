#!/bin/sh
# Turn a dSYM into the symbol table Apphelm symbolicates iOS and macOS crashes with, and
# optionally upload it.
#
# Apphelm's server can't read DWARF, so the dSYM stays on this machine. This script reads
# it with Xcode's own tools and writes, for each architecture in it, a small text file:
# the binary's UUID, then one line per function with its offset from the start of the
# image, its size, its name and (with --lines) the file and line it is declared at.
#
#   dwarfdump --uuid   the UUID and architecture of each binary in the dSYM
#   otool -l           where the binary is linked to load (__TEXT vmaddr)
#   nm                 the functions and their addresses
#   swift-demangle     readable Swift names (skipped when it isn't installed)
#   atos               file and line of each function (only with --lines; slower)
#
# Usage:
#   apphelm-symbols.sh <App.dSYM> [--out DIR] [--lines]
#   apphelm-symbols.sh <App.dSYM> --upload --product prd_… --release ios@2.3.0 [--lines]
#
# --upload needs APPHELM_API_KEY (a key with events:write) in the environment, and sends
# to APPHELM_BASE_URL (default https://apphelm.dev). Run it in the build that archives the
# app, for every dSYM in the archive (the app's and each embedded framework's). The key is
# passed to curl in a header file, never on the command line.
#
# For tests, the conversion alone, from saved tool output:
#   apphelm-symbols.sh --convert NM_OUTPUT --uuid UUID --arch ARCH --name NAME --base HEX [--atos-output FILE]
set -eu

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

DSYM="" OUT="." LINES=0 UPLOAD=0 PRODUCT="" RELEASE=""
CONVERT="" UUID="" ARCH="" NAME="" BASE="" ATOS_OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --lines) LINES=1; shift ;;
    --upload) UPLOAD=1; shift ;;
    --product) PRODUCT=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
    --convert) CONVERT=$2; shift 2 ;;
    --uuid) UUID=$2; shift 2 ;;
    --arch) ARCH=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --atos-output) ATOS_OUTPUT=$2; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) DSYM=$1; shift ;;
  esac
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# nm lines ("0000000100003f20 T _main") to "offset size name", sorted by address. Only
# functions (the text section, types t and T) are kept. A function's size is the distance
# to the next one; the last one's is unknown (0). Also writes each function's address to
# $WORK/addresses for atos.
nm_to_table() {
  awk -v base="$2" -v addresses="$WORK/addresses" '
    function hexval(s,  i, c, d, n) { n = 0; s = tolower(s); sub(/^0x/, "", s)
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); d = index("0123456789abcdef", c) - 1; if (d < 0) return -1; n = n * 16 + d }
      return n }
    function tohex(n,  s, d) { if (n == 0) return "0"; s = ""
      while (n > 0) { d = n % 16; s = substr("0123456789abcdef", d + 1, 1) s; n = (n - d) / 16 }
      return s }
    BEGIN { origin = hexval(base); count = 0 }
    $2 == "t" || $2 == "T" {
      address = hexval($1); if (address < origin) next
      name = $0; sub(/^[0-9a-fA-F]+ [A-Za-z] /, "", name)
      # C symbols carry a leading underscore; Swift mangled names start with _$s.
      if (substr(name, 1, 1) == "_") name = substr(name, 2)
      if (name == "") next
      count++; at[count] = address; names[count] = substr(name, 1, 300)
    }
    END {
      for (i = 1; i <= count; i++) {
        size = 0
        for (j = i + 1; j <= count; j++) if (at[j] > at[i]) { size = at[j] - at[i]; break }
        print tohex(at[i] - origin), tohex(size), names[i]
        print "0x" tohex(at[i]) > addresses
      }
    }' "$1"
}

# atos lines ("Shop.CartView.submit() (in Shop) (CartView.swift:41)") to "CartView.swift:41",
# or an empty line when atos found no line for that address.
atos_to_locations() {
  awk '{
    location = ""
    if (substr($0, length($0), 1) == ")") {
      open = 0; for (i = length($0) - 1; i > 0; i--) if (substr($0, i, 1) == "(") { open = i; break }
      if (open > 0) { inside = substr($0, open + 1, length($0) - open - 1)
        if (inside ~ /:[0-9]+$/ && inside !~ /^<compiler-generated>/ && inside !~ /^in / && inside !~ /:0$/) location = inside }
    }
    print location
  }' "$1"
}

# "offset size name" plus one location per line to the final table on stdout.
write_table() {
  printf 'APPHELM-SYMBOLS 1\nuuid %s\narch %s\nname %s\nbase %s\n' "$1" "$2" "$3" "$4"
  if [ -n "$6" ]; then
    paste "$5" "$6" | awk -F '\t' '{ if ($2 == "") print $1; else print $1 "\t" $2 }'
  else
    cat "$5"
  fi
}

# Swift names, readable, when the toolchain has a demangler. The first two columns are
# kept apart so a demangled name (which has spaces) can't be mistaken for them.
demangle() {
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    cut -d ' ' -f 1,2 "$1" > "$WORK/columns"
    cut -d ' ' -f 3- "$1" | xcrun swift-demangle --simplified | cut -c 1-300 > "$WORK/names"
    paste -d ' ' "$WORK/columns" "$WORK/names"
  else
    cat "$1"
  fi
}

# Every byte as %XX: valid in a query whatever the release is called.
urlencode() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'; }

if [ -n "$CONVERT" ]; then
  [ -n "$UUID" ] && [ -n "$ARCH" ] && [ -n "$NAME" ] && [ -n "$BASE" ] || usage
  nm_to_table "$CONVERT" "$BASE" > "$WORK/table"
  LOCATIONS=""
  if [ -n "$ATOS_OUTPUT" ]; then atos_to_locations "$ATOS_OUTPUT" > "$WORK/locations"; LOCATIONS="$WORK/locations"; fi
  write_table "$UUID" "$ARCH" "$NAME" "$BASE" "$WORK/table" "$LOCATIONS"
  exit 0
fi

[ -n "$DSYM" ] || usage
[ -e "$DSYM" ] || { echo "No such dSYM: $DSYM" >&2; exit 1; }
if [ "$UPLOAD" = 1 ]; then
  [ -n "$PRODUCT" ] && [ -n "$RELEASE" ] || { echo "--upload needs --product and --release." >&2; exit 2; }
  [ -n "${APPHELM_API_KEY:-}" ] || { echo "--upload needs APPHELM_API_KEY in the environment." >&2; exit 2; }
fi
mkdir -p "$OUT"

# One line per binary: "UUID: 2F1A… (arm64) /path/App.dSYM/Contents/Resources/DWARF/App".
xcrun dwarfdump --uuid "$DSYM" > "$WORK/uuids"
[ -s "$WORK/uuids" ] || { echo "dwarfdump found no UUID in $DSYM." >&2; exit 1; }

while IFS= read -r entry; do
  uuid=$(printf '%s\n' "$entry" | awk '{ print $2 }')
  arch=$(printf '%s\n' "$entry" | awk '{ gsub(/[()]/, "", $3); print $3 }')
  binary=$(printf '%s\n' "$entry" | sed 's/^UUID: [^ ]* ([^)]*) //')
  name=$(basename "$binary")
  base=$(xcrun otool -arch "$arch" -l "$binary" | awk '$1 == "segname" && $2 == "__TEXT" { text = 1 } text && $1 == "vmaddr" { print $2; exit }')
  [ -n "$base" ] || { echo "No __TEXT segment in $binary ($arch); skipped." >&2; continue; }
  xcrun nm -arch "$arch" --numeric-sort --defined-only "$binary" > "$WORK/nm" 2>/dev/null || true
  nm_to_table "$WORK/nm" "$base" > "$WORK/raw"
  [ -s "$WORK/raw" ] || { echo "No functions found in $binary ($arch); skipped." >&2; continue; }
  demangle "$WORK/raw" > "$WORK/table"
  locations=""
  if [ "$LINES" = 1 ]; then
    xcrun atos -o "$binary" -arch "$arch" -l "$base" -f "$WORK/addresses" > "$WORK/atos" 2>/dev/null || true
    if [ "$(wc -l < "$WORK/atos")" -eq "$(wc -l < "$WORK/table")" ]; then
      atos_to_locations "$WORK/atos" > "$WORK/locations"; locations="$WORK/locations"
    else
      echo "atos did not answer for every function in $name ($arch); written without lines." >&2
    fi
  fi
  file="$OUT/$uuid.apphelm-symbols"
  write_table "$uuid" "$arch" "$name" "$base" "$WORK/table" "$locations" > "$file"
  echo "$file: $name $arch, $(($(wc -l < "$file") - 5)) functions"
  if [ "$UPLOAD" = 1 ]; then
    printf 'authorization: Bearer %s\n' "$APPHELM_API_KEY" > "$WORK/headers"
    curl --fail --silent --show-error -X POST -H @"$WORK/headers" -H 'content-type: text/plain' --data-binary @"$file" \
      "${APPHELM_BASE_URL:-https://apphelm.dev}/api/v1/symbols?productId=$(urlencode "$PRODUCT")&type=apple&release=$(urlencode "$RELEASE")" > /dev/null
    echo "uploaded $uuid for release $RELEASE"
  fi
done < "$WORK/uuids"
