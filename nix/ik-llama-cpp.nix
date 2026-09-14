# ik_llama.cpp: ikawrakow's llama.cpp fork with much faster CPU matrix
# kernels (iqk_mul_mat, fused MoE). Measured on ac-box, 14 Sep 2026, against
# Qwen3-Coder-Next Q8_0 with the pages interleaved across both NUMA nodes and
# 23 threads on physical cores 3-25: prefill 121 tok/s and generation 12.5
# tok/s, versus 30 / 5.8 for nixpkgs' llama-cpp (b9190) on the same pages and
# cores. The deployed unit measured 17 / 4.5 before this work. Full table in
# docs/prefill-tuning.md.
#
# Built the way the fork's own .devops/nix/package.nix builds it, minus BLAS
# (the iqk kernels are the point; OpenBLAS would take the f32 matmuls away
# from them) and minus curl (the server never fetches models). GGML_NATIVE is
# OFF there, so this is a generic AVX2/FMA/F16C binary, not -march=native of
# whatever built it -- ac-box is Broadwell (E5-2680 v4) with no AVX-512, and
# the WSL2 box that usually builds this is something else entirely.
#
# Pinned by commit, not tag: the fork does not cut releases. Bump REV and the
# hash together; qwen3next support (this model's hybrid Gated-DeltaNet +
# attention architecture) is in from well before this rev.
{ pkgs ? import <nixpkgs> { } }:

let
  src = pkgs.fetchFromGitHub {
    owner = "ikawrakow";
    repo = "ik_llama.cpp";
    rev = "3bb386eb68ffee0a5dc7db21da0735d594929eeb"; # main, 10 Sep 2026
    hash = "sha256-UTFC+7nTg28SgXabzpgNK93NsheCSQVdl8R7Y1vKARA=";
  };
  scope = pkgs.callPackage "${src}/.devops/nix/scope.nix" { llamaVersion = "3bb386e"; };
in
scope.llama-cpp.override {
  useBlas = false;
  enableCurl = false;
}
