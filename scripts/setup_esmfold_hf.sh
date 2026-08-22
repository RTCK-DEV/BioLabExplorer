#!/usr/bin/env bash
set -euo pipefail
ENV_NAME="${FOLD_ENV_NAME:-biolab-fold}"
if [[ "${1:-}" == "--plan" ]]; then
  cat <<'PLAN'
Hugging Face ESMFold plan (isolated conda env: biolab-fold)
  - Python 3.11, PyTorch, Transformers, Accelerate
  - facebook/esmfold_v1 is revision-pinned by config/folding_manifest.json
  - model weights are downloaded only by esmfold_hf.py --allow-network (~15+ GB repository)
  - MPS is attempted explicitly; CPU remains a visible fallback, never a hidden one
PLAN
  exit 0
fi
if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "setup_esmfold_hf: refusing downloads; inspect --plan then set ALLOW_NETWORK=1" >&2
  exit 2
fi
command -v mamba >/dev/null 2>&1 && CONDA=mamba || CONDA=conda
command -v "${CONDA}" >/dev/null 2>&1 || { echo "conda/mamba not found" >&2; exit 2; }
if ! "${CONDA}" run -n "${ENV_NAME}" python --version >/dev/null 2>&1; then
  "${CONDA}" create -y -n "${ENV_NAME}" python=3.11 pip
fi
"${CONDA}" run -n "${ENV_NAME}" python -m pip install 'torch>=2.2' 'transformers>=4.48,<5' 'accelerate>=1,<2'
"${CONDA}" run -n "${ENV_NAME}" python -c 'import torch,transformers,accelerate; print(torch.__version__, transformers.__version__, accelerate.__version__, "mps=", torch.backends.mps.is_available())'
echo "Set ESMFOLD_PYTHON to: $("${CONDA}" run -n "${ENV_NAME}" python -c 'import sys; print(sys.executable)')"
