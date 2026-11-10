#!/bin/bash
# 10.11 (слово користувача): чи всі можливості заліза використовуємо. Рушії LM Studio зібрані під AVX2, а Ryzen 5 7600X
# (Zen 4) має AVX-512 (+VNNI, BF16) — на CPU працюють експерти Q4/flint (-ncmoe) і зір. Власна збірка llama.cpp:
# GGML_NATIVE (усе, що вміє цей процесор) + ядра CUDA саме під RTX 5060 Ti (sm_120). flint у llama.cpp — з b11803 (21.10.2026).
# Потрібно (ставить користувач): sudo apt install cmake cuda-toolkit-13-1
# Збирає в ~/llama.cpp-native/<тег>/build/bin, посилання ~/llama.cpp-native/current. ~10–15 хв на 12 потоках.
# Не запускати під час прогону стенду: збірка забирає всі ядра CPU, а Q4/flint рахують на них експертів.
set -eu
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду"; exit 1;; esac; done 2>/dev/null
NVCC=$(command -v nvcc || ls /usr/local/cuda*/bin/nvcc 2>/dev/null | sort -V | tail -1 || true)
[ -x "${NVCC:-}" ] || { echo "== немає nvcc: sudo apt install cuda-toolkit-13-1"; exit 1; }
command -v cmake >/dev/null || { echo "== немає cmake: sudo apt install cmake"; exit 1; }
TAG="${TAG:-$(git ls-remote --tags https://github.com/ggml-org/llama.cpp.git 'refs/tags/b*' | grep -oE 'b[0-9]+$' | sort -V | tail -1)}"
[ "${TAG#b}" -ge 11803 ] || { echo "== $TAG старіший за b11803 — без flint"; exit 1; }
R="$HOME/llama.cpp-native"; S="$R/$TAG"; mkdir -p "$R"
echo "== $(date '+%F %T') llama.cpp $TAG, nvcc $("$NVCC" --version | grep -oE 'release [0-9.]+')"
[ -d "$S/.git" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$S"
cmake -S "$S" -B "$S/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_COMPILER="$NVCC" \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF > "$R/cmake-$TAG.log"
grep -iE "AVX512|CUDA Toolkit|architectures" "$R/cmake-$TAG.log" | head -5 || true
cmake --build "$S/build" -j"$(nproc)" --target llama-server > "$R/build-$TAG.log" 2>&1 || { tail -20 "$R/build-$TAG.log"; exit 1; }
ln -sfn "$S/build/bin" "$R/current"
"$R/current/llama-server" --version 2>&1 | tail -2
echo "== $(date '+%F %T') готово: $R/current/llama-server"
