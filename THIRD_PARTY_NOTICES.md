# Third-Party Software Notices

LokalBot includes or links software developed by third parties. The source and
binary release are governed by LokalBot's GPL-3.0 license, while each component
below remains subject to its own license and copyright notices.

Versions are locked in
`LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
the vendor fetch scripts, and `AgentRuntimeManifest`.

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
| sherpa-onnx | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime | MIT | https://github.com/microsoft/onnxruntime |
| Bun (optional Agent Mode runtime) | MIT | https://github.com/oven-sh/bun |
| pi agent packages (optional, installed on request) | MIT | https://github.com/earendil-works/pi |
| LFM models (downloaded on request) | LFM Open License v1.0 | https://docs.liquid.ai/lfm/help/model-license |
| Parakeet Ultra (downloaded on request; moondream post-training of NVIDIA Parakeet v3, Core ML conversion by FluidInference) | CC-BY-4.0 | https://huggingface.co/moondream/parakeet-ultra / https://huggingface.co/FluidInference/parakeet-ultra-coreml |

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

## MIT License

mlx-audio portions: Copyright (c) 2024 Prince Canuma.

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
`LICENSE` file of every Apache-licensed component listed in this notice.
