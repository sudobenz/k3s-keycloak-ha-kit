#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

ERRORS=0
WARNINGS=0
ok() { printf '[OK]   %s\n' "$*"; }
err() { printf '[ERR]  %s\n' "$*" >&2; ERRORS=$((ERRORS+1)); }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }

for file in scripts/*.sh; do
  if bash -n "$file"; then ok "Syntaxe Bash : $file"; else err "Syntaxe Bash invalide : $file"; fi
done

if python3 - <<'PY'
from pathlib import Path
compile(Path('scripts/http-benchmark.py').read_text(encoding='utf-8'), 'scripts/http-benchmark.py', 'exec')
PY
then ok 'Compilation Python : scripts/http-benchmark.py'; else err 'Compilation Python échouée.'; fi

if python3 - <<'PY'
try:
    import yaml
except ImportError:
    raise SystemExit(2)
from pathlib import Path
files=list(Path('.').rglob('*.yaml'))+list(Path('.').rglob('*.yml'))
for p in files:
    if any(part in {'output','backups'} for part in p.parts):
        continue
    with p.open(encoding='utf-8') as f:
        list(yaml.safe_load_all(f))
print(f'{len(files)} fichiers YAML/YML analysés.')
PY
then ok 'Analyse syntaxique YAML (PyYAML)'; else
  rc=$?
  if [[ $rc -eq 2 ]]; then warn 'PyYAML absent : analyse YAML sautée (installer python3-yaml pour l’activer).'; else err 'Analyse YAML échouée.'; fi
fi

# Les chemins de scripts référencés dans la documentation doivent exister.
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  [[ -e "$ref" ]] || err "Référence manquante : $ref"
done < <(grep -RhoE 'scripts/[A-Za-z0-9._-]+\.(sh|py)' README.md docs portainer manifests 2>/dev/null | sort -u)
(( ERRORS == 0 )) && ok 'Références documentaires vers les scripts'

if [[ -e secrets.env || -e kubeconfig || -e output/kubeconfig ]]; then
  err 'Un fichier secret/kubeconfig est présent dans la racine ou output : ne pas archiver.'
else
  ok 'Aucun secrets.env ou kubeconfig dans le kit source'
fi

if python3 - <<'PYSCAN'
from pathlib import Path
bad=[]
for p in Path('.').rglob('*'):
    if not p.is_file() or '.git' in p.parts or p.name == 'validate-kit.sh':
        continue
    try:
        data=p.read_bytes()
    except OSError:
        continue
    if (b'-----BEGIN PRIVATE KEY-----' in data
        or b'-----BEGIN RSA PRIVATE KEY-----' in data
        or b'-----BEGIN OPENSSH PRIVATE KEY-----' in data):
        bad.append(str(p))
if bad:
    print('Clés privées détectées : ' + ', '.join(bad))
    raise SystemExit(1)
PYSCAN
then ok 'Aucun en-tête de clé privée détecté'; else err 'Clé privée détectée dans le kit.'; fi

if (( ERRORS > 0 )); then
  printf '\nValidation en échec : %s erreur(s), %s avertissement(s).\n' "$ERRORS" "$WARNINGS" >&2
  exit 1
fi
printf '\nValidation statique réussie : %s avertissement(s).\n' "$WARNINGS"
