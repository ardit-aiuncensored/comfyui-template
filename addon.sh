#!/bin/bash
# AI Uncensored add-on setup.
# Adds: newer ComfyUI, extra custom nodes, MiniMax H3 + other models, workflows, settings.
# Safe to re-run: skips anything already done.

# Models to leave out, even if they are listed in models_addon.txt (space-separated filenames)
SKIP_MODELS="minimax_h3_ref2va_pruned_int8.safetensors"

REPO="${SETUP_REPO:?SETUP_REPO is not set in the template}"
BRANCH="${SETUP_BRANCH:-main}"
C=/ComfyUI   # runs from the container disk; models/user/output/input link to /workspace
if [ -x /opt/venv/bin/python3 ]; then PY=/opt/venv/bin/python3; else PY=python3; fi
pipi() { $PY -m pip install -q "$@" </dev/null || uv pip install --python "$PY" "$@" </dev/null; }
echo "==== add-on started $(date)"
cd /
# Files on network volumes are owned by "nobody"; without this, git refuses to
# touch them ("dubious ownership").
git config --global --add safe.directory '*'

# 1. Wait until the start script has linked the volume folders in
echo "waiting for ComfyUI folders to be ready..."
until [ -f "$C/main.py" ] && [ -L "$C/models" ]; do sleep 5; done
echo "ComfyUI is ready"

# 2. Download this repo
T=/tmp/addon; rm -rf "$T"; mkdir -p "$T"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$T" --strip-components=1 \
  || { echo "Could not download repo $REPO"; exit 1; }
CHANGED=0

# 3. ComfyUI version (MiniMax H3 needs a newer ComfyUI than the image ships)
# ComfyUI is on the container disk, which resets to the image on every boot, so
# this runs every boot. -f drops the image's own edit to comfy/samplers.py,
# which otherwise blocks the update.
CV=$(tr -d '[:space:]' < "$T/comfy_version.txt")
if [ -n "$CV" ] && [ "$(git -C "$C" rev-parse HEAD 2>/dev/null)" != "$CV" ]; then
  # models/user/output/input are links to the volume. Git doesn't write through
  # links (it would swap them for empty folders), so unlink them for the update
  # and link them again afterwards. The files on the volume are never touched.
  for sub in models user output input; do [ -L "$C/$sub" ] && rm "$C/$sub"; done
  if { git -C "$C" cat-file -e "$CV^{commit}" 2>/dev/null || git -C "$C" fetch -q origin </dev/null; } \
     && git -C "$C" checkout -q -f "$CV" </dev/null; then
    UPDATED=1
  else
    UPDATED=0
  fi
  for sub in models user output input; do
    [ -L "$C/$sub" ] || rm -rf "$C/$sub"          # placeholder folder git just made
    ln -sfn "/workspace/ComfyUI/$sub" "$C/$sub"
  done
  if [ "$UPDATED" = 1 ]; then
    pipi -r "$C/requirements.txt"; CHANGED=1; echo "ComfyUI set to $CV"
  else
    echo "FAILED to update ComfyUI to $CV"
  fi
fi

# 4. Custom nodes, pinned to the tested versions (nodes.txt: name url commit)
while read -r NAME URL COMMIT; do
  [ -z "${NAME:-}" ] && continue
  D="$C/custom_nodes/$NAME"
  if [ ! -d "$D" ]; then
    echo "installing node: $NAME"
    # Clone on the container disk first, then copy onto the volume. Some network
    # volumes block the permission changes git makes while cloning
    # ("chmod on .git/config.lock failed"), which made these installs fail.
    TMPN="/tmp/nodes/$NAME"; rm -rf "$TMPN"; mkdir -p /tmp/nodes
    git clone -q "$URL" "$TMPN" </dev/null || { echo "FAILED node $NAME (clone)"; continue; }
    git -C "$TMPN" checkout -q "$COMMIT" </dev/null || echo "WARN: $NAME commit not found, kept latest version"
    cp -r "$TMPN" "$D" || { echo "FAILED node $NAME (copy to volume)"; rm -rf "$D"; continue; }
    rm -rf "$TMPN"
    echo "installed node: $NAME"; CHANGED=1
  elif [ ! -d "$D/.git" ] || [ "$(git -C "$D" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ]; then
    continue   # shipped in the image at the right version; its packages are already there
  else
    echo "updating node: $NAME"
    git -C "$D" fetch -q origin </dev/null
    git -C "$D" checkout -q "$COMMIT" </dev/null || echo "WARN: $NAME commit not found, kept current version"
    CHANGED=1
  fi
  [ -f "$D/requirements.txt" ] && pipi -r "$D/requirements.txt"
done < "$T/nodes.txt"

# Node packs that are not on GitHub (shipped in this repo)
for n in ComfyUI-LoadImageCrop comfyui_fearnworksnodes; do
  if [ ! -d "$C/custom_nodes/$n" ] && [ -f "$T/extra_nodes.tar.gz" ]; then
    tar xzf "$T/extra_nodes.tar.gz" -C "$C/custom_nodes" "$n" && CHANGED=1 && echo "installed node: $n"
  fi
done

# ComfyUI-Manager moved to Comfy-Org; fix its node-list address
for F in "$C/user/__manager/config.ini" "$C/user/__manager/channels.list"; do
  [ -f "$F" ] && sed -i 's#ltdrdata/ComfyUI-Manager#Comfy-Org/ComfyUI-Manager#g' "$F"
done

# 5. Workflows and settings (never overwrites a student's own files)
mkdir -p "$C/user/default/workflows"
cp -n "$T"/workflows/*.json "$C/user/default/workflows/" 2>/dev/null
[ -f "$C/user/default/comfy.settings.json" ] || cp "$T/comfy.settings.json" "$C/user/default/" 2>/dev/null

# 6. Models the image doesn't download (models_addon.txt: folder|filename|url)
# These run in the BACKGROUND so ComfyUI can open right away. The big video
# models (10Eros alone is ~28 GB) keep arriving while students use Krea 2; they
# show up in ComfyUI's model lists after a page refresh.
# Progress: /workspace/model_downloads.log

# Hugging Face files: use Hugging Face's own downloader (hf_xet, already in the
# image). Some repos (e.g. TenStrip/LTX2.3-10Eros) stall when pulled with aria2.
hf_get() {  # hf_get URL DEST_DIR FILENAME
  local rest="${1#https://huggingface.co/}"          # owner/repo/resolve/rev/path
  rest="${rest%%\?*}"
  local repo rev path
  repo="$(echo "$rest" | cut -d/ -f1-2)"
  rev="$(echo "$rest" | cut -d/ -f4)"
  path="$(echo "$rest" | cut -d/ -f5-)"
  HF_HUB_DOWNLOAD_TIMEOUT=60 $PY - "$repo" "$path" "$rev" "$2/.hf_tmp" "$2/$3" <<'EOF' </dev/null
import os, sys, urllib.parse
from huggingface_hub import hf_hub_download
repo, path, rev, tmp, dest = sys.argv[1:6]
p = hf_hub_download(repo_id=repo, filename=urllib.parse.unquote(path), revision=rev, local_dir=tmp)
os.replace(p, dest)
EOF
}

aria_get() {  # aria_get URL DEST_DIR FILENAME
  aria2c -q -x 8 -s 8 -k 1M -c --max-tries=20 --retry-wait=15 --timeout=60 --connect-timeout=30 \
    --file-allocation=none -d "$2" -o "$3" "$1" </dev/null
}

get_models() {
  echo "==== model downloads started $(date)"
  while IFS='|' read -r FO FI U; do
    [ -z "${FO:-}" ] && continue
    case " $SKIP_MODELS " in *" $FI "*) echo "not installing: $FI"; continue ;; esac
    D="$C/models/$FO"; mkdir -p "$D"
    if [ -s "$D/$FI" ] && [ ! -f "$D/$FI.aria2" ]; then continue; fi
    case "$U" in
      *civitai.com*)
        if [ -z "${CIVITAI_TOKEN:-}" ]; then echo "SKIPPED $FI (add your CIVITAI_TOKEN to the template)"; continue; fi
        U="$U&token=$CIVITAI_TOKEN" ;;
    esac
    rm -f "$D/$FI.part"   # leftover from the old curl fallback, never resumable
    echo "downloading: $FI"
    OK=0
    for TRY in 1 2 3 4 5 6; do
      case "$U" in
        https://huggingface.co/*)
          # Clear any half-finished aria2 copy; hf keeps its own resumable progress.
          [ -f "$D/$FI.aria2" ] && rm -f "$D/$FI" "$D/$FI.aria2"
          hf_get "$U" "$D" "$FI" && OK=1 ;;
        *)
          aria_get "$U" "$D" "$FI" && OK=1 ;;
      esac
      [ "$OK" = 1 ] && break
      echo "connection dropped, resuming $FI (attempt $((TRY+1)) of 6)..."
      sleep 20
    done
    if [ "$OK" = 1 ]; then
      rm -rf "$D/.hf_tmp"
      echo "downloaded: $FI"
    else
      echo "FAILED $FI (progress kept; re-running the add-on resumes it)"
    fi
  done < "$T/models_addon.txt"
  echo "==== model downloads finished $(date)"
}

# Output goes to its own log so this script (and the startup) doesn't wait for it.
# The lock stops two copies running at once if the add-on is re-run mid-download.
( flock -n 9 || { echo "model downloads already running"; exit 0; }; get_models ) \
  9>/tmp/model_downloads.lock >> /workspace/model_downloads.log 2>&1 < /dev/null &
echo "model downloads running in the background; progress: /workspace/model_downloads.log"

# 7. Restart ComfyUI once the image has started it, so it loads new nodes / ComfyUI version
if [ "$CHANGED" = 1 ] && [ -z "${ADDON_NO_RESTART:-}" ]; then
  echo "waiting for ComfyUI to come up before restarting it..."
  until curl -sf http://127.0.0.1:8188 >/dev/null; do sleep 10; done
  pkill -f "ComfyUI/main.py"; sleep 5
  export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  cd "$C" && setsid nohup $PY "$C/main.py" --listen --disable-smart-memory --disable-cuda-malloc \
    > /workspace/comfyui_addon.log 2>&1 < /dev/null &
  echo "ComfyUI restarted"
fi
echo "==== add-on finished $(date)"
