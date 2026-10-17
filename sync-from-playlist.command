#!/bin/bash
# ============================================================
# YouTubeSync v14 — ScafNet
# NOVITA' rispetto alla v13: INTERFACCIA "APP" PER MAX.
#  - Max vede: versione, barra di avanzamento, playlist in corso,
#    contatore brani nuovi; a fine sync una tabella pulita
#    (YouTube vs Mac) con ✓/⚠, totali ed eventuali non scaricati.
#  - Tutto l'output tecnico di yt-dlp e' nascosto e finisce SOLO
#    nel log completo inviato a Stefano (Google Sheet), inclusi i
#    titoli dei brani falliti.
#  - Resta: AUTO-AGGIORNANTE da GitHub, classificazione falliti
#    (morti/signin/403/429), _RIMOSSI unica, riallineamento
#    archivio, fix grep "--", config locale.
# ============================================================

APP_VERSION="v14"
GHRAW="https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/sync-from-playlist.command"

export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"
CONFIG_FILE="$SELF_DIR/config.sh"

# --- AUTO-UPDATE DA GITHUB (silenzioso) ---
if [ -z "$YTS_SELFUPDATE_DONE" ] && printf '%s' "$GHRAW" | grep -q "^https"; then
  NEW="$(mktemp)"
  if curl -fsSL "$GHRAW" -o "$NEW" 2>/dev/null \
     && [ -s "$NEW" ] \
     && grep -q "YouTubeSync v" "$NEW" \
     && bash -n "$NEW" 2>/dev/null; then
    if ! cmp -s "$NEW" "$SELF_PATH"; then
      cp "$NEW" "$SELF_PATH" && chmod +x "$SELF_PATH"
      rm -f "$NEW"; export YTS_SELFUPDATE_DONE=1; exec "$SELF_PATH"
    fi
  fi
  rm -f "$NEW"
fi

# --- CONFIG LOCALE (ENDPOINT_URL) ---
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${ENDPOINT_URL:=}"

# --- CONFIG ---
DEST_FOLDER="$HOME/Music/Youtube"
ARCHIVE_FILE="$DEST_FOLDER/archive_global.txt"
LOG_FILE="$DEST_FOLDER/youtube_sync.log"
PLAYLIST_CACHE="$DEST_FOLDER/playlist_cache.txt"
PLAYLIST_LOCAL="$HOME/Desktop/playlist.txt"
REMOVED_DIRNAME="_RIMOSSI"
REMOVED_FOLDER="$DEST_FOLDER/$REMOVED_DIRNAME"

YT_NET_OPTS=(--retries 5 --fragment-retries 5 --extractor-retries 3)
YT_META_OPTS=(--retries 5 --extractor-retries 3)

# --- STATO ---
ANY_NEW=false; ANY_REMOVED=false; ANY_RESTORED=false
VALID_PLAYLISTS=0; SKIPPED_LINES=0; UNREACHABLE=0
TOTAL_REMOVED=0; TOTAL_RESTORED=0; TOTAL_DLERR=0; TOTAL_NEW=0
DEAD=0; BOT=0; E403=0; E429=0
START_TIME=$(date +%s)

mkdir -p "$DEST_FOLDER"
RUN_LOG=$(mktemp)      # log tecnico completo -> Stefano
RPT=$(mktemp)          # righe tabella finale -> Max

# log tecnico: SOLO su file (non a schermo). A schermo parla la UI.
log() {
  local line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >> "$RUN_LOG"
}

extract_id_from_filename() {
  local name="$1"
  if [[ "$name" =~ \[([A-Za-z0-9_-]{11})\]\.mp3$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# ---------- INTERFACCIA ----------
UI_LINE='   ──────────────────────────────────────────'
draw_header() {
  printf '\033[2J\033[H\n'
  printf '   ════════════════════════════════════════════\n'
  printf '      🎵  YouTubeSync      %s\n' "$APP_VERSION"
  printf '   ════════════════════════════════════════════\n\n'
}
draw_progress() {
  # $1 idx  $2 total  $3 nome playlist  $4 nuovi finora
  local idx=$1 total=$2 name=$3 newc=$4
  local bl=26 f=0 i=0 bar=""
  [ "$total" -gt 0 ] && f=$(( idx * bl / total ))
  [ "$f" -gt "$bl" ] && f=$bl
  while [ $i -lt $f ];  do bar="$bar█"; i=$((i+1)); done
  while [ $i -lt $bl ]; do bar="$bar░"; i=$((i+1)); done
  draw_header
  printf '      Sincronizzazione in corso…\n\n'
  printf '      [%s]   %d / %d\n\n' "$bar" "$idx" "$total"
  printf '      ▶  %s\n\n' "$name"
  printf '      Brani nuovi scaricati finora:  %d\n' "$newc"
  printf '\n\n      (puoi lasciare la finestra aperta, ci penso io)\n'
}

draw_header
printf '      Avvio in corso…\n'

osascript -e 'display notification "Sincronizzazione avviata" with title "YouTubeSync"' 2>/dev/null
log "inizio sincronizzazione ($APP_VERSION)"

# --- CHECK DIPENDENZE ---
missing=""
command -v yt-dlp  >/dev/null 2>&1 || missing="yt-dlp"
command -v ffmpeg  >/dev/null 2>&1 || missing="${missing:+$missing, }ffmpeg"
if [ -n "$missing" ]; then
  draw_header
  printf '      ⚠  Manca un componente (%s).\n\n      Chiama Stefano.\n\n' "$missing"
  osascript -e 'display notification "Manca un componente. Chiama Stefano." with title "YouTubeSync"' 2>/dev/null
  log "ERRORE componente mancante: $missing"
  exit 1
fi
command -v deno >/dev/null 2>&1 || log "AVVISO deno non trovato — alcuni video potrebbero fallire (JS challenge)"

# --- RIALLINEAMENTO ARCHIVIO DAI FILE GIA' PRESENTI ---
touch "$ARCHIVE_FILE"
EXIST_IDS=$(mktemp); ARCH_IDS=$(mktemp)
find "$DEST_FOLDER" -type f -name "*].mp3" ! -path "$REMOVED_FOLDER/*" 2>/dev/null \
  | grep -oE '\[[A-Za-z0-9_-]{11}\]\.mp3$' | sed -E 's/^\[//; s/\]\.mp3$//' | sort -u > "$EXIST_IDS"
awk '/^youtube /{print $2}' "$ARCHIVE_FILE" | sort -u > "$ARCH_IDS"
added=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! grep -qx -- "$id" "$ARCH_IDS"; then
    echo "youtube $id" >> "$ARCHIVE_FILE"; added=$((added + 1))
  fi
done < "$EXIST_IDS"
rm -f "$EXIST_IDS" "$ARCH_IDS"
[ "$added" -gt 0 ] && log "archivio riallineato: +$added id dai file esistenti"

# --- LISTA PLAYLIST (web -> cache -> locale) ---
PLAYLIST_FILE=""
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  if curl -fsSL "$ENDPOINT_URL" -o "${PLAYLIST_CACHE}.new" 2>/dev/null && [ -s "${PLAYLIST_CACHE}.new" ]; then
    mv "${PLAYLIST_CACHE}.new" "$PLAYLIST_CACHE"; PLAYLIST_FILE="$PLAYLIST_CACHE"
    log "lista playlist aggiornata da internet"
  else
    rm -f "${PLAYLIST_CACHE}.new"
    [ -s "$PLAYLIST_CACHE" ] && { PLAYLIST_FILE="$PLAYLIST_CACHE"; log "AVVISO internet assente: uso lista in cache"; }
  fi
fi
[ -z "$PLAYLIST_FILE" ] && [ -s "$PLAYLIST_LOCAL" ] && { PLAYLIST_FILE="$PLAYLIST_LOCAL"; log "AVVISO uso playlist.txt locale"; }
if [ -z "$PLAYLIST_FILE" ]; then
  draw_header
  printf '      ⚠  Non trovo la lista delle playlist.\n\n      Chiama Stefano.\n\n'
  osascript -e 'display notification "Non trovo la lista playlist. Chiama Stefano." with title "YouTubeSync"' 2>/dev/null
  log "ERRORE nessuna lista playlist disponibile."
  [ -n "$ENDPOINT_URL" ] && curl -fsS -X POST "$ENDPOINT_URL" --data-urlencode "summary=ERRORE: nessuna lista playlist" --data-urlencode "detail@$RUN_LOG" >/dev/null 2>&1
  rm -f "$RUN_LOG" "$RPT"; exit 1
fi

TOTAL_PL=$(grep -cE 'list=' "$PLAYLIST_FILE"); [ "$TOTAL_PL" -eq 0 ] && TOTAL_PL=1
idx=0

# --- LOOP PLAYLIST ---
while IFS= read -r raw_line; do

  listid=$(printf '%s' "$raw_line" | grep -oE 'list=[A-Za-z0-9_-]+' | head -n1 | cut -d= -f2)
  if [ -z "$listid" ]; then SKIPPED_LINES=$((SKIPPED_LINES + 1)); continue; fi
  idx=$((idx + 1))

  playlist_url="https://www.youtube.com/playlist?list=$listid"

  draw_progress "$idx" "$TOTAL_PL" "collegamento a YouTube…" "$TOTAL_NEW"

  folder_name=$(yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --playlist-items 1 --print "%(playlist_title)s" "$playlist_url" 2>/dev/null | head -n 1)
  if [ -z "$folder_name" ]; then
    log "playlist non raggiungibile: $playlist_url"
    UNREACHABLE=$((UNREACHABLE + 1))
    printf 'UNREACH\t%s\t-\t-\t0\n' "playlist #$idx (non raggiungibile)" >> "$RPT"
    continue
  fi

  VALID_PLAYLISTS=$((VALID_PLAYLISTS + 1))
  playlist_folder="$DEST_FOLDER/$folder_name"
  mkdir -p "$playlist_folder"
  draw_progress "$idx" "$TOTAL_PL" "$folder_name" "$TOTAL_NEW"
  log "sync: $folder_name"

  # FASE 0 — RIPRISTINO da _RIMOSSI
  if [ -d "$REMOVED_FOLDER" ]; then
    CUR0=$(mktemp)
    yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR0"
    if [ -s "$CUR0" ]; then
      for file in "$REMOVED_FOLDER"/*.mp3; do
        [ ! -e "$file" ] && continue
        base=$(basename "$file"); fid=$(extract_id_from_filename "$base"); [ -z "$fid" ] && continue
        if grep -Fxq -- "$fid" "$CUR0" && [ ! -e "$playlist_folder/$base" ]; then
          mv "$file" "$playlist_folder/"; echo "youtube $fid" >> "$ARCHIVE_FILE"
          log "   ripristinato da _RIMOSSI: $base -> $folder_name"
          TOTAL_RESTORED=$((TOTAL_RESTORED + 1)); ANY_RESTORED=true
        fi
      done
    fi
    rm -f "$CUR0"
  fi

  # FASE 1 — DOWNLOAD (silenzioso; errori -> ERRLOG, classificati)
  cd "$playlist_folder" || continue
  before=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  ERRLOG=$(mktemp)
  yt-dlp \
    --quiet --no-warnings --yes-playlist --ignore-errors --no-overwrites \
    "${YT_NET_OPTS[@]}" \
    --extract-audio --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail --add-metadata \
    --download-archive "$ARCHIVE_FILE" \
    --output "%(title)s [%(id)s].%(ext)s" \
    "$playlist_url" >>"$RUN_LOG" 2>"$ERRLOG"
  dlerr=$(grep -c '^ERROR:' "$ERRLOG" 2>/dev/null)
  if [ "${dlerr:-0}" -gt 0 ]; then
    d_dead=$(grep -ciE '^ERROR:.*(unavailable|private|removed|terminated|copyright|not available|no longer)' "$ERRLOG")
    d_bot=$(grep -ciE '^ERROR:.*(sign in to confirm|not a bot|confirm you)' "$ERRLOG")
    d_403=$(grep -ciE '^ERROR:.*(403|forbidden)' "$ERRLOG")
    d_429=$(grep -ciE '^ERROR:.*(429|too many requests)' "$ERRLOG")
    DEAD=$((DEAD + d_dead)); BOT=$((BOT + d_bot)); E403=$((E403 + d_403)); E429=$((E429 + d_429))
    TOTAL_DLERR=$((TOTAL_DLERR + dlerr))
    log "   $dlerr non scaricabili in \"$folder_name\" (morti:$d_dead signin:$d_bot 403:$d_403 429:$d_429)"
    grep '^ERROR:' "$ERRLOG" | head -n 25 | sed 's/^/     /' >> "$RUN_LOG"
  fi
  rm -f "$ERRLOG"
  after=$(ls -1 *.mp3 2>/dev/null | wc -l | tr -d ' ')
  new=$((after - before)); [ "$new" -lt 0 ] && new=0
  if [ "$new" -gt 0 ]; then ANY_NEW=true; TOTAL_NEW=$((TOTAL_NEW + new)); log "nuovi in \"$folder_name\": $new"; fi
  draw_progress "$idx" "$TOTAL_PL" "$folder_name" "$TOTAL_NEW"

  # FASE 2 — RIMOZIONI -> _RIMOSSI
  CUR=$(mktemp)
  yt-dlp "${YT_META_OPTS[@]}" --flat-playlist --print "%(id)s" "$playlist_url" 2>/dev/null > "$CUR"
  yt_count=$(grep -cvE '^\s*$' "$CUR")
  if [ "$yt_count" -eq 0 ]; then
    log "AVVISO lettura \"$folder_name\" a 0 brani: rimozioni SALTATE."
    rm -f "$CUR"
    yt_count="?"
  else
    for file in *.mp3; do
      [ ! -e "$file" ] && continue
      fid=$(extract_id_from_filename "$file")
      if [ -z "$fid" ]; then log "   senza ID, ignorato: $file"; continue; fi
      if ! grep -Fxq -- "$fid" "$CUR"; then
        mkdir -p "$REMOVED_FOLDER"; mv -f "$file" "$REMOVED_FOLDER/"
        if [ -f "$ARCHIVE_FILE" ]; then
          grep -vxF -- "youtube $fid" "$ARCHIVE_FILE" > "${ARCHIVE_FILE}.tmp" 2>/dev/null && mv "${ARCHIVE_FILE}.tmp" "$ARCHIVE_FILE"
        fi
        log "   rimosso da \"$folder_name\" -> _RIMOSSI: $file"
        TOTAL_REMOVED=$((TOTAL_REMOVED + 1)); ANY_REMOVED=true
      fi
    done
    rm -f "$CUR"
  fi

  # riga per la tabella finale
  mac_count=$(ls -1 "$playlist_folder"/*.mp3 2>/dev/null | wc -l | tr -d ' ')
  status="OK"
  if [ "$yt_count" != "?" ] && [ "$mac_count" -lt "$yt_count" ]; then status="WARN"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$folder_name" "$yt_count" "$mac_count" "$new" >> "$RPT"

done < <(grep -vE '^\s*$|^\s*#' "$PLAYLIST_FILE")

# --- TEMPO / SUMMARY TECNICO ---
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME))
DMIN=$((DURATION / 60)); DSEC=$((DURATION % 60))
OTHER=$((TOTAL_DLERR - DEAD - BOT - E403 - E429)); [ "$OTHER" -lt 0 ] && OTHER=0
SUMMARY="Sync $APP_VERSION — playlist:$VALID_PLAYLISTS, nuovi_tot:$TOTAL_NEW, rimossi:$TOTAL_REMOVED, ripristinati:$TOTAL_RESTORED, video_falliti:$TOTAL_DLERR [morti:$DEAD signin:$BOT 403:$E403 429:$E429 altro:$OTHER], righe_saltate:$SKIPPED_LINES, non_raggiungibili:$UNREACHABLE (${DMIN}m${DSEC}s)"
[ "$UNREACHABLE" -gt 0 ] && SUMMARY="ATTENZIONE $SUMMARY"
log "durata: ${DMIN}m ${DSEC}s"
log "fine — $SUMMARY"

# tabella anche nel log tecnico (per Stefano)
{
  echo "---- RIEPILOGO PLAYLIST (YouTube / Mac / nuovi) ----"
  awk -F'\t' '{printf "  [%-6s] %-28s yt:%-4s mac:%-4s nuovi:%s\n",$1,$2,$3,$4,$5}' "$RPT"
  echo "----------------------------------------------------"
} >> "$RUN_LOG"
echo "----------------------------------------" >> "$LOG_FILE"

# --- INVIO LOG COMPLETO A STEFANO ---
if printf '%s' "$ENDPOINT_URL" | grep -q "^https"; then
  curl -fsS -X POST "$ENDPOINT_URL" \
    --data-urlencode "summary=$SUMMARY" \
    --data-urlencode "detail@$RUN_LOG" >/dev/null 2>&1 \
    && log "stato inviato a Stefano" || log "AVVISO invio stato non riuscito"
fi

# ---------- SCHERMATA FINALE PER MAX ----------
draw_header
if [ "$TOTAL_DLERR" -gt 0 ] || [ "$UNREACHABLE" -gt 0 ]; then
  printf '      ✅  Fatto   (con qualche avviso)\n\n'
else
  printf '      ✅  Tutto sincronizzato!\n\n'
fi
printf '      %-28s %6s %6s\n' "Playlist" "YouTube" "Mac"
printf '%s\n' "$UI_LINE"
awk -F'\t' '{
  name=$2; if (length(name)>26) name=substr(name,1,25) "…";
  mark=($1=="OK")?"✓":(($1=="UNREACH")?"—":"⚠");
  printf "      %-28s %6s %6s  %s\n", name, $3, $4, mark
}' "$RPT"
printf '%s\n\n' "$UI_LINE"
printf '      Brani nuovi scaricati:  %d\n' "$TOTAL_NEW"
if [ "$TOTAL_DLERR" -gt 0 ]; then
  printf '      Brani non scaricati:    %d  ⚠\n\n' "$TOTAL_DLERR"
  printf '      I "non scaricati" di solito sono blocchi\n'
  printf '      temporanei di YouTube: si risolvono da soli\n'
  printf '      al prossimo avvio. Se restano, avvisa Stefano.\n'
else
  printf '\n      Nessun brano mancante. 👍\n'
fi
if [ "$UNREACHABLE" -gt 0 ]; then
  printf '\n      ⚠  %d playlist non raggiungibili (— in tabella).\n' "$UNREACHABLE"
fi
printf '\n\n      Puoi chiudere questa finestra.  👋\n\n'

# notifica di sistema
if [ "$VALID_PLAYLISTS" -eq 0 ]; then
  osascript -e 'display notification "Nessuna musica aggiornata. Se non e giusto, chiama Stefano." with title "YouTubeSync"' 2>/dev/null
else
  msg="Fatto! Musica aggiornata."
  [ "$ANY_NEW" = true ] && msg="$msg $TOTAL_NEW brani nuovi."
  osascript -e "display notification \"$msg\" with title \"YouTubeSync\" sound name \"Glass\"" 2>/dev/null
fi

rm -f "$RUN_LOG" "$RPT"
