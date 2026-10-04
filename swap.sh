#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
DIR=/var/lib/swap-manager
CONF=/etc/sysctl.d/99-swap-manager.conf
die() { echo "ERRO: $*" >&2; exit 1; }
root() {
  (( EUID == 0 )) || die "Execute com sudo bash $0"
  for c in flock swapon swapoff mkswap findmnt df awk sysctl; do
    command -v "$c" >/dev/null || die "Comando necessário: $c"
  done
  [[ ! -L "$DIR" ]] || die "Diretório não pode ser link simbólico."
  mkdir -p "$DIR" /etc/sysctl.d
  chmod 700 "$DIR"
  exec 9>"$DIR/lock"
  flock -n 9 || die "Outro gerenciador está executando."
}
active() { swapon --show=NAME --noheadings --raw | awk -v p="$1" '$0==p {found=1} END {exit !found}'; }
owned_files() {
  local p
  for p in "$DIR/swapfile" "$DIR/swapfile-next"; do
    [[ ! -L "$p" ]] || die "Arquivo de swap não pode ser link."
    [[ ! -e "$p" || -f "$p" ]] || die "Caminho inválido: $p"
  done
}
ui_init() {
  UI_CYAN='' UI_GREEN='' UI_BOLD='' UI_RESET=''
  if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    UI_CYAN=$'\033[36m' UI_GREEN=$'\033[32m' UI_BOLD=$'\033[1m' UI_RESET=$'\033[0m'
  fi
}
ui_line() { printf '%s%s%s\n' "$UI_CYAN" "$1" "$UI_RESET"; }
ui_row() {
  # Width counts Unicode characters using awk, even with LC_ALL=C.
  local value=$1 length padding
  length=$(printf '%s' "$value" | od -An -tu1 | awk '{for(i=1;i<=NF;i++) if($i<128 || $i>=192) n++} END {print n+0}')
  padding=$((46-length))
  (( padding >= 0 )) || padding=0
  printf '%s║%s %s%*s %s║%s\n' "$UI_CYAN" "$UI_RESET" "$value" "$padding" '' "$UI_CYAN" "$UI_RESET"
}
ui_metric() {
  local length
  length=$(printf '%s' "$1" | od -An -tu1 | awk '{for(i=1;i<=NF;i++) if($i<128 || $i>=192) n++} END {print n+0}')
  ui_row "$(printf '%s%*s%s' "$1" "$((24-length))" '' "$2")"
}
status() {
  local ram used available swap swap_used tendency
  read -r ram used available swap swap_used < <(awk '
    /^MemTotal:/ {m=$2} /^MemAvailable:/ {a=$2}
    /^SwapTotal:/ {s=$2} /^SwapFree:/ {f=$2}
    END {printf "%.2f %.2f %.2f %.2f %.2f\n",m/1048576,(m-a)/1048576,a/1048576,s/1048576,(s-f)/1048576}
  ' /proc/meminfo)
  tendency=$(sysctl -n vm.swappiness)
  ui_line '╔════════════════════════════════════════════════╗'
  ui_row "             Linux Swap Manager"
  ui_line '╠════════════════════════════════════════════════╣'
  ui_metric 'RAM instalada:' "$ram GiB"
  ui_metric 'RAM em uso (estimada):' "$used GiB"
  ui_metric 'RAM disponível:' "$available GiB"
  ui_metric 'Swap total:' "$swap GiB"
  ui_metric 'Swap usada:' "$swap_used GiB"
  ui_metric 'Swappiness:' "$tendency / 200"
  ui_line '╚════════════════════════════════════════════════╝'
}
valid_swappiness() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( 10#$1 <= 200 )); }
set_swappiness() {
  local value=$1 previous tmp
  valid_swappiness "$value" || die "Swappiness deve ser 0–200."
  value=$((10#$value))
  if [[ -e "$CONF" ]] && ! rg_marker "$CONF"; then die "Configuração sysctl já existe e não pertence ao gerenciador."; fi
  previous=$(sysctl -n vm.swappiness)
  [[ -e "$DIR/previous-swappiness" ]] || printf '%s\n' "$previous" > "$DIR/previous-swappiness"
  tmp=$(mktemp /etc/sysctl.d/.swap-manager.XXXXXX)
  printf '# swap-manager\nvm.swappiness=%s\n' "$value" > "$tmp"
  chmod 644 "$tmp"
  sysctl -w "vm.swappiness=$value" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONF"
  printf '%s\n' "$value" > "$DIR/last-swappiness"
}
rg_marker() { head -n 1 "$1" | awk '$0=="# swap-manager" {ok=1} END {exit !ok}'; }
fstab() {
  local target=${1:-} tmp backup
  [[ -f /etc/fstab && ! -L /etc/fstab ]] || die "/etc/fstab ausente ou não regular."
  tmp=$(mktemp /etc/.fstab-swap-manager.XXXXXX)
  backup=$(mktemp "$DIR/fstab-backup.XXXXXX")
  cp -p /etc/fstab "$backup"
  awk -v a="$DIR/swapfile" -v b="$DIR/swapfile-next" '$1!=a && $1!=b {print}' /etc/fstab > "$tmp"
  [[ -z "$target" ]] || printf '%s none swap sw 0 0\n' "$target" >> "$tmp"
  chmod --reference=/etc/fstab "$tmp"
  chown --reference=/etc/fstab "$tmp"
  mv -f "$tmp" /etc/fstab
}
configure() {
  local gib=${1:-} tendency=${2:-10} old='' new bytes available fs p
  [[ "$gib" =~ ^[0-9]{1,6}$ ]] && (( 10#$gib >= 1 && 10#$gib <= 104857 )) || die "Tamanho: 1–104857 GiB inteiros."
  valid_swappiness "$tendency" || die "Swappiness deve ser 0–200."
  owned_files
  for p in "$DIR/swapfile" "$DIR/swapfile-next"; do
    if [[ -e "$p" ]]; then
      [[ -z "$old" ]] || die "Dois arquivos existentes. Use disable/remove antes de configurar novamente."
      old=$p
    fi
  done
  new="$DIR/swapfile"
  [[ "$old" != "$new" ]] || new="$DIR/swapfile-next"
  bytes=$((10#$gib * 1073741824))
  available=$(df -B1 --output=avail "$DIR" | awk 'NR==2 {print $1}')
  (( available >= bytes + 1073741824 )) || die "Espaço insuficiente: precisa do tamanho solicitado + 1 GiB livre."
  fs=$(findmnt -n -o FSTYPE -T "$DIR")
  case "$fs" in ext4|ext3|ext2|xfs|btrfs) ;; *) die "Filesystem $fs não suportado automaticamente." ;; esac
  echo "Criando $gib GiB em $new..."
  (
    trap 'if ! active "$new"; then rm -f -- "$new"; fi' EXIT
    umask 077
    if [[ "$fs" == btrfs ]]; then
      command -v btrfs >/dev/null || die "Instale btrfs-progs."
      btrfs filesystem mkswapfile --size "$bytes" "$new" || exit 1
    else
      dd if=/dev/zero of="$new" bs=1M count=$((10#$gib * 1024)) status=progress || exit 1
      chmod 600 "$new"
      mkswap "$new" || exit 1
    fi
    chmod 600 "$new"
    swapon "$new" || exit 1
    if [[ -n "$old" ]] && active "$old"; then
      if ! swapoff "$old"; then
        echo "Swap antiga preservada. Tentando desfazer a nova." >&2
        swapoff "$new" || echo "Nova swap continua ativa; arquivos preservados. Execute status." >&2
        exit 1
      fi
    fi
    fstab "$new" || exit 1
    [[ -z "$old" ]] || rm -f -- "$old"
    set_swappiness "$tendency" || exit 1
  )
  local result=$?
  (( result == 0 )) || return "$result"
  echo "Swap configurada e persistida."
  status
}
disable() {
  local p
  owned_files
  for p in "$DIR/swapfile" "$DIR/swapfile-next"; do
    if active "$p"; then swapoff "$p" || die "Não foi possível desativar $p; arquivo preservado."; fi
  done
  fstab
  echo "Swap do gerenciador desativada, inclusive na inicialização."
}
enable() {
  local p found=''
  owned_files
  for p in "$DIR/swapfile" "$DIR/swapfile-next"; do
    if [[ -f "$p" ]]; then
      [[ -z "$found" ]] || die "Dois arquivos existentes; resolva antes de ativar."
      found=$p
    fi
  done
  [[ -n "$found" ]] || die "Crie uma swap primeiro."
  chmod 600 "$found"
  active "$found" || swapon "$found"
  fstab "$found"
}
remove() {
  disable
  rm -f -- "$DIR/swapfile" "$DIR/swapfile-next"
  if [[ -f "$CONF" ]] && rg_marker "$CONF"; then
    if [[ -f "$DIR/previous-swappiness" && -f "$DIR/last-swappiness" ]] && [[ "$(sysctl -n vm.swappiness)" == "$(cat "$DIR/last-swappiness")" ]]; then
      sysctl -w "vm.swappiness=$(cat "$DIR/previous-swappiness")"
    fi
    rm -f "$CONF" "$DIR/previous-swappiness" "$DIR/last-swappiness"
  fi
  echo "Configuração removida. Backups de fstab preservados em $DIR."
}
help() {
  echo "Uso: sudo bash $0 [configure GiB [swappiness] | swappiness 0–200 | enable | disable | remove | status | help]"
  echo "Sem argumentos: menu. Tamanho limita este arquivo; outras swaps continuam independentes."
}
menu() {
  local option size tendency confirm pause
  while true; do
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then printf '\033[2J\033[H'; fi
    status
    ui_line '╔════════════════════════════════════════════════╗'
    ui_row '1. Criar / alterar Swap'
    ui_row '2. Definir Swappiness'
    ui_row '3. Ativar Swap'
    ui_row '4. Mostrar uso detalhado'
    ui_row '5. Desativar Swap'
    ui_row '6. Remover configuração'
    ui_row '0. Sair'
    ui_line '╚════════════════════════════════════════════════╝'
    printf '\n%sEscolha uma opção [0–6]%s\n' "$UI_GREEN" "$UI_RESET"
    read -r -p '➜ ' option || return 0
    case "$option" in
      1) read -r -p 'Capacidade em GiB (ex.: 8): ' size; read -r -p 'Swappiness (0–200, padrão 10): ' tendency; configure "$size" "${tendency:-10}" ;;
      2) read -r -p 'Swappiness (0–200): ' tendency; set_swappiness "$tendency" ;;
      3) enable ;;
      4) status; printf '\n'; swapon --show ;;
      5|6) read -r -p 'Isso pode pressionar a RAM. Confirme digitando SIM: ' confirm; [[ "$confirm" != SIM ]] || { if [[ "$option" == 5 ]]; then disable; else remove; fi; } ;;
      0) return ;;
      *) echo 'Opção inválida.' ;;
    esac
    read -r -p 'Pressione Enter para voltar ao menu...' pause || return 0
  done
}
main() {
  case "${1:-menu}" in
    help|--help|-h) help ;;
    status) status ;;
    configure) [[ $# -ge 2 && $# -le 3 ]] || die "Use configure GiB [swappiness]."; root; configure "$2" "${3:-10}" ;;
    swappiness) [[ $# == 2 ]] || die "Use swappiness 0–200."; root; set_swappiness "$2" ;;
    enable|disable|remove) [[ $# == 1 ]] || die "Argumentos inesperados."; root; "$1" ;;
    menu) root; menu ;;
    *) help; exit 1 ;;
  esac
}
ui_init
main "$@"
