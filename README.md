# Mirage

A native macOS app for generating images and video on your own Mac with MLX. Nothing is sent to a server: models download once from Hugging Face and run on the Apple Silicon GPU.

![Mirage's Create screen](docs/screenshot.jpg)

## What it does

- **Images:** text to image, image to image and instruction-based editing with FLUX, Z-Image, Qwen Image, Krea and other models supported by [mflux](https://github.com/filipstrand/mflux).
- **Video:** LTX-2.3 / LTX-2.5 through [ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx) and Wan 2.x through [mlx-video](https://github.com/Blaizzy/mlx-video), from text, an image or an audio track.
- **Upscaling:** enlarge any image up to 4× with the optional SeedVR2 upscaler, with adjustable scale, softness, precision and tile size.
- **Fits the Mac it runs on:** reads the machine's memory, recommends the model variant that fits (4-bit on small Macs, full precision on large ones), switches on low-memory modes automatically and shows what each generation will need before it starts. Every limit can be raised by hand.
- **Hugging Face browser:** live search of MLX image and video models, per-file selection, pause and resume, and a choice of where models are stored.
- **Liquid Glass interface:** top toolbar, queue, gallery with search and favourites, prompt history, style presets and a full-window viewer.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Xcode 26 or later (Swift 6.2) to build

## Build

```bash
Scripts/build.sh --install
```

This builds `build/Mirage.app`, copies it to `/Applications` and opens it. Use `Scripts/build.sh --open` to run it without installing.

The app is signed ad hoc, not notarized, so another Mac will ask you to allow it under System Settings → Privacy & Security.

## How it works

Mirage is a SwiftUI front end. The model work is done by three Python engines, each installed on demand into its own private environment under `~/Library/Application Support/Mirage/engines` using [uv](https://github.com/astral-sh/uv) (downloaded automatically if it is missing). Models are kept in the standard Hugging Face cache unless you choose another folder.

| Engine | Used for |
|---|---|
| `mflux` | image generation, editing and upscaling |
| `ltx-2-mlx` | LTX video with sound |
| `mlx-video` | Wan video |

## Headless checks

The binary has test commands that exercise the core without the window:

```bash
swift build
.build/debug/Mirage --selftest system
.build/debug/Mirage --selftest search "flux"
.build/debug/Mirage --selftest download mflux-community/flux2-klein-4b-mflux-q4
.build/debug/Mirage --selftest generate mflux-community/flux2-klein-4b-mflux-q4 "a red fox in snow" 768 768
```

## Status

Developed and tested on an M5 with 16 GB. Image generation, editing and 2× upscaling have been run end to end. The video engines are wired up and their command lines are checked, but no video has been generated end to end yet.

Models and engines belong to their authors and carry their own licences; check each model's page before commercial use.
