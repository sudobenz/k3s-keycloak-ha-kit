#!/usr/bin/env bash
set -Eeuo pipefail
JAIL_FILE=/etc/fail2ban/jail.d/99-k3s-host-ssh.local
APT_FILE=/etc/apt/apt.conf.d/99-k3s-cluster-maintenance
ERRORS=0

check() { if "$@"; then printf '[OK] '; else printf '[ERREUR] '; ERRORS=$((ERRORS+1)); fi; }
show() { printf '%s\n' "$*"; }

if [[ -f "$JAIL_FILE" ]] && grep -Eq '^enabled[[:space:]]*=[[:space:]]*true' "$JAIL_FILE" && grep -Eq '^backend[[:space:]]*=[[:space:]]*systemd' "$JAIL_FILE"; then
  show '[OK] Configuration Fail2ban SSH présente (backend systemd).'
else
  show '[ERREUR] Configuration Fail2ban SSH absente ou incomplète.'; ERRORS=$((ERRORS+1))
fi
if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
  show '[OK] Service Fail2ban actif et jail sshd chargé.'
else
  show '[ERREUR] Fail2ban ou jail sshd non opérationnel.'; ERRORS=$((ERRORS+1))
fi
if [[ -f "$APT_FILE" ]] && grep -Eq '^APT::Periodic::Update-Package-Lists "1";' "$APT_FILE" && grep -Eq '^APT::Periodic::Unattended-Upgrade "0";' "$APT_FILE" && grep -Eq '^Unattended-Upgrade::Automatic-Reboot "false";' "$APT_FILE"; then
  show '[OK] Installation OS autonome désactivée; redémarrage automatique désactivé.'
else
  show '[ERREUR] Politique APT de maintenance absente ou incomplète.'; ERRORS=$((ERRORS+1))
fi
if systemctl is-active --quiet k3s; then
  show '[OK] Service k3s actif.'
elif systemctl is-active --quiet k3s-server; then
  show '[OK] Service k3s-server actif.'
else
  show '[AVERTISSEMENT] Service K3s non détecté/actif sur cet hôte; vérifier le rôle du nœud.'
fi
if [[ -e /var/run/reboot-required ]]; then
  show '[AVERTISSEMENT] /var/run/reboot-required présent : un redémarrage est probablement requis. Ne pas redémarrer hors procédure séquentielle.'
  if [[ -s /var/run/reboot-required.pkgs ]]; then
    show 'Paquets concernés :'; sed 's/^/  - /' /var/run/reboot-required.pkgs
  fi
else
  show '[OK] Aucun indicateur /var/run/reboot-required.'
fi

if (( ERRORS > 0 )); then
  show "Bilan : ${ERRORS} contrôle(s) en erreur."; exit 1
fi
show 'Bilan : contrôles locaux terminés.'
