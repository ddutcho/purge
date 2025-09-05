#!/usr/bin/env bash
# sysclean.sh - Pulizia interattiva di spazio su disco per server Linux con focus Docker
# Autore: ChatGPT (modalità sysadmin)
# Sicuro per uso quotidiano: rimuove solo risorse non usate, cache, log vecchi, temporanei
# Richiede: bash, privilegi root (ri-esegue con sudo se necessario)

set -Euo pipefail

# ==== colori ====
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_G=$(tput setaf 2); C_R=$(tput setaf 1); C_Y=$(tput setaf 3); C_C=$(tput setaf 6); C_B=$(tput bold); C_N=$(tput sgr0)
else
  C_G=""; C_R=""; C_Y=""; C_C=""; C_B=""; C_N=""
fi

# ==== root check ====
if [[ $EUID -ne 0 ]]; then
  echo -e "${C_Y}[*] Richiesti privilegi root. Ri-eseguo con sudo...${C_N}"
  exec sudo -E bash "$0" "$@"
fi

# ==== logging ====
LOGFILE="/var/log/sysclean.log"
if ! touch "$LOGFILE" 2>/dev/null; then
  LOGFILE="${HOME}/sysclean.log"
  touch "$LOGFILE" 2>/dev/null || true
fi

log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" >/dev/null; }
info() { echo -e "${C_G}[OK]${C_N} $*"; log "[OK] $*"; }
warn() { echo -e "${C_Y}[!]${C_N} $*"; log "[WARN] $*"; }
err()  { echo -e "${C_R}[X]${C_N} $*"; log "[ERR] $*"; }

trap 'err "Errore alla linea $LINENO (ultimo comando: ${BASH_COMMAND})"' ERR

press_enter() { read -rp $'\nPremi INVIO per continuare...'; }

confirm() {
  local msg="${1:-Confermi?} [s/N]: "
  read -rp "$msg" -n1 ans; echo
  [[ "${ans,,}" == "s" ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# ==== utility di stampa ====
header() {
  echo -e "\n${C_B}${C_C}== $* ==${C_N}\n"
}

# ==== sezioni diagnostica ====
disk_usage() {
  header "Utilizzo disco"
  df -h | tee -a "$LOGFILE"
  if have docker; then
    echo
    echo "Docker system df:"
    docker system df | tee -a "$LOGFILE" || true
    echo
    echo "Dettaglio /var/lib/docker:"
    du -xh --max-depth=1 /var/lib/docker 2>/dev/null | sort -h | tee -a "$LOGFILE" || true
  fi
}

top_space_hogs() {
  header "Directory più ingombranti (top 25 dalla root /)"
  du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -n 25 | tee -a "$LOGFILE" || true
}

# ==== Docker ====
docker_container_prune() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: rimozione container stoppati"
  if confirm "Rimuovere TUTTI i container stoppati? [s/N]"; then
    docker container prune -f | tee -a "$LOGFILE" || true
    info "Container stoppati rimossi (se presenti)."
  else
    warn "Annullato."
  fi
}

docker_image_prune() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: rimozione immagini non usate"
  if confirm "Rimuovere tutte le IMMAGINI non usate (nessun container le usa)? [s/N]"; then
    docker image prune -a -f | tee -a "$LOGFILE" || true
    info "Immagini non usate ripulite."
  else
    warn "Annullato."
  fi
}

docker_builder_prune() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: pulizia cache builder (layers)"
  if confirm "Rimuovere la cache di build (builder prune)? [s/N]"; then
    docker builder prune -af | tee -a "$LOGFILE" || true
    info "Cache builder ripulita."
  else
    warn "Annullato."
  fi
}

docker_network_prune() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: rimozione reti non usate"
  if confirm "Rimuovere RETI non usate? [s/N]"; then
    docker network prune -f | tee -a "$LOGFILE" || true
    info "Reti non usate rimosse."
  else
    warn "Annullato."
  fi
}

docker_volume_prune() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: rimozione volumi non usati"
  echo -e "${C_Y}ATTENZIONE:${C_N} verranno rimossi solo i volumi non referenziati da alcun container,\nma potrebbero contenere dati che non servono più."
  if confirm "Procedere con 'docker volume prune'? [s/N]"; then
    docker volume prune -f | tee -a "$LOGFILE" || true
    info "Volumi non usati rimossi."
  else
    warn "Annullato."
  fi
}

docker_system_prune_all() {
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  header "Docker: system prune completo (immagini/rette/container/cache/volumi non usati)"
  echo -e "${C_Y}Nota:${C_N} rimuove TUTTE le risorse non usate; i volumi solo se non usati."
  if confirm "Eseguire 'docker system prune -af --volumes'? [s/N]"; then
    docker system prune -af --volumes | tee -a "$LOGFILE" || true
    info "Prune completo eseguito."
  else
    warn "Annullato."
  fi
}

# ==== journald ====
journald_vacuum() {
  header "journald: vacuum"
  if ! have journalctl; then warn "systemd-journald non presente. Salto."; return; fi
  journalctl --disk-usage | tee -a "$LOGFILE" || true
  read -rp "Imposta dimensione massima da mantenere (default 1G, es. 500M/2G): " JSIZE
  JSIZE="${JSIZE:-1G}"
  if confirm "Eseguire 'journalctl --vacuum-size=${JSIZE}'? [s/N]"; then
    journalctl --vacuum-size="$JSIZE" | tee -a "$LOGFILE" || true
    info "journald ridotto a ~${JSIZE}."
  else
    warn "Annullato."
  fi
}

configure_journald_limits() {
  header "journald: limiti persistenti"
  if ! have systemctl; then warn "systemd non presente. Salto."; return; fi
  install -d /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
EOF
  systemctl restart systemd-journald || true
  info "Impostati limiti permanenti: SystemMaxUse=1G, SystemMaxFileSize=100M. Servizio riavviato."
}

# ==== APT ====
apt_cleanup() {
  header "APT: pulizia cache e pacchetti inutili"
  if ! have apt-get; then warn "APT non trovato (non Debian/Ubuntu). Salto."; return; fi
  if confirm "Eseguire 'apt-get autoremove --purge', 'autoclean' e 'clean'? [s/N]"; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || true
    apt-get autoclean -y || true
    apt-get clean || true
    info "APT pulito."
  else
    warn "Annullato."
  fi
}

# ==== SNAP ====
snap_cleanup() {
  header "SNAP: rimozione revisioni disabilitate e riduzione retain"
  if ! have snap; then warn "snapd non presente. Salto."; return; fi
  if confirm "Impostare retain=2 e rimuovere revisioni disabilitate? [s/N]"; then
    snap set system refresh.retain=2 || true
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r name rev; do
      snap remove "$name" --revision="$rev" || true
    done
    info "SNAP ripulito (retain=2; revisioni disabilitate rimosse)."
  else
    warn "Annullato."
  fi
}

# ==== Log e temporanei ====
logs_and_temp_cleanup() {
  header "Log ruotati e temporanei"
  echo "Rimuoverò log compressi/ruotati più vecchi di 14 giorni, crash dump e file in /tmp e /var/tmp non toccati da >10 giorni."
  if confirm "Procedere? [s/N]"; then
    find /var/log -type f -regextype posix-extended -regex '.*\.(gz|xz|[1-9]|old)$' -mtime +14 -print -delete 2>/dev/null | tee -a "$LOGFILE" || true
    rm -f /var/crash/* 2>/dev/null || true
    find /tmp -type f -mtime +10 -print -delete 2>/dev/null | tee -a "$LOGFILE" || true
    find /var/tmp -type f -mtime +10 -print -delete 2>/dev/null | tee -a "$LOGFILE" || true
    info "Log e temporanei ripuliti."
  else
    warn "Annullato."
  fi
}

# ==== Cache strumenti sviluppo ====
dev_caches() {
  header "Cache strumenti sviluppo (npm/pip)"
  if have npm; then npm cache clean --force || true; info "npm cache pulita."; else warn "npm non presente."; fi
  if have pip3; then pip3 cache purge || true; info "pip3 cache pulita."; fi
  if have pip; then pip cache purge || true; info "pip cache pulita."; fi
}

# ==== Configurazione Docker logging persistente ====
configure_docker_log_rotation() {
  header "Docker: rotazione log json-file"
  if ! have docker; then warn "Docker non trovato. Salto."; return; fi
  local DAEMON="/etc/docker/daemon.json"
  if [[ ! -f "$DAEMON" ]]; then
    cat >"$DAEMON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker || true
    info "Creato $DAEMON con rotazione log (50m x 3). Docker riavviato."
  else
    warn "$DAEMON esiste già. Aprilo e verifica che contenga:
  \"log-driver\": \"json-file\",
  \"log-opts\": { \"max-size\": \"50m\", \"max-file\": \"3\" }
Poi riavvia Docker con: systemctl restart docker"
  fi
}

# ==== batch "sicuro" ====
full_safe_cleanup() {
  header "Pulizia completa (sicura) - batch"
  if have docker; then
    docker container prune -f || true
    docker image prune -a -f || true
    docker builder prune -af || true
    docker network prune -f || true
    docker volume prune -f || true
  fi
  if have journalctl; then journalctl --vacuum-size=1G || true; fi
  if have apt-get; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || true
    apt-get autoclean -y || true
    apt-get clean || true
  fi
  find /var/log -type f -regextype posix-extended -regex '.*\.(gz|xz|[1-9]|old)$' -mtime +14 -delete 2>/dev/null || true
  rm -f /var/crash/* 2>/dev/null || true
  find /tmp -type f -mtime +10 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +10 -delete 2>/dev/null || true
  if have npm; then npm cache clean --force || true; fi
  if have pip3; then pip3 cache purge || true; fi
  if have pip; then pip cache purge || true; fi
  info "Batch completato."
  disk_usage
}

# ==== MENU ====
show_menu() {
  echo -e "${C_B}${C_C}
███████╗██╗   ██╗███████╗ ██████╗██╗     ███████╗ █████╗ ███╗  ██╗
██╔════╝██║   ██║██╔════╝██╔════╝██║     ██╔════╝██╔══██╗████╗ ██║
█████╗  ██║   ██║█████╗  ██║     ██║     █████╗  ███████║██╔██╗██║
██╔══╝  ╚██╗ ██╔╝██╔══╝  ██║     ██║     ██╔══╝  ██╔══██║██║╚████║
███████╗ ╚████╔╝ ███████╗╚██████╗███████╗███████╗██║  ██║██║ ╚███║
╚══════╝  ╚═══╝  ╚══════╝ ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚══╝${C_N}
  ${C_B}Pulizia spazio su disco – Interattivo${C_N}
  Log: $LOGFILE

  1) Mostra utilizzo disco
  2) Docker: container prune (stoppati)
  3) Docker: image prune (non usate)
  4) Docker: builder prune (cache)
  5) Docker: network prune (non usate)
  6) Docker: volume prune (non usati)
  7) Docker: system prune TUTTO (+volumi)
  8) journald: vacuum (imposta dimensione)
  9) APT: autoremove/autoclean/clean
 10) SNAP: rimuovi revisioni disabilitate (retain=2)
 11) Log e temporanei: cleanup sicuro
 12) Cache sviluppo: npm/pip
 13) journald: limiti PERSISTENTI (1G/100M)
 14) Docker: rotazione log PERSISTENTE (50m x 3)
 15) Directory più ingombranti (top 25)
 16) PULIZIA COMPLETA (batch sicuro)
 17) Esci
"
}

main_loop() {
  while true; do
    show_menu
    read -rp "Seleziona un'opzione [1-17]: " choice
    case "${choice:-}" in
      1) disk_usage; press_enter ;;
      2) docker_container_prune; press_enter ;;
      3) docker_image_prune; press_enter ;;
      4) docker_builder_prune; press_enter ;;
      5) docker_network_prune; press_enter ;;
      6) docker_volume_prune; press_enter ;;
      7) docker_system_prune_all; press_enter ;;
      8) journald_vacuum; press_enter ;;
      9) apt_cleanup; press_enter ;;
     10) snap_cleanup; press_enter ;;
     11) logs_and_temp_cleanup; press_enter ;;
     12) dev_caches; press_enter ;;
     13) configure_journald_limits; press_enter ;;
     14) configure_docker_log_rotation; press_enter ;;
     15) top_space_hogs; press_enter ;;
     16) full_safe_cleanup; press_enter ;;
     17) echo "Uscita. Log completo: $LOGFILE"; exit 0 ;;
      *) warn "Scelta non valida."; press_enter ;;
    esac
  done
}

# ==== Avvio ====
header "Benvenuto in sysclean.sh"
disk_usage
main_loop
