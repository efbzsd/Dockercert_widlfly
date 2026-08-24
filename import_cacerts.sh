#!/usr/bin/env bash
# Java cacerts tanúsítványimport WildFly konténerekbe.
# Hostoldali script: openssl a tanúsítványokhoz, docker cp/restart a konténerhez.
# Az eredeti konténert nem törli és nem cseréli le, csak a cacerts fájlt írja vissza.
# Támogatott bemenet: .cer .crt .pem .der .key, valamint PKCS#7 lánc (.p7b/.p7c).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTIMPORT_DIR="${CERTIMPORT_DIR:-$SCRIPT_DIR/certimport}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/naplo.txt}"
DEFAULT_STOREPASS="changeit"
CACERTS_REL="lib/security/cacerts"

CONTAINER_NAME=""
IMPORTED=()
SKIPPED=()
KS_INDEX=""

log_event() {
  local result="$1"
  local cname="$2"
  local details="$3"
  local ts
  ts="$(date '+%Y.%m.%d %H:%M:%S')"
  printf '%s | %s | %s | %s\n' "$ts" "$cname" "$result" "$details" >> "$LOG_FILE"
}

die() {
  echo "HIBA: $*" >&2
  log_event "HIBA" "${CONTAINER_NAME:--}" "$*"
  exit 1
}

info() { echo "$*"; }

cleanup() {
  rm -f "${KS_INDEX:-}"
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "hiányzó parancs: $1"
}

need_cmd docker
need_cmd openssl
need_cmd date
need_cmd cp

normalize_fp() {
  echo "$1" | tr -d ' \t:' | tr '[:lower:]' '[:upper:]'
}

# Abszolút host-útvonal -> /hostwork/... a keytool konténerben.
# A Backup_* könyvtárnév kettőspontot tartalmaz (óra:perc:másodperc),
# ezért a teljes SCRIPT_DIR-t mountoljuk, nem a backup mappát.
hostwork_path() {
  local abs="$1"
  echo "/hostwork/${abs#"$SCRIPT_DIR"/}"
}

cert_info() {
  local pem="$1"
  openssl x509 -in "$pem" -noout -nameopt RFC2253,utf8 \
    -subject -issuer -dates -serial -fingerprint -sha256 2>/dev/null \
    || openssl x509 -in "$pem" -noout \
      -subject -issuer -dates -serial -fingerprint -sha256 2>/dev/null \
    || die "nem olvasható tanúsítvány: $pem"
}

cert_fingerprint() {
  local pem="$1"
  local raw
  raw="$(openssl x509 -in "$pem" -noout -fingerprint -sha256 2>/dev/null)" \
    || die "ujjlenyomat számítás sikertelen: $pem"
  normalize_fp "${raw#*=}"
}

cert_cn() {
  local pem="$1"
  openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*CN=\([^,]*\).*/\1/p' \
    | head -n1
}

make_alias() {
  local pem="$1"
  local cn fp short
  cn="$(cert_cn "$pem")"
  fp="$(cert_fingerprint "$pem")"
  short="$(echo "$fp" | cut -c1-8 | tr '[:upper:]' '[:lower:]')"
  cn="$(echo "${cn:-cert}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g' | cut -c1-40)"
  echo "${cn}_${short}"
}

container_java_home() {
  local name="$1"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" \
    | sed -n 's/^JAVA_HOME=//p' \
    | tail -n1
}

container_image() {
  docker inspect -f '{{.Config.Image}}' "$1"
}

container_id() {
  docker inspect -f '{{.Id}}' "$1"
}

container_cacerts_path() {
  local name="$1"
  local java_home
  java_home="$(container_java_home "$name")"
  [[ -n "$java_home" ]] || die "JAVA_HOME nem található a(z) $name konténerben"
  echo "${java_home%/}/${CACERTS_REL}"
}

# docker cp a konténerbe root tulajdonnal másol; az eredeti UID/GID/mód kell a JVM usernek.
container_file_meta() {
  local name="$1"
  local path="$2"
  docker exec -u 0 "$name" stat -c '%u %g %a' "$path" 2>/dev/null
}

restore_container_file_meta() {
  local name="$1"
  local path="$2"
  local uid="$3"
  local gid="$4"
  local mode="$5"
  docker exec -u 0 "$name" chown "${uid}:${gid}" "$path" >/dev/null
  docker exec -u 0 "$name" chmod "$mode" "$path" >/dev/null
}

# A keytool az image USER-ével (pl. jboss) futna, a host Backup_* könyvtárába
# pedig a hívó usernek kell írnia. Linuxon + SELinuxon ez Permission denied.
# Host UID + :z relabel: írható bind-mount, a fájl tulajdonosa a hívó marad.
run_keytool() {
  local image="$1"
  shift
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint keytool \
    -v "${SCRIPT_DIR}:/hostwork:z" \
    "$image" \
    "$@"
}

list_running_containers() {
  docker ps --format '{{.Names}}' | sort
}

# naplo.txt utolsó sora a konténerhez: dátum | név | OK|HIBA | ...
last_log_line() {
  local name="$1"
  [[ -f "$LOG_FILE" ]] || return 1
  grep -E "^[0-9.]+ [0-9:]+ \| ${name} \| " "$LOG_FILE" 2>/dev/null | tail -n1
}

format_container_row() {
  local idx="$1"
  local name="$2"
  local line ts result
  line="$(last_log_line "$name" || true)"
  if [[ -z "$line" ]]; then
    printf '  %d) %-12s  utolsó módosítás: %-19s  eredmény: %s\n' \
      "$idx" "$name" "nincs adat" "-"
    return
  fi
  ts="$(echo "$line" | awk -F ' \\| ' '{print $1}')"
  result="$(echo "$line" | awk -F ' \\| ' '{print $3}')"
  printf '  %d) %-12s  utolsó módosítás: %-19s  eredmény: %s\n' \
    "$idx" "$name" "$ts" "$result"
}

select_container() {
  local preset="${1:-}"
  local -a names=()
  local n i choice

  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(list_running_containers)

  ((${#names[@]} > 0)) || die "nincs futó konténer"

  if [[ -n "$preset" ]]; then
    for n in "${names[@]}"; do
      if [[ "$n" == "$preset" ]]; then
        echo "$preset"
        return
      fi
    done
    die "a(z) $preset konténer nem fut"
  fi

  echo "Futó konténerek:" >&2
  for i in "${!names[@]}"; do
    format_container_row "$((i + 1))" "${names[$i]}" >&2
  done

  while true; do
    if ! read -r -p "Válassz konténert [1-${#names[@]}]: " choice; then
      echo "Nincs választás." >&2
      exit 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#names[@]})); then
      echo "${names[$((choice - 1))]}"
      return
    fi
    echo "Érvénytelen választás." >&2
  done
}

file_ext() {
  local base ext
  base="$(basename "$1")"
  ext="${base##*.}"
  echo "$ext" | tr '[:upper:]' '[:lower:]'
}

is_importable_cert() {
  case "$(file_ext "$1")" in
    cer|crt|pem|der|key|p7b|p7c) return 0 ;;
    *) return 1 ;;
  esac
}

has_certificate_block() {
  grep -a -q -- "-----BEGIN CERTIFICATE-----" "$1" 2>/dev/null
}

is_private_key_only() {
  local src="$1"
  grep -a -q -- "PRIVATE KEY-----" "$src" 2>/dev/null || return 1
  has_certificate_block "$src" && return 1
  return 0
}

# PEM/DER X.509, PKCS#7 vagy cert+key csomag -> PEM (egy cert vagy lánc).
convert_to_pem() {
  local src="$1"
  local dest="$2"
  local tmp=""

  rm -f "$dest"

  if has_certificate_block "$src"; then
    cp "$src" "$dest"
    return 0
  fi

  if grep -a -q -- "-----BEGIN PKCS7-----" "$src" 2>/dev/null \
     || grep -a -q -- "-----BEGIN PKCS #7-----" "$src" 2>/dev/null; then
    openssl pkcs7 -in "$src" -print_certs -out "$dest" 2>/dev/null \
      && has_certificate_block "$dest" && return 0
  fi

  if openssl x509 -inform DER -in "$src" -out "$dest" 2>/dev/null; then
    return 0
  fi

  if openssl pkcs7 -inform DER -in "$src" -print_certs -out "$dest" 2>/dev/null; then
    has_certificate_block "$dest" && return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/cerb64.XXXXXX")"
  if base64 -d < "$src" > "$tmp" 2>/dev/null || base64 -D < "$src" > "$tmp" 2>/dev/null; then
    if openssl x509 -inform DER -in "$tmp" -out "$dest" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    if openssl pkcs7 -inform DER -in "$tmp" -print_certs -out "$dest" 2>/dev/null; then
      rm -f "$tmp"
      has_certificate_block "$dest" && return 0
    fi
  fi
  rm -f "$tmp" "$dest"
  return 1
}

split_pem_chain() {
  local pem="$1"
  local outdir="$2"
  local n=0
  local outfile=""
  local line

  mkdir -p "$outdir"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"-----BEGIN CERTIFICATE-----"* ]]; then
      n=$((n + 1))
      outfile="$(printf '%s/part_%02d.pem' "$outdir" "$n")"
      printf '%s\n' "$line" > "$outfile"
    elif [[ -n "$outfile" ]]; then
      printf '%s\n' "$line" >> "$outfile"
      if [[ "$line" == *"-----END CERTIFICATE-----"* ]]; then
        outfile=""
      fi
    fi
  done < "$pem"

  echo "$n"
}

refresh_keystore_index() {
  local image="$1"
  local store_host="$2"
  local pass="$3"
  if [[ -z "$KS_INDEX" ]]; then
    KS_INDEX="$(mktemp "${TMPDIR:-/tmp}/ksindex.XXXXXX")"
  fi
  run_keytool "$image" -list -v -keystore "$(hostwork_path "$store_host")" -storepass "$pass" \
    > "$KS_INDEX" 2>/dev/null
}

find_alias_by_fp() {
  local want_fp="$1"
  local alias=""
  local line fp

  [[ -n "$KS_INDEX" && -f "$KS_INDEX" ]] || return 1

  while IFS= read -r line; do
    if [[ "$line" =~ ^Alias\ name:\ (.*)$ ]]; then
      alias="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ SHA256:\ *(.*)$ ]]; then
      fp="$(normalize_fp "${BASH_REMATCH[1]}")"
      if [[ "$fp" == "$want_fp" ]]; then
        echo "$alias"
        return 0
      fi
    fi
  done < "$KS_INDEX"

  return 1
}

export_alias_pem() {
  local image="$1"
  local store_host="$2"
  local pass="$3"
  local alias="$4"
  local dest_host="$5"

  run_keytool "$image" \
    -exportcert -rfc \
    -keystore "$(hostwork_path "$store_host")" \
    -storepass "$pass" \
    -alias "$alias" \
    -file "$(hostwork_path "$dest_host")" >/dev/null 2>&1
}

ask_overwrite() {
  local ans
  printf 'Felülírható? [Y/n]: ' >&2
  read -r ans || true
  ans="$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "yes" ]]
}

import_one_cert() {
  local workdir="$1"
  local image="$2"
  local store_host="$3"
  local pass="$4"
  local pem="$5"
  local label="$6"
  local fp alias existing_pem

  fp="$(cert_fingerprint "$pem")"
  info ""
  info "=== Import: $label ==="
  info "Importálandó tanúsítvány adatai:"
  cert_info "$pem"

  if alias="$(find_alias_by_fp "$fp")"; then
    existing_pem="$workdir/existing_$(echo "$alias" | sed 's/[^a-z0-9._-]/_/g').pem"
    export_alias_pem "$image" "$store_host" "$pass" "$alias" "$existing_pem"
    info ""
    info "A tanúsítvány már benne van a kulcstárban (alias: $alias)."
    info "Jelenlegi (kulcstárbeli) tanúsítvány adatai:"
    cert_info "$existing_pem"
    info ""
    info "Importálandó tanúsítvány adatai:"
    cert_info "$pem"
    if ! ask_overwrite; then
      info "Kihagyva: $label"
      SKIPPED+=("$label")
      return 0
    fi
    run_keytool "$image" \
      -delete -keystore "$(hostwork_path "$store_host")" -storepass "$pass" -alias "$alias" >/dev/null
    info "Régi bejegyzés törölve: $alias"
    refresh_keystore_index "$image" "$store_host" "$pass"
  fi

  alias="$(make_alias "$pem")"
  if run_keytool "$image" -list -keystore "$(hostwork_path "$store_host")" -storepass "$pass" -alias "$alias" >/dev/null 2>&1; then
    alias="${alias}_new"
  fi

  cp "$pem" "$workdir/import_tmp.pem"
  run_keytool "$image" \
    -importcert -noprompt -trustcacerts \
    -keystore "$(hostwork_path "$store_host")" \
    -storepass "$pass" \
    -alias "$alias" \
    -file "$(hostwork_path "$workdir/import_tmp.pem")"
  rm -f "$workdir/import_tmp.pem"
  refresh_keystore_index "$image" "$store_host" "$pass"
  info "Importálva alias=$alias ($label)"
  IMPORTED+=("$label")
}

process_certimport_file() {
  local workdir="$1"
  local image="$2"
  local store_host="$3"
  local pass="$4"
  local src="$5"
  local base splitdir count i part pemfile

  base="$(basename "$src")"
  splitdir="$workdir/split_${base}"
  pemfile="$workdir/converted_${base}.pem"
  rm -rf "$splitdir"

  if is_private_key_only "$src"; then
    info "Kihagyva (privát kulcs, a cacerts truststore-ba nem kerül): $base"
    SKIPPED+=("$base (privát kulcs)")
    return 0
  fi

  if ! convert_to_pem "$src" "$pemfile"; then
    info "Kihagyva (nem olvasható tanúsítvány): $base"
    SKIPPED+=("$base (olvashatatlan)")
    return 0
  fi
  count="$(split_pem_chain "$pemfile" "$splitdir")"
  ((count > 0)) || { info "Nincs tanúsítvány a fájlban: $base"; SKIPPED+=("$base (üres)"); return 0; }

  if ((count == 1)); then
    info ""
    info "Fájl: $base (egyetlen tanúsítvány)"
  else
    info ""
    info "Fájl: $base (tanúsítványlánc, $count elem)"
  fi

  i=1
  while ((i <= count)); do
    part="$(printf '%s/part_%02d.pem' "$splitdir" "$i")"
    import_one_cert "$workdir" "$image" "$store_host" "$pass" "$part" "$base [$i/$count]"
    i=$((i + 1))
  done
}

finish_ok() {
  local container="$1"
  local imported_txt skipped_txt details
  if ((${#IMPORTED[@]} > 0)); then
    imported_txt="${IMPORTED[*]}"
  else
    imported_txt="nincs"
  fi
  details="importált: $imported_txt"
  if ((${#SKIPPED[@]} > 0)); then
    skipped_txt="${SKIPPED[*]}"
    details="$details; kihagyva: $skipped_txt"
  fi
  log_event "OK" "$container" "$details"
}

main() {
  local preset="${1:-}"
  local container image cacerts_path ts workdir backup_name work_name storepass
  local f cid_before cid_after orig_uid orig_gid orig_mode meta_after

  [[ -d "$CERTIMPORT_DIR" ]] || die "certimport könyvtár nem található: $CERTIMPORT_DIR"

  container="$(select_container "$preset")"
  CONTAINER_NAME="$container"
  image="$(container_image "$container")"
  cacerts_path="$(container_cacerts_path "$container")"
  cid_before="$(container_id "$container")"

  ts="$(date +%Y%m%d_____%H:%M:%S)"
  workdir="$SCRIPT_DIR/Backup_${container}_${ts}"
  mkdir -p "$workdir"

  backup_name="cacert_${container}_backup"
  work_name="${container}_cacert"

  info "Konténer: $container"
  info "Image: $image"
  info "Konténer ID: ${cid_before:0:12} (az eredeti konténer megmarad)"
  info "Cacerts a konténerben: $cacerts_path"
  info "Munkakönyvtár: $workdir"

  docker cp "${container}:${cacerts_path}" "$workdir/$backup_name"
  cp "$workdir/$backup_name" "$workdir/$work_name"
  chmod u+rwx "$workdir" 2>/dev/null || true
  chmod u+rw "$workdir/$backup_name" "$workdir/$work_name" 2>/dev/null || true
  orig_uid=""
  orig_gid=""
  orig_mode=""
  if IFS=' ' read -r orig_uid orig_gid orig_mode < <(container_file_meta "$container" "$cacerts_path"); then
    info "Eredeti cacerts tulajdonos a konténerben: uid=${orig_uid} gid=${orig_gid} mód=${orig_mode}"
  else
    die "az eredeti cacerts tulajdonos nem olvasható a konténerből"
  fi
  info "Kulcstár kimásolva: $backup_name"
  info "Munkapéldány: $work_name"

  read -r -s -p "Kulcstár jelszó [changeit]: " storepass || true
  echo
  storepass="${storepass:-$DEFAULT_STOREPASS}"

  run_keytool "$image" \
    -list -keystore "$(hostwork_path "$workdir/$work_name")" -storepass "$storepass" >/dev/null \
    || die "a kulcstár nem nyitható meg (hibás jelszó?)"
  refresh_keystore_index "$image" "$workdir/$work_name" "$storepass"

  shopt -s nullglob
  local files=("$CERTIMPORT_DIR"/*)
  shopt -u nullglob
  ((${#files[@]} > 0)) || die "üres a certimport könyvtár"

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if ! is_importable_cert "$f"; then
      info "Kihagyva (nem tanúsítványfájl): $(basename "$f")"
      continue
    fi
    process_certimport_file "$workdir" "$image" "$workdir/$work_name" "$storepass" "$f"
  done

  info ""
  info "Visszamásolás a konténerbe..."
  docker cp "$workdir/$work_name" "${container}:${cacerts_path}"
  restore_container_file_meta "$container" "$cacerts_path" "$orig_uid" "$orig_gid" "$orig_mode"
  meta_after="$(container_file_meta "$container" "$cacerts_path" || true)"
  if [[ "$meta_after" != "${orig_uid} ${orig_gid} ${orig_mode}" ]]; then
    die "a cacerts tulajdonos visszaállítása sikertelen (most: ${meta_after:-ismeretlen}, elvárt: ${orig_uid} ${orig_gid} ${orig_mode})"
  fi
  info "Cacerts tulajdonos visszaállítva: uid=${orig_uid} gid=${orig_gid} mód=${orig_mode}"
  info "Konténer újraindítása (az eredeti példány megmarad): $container"
  docker restart "$container" >/dev/null
  cid_after="$(container_id "$container")"
  if [[ "$cid_before" != "$cid_after" ]]; then
    die "a konténer azonosítója megváltozott, az eredeti példány nem maradt meg"
  fi
  info "Kész. Backup: $workdir"
  finish_ok "$container"
}

main "$@"
