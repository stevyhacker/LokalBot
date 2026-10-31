# Third-Party Software Notices

LokalBot includes or links software developed by third parties. The source and
binary release are governed by LokalBot's GPL-3.0 license, while each component
below remains subject to its own license and copyright notices.

Versions are locked in
`LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
the vendor fetch scripts, and `AgentRuntimeManifest`. The Linux and Windows app
has its own section, [LokalBot for Linux and Windows](#lokalbot-for-linux-and-windows).

| Component | License | Source |
| --- | --- | --- |
| FluidAudio | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| WhisperKit / ArgmaxCore | MIT | https://github.com/argmaxinc/WhisperKit |
| speech-swift / Qwen3Speech | Apache-2.0 | https://github.com/soniqo/speech-swift |
| Sparkle | BSD-3-Clause | https://github.com/sparkle-project/Sparkle |
| LaunchAtLogin-Modern | MIT | https://github.com/sindresorhus/LaunchAtLogin-Modern |
| swift-argument-parser, swift-log, SwiftNIO and related Apple Swift packages | Apache-2.0 | https://github.com/apple |
| MLX Swift | MIT | https://github.com/ml-explore/mlx-swift |
| mlx-audio Granite 5 inference and audio frontend (adapted to Swift) | MIT | https://github.com/Blaizzy/mlx-audio/tree/0d3ad3c58220a0ceb4b09b07734b7ba07439d420/mlx_audio/stt/models/granite_speech5_ctc |
| Cotabby (portions of the Autocomplete engine, ported and modified) | AGPL-3.0 | https://github.com/FuJacob/cotabby |
| Hugging Face Swift libraries | Apache-2.0 | https://github.com/huggingface |
| Hummingbird and related packages | Apache-2.0 | https://github.com/hummingbird-project |
| EventSource | MIT | https://github.com/mattt/EventSource |
| yyjson | MIT | https://github.com/ibireme/yyjson |
| llama.cpp | MIT | https://github.com/ggml-org/llama.cpp |
| DigUpKit (DigUp's file crawler, readers, index and search, used by Files; image sizing ported to Swift in LokalBot) | MIT | https://github.com/ARahim3/DigUp |
| sherpa-onnx | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime | MIT | https://github.com/microsoft/onnxruntime |
| Sample meeting recordings (bundled; a fictional script voiced in English with the ElevenLabs Eleven v4 premade voices "Bella" and "Chris", and in German, Simplified Chinese and Serbian with Gemini 3.8 Flash TTS voices) | Generated audio used under the ElevenLabs Terms of Service and the Gemini API Terms of Service; scripts GPL-3.0 as part of LokalBot | `LokalBot/Resources/SampleMeeting/README.md` |
| Bun (optional Agent Mode runtime; it statically links JavaScriptCore, under LGPL-2, as its `LICENSE.md` describes) | MIT | https://github.com/oven-sh/bun |
| pi agent packages (optional, installed on request) | MIT | https://github.com/earendil-works/pi |
| LFM models (downloaded on request) | LFM Open License v1.0 | https://docs.liquid.ai/lfm/help/model-license |
| Parakeet Ultra (downloaded on request; moondream post-training of NVIDIA Parakeet v3, Core ML conversion by FluidInference) | CC-BY-4.0 | https://huggingface.co/moondream/parakeet-ultra / https://huggingface.co/FluidInference/parakeet-ultra-coreml |
| EmbeddingGemma 2 (downloaded on first use of search by meaning, and its image and audio projector when Files is turned on; ggml-org's GGUF conversion) | Apache-2.0 | https://huggingface.co/google/embeddinggemma-2 / https://huggingface.co/ggml-org/embeddinggemma-2-GGUF |
| Granite Speech 5.0 2B (downloaded on request; official IBM GGUF and projector) | Apache-2.0 | https://huggingface.co/ibm-granite/granite-speech-5.0-2b / https://huggingface.co/ibm-granite/granite-speech-5.0-2b-GGUF |

Downloaded AI models are not bundled with LokalBot. Each model remains subject
to the license shown by its publisher; review that license before downloading
or using a model, especially in a commercial setting. LFM's terms include a
commercial-use revenue threshold and redistribution notice obligations; users
outside those terms must obtain a separate license from Liquid AI.

## Cotabby (GNU AGPL v3.0)

Parts of LokalBot's Autocomplete engine were ported from Cotabby, copyright the
Cotabby authors (https://github.com/FuJacob/cotabby), and have been modified for
LokalBot since 23 June 2026. Those parts remain under the GNU Affero General
Public License version 3. Its full text is in `LICENSES/AGPL-3.0.txt` and ships
in the app bundle beside this notice.

Section 13 of both GPL-3.0 and AGPL-3.0 permits combining code under the two
licenses into one work. LokalBot's own code stays under GPL-3.0, and AGPL-3.0's
section 13 requirements on interaction through a network apply to the
combination as such. The complete corresponding source is published at
https://github.com/stevyhacker/LokalBot.

Each file that contains ported Cotabby code starts with a header naming Cotabby
and the date LokalBot's modifications began:

- `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (the `AXBoundsForRange` lookup)
- `LokalBot/Cotyping/CotypingAXHelper.swift`
- `LokalBot/Cotyping/CotypingBrowserDomain.swift`
- `LokalBot/Cotyping/CotypingClipboardContext.swift`
- `LokalBot/Cotyping/CotypingCoordinator.swift`
- `LokalBot/Cotyping/CotypingEmoji.swift`
- `LokalBot/Cotyping/CotypingFieldStyle.swift`
- `LokalBot/Cotyping/CotypingFocusTracker.swift`
- `LokalBot/Cotyping/CotypingInputMonitor.swift`
- `LokalBot/Cotyping/CotypingInserter.swift`
- `LokalBot/Cotyping/CotypingMacro.swift`
- `LokalBot/Cotyping/CotypingMidWord.swift`
- `LokalBot/Cotyping/CotypingPrefixWindow.swift`
- `LokalBot/Cotyping/CotypingPromptRenderer.swift`
- `LokalBot/Cotyping/CotypingRenderMode.swift`
- `LokalBot/Cotyping/CotypingSeamGuard.swift`
- `LokalBot/Cotyping/CotypingSpellChecker.swift`
- `LokalBot/Cotyping/CotypingSurfaceContext.swift`
- `LokalBot/Cotyping/CotypingTextNormalizer.swift`
- `LokalBot/Cotyping/CotypingTypo.swift`

The Linux and Windows app (`LinuxWindows/`) ports the same code to Rust, with
the same header, in:

- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/emoji.rs`
- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/normalize.rs`
- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/prompt.rs`
- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/seam.rs`
- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/surface.rs`
- `LinuxWindows/crates/lokalbot-ai/src/autocomplete/window.rs`
- `LinuxWindows/crates/lokalbot-app/src/autocomplete/layout.rs`
- `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs`
- `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/win32.rs`
- `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs`

## LokalBot for Linux and Windows

The Linux and Windows app is built from `LinuxWindows/` into two programs,
`lokalbot` and `lokalbot-cli`. Its archives, Linux packages and Windows
installer carry this file and the `LICENSES/` folder beside the programs; the
Linux packages install them in `/usr/share/doc/lokalbot`. `LICENSES/` holds
the text of each license named below by its SPDX identifier (for example
`LICENSES/MIT.txt`), and LokalBot's own GPL-3.0 text is in `LICENSE` (the
packages' copyright or license file). Model licenses without an SPDX
identifier are linked instead.

### Rust crates

[`LICENSES/rust-crates.md`](LICENSES/rust-crates.md) lists every Rust crate
compiled into the two programs for x86_64 Linux and Windows, each with the
license it is used under and that license's text and copyright notices as the
crate ships them. cargo-about generates it from `LinuxWindows/Cargo.lock`
(the repository's [RELEASING.md](RELEASING.md#third-party-licenses) has the
command). It includes GPUI, Zed's UI framework (the `gpui-pre-*`
crates, Apache-2.0), GPUI Kit (Apache-2.0), rusqlite with SQLite compiled in
(SQLite is in the public domain), rustls and ring, cpal, keyring, zbus and
ashpd, x11rb, enigo, arboard, image, ocrs and rten, and Symphonia (MPL-2.0).
The MPL-2.0 crates are used unmodified, and their source code is available
from crates.io at the versions listed.

The Rust standard library is compiled into both programs as well. It is
available under MIT or Apache-2.0, as is most of what it is built from; see
https://github.com/rust-lang/rust/blob/master/COPYRIGHT.

### Native libraries linked into the programs

The `sherpa-onnx` crate, through `sherpa-onnx-sys`, links the static
libraries that k2-fsa publishes with sherpa-onnx 1.13.8
(`sherpa-onnx-v1.13.8-linux-x64-static-lib.tar.bz2` and
`sherpa-onnx-v1.13.8-win-x64-static-MT-Release-lib.tar.bz2`). sherpa-onnx's
`cmake/` folder at that version names the source of each component they
contain:

| Component | Version | License | Source |
| --- | --- | --- | --- |
| sherpa-onnx | 1.13.8 | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime (static build from csukuangfj/onnxruntime-libs) | 1.28.2 | MIT; the third-party components it can include are listed in `LICENSES/onnxruntime-ThirdPartyNotices.txt` | https://github.com/microsoft/onnxruntime |
| kaldi-native-fbank | 1.22.3 | Apache-2.0 | https://github.com/csukuangfj/kaldi-native-fbank |
| KISS FFT | commit febd4ca | BSD-3-Clause | https://github.com/mborgerding/kissfft |
| kaldi-decoder | 0.3.0 | Apache-2.0 | https://github.com/k2-fsa/kaldi-decoder |
| kaldifst | 1.8.0 | Apache-2.0 | https://github.com/k2-fsa/kaldifst |
| OpenFst (fork) | v1.8.5-2026-07-09 | Apache-2.0 | https://github.com/csukuangfj/openfst |
| simple-sentencepiece | 0.7 | Apache-2.0 | https://github.com/pkufool/simple-sentencepiece |
| fastcluster (hclust-cpp) | 2026-02-25 | BSD-2-Clause | https://github.com/csukuangfj/hclust-cpp |
| Eigen | 5.0.1 | MPL-2.0 | https://gitlab.com/libeigen/eigen |
| JSON for Modern C++ | 3.12.0 | MIT | https://github.com/nlohmann/json |
| piper-phonemize (fork) | commit f3ff95a | MIT | https://github.com/csukuangfj/piper-phonemize |
| eSpeak NG (fork), with ucd-tools | commit ed530aa | GPL-3.0-or-later; the Unicode data it includes is under the Unicode license (`LICENSES/Unicode-DFS-2016.txt`) | https://github.com/csukuangfj/espeak-ng |

eSpeak NG and piper-phonemize belong to sherpa-onnx's text-to-speech code.
LokalBot doesn't use it, but the sherpa-onnx library links it. eSpeak NG's
"or later" terms allow it to be distributed under GPL-3.0, LokalBot's license,
and its complete source is at the commit above.

Copyright notices for these libraries:

- ONNX Runtime: Copyright (c) Microsoft Corporation.
- KISS FFT: Copyright (c) 2003-2010 Mark Borgerding. All rights reserved.
- fastcluster: © 2011 Daniel Müllner (`fastcluster_dm.cpp`,
  `fastcluster_R_dm.cpp`); © 2018 Christoph Dalitz (`fastcluster.h`,
  `fastcluster.cpp`). All rights reserved.
- JSON for Modern C++: Copyright (c) 2013-2025 Niels Lohmann.
- piper-phonemize: Copyright (c) 2023 Michael Hansen.
- eSpeak NG: Copyright (C) 2005 to 2014 Jonathan Duddington; Copyright (C)
  2015-2017 Reece H. Dunn; and the eSpeak NG contributors. ucd-tools:
  Copyright (C) 2012-2018, 2021 Reece H. Dunn. Unicode data: Copyright ©
  1991-2018 Unicode, Inc.

On Linux, `freetype-sys` compiles its bundled FreeType (FreeType License or
GPL-2.0-or-later) only when the build machine has no FreeType of its own; the
release builds contain no FreeType code. Libraries the programs load from the
system at run time (the C and C++ runtimes, ALSA, X11 and Wayland libraries,
the Vulkan loader) are not distributed with LokalBot, apart from the Visual C++
runtime below.

### Microsoft Visual C++ runtime (Windows)

The Windows archive and installer include `msvcp140.dll`, `vcruntime140.dll`
and `vcruntime140_1.dll` from the Microsoft Visual C++ Redistributable,
unmodified, in the `vc-runtime` folder. LokalBot's own programs link the C
runtime statically and don't use them: it copies them beside each
`llama-server.exe` it downloads, so llama.cpp also runs where the Visual C++
Redistributable isn't installed. They are Copyright (c) Microsoft Corporation
and are distributed as Distributable Code under the Microsoft Visual Studio
license terms (https://learn.microsoft.com/visualstudio/releases/2022/redistribution),
not under LokalBot's license. Anyone who distributes them further must keep
them unmodified and bind the people they distribute them to under terms that
protect them at least as much as Microsoft's own terms.

### Assets compiled into the app

| Asset | License | Copyright and source |
| --- | --- | --- |
| Inter 4.001, the interface font | OFL-1.1 | Copyright 2016 The Inter Project Authors, https://github.com/rsms/inter |
| Lucide icons, through GPUI Kit's `gpui-kit-assets` | ISC | Copyright (c) 2026 Lucide Icons and Contributors, https://github.com/lucide-icons/lucide |
| Lucide icons derived from Feather (listed in `LICENSES/rust-crates.md` under `gpui-kit-assets`) | MIT | Copyright (c) 2013-present Cole Bemis, https://github.com/feathericons/feather |

### Downloaded on request

The app doesn't include any AI model. It downloads the ones below when you
choose them, or when you turn on a feature that needs them, and each stays
under the license of the model it comes from. The speech models are
sherpa-onnx's ONNX conversions from its `asr-models`,
`speaker-segmentation-models` and `speaker-recongition-models` releases
(https://github.com/k2-fsa/sherpa-onnx/releases), the ocrs models come from
ocrs's own storage, and the text models come from Hugging Face, pinned to a
revision.

| Model | Used for | License | Source |
| --- | --- | --- | --- |
| Qwen3-ASR 0.6B (int8) | transcription (default) | Apache-2.0 | https://huggingface.co/Qwen/Qwen3-ASR-0.6B |
| Parakeet TDT 0.6B v3 (int8), NVIDIA | transcription (optional) | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| SenseVoice Small Yue (int8), ASLP-lab's fine-tune of FunAudioLLM's SenseVoice Small | transcription (optional) | WSYue-ASR's model card states Apache-2.0; SenseVoice Small is under the FunASR Model Open Source License Agreement 1.1, which also covers fine-tuned models | https://huggingface.co/ASLP-lab/WSYue-ASR, https://huggingface.co/FunAudioLLM/SenseVoiceSmall, https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE |
| Whisper large-v3 turbo, OpenAI | transcription (optional) | MIT | https://huggingface.co/openai/whisper-large-v3-turbo |
| Silero VAD | finding speech | MIT | https://github.com/snakers4/silero-vad |
| pyannote segmentation 3.0 | telling speakers apart | MIT | https://huggingface.co/pyannote/segmentation-3.0 |
| TitaNet-S, NVIDIA NeMo | recognizing voices | Apache-2.0: NVIDIA's model card puts it under the NeMo toolkit's license | https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small |
| ocrs text detection and recognition | screen text | CC-BY-SA-4.0 | https://huggingface.co/robertknight/ocrs |
| Qwen3.5 0.8B, 2B and 4B; Qwen3.6 27B and 35B-A3B (GGUF by Unsloth) | Think, Autocomplete | Apache-2.0 | https://huggingface.co/Qwen |
| LFM2.5 1.2B Instruct (GGUF by Unsloth), 2.6B and 8B-A1B, Liquid AI | Think, Autocomplete | LFM Open License v1.0 | https://huggingface.co/LiquidAI |
| Gemma 4 E2B base (GGUF by mradermacher), E4B and 12B (GGUF by Unsloth), Google DeepMind | Think, Autocomplete | Apache-2.0 | https://ai.google.dev/gemma/docs/gemma_4_license |
| Granite 4.1 3B, IBM | Think | Apache-2.0 | https://huggingface.co/ibm-granite/granite-4.1-3b |
| Ministral 3 3B Instruct 2512, Mistral AI | Think | Apache-2.0 | https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512 |
| EmbeddingGemma 2 (GGUF by ggml-org), Google DeepMind | search | Apache-2.0 | https://huggingface.co/google/embeddinggemma-2 |

It runs the text models with llama.cpp's `llama-server` (MIT), downloaded from
the ggml-org release named in `LinuxWindows/crates/lokalbot-ai/src/runtime.rs`,
and Agent Mode with Bun and pi, as in the table at the top.

The optional Linux/Windows CUDA backend uses NVIDIA's CUDA Runtime, cuBLAS and
cuBLASLt under the [NVIDIA CUDA Toolkit license](https://docs.nvidia.com/cuda/eula/index.html).
Compatible system libraries are reused when available. Otherwise LokalBot
downloads the companion archive from the same pinned llama.cpp release into its
own runtime folder. The NVIDIA GPU driver remains installed and managed by the
user's operating system; it is not included in LokalBot's downloads.

## MIT License

mlx-audio portions: Copyright (c) 2024 Prince Canuma.

DigUp and DigUpKit portions: Copyright (c) 2026 Abdur Rahim.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## BSD 3-Clause License

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Sparkle's copyright notice is reproduced from its distribution:

Copyright (c) 2006-2013 Andy Matuschak; 2009-2013 Elgato Systems GmbH;
2011-2014 Kornel Lesiński; 2015-2017 Mayur Pawashe; 2014 C.W. Betts;
2014 Petroules Corporation; 2014 Big Nerd Ranch. All rights reserved.

## Apache License 2.0

Copyright 2004 The Apache Software Foundation

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at:

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

The complete Apache License 2.0 text is available at the URL above and in the
`LICENSE` file of every Apache-licensed component listed in this notice. The
Linux and Windows downloads also include it as `LICENSES/Apache-2.0.txt`.
