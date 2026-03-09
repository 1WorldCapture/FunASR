#!/usr/bin/env bash
# ============================================================================
# FunASR Offline 模型一键下载脚本
#
# 功能：将 funasr-onnx-offline 所需的全部模型从 ModelScope 下载到指定目录
# 逻辑：
#   1. 目录不存在 → git clone
#   2. 目录已存在 → git pull
#   3. 自动检测 .gitattributes 中是否有 LFS 规则，按需执行 git lfs pull
#
# 用法：
#   bash download_models.sh [--model-dir <目录>] [--skip-itn] [--skip-lm]
#
# 示例：
#   bash download_models.sh --model-dir ./models
#   bash download_models.sh --model-dir /data/funasr_models --skip-itn
# ============================================================================

set -euo pipefail

# ─── 颜色定义 ────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# ─── 默认配置 ────────────────────────────────────────────────────────────────
MODEL_BASE_DIR="./models"
SKIP_ITN=false
SKIP_LM=false
MODELSCOPE_BASE_URL="https://www.modelscope.cn"

# ─── 模型定义 ────────────────────────────────────────────────────────────────
# 格式: "角色|Model ID|说明|必选/可选"
declare -a MODELS=(
  "ASR|manyeyes/paraformer-seaco-large-zh-timestamp-onnx-offline|SeacoParaformer 语音识别 + 时间戳 (ONNX)|必选"
  "VAD|damo/speech_fsmn_vad_zh-cn-16k-common-onnx|FSMN-VAD 语音活动检测 (ONNX)|推荐"
  "PUNC|damo/punc_ct-transformer_cn-en-common-vocab471067-large-onnx|CT-Transformer 标点恢复 (ONNX)|推荐"
  "ITN|thuduj12/fst_itn_zh|FST 反文本正则化|可选"
  "LM|damo/speech_ngram_lm_zh-cn-ai-wesp-fst|N-gram 语言模型 (WFST)|可选"
)

# ─── 用法说明 ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}FunASR Offline 模型一键下载脚本${RESET}

${BOLD}用法:${RESET}
  bash $0 [选项]

${BOLD}选项:${RESET}
  --model-dir <目录>    模型存放根目录 (默认: ./models)
  --skip-itn            跳过 ITN 模型 (macOS 不支持 ITN，建议跳过)
  --skip-lm             跳过 LM 语言模型
  -h, --help            显示帮助

${BOLD}示例:${RESET}
  bash $0 --model-dir ./models
  bash $0 --model-dir /data/funasr_models --skip-itn
EOF
  exit 0
}

# ─── 工具函数 ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
log_step()    { echo -e "${CYAN}[STEP]${RESET}  $*"; }
log_divider() { echo -e "${BOLD}────────────────────────────────────────────────────────────────${RESET}"; }

# ─── 前置检查 ─────────────────────────────────────────────────────────────────
check_prerequisites() {
  log_step "检查前置依赖..."

  if ! command -v git &>/dev/null; then
    log_error "未找到 git，请先安装 git"
    exit 1
  fi
  log_info "git: $(git --version)"

  if command -v git-lfs &>/dev/null; then
    log_info "git-lfs: $(git lfs version 2>/dev/null | head -1)"
    HAS_GIT_LFS=true
  else
    log_warn "未安装 git-lfs。如果模型仓库使用 LFS，大文件将无法正确下载"
    log_warn "安装方法: brew install git-lfs && git lfs install"
    HAS_GIT_LFS=false
  fi

  echo ""
}

# ─── 检查仓库是否使用 LFS ────────────────────────────────────────────────────
repo_uses_lfs() {
  local repo_dir="$1"

  # 检查 .gitattributes 是否存在且包含 lfs 规则
  local gitattributes="$repo_dir/.gitattributes"
  if [[ -f "$gitattributes" ]] && grep -q "filter=lfs" "$gitattributes" 2>/dev/null; then
    return 0  # true: 使用 LFS
  fi

  return 1  # false: 不使用 LFS
}

# ─── 列出 LFS 跟踪的文件模式 ────────────────────────────────────────────────
show_lfs_patterns() {
  local repo_dir="$1"
  local gitattributes="$repo_dir/.gitattributes"

  if [[ -f "$gitattributes" ]]; then
    log_info "LFS 跟踪的文件模式:"
    grep "filter=lfs" "$gitattributes" | awk '{print "    " $1}' || true
  fi
}

# ─── 检查 LFS 文件是否已正确拉取 ────────────────────────────────────────────
lfs_files_need_pull() {
  local repo_dir="$1"

  # 进入目录检查是否有 LFS pointer 还未被拉取为真实文件
  # LFS pointer 文件以 "version https://git-lfs.github.com/spec/" 开头
  local lfs_pointers
  lfs_pointers=$(cd "$repo_dir" && git lfs ls-files 2>/dev/null | grep -c "^[a-f0-9].* -" || true)

  if [[ "$lfs_pointers" -gt 0 ]]; then
    return 0  # true: 有未拉取的 LFS 文件
  fi

  return 1  # false: 所有 LFS 文件已拉取
}

# ─── 下载单个模型 ─────────────────────────────────────────────────────────────
download_model() {
  local role="$1"
  local model_id="$2"
  local description="$3"
  local required="$4"

  # 从 model_id 提取本地目录名 (取 / 后面的部分)
  local dir_name="${model_id##*/}"
  local local_dir="$MODEL_BASE_DIR/$dir_name"
  local clone_url="${MODELSCOPE_BASE_URL}/${model_id}.git"

  log_divider
  echo -e "  ${BOLD}[$role]${RESET} $description"
  echo -e "  Model ID : ${CYAN}$model_id${RESET}"
  echo -e "  本地路径  : ${CYAN}$local_dir${RESET}"
  echo -e "  状态     : $required"
  echo ""

  if [[ -d "$local_dir/.git" ]]; then
    # ── 已存在：git pull ──────────────────────────────────────────────
    log_info "仓库已存在，执行 git pull ..."
    (
      cd "$local_dir"
      git pull --ff-only 2>&1 | sed 's/^/    /'
    ) || {
      log_warn "git pull 失败（可能有本地修改），尝试 git fetch + reset ..."
      (
        cd "$local_dir"
        git fetch origin 2>&1 | sed 's/^/    /'
        git reset --hard origin/master 2>&1 | sed 's/^/    /' || \
        git reset --hard origin/main 2>&1 | sed 's/^/    /'
      )
    }
  elif [[ -d "$local_dir" ]]; then
    # 目录存在但不是 git 仓库
    log_warn "目录 $local_dir 存在但不是 git 仓库"
    log_warn "请手动删除后重新运行，或改用其他目录"
    return 1
  else
    # ── 不存在：git clone ─────────────────────────────────────────────
    log_info "开始克隆仓库 ..."
    git clone "$clone_url" "$local_dir" 2>&1 | sed 's/^/    /'
  fi

  # ── LFS 检测与拉取 ─────────────────────────────────────────────────
  if repo_uses_lfs "$local_dir"; then
    show_lfs_patterns "$local_dir"

    if [[ "$HAS_GIT_LFS" == "true" ]]; then
      if lfs_files_need_pull "$local_dir"; then
        log_info "检测到未拉取的 LFS 大文件，执行 git lfs pull ..."
        (cd "$local_dir" && git lfs pull 2>&1 | sed 's/^/    /')
      else
        log_info "LFS 文件已完整拉取 ✓"
      fi
    else
      log_warn "该仓库使用 Git LFS 管理大文件，但本机未安装 git-lfs！"
      log_warn "模型文件可能为 LFS pointer 而非真实数据，请安装后执行:"
      echo -e "    ${CYAN}cd $local_dir && git lfs pull${RESET}"
    fi
  else
    log_info "该仓库未使用 Git LFS ✓"
  fi

  log_info "[$role] 完成 ✓"
  echo ""
}

# ─── 参数解析 ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-dir)
      MODEL_BASE_DIR="$2"
      shift 2
      ;;
    --skip-itn)
      SKIP_ITN=true
      shift
      ;;
    --skip-lm)
      SKIP_LM=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "未知参数: $1"
      usage
      ;;
  esac
done

# ─── macOS 自动检测 ──────────────────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]] && [[ "$SKIP_ITN" == "false" ]]; then
  log_warn "检测到 macOS 系统，FunASR 的 ITN 模块在 macOS 上被禁用"
  log_warn "自动跳过 ITN 模型下载 (可通过去掉 --skip-itn 检测来覆盖)"
  SKIP_ITN=true
  echo ""
fi

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║        FunASR Offline 模型一键下载                          ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  模型存放目录: ${CYAN}${MODEL_BASE_DIR}${RESET}"
  echo -e "  跳过 ITN    : ${SKIP_ITN}"
  echo -e "  跳过 LM     : ${SKIP_LM}"
  echo ""

  check_prerequisites

  mkdir -p "$MODEL_BASE_DIR"

  local success_count=0
  local skip_count=0
  local fail_count=0

  for model_entry in "${MODELS[@]}"; do
    IFS='|' read -r role model_id description required <<< "$model_entry"

    # 跳过判断
    if [[ "$role" == "ITN" && "$SKIP_ITN" == "true" ]]; then
      log_info "跳过 [$role] $description"
      ((skip_count++))
      continue
    fi
    if [[ "$role" == "LM" && "$SKIP_LM" == "true" ]]; then
      log_info "跳过 [$role] $description"
      ((skip_count++))
      continue
    fi

    if download_model "$role" "$model_id" "$description" "$required"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
  done

  # ── 汇总报告 ───────────────────────────────────────────────────────
  log_divider
  echo ""
  echo -e "${BOLD}下载汇总:${RESET}"
  echo -e "  ${GREEN}成功: $success_count${RESET}"
  [[ $skip_count -gt 0 ]] && echo -e "  ${YELLOW}跳过: $skip_count${RESET}"
  [[ $fail_count -gt 0 ]] && echo -e "  ${RED}失败: $fail_count${RESET}"
  echo ""

  # ── 打印 funasr-onnx-offline 运行示例 ──────────────────────────────
  echo -e "${BOLD}运行示例:${RESET}"
  echo ""

  local asr_dir="$MODEL_BASE_DIR/paraformer-seaco-large-zh-timestamp-onnx-offline"
  local vad_dir="$MODEL_BASE_DIR/speech_fsmn_vad_zh-cn-16k-common-onnx"
  local punc_dir="$MODEL_BASE_DIR/punc_ct-transformer_cn-en-common-vocab471067-large-onnx"

  echo -e "  ${CYAN}./funasr-onnx-offline \\\\${RESET}"
  echo -e "  ${CYAN}  --model-dir $asr_dir \\\\${RESET}"
  echo -e "  ${CYAN}  --quantize  false \\\\${RESET}"
  echo -e "  ${CYAN}  --vad-dir   $vad_dir \\\\${RESET}"
  echo -e "  ${CYAN}  --punc-dir  $punc_dir \\\\${RESET}"
  echo -e "  ${CYAN}  --wav-path  test.wav${RESET}"
  echo ""

  if [[ $fail_count -gt 0 ]]; then
    exit 1
  fi
}

main
