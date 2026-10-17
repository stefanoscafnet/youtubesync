#!/bin/bash
# ============================================================
# YouTubeSync Gestisci playlist v2 — ScafNet
# v2: corretti i nomi tra « » (bash del Mac) e la lettura della risposta del foglio.
# Per Max: aggiungere, togliere e vedere le playlist sincronizzate,
# con le finestre normali del Mac. Le modifiche vanno nel foglio
# Google di Stefano (che le vede anche nel foglio Log).
# Questo file viene installato e aggiornato da solo dallo script
# di sincronizzazione: non va modificato sul Mac.
# ============================================================

export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SELF_DIR/config.sh"
SYNC_SCRIPT="$SELF_DIR/sync-from-playlist.command"
DEST_FOLDER="$HOME/Music/Youtube"
TITLE="YouTubeSync"
NO="__ANNULLA__"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${ENDPOINT_URL:=}"

# chiude la finestra del Terminale che si apre con il doppio clic
close_terminal() {
  osascript -e 'tell application "Terminal" to close (every window whose name contains "Gestisci playlist")' >/dev/null 2>&1 &
}

# ---------- finestre del Mac ----------
ask_text() {   # $1 messaggio  $2 testo proposto
  osascript - "$1" "$2" "$TITLE" <<'EOF' 2>/dev/null
on run argv
  activate
  try
    set r to display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"Annulla", "Avanti"} default button "Avanti" cancel button "Annulla"
    return text returned of r
  on error number -128
    return "__ANNULLA__"
  end try
end run
EOF
}
ask_buttons() {   # $1 messaggio, poi i pulsanti (max 3); l'ultimo argomento e' quello predefinito
  osascript - "$TITLE" "$@" <<'EOF' 2>/dev/null
on run argv
  activate
  set t to item 1 of argv
  set p to item 2 of argv
  set btns to items 3 thru -2 of argv
  set d to item -1 of argv
  try
    set r to display dialog p with title t buttons btns default button d
    return button returned of r
  on error number -128
    return "__ANNULLA__"
  end try
end run
EOF
}
choose_one() {   # $1 messaggio, poi le voci
  osascript - "$TITLE" "$@" <<'EOF' 2>/dev/null
on run argv
  activate
  set t to item 1 of argv
  set p to item 2 of argv
  set L to items 3 thru -1 of argv
  set r to choose from list L with title t with prompt p OK button name "Scegli" cancel button name "Chiudi"
  if r is false then return "__ANNULLA__"
  return item 1 of r
end run
EOF
}
info() { ask_buttons "$1" "OK" "OK" >/dev/null; }
notify() { osascript -e "display notification \"$1\" with title \"$TITLE\"" >/dev/null 2>&1; }

# ---------- foglio di Stefano ----------
LIST_FILE="$(mktemp)"
trap 'rm -f "$LIST_FILE"' EXIT
load_list() {   # righe: id <TAB> nome <TAB> link
  curl -fsSL --max-time 30 "${ENDPOINT_URL}?action=list" -o "$LIST_FILE" 2>/dev/null || return 1
  grep -q $'\t' "$LIST_FILE" || [ ! -s "$LIST_FILE" ]
}
name_of() { awk -F'\t' -v id="$1" '$1==id { print ($2!="" ? $2 : $1); exit }' "$LIST_FILE"; }
# niente -X POST: con --data curl fa POST e, sul reindirizzamento di Google, prosegue in GET
# e legge la risposta vera ("OK", "GIA_PRESENTE", ...)
post() { curl -fsSL --max-time 30 "$ENDPOINT_URL" "$@" 2>/dev/null; }

# ---------- controlli iniziali ----------
if ! printf '%s' "$ENDPOINT_URL" | grep -q '^https'; then
  info "Manca la configurazione. Chiama Stefano."; close_terminal; exit 1
fi
ver=$(curl -fsSL --max-time 30 "${ENDPOINT_URL}?action=version" 2>/dev/null | head -n1)
if [ -z "$ver" ]; then
  info "Non riesco a collegarmi. Controlla la connessione a internet e riprova."; close_terminal; exit 1
fi
if [ "$ver" != "YTS-GAS v3" ]; then
  info "Questa funzione non e' ancora attiva. Chiama Stefano."; close_terminal; exit 1
fi

# ---------- azioni ----------
do_add() {
  local clip def link id meta title count resp
  clip=$(pbpaste 2>/dev/null | head -n1)
  def=""; printf '%s' "$clip" | grep -q 'list=' && def="$clip"
  link=$(ask_text "Incolla qui il link della playlist.

Su YouTube: apri la playlist, tocca Condividi e poi Copia link." "$def")
  [ "$link" = "$NO" ] && return
  id=$(printf '%s' "$link" | grep -oE 'list=[A-Za-z0-9_-]+' | head -n1 | cut -d= -f2)
  if [ -z "$id" ]; then
    info "Questo non e' il link di una playlist.

Il link giusto contiene la parola «list=». Riprova copiandolo da YouTube con Condividi > Copia link."
    return
  fi
  case "$id" in
    RD*) info "Questo e' un «Mix» creato da YouTube, non una tua playlist: non si puo' sincronizzare.

Crea una playlist tua con i brani che vuoi e aggiungi quella."; return ;;
    LL|WL) info "Questa lista e' privata per forza (Mi piace / Guarda piu' tardi) e non si puo' sincronizzare.

Crea una playlist tua con i brani che vuoi e aggiungi quella."; return ;;
  esac
  load_list
  if [ -n "$(name_of "$id")" ]; then
    info "La playlist «$(name_of "$id")» e' gia' nell'elenco."; return
  fi
  notify "Controllo la playlist su YouTube..."
  meta=$(yt-dlp --flat-playlist --print $'%(playlist_title)s\t%(id)s' "https://www.youtube.com/playlist?list=$id" </dev/null 2>/dev/null)
  title=$(printf '%s\n' "$meta" | head -n1 | cut -f1)
  count=$(printf '%s\n' "$meta" | grep -c $'\t')
  if [ -z "$title" ] || [ "$title" = "NA" ]; then
    info "Non riesco a leggere questa playlist.

Di solito succede quando e' «Privata». Su YouTube apri la playlist, cambia la visibilita' in «Non in elenco» (o «Pubblica») e riprova."
    return
  fi
  [ "$(ask_buttons "Ho trovato:

«${title}»
$count brani

La aggiungo alla sincronizzazione?" "Annulla" "Aggiungi" "Aggiungi")" = "Aggiungi" ] || return
  resp=$(post --data-urlencode "action=add" --data-urlencode "link=https://www.youtube.com/playlist?list=$id" --data-urlencode "name=$title")
  case "$resp" in
    OK)
      if [ "$(ask_buttons "Fatto! «${title}» e' stata aggiunta.

I brani verranno scaricati alla prossima sincronizzazione." "Piu' tardi" "Sincronizza adesso" "Sincronizza adesso")" = "Sincronizza adesso" ]; then
        open "$SYNC_SCRIPT"; close_terminal; exit 0
      fi ;;
    GIA_PRESENTE) info "La playlist «${title}» e' gia' nell'elenco." ;;
    *) info "Non sono riuscito a salvarla. Controlla internet e riprova; se continua, chiama Stefano." ;;
  esac
}

do_remove() {
  local items=() ids=() sel i id nm resp n_same folder
  if ! load_list; then info "Non riesco a leggere l'elenco. Controlla internet e riprova."; return; fi
  if [ ! -s "$LIST_FILE" ]; then info "Non ci sono playlist da togliere."; return; fi
  while IFS=$'\t' read -r id nm _; do
    [ -z "$id" ] && continue
    [ -z "$nm" ] && nm="$id"
    ids+=("$id"); items+=("$nm")
  done < "$LIST_FILE"
  sel=$(choose_one "Quale playlist vuoi togliere dalla sincronizzazione?" "${items[@]}")
  [ "$sel" = "$NO" ] && return
  id=""
  for i in "${!items[@]}"; do
    if [ "${items[$i]}" = "$sel" ]; then id="${ids[$i]}"; break; fi
  done
  [ -z "$id" ] && return
  [ "$(ask_buttons "Togliere «${sel}» dalla sincronizzazione?

I brani gia' scaricati restano sul Mac." "Annulla" "Togli" "Annulla")" = "Togli" ] || return
  resp=$(post --data-urlencode "action=remove" --data-urlencode "listid=$id")
  case "$resp" in
    OK|NON_TROVATA) ;;
    *) info "Non sono riuscito a toglierla. Controlla internet e riprova; se continua, chiama Stefano."; return ;;
  esac
  folder="$DEST_FOLDER/$sel"
  n_same=$(awk -F'\t' -v n="$sel" -v id="$id" '$2==n && $1!=id' "$LIST_FILE" | wc -l | tr -d ' ')
  case "$sel" in ""|_*|*/*) folder="" ;; esac
  if [ -n "$folder" ] && [ -d "$folder" ] && [ "$n_same" -eq 0 ]; then
    if [ "$(ask_buttons "Fatto: «${sel}» non verra' piu' sincronizzata.

Vuoi spostare anche la sua cartella nel Cestino? (Se cambi idea la recuperi dal Cestino.)" "Sposta nel Cestino" "Tienila" "Tienila")" = "Sposta nel Cestino" ]; then
      trash_dest="$HOME/.Trash/$sel"
      [ -e "$trash_dest" ] && trash_dest="$HOME/.Trash/$sel $(date +%H%M%S)"
      mv "$folder" "$trash_dest" 2>/dev/null
      if [ -d "$folder" ]; then   # piano B: tramite Finder
        osascript - "$folder" <<'EOF' >/dev/null 2>&1
on run argv
  tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)
end run
EOF
      fi
      if [ ! -d "$folder" ]; then info "Cartella «${sel}» spostata nel Cestino."
      else info "Non sono riuscito a spostare la cartella. Puoi trascinarla nel Cestino tu dalla cartella Musica > Youtube."
      fi
    fi
  else
    info "Fatto: «${sel}» non verra' piu' sincronizzata."
  fi
}

do_list() {
  local txt n
  if ! load_list; then info "Non riesco a leggere l'elenco. Controlla internet e riprova."; return; fi
  n=$(grep -c . "$LIST_FILE")
  txt=$(awk -F'\t' '$1!="" { print "•  " ($2!="" ? $2 : $1) }' "$LIST_FILE")
  info "Playlist sincronizzate ($n):

$txt"
}

# ---------- menu ----------
while true; do
  c=$(choose_one "Cosa vuoi fare?" "Aggiungi una playlist" "Togli una playlist" "Vedi le playlist")
  case "$c" in
    "Aggiungi una playlist") do_add ;;
    "Togli una playlist")    do_remove ;;
    "Vedi le playlist")      do_list ;;
    *) break ;;
  esac
done
close_terminal
exit 0
