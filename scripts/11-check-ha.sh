#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster
WARNINGS=0
ha_warn() { printf 'AVERTISSEMENT HA : %s\n' "$*" >&2; WARNINGS=$((WARNINGS+1)); }
printf '=== Keycloak pods et placement ===\n'
k get pods -n "$KEYCLOAK_NAMESPACE" -l 'app.kubernetes.io/component=server' -o wide
KC_ROWS="$(k get pods -n "$KEYCLOAK_NAMESPACE" -l 'app.kubernetes.io/component=server' -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
KC_COUNT="$(printf '%s\n' "$KC_ROWS" | awk 'NF {n++} END {print n+0}')"
KC_RUNNING="$(printf '%s\n' "$KC_ROWS" | awk '$3=="Running" {n++} END {print n+0}')"
KC_NODES="$(printf '%s\n' "$KC_ROWS" | awk 'NF>=2 {print $2}' | sort -u | wc -l)"
printf 'Keycloak : pods=%s running=%s nodes-distincts=%s\n' "$KC_COUNT" "$KC_RUNNING" "$KC_NODES"
(( KC_RUNNING == KEYCLOAK_REPLICAS )) || ha_warn "Attendu ${KEYCLOAK_REPLICAS} pods Keycloak Running."
(( KC_NODES >= KEYCLOAK_REPLICAS )) || ha_warn 'Les pods Keycloak ne sont pas répartis sur 3 nœuds distincts.'
printf '\n=== PostgreSQL CNPG pods et placement ===\n'
k get pods -n "$KEYCLOAK_NAMESPACE" -l "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o wide
PG_ROWS="$(k get pods -n "$KEYCLOAK_NAMESPACE" -l "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}')"
PG_COUNT="$(printf '%s\n' "$PG_ROWS" | awk 'NF {n++} END {print n+0}')"
PG_RUNNING="$(printf '%s\n' "$PG_ROWS" | awk '$3=="Running" {n++} END {print n+0}')"
PG_NODES="$(printf '%s\n' "$PG_ROWS" | awk 'NF>=2 {print $2}' | sort -u | wc -l)"
printf 'PostgreSQL : pods=%s running=%s nodes-distincts=%s\n' "$PG_COUNT" "$PG_RUNNING" "$PG_NODES"
(( PG_RUNNING == CNPG_INSTANCES )) || ha_warn "Attendu ${CNPG_INSTANCES} pods PostgreSQL Running."
(( PG_NODES >= CNPG_INSTANCES )) || ha_warn 'Les instances PostgreSQL ne sont pas réparties sur 3 nœuds distincts.'
printf '\n=== Operator Keycloak ===\n'
k get deployment keycloak-operator -n "$KEYCLOAK_NAMESPACE" -o wide
printf '\nL’Operator peut rester à 1 replica : c’est un contrôleur du plan de gestion. La HA des requêtes est portée par les pods Keycloak et la base PostgreSQL.\n'
printf 'Ce contrôle observe le placement ; il ne provoque aucune panne et ne certifie pas le RTO/RPO.\n'
if (( WARNINGS > 0 )); then printf '\nContrôle HA en échec : %s anomalie(s).\n' "$WARNINGS" >&2; exit 1; fi
printf 'Contrôle HA réussi.\n'
