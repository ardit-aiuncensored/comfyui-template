#!/bin/bash
# AI Uncensored add-on setup.
# Adds: newer ComfyUI, extra custom nodes, MiniMax H3 + other models, workflows, settings.
# Safe to re-run: skips anything already done.

# Models to leave out, even if they are listed in models_addon.txt (space-separated filenames)
SKIP_MODELS="minimax_h3_ref2va_pruned_int8.safetensors"

REPO="${SETUP_REPO:?SETUP_REPO is not set in the template}"
BRANCH="${SETUP_BRANCH:-main}"
C=/workspace/ComfyUI
if [ -x /opt/venv/bin/python3 ]; then PY=/opt/venv/bin/python3; else PY=python3; fi
pipi() { $PY -m pip install -q "$@" </dev/null || uv pip install --python "$PY" "$@" </dev/null; }
echo "==== add-on started $(date)"

# 1. Wait for the image to finish moving ComfyUI onto the volume (can take a while)
echo "waiting for ComfyUI to be ready on the volume..."
until [ -f "$C/main.py" ] && ! pgrep -f "mv /ComfyUI" >/dev/null; do sleep 15; done
echo "ComfyUI is on the volume"

# 2. Download this repo
T=/tmp/addon; rm -rf "$T"; mkdir -p "$T"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$T" --strip-components=1 \
  || { echo "Could not download repo $REPO"; exit 1; }
CHANGED=0

# 3. ComfyUI version (MiniMax H3 needs a newer ComfyUI than the image ships)
CV=$(tr -d '[:space:]' < "$T/comfy_version.txt")
if [ -n "$CV" ] && [ "$(git -C "$C" rev-parse HEAD 2>/dev/null)" != "$CV" ]; then
  git -C "$C" fetch -q origin </dev/null && git -C "$C" checkout -q "$CV" </dev/null \
    && pipi -r "$C/requirements.txt" && CHANGED=1 && echo "ComfyUI set to $CV"
fi

# 4. Custom nodes, pinned to the tested versions (nodes.txt: name url commit)
while read -r NAME URL COMMIT; do
  [ -z "${NAME:-}" ] && continue
  D="$C/custom_nodes/$NAME"
  if [ ! -d "$D" ]; then
    echo "installing node: $NAME"
    git clone -q "$URL" "$D" </dev/null || { echo "FAILED node $NAME"; continue; }
  elif [ ! -d "$D/.git" ] || [ "$(git -C "$D" rev-parse HEAD)" = "$COMMIT" ]; then
    continue
  else
    echo "updating node: $NAME"
    git -C "$D" fetch -q origin </dev/null
  fi
  git -C "$D" checkout -q "$COMMIT" </dev/null || echo "WARN: $NAME commit not found, kept current version"
  [ -f "$D/requirements.txt" ] && pipi -r "$D/requirements.txt"
  CHANGED=1
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
  echo "downloading: $FI"
  if ! aria2c -q -x 16 -s 16 -k 1M -c -d "$D" -o "$FI" "$U" </dev/null; then
    echo "retrying: $FI"
    rm -f "$D/$FI" "$D/$FI.aria2"
    if curl -fsSL --retry 3 -o "$D/$FI.part" "$U" </dev/null; then
      mv "$D/$FI.part" "$D/$FI"
    else
      rm -f "$D/$FI.part"; echo "FAILED $FI"
    fi
  fi
  CHANGED=1
done < "$T/models_addon.txt"

# 7. Restart ComfyUI once the image has started it, so it loads everything above
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
