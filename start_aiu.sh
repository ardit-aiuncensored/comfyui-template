#!/usr/bin/env bash

TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"


if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Run from / so JupyterLab and pip never sit inside /ComfyUI, which gets moved
# to the volume below (that broke new Jupyter terminals and a pip install).
cd /

# Files on network volumes are owned by "nobody", so git refuses to work in
# them ("dubious ownership") unless told to trust them.
git config --global --add safe.directory '*'

NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

if [ ! -d "$NETWORK_VOLUME" ]; then
    echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
    NETWORK_VOLUME="/"
    echo "NETWORK_VOLUME directory doesn't exist. Starting JupyterLab on root directory..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
else
    echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
fi

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"

CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

CRT_REQS="$CUSTOM_NODES_DIR/CRT-Nodes/requirements.txt"
if [ -f "$CRT_REQS" ] && grep -q '^[[:space:]]*pedalboard[[:space:]]*$' "$CRT_REQS"; then
    sed -i '/^[[:space:]]*pedalboard[[:space:]]*$/d' "$CRT_REQS"
    echo "Removed pedalboard from CRT-Nodes requirements (crashes on some hosts)."
fi
if python3 -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('pedalboard') else 1)" 2>/dev/null; then
    pip uninstall -y pedalboard >/dev/null 2>&1         && echo "Uninstalled pedalboard (illegal-instruction crash on some CPUs)."
fi

if [ ! -d "$COMFYUI_DIR" ]; then
    mv /ComfyUI "$COMFYUI_DIR"
else
    echo "Directory already exists, skipping move."
fi

pip install onnxruntime-gpu &


export change_preview_method="true"


cd "$CUSTOM_NODES_DIR" || exit 1

download_model() {
    local url="$1"
    local full_path="$2"
    local min_bytes="${3:-10485760}"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # A .aria2 file means an earlier download was interrupted. aria2 reserves the
    # full file size up front, so the file can look complete when it isn't.
    # Check for .aria2 first and resume it, rather than skipping or deleting it.
    if [ -f "${full_path}.aria2" ]; then
        echo "⏯️  Resuming unfinished download: $destination_file"
    elif [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt "$min_bytes" ]; then
            echo "🗑️  Deleting corrupted file (${size_bytes}B < ${min_bytes}B): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    aria2c -x 16 -s 16 -k 1M --continue=true --max-tries=20 --retry-wait=15 --timeout=60 --connect-timeout=30 \
        -d "$destination_dir" -o "$destination_file" "$url" &

    echo "Download started in background for $destination_file"
}

CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

download_civitai() {
    local version_id="$1"
    local full_path="$2"
    local file_id="$3"   # optional; pins which file when a version ships more than one
    local min_bytes="$4" # optional; see download_model

    if [ -z "$CIVITAI_TOKEN" ]; then
        echo "⚠️  CIVITAI_TOKEN not set — skipping $(basename "$full_path")."
        echo "    Create a key at https://civitai.com/user/account and pass it to the container."
        return 0
    fi

    local url="https://civitai.com/api/download/models/${version_id}?token=${CIVITAI_TOKEN}"
    [ -n "$file_id" ] && url="${url}&fileId=${file_id}"

    download_model "$url" "$full_path" "$min_bytes"
}

DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
UNET_DIR="$NETWORK_VOLUME/ComfyUI/models/unet"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
CLIP_DIR="$NETWORK_VOLUME/ComfyUI/models/clip"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
CHECKPOINTS_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints"
UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/upscale_models"
LATENT_UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/latent_upscale_models"
SAMS_DIR="$NETWORK_VOLUME/ComfyUI/models/sams"
ULTRALYTICS_BBOX_DIR="$NETWORK_VOLUME/ComfyUI/models/ultralytics/bbox"
HUMANPARTS_DIR="$NETWORK_VOLUME/ComfyUI/models/onnx/human-parts"

echo "📦 Starting model downloads..."

download_model "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_fp8_scaled.safetensors" "$DIFFUSION_MODELS_DIR/krea2_turbo_fp8_scaled.safetensors"

download_model "https://huggingface.co/lilcheaty/Krea2-INT8-ConvRot/resolve/main/Krea2-Turbo-int8-ConvRot.safetensors" "$DIFFUSION_MODELS_DIR/krea2_turbo_int8_convrot.safetensors"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/RawGirlKrea2_v10_int8_convrot.safetensors" "$DIFFUSION_MODELS_DIR/rawgirlKrea2INT8_v10.safetensors"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/Beyondrealism2.safetensors" "$DIFFUSION_MODELS_DIR/Beyondrealism2.safetensors"

download_model "https://huggingface.co/Comfy-Org/Qwen3-VL/resolve/b58e627c376915e49cb6bba978416085aa31767f/text_encoders/qwen3vl_4b_bf16.safetensors" "$CLIP_DIR/qwen3vl_4b_bf16.safetensors"

download_model "https://huggingface.co/Comfy-Org/Qwen3-VL/resolve/b58e627c376915e49cb6bba978416085aa31767f/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" "$CLIP_DIR/qwen3vl_4b_fp8_scaled.safetensors"

download_model "https://huggingface.co/dci05049/wan-animate/resolve/main/wan_2.1_vae.safetensors" "$VAE_DIR/wan_2.1_vae.safetensors"

download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/flux-2-klein-9b.safetensors" "$DIFFUSION_MODELS_DIR/flux-2-klein-9b.safetensors"

download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/flux2-vae.safetensors" "$VAE_DIR/flux2-vae.safetensors"

download_model "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors" "$CLIP_DIR/qwen_3_8b_fp8mixed.safetensors"

download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/f2k_9B_lcs_consist_20260415.safetensors" "$LORAS_DIR/f2k_9B_lcs_consist_20260415 (1).safetensors"
download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/Samsung_fluxklein9b.safetensors" "$LORAS_DIR/Samsung_fluxklein9b.safetensors"
download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/Klein_realistic_I2I.safetensors" "$LORAS_DIR/Klein_realistic_I2I.safetensors"
download_model "https://huggingface.co/dci05049/flux2-klein-9b/resolve/main/HighResolution9B.safetensors" "$LORAS_DIR/HighResolution9B.safetensors"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/Eyeful_v2-Individual.pt" "$ULTRALYTICS_BBOX_DIR/Eyeful_v2-Individual.pt"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/Eyeful_v2-Paired.pt" "$ULTRALYTICS_BBOX_DIR/Eyeful_v2-Paired.pt"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/deeplabv3p-resnet50-human.onnx" "$HUMANPARTS_DIR/deeplabv3p-resnet50-human.onnx"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/1x-ITF-SkinDiffDetail-Lite-v1.pth" "$UPSCALE_DIR/1x-ITF-SkinDiffDetail-Lite-v1.pth"

download_model "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" "$SAMS_DIR/sam_vit_b_01ec64.pth"

download_model "https://huggingface.co/Comfy-Org/sam3.1/resolve/main/checkpoints/sam3.1_multiplex_fp16.safetensors" "$CHECKPOINTS_DIR/sam3.1_multiplex_fp16.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/1xSkinContrast-High-SuperUltraCompact.pth" "$UPSCALE_DIR/1xSkinContrast-High-SuperUltraCompact.pth"

download_model "https://huggingface.co/dci05049/krea2/resolve/main/skindetails_krea2_loraholic.safetensors" "$LORAS_DIR/skindetails_krea2_loraholic.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/ass_v2_krea2_loraholic.safetensors" "$LORAS_DIR/ass_v2_krea2_loraholic.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/breast_size_v2_krea2_loraholic.safetensors" "$LORAS_DIR/breast_size_v2_krea2_loraholic.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/candid_krea2_loraholic.safetensors" "$LORAS_DIR/candid_krea2_loraholic.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/real_3d_krea2_loraholic.safetensors" "$LORAS_DIR/real_3d_krea2_loraholic.safetensors" 1048576
download_model "https://huggingface.co/dci05049/krea2/resolve/main/RawGirlV2_epoch_10.safetensors" "$LORAS_DIR/RawGirlV2_epoch_10.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/RawGirlV2Spicy_epoch_10.safetensors" "$LORAS_DIR/RawGirlV2Spicy_epoch_10.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/Krea2_TextFusion_Refusal_Reduction.safetensors" "$LORAS_DIR/Krea2_TextFusion_Refusal_Reduction.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/Krea2-realism-V1.safetensors" "$LORAS_DIR/Krea2-realism-V1.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/SummerVibesHM_krea2_epoch8.safetensors" "$LORAS_DIR/SummerVibesHM_krea2_epoch8.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/bloomgirls-ultrarealism-krea2_4k.safetensors" "$LORAS_DIR/bloomgirls-ultrarealism-krea2_4k.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/lenovo_krea2.safetensors" "$LORAS_DIR/lenovo_krea2.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/michelle%20krea%202_000003000.safetensors" "$LORAS_DIR/michelle_krea_2_000003000.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/snofs_krea_v1.safetensors" "$LORAS_DIR/snofs_krea_v1.safetensors"
download_model "https://huggingface.co/dci05049/krea2/resolve/main/RealisticSnapshotKrea2.safetensors" "$LORAS_DIR/RealisticSnapshotKrea2.safetensors"

download_model "https://huggingface.co/Patil/Krea-2-depth-controlnet/resolve/main/depth-control-lora.safetensors" "$LORAS_DIR/depth-control-lora.safetensors"

download_civitai 3156053 "$LORAS_DIR/RawGirlV3.safetensors" 3036870

download_civitai 3141485 "$LORAS_DIR/RawGirlSpicyV3.safetensors" 3021786


echo "Installing AI Uncensored extras..."
curl -fsSL "https://raw.githubusercontent.com/$SETUP_REPO/main/addon.sh" -o /addon.sh && ADDON_NO_RESTART=1 bash /addon.sh 2>&1 | tee -a /workspace/addon.log
while pgrep -x "aria2c" > /dev/null; do
    echo "Models are downloading (In Progress)"
    sleep 5  # Check every 5 seconds
done

echo "All models downloaded successfully"

cd /

if [ "$change_preview_method" == "true" ]; then
    echo "Updating default preview method..."
    CONFIG_PATH="/ComfyUI/user/default/ComfyUI-Manager"
    CONFIG_FILE="$CONFIG_PATH/config.ini"

mkdir -p "$CONFIG_PATH"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.ini..."
    cat <<EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/Comfy-Org/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi
echo "Config file setup complete!"
    echo "Default preview method updated to 'auto'"
else
    echo "Skipping preview method update (change_preview_method is not 'true')."
fi

echo "cd $NETWORK_VOLUME" >> ~/.bashrc

echo "Renaming loras downloaded as zip files to safetensors files"
mkdir -p "$LORAS_DIR"
cd "$LORAS_DIR"
for file in *.zip; do
    [ -f "$file" ] || continue
    mv "$file" "${file%.zip}.safetensors"
done

echo "Starting ComfyUI"

export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

nohup python3 "$NETWORK_VOLUME/ComfyUI/main.py" --listen --disable-smart-memory --disable-cuda-malloc > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &

    counter=0
    max_wait=45

    until curl --silent --fail "$URL" --output /dev/null; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI is still starting. Check the startup log in /workspace."
            break
        fi

        echo "🔄  ComfyUI Starting Up... You can view the startup logs here: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
        sleep 2
        counter=$((counter + 2))
    done

    if curl --silent --fail "$URL" --output /dev/null; then
        echo "🚀 ComfyUI is UP"
    fi

    sleep infinity
