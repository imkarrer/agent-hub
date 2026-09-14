# stable-diffusion.cpp for a CPU-only x86 host: nixpkgs' package with the
# SIMD it forgets. Under Nix, ggml's GGML_NATIVE defaults OFF (SOURCE_DATE_EPOCH
# is set, so it will not -march=native), and sd.cpp's vendored ggml then
# leaves every x86 extension off unless asked -- nixpkgs' derivation does not
# ask. The result, verified on ac-box 14 Sep 2026 with `sd-cli -v`:
#
#   System Info: AVX = 0 | AVX2 = 0 | FMA = 0 | F16C = 0
#
# i.e. scalar matmuls, 570 s for a 512x512 Z-Image-Turbo at 8 steps. This
# turns on what every x86-64-v3 CPU has (AVX2/FMA/F16C) and nothing newer:
# ac-box is Broadwell, no AVX-512, and a binary built with it would SIGILL
# there. Same shape as nix/ik-llama-cpp.nix's reasoning about -march=native.
{ pkgs ? import <nixpkgs> { } }:

pkgs.stable-diffusion-cpp.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DGGML_AVX=ON"
    "-DGGML_AVX2=ON"
    "-DGGML_FMA=ON"
    "-DGGML_F16C=ON"
  ];
})
