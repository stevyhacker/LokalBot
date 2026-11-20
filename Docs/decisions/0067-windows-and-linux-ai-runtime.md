# 0067. Windows and Linux: ai — runtime

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs`, `LinuxWindows/crates/lokalbot-ai/src/runtime/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/runtime.rs`

#### Built-in llama.cpp runtime: pinned prebuilt download, one loopback server per role with token
The built-in llama.cpp runtime (`Engines/LlamaServer.swift`,
`CLISupport/LlamaServerRole.swift`, `InferenceBroker.swift`).

macOS bundles a source build; here the pinned prebuilt release of
ggml-org/llama.cpp is downloaded once, verified, and unpacked into
`<root>/runtimes/llama-cpp/<build>-<asset tag>/`. Each role (Think,
embeddings, autocomplete) is its own `llama-server` subprocess on a fixed
loopback port with a random bearer token. A [`Lease`] keeps a server loaded;
after the last lease drops it lingers for the role's idle time, then stops.

#### All platforms run the same llama.cpp release; macOS builds same commit from v1.0.0
`LLAMA_BUILD`: The llama.cpp release every platform runs. macOS builds the same commit
from its `v1.0.0` tag.

#### Asset sizes and digests come from the GitHub release API
`RuntimeAsset`: One prebuilt release archive (sizes and digests from the GitHub release API).

#### Auto keeps Vulkan/CPU policy until native NVIDIA validation allows changing it
`download_bytes`: Upper bound before probing system CUDA libraries. Auto keeps its Vulkan /
CPU policy until native NVIDIA validation supports changing that default.

#### vc-runtime folder beside lokalbot.exe must match scripts/package.sh and update install.rs
`VC_RUNTIME_DIR`: The folder beside `lokalbot.exe` that holds [`VC_RUNTIME_DLLS`]
(scripts/package.sh). lokalbot-update's `install.rs` names it too.

#### Bundle VC++ runtime DLLs beside each llama-server because Windows may lack the Redistributable
`VC_RUNTIME_DLLS`: The Microsoft Visual C++ runtime DLLs upstream's Windows builds import.
Windows without the Visual C++ Redistributable has none of them, so each
runtime gets the bundled copies beside its `llama-server.exe`.

#### Missing DLL makes the process exit with this code before printing anything
`STATUS_DLL_NOT_FOUND`: STATUS_DLL_NOT_FOUND: Windows found no file for a DLL the program
imports. The process exits with it before printing anything.

#### Main role is the Think server: summaries, digests, Ask
`Role::Main`: Think: summaries, digests, Ask.

#### Media embedder is embedder plus projector for Files passes and saved-screen pictures
`Role::MediaEmbedder`: The embedder plus its image and audio projector, started for a Files
pass or for pictures of saved screens (`LlamaServerRole.mediaEmbedder`).

#### Release ports are fixed because CLI and MCP clients rely on them
`Role::release_port`: The ports the CLI and MCP clients rely on; they never move.

#### LOKALBOT_PORT_OFFSET keeps dev copies and tests off the installed app's ports
`Role::port`: `release_port` plus `LOKALBOT_PORT_OFFSET`, so a development copy or a
test run never fights the installed app for a port.

#### Media embedder stops two minutes after the last pass
`Role::idle_timeout`: Stopped two minutes after the last pass (`FileMediaEmbedderRuntime`).

#### Autocomplete never downloads the runtime because it starts as you type
`Role::downloads_runtime`: Whether starting this role's server may download the llama.cpp
build. Autocomplete starts as you type, so it only ever uses a build
that is already installed.

#### Images are pre-resized so token limits stop llama.cpp rescaling them
`Role::projector_args`: With images resized for their budget before they are sent, the token
limits keep llama.cpp from rescaling them.

#### Pass role flags only if this llama.cpp build supports them
`Role::extra_args`: Role arguments, keeping only flags this build understands.

#### Embedder needs each input in one micro-batch; EmbeddingGemma carries own pooling
`Role::extra_args`: EmbeddingGemma carries its own pooling; as a bidirectional
encoder each input must fit one micro-batch.

#### install.json inside an installed runtime folder records the install
`InstallRecord`: `install.json` inside an installed runtime folder.

#### Store the conditional flags found in --help
`InstallRecord.flags`: The flags from `--help` that LokalBot passes conditionally.

#### Probe field says which CONDITIONAL_FLAGS list produced flags
`InstallRecord.probe`: Which `CONDITIONAL_FLAGS` list produced `flags`.

#### cuda_libraries is system or companion digest; absent before CUDA support
`InstallRecord.cuda_libraries`: "system" after a successful device probe, or the companion archive's
pinned digest. Absent on installations predating CUDA support.

#### Unverified CUDA files kept; background starts skip CUDA until setup confirms
`InstallRecord.cuda_unverified`: Setup kept complete, verified files although its final device check
failed. Background starts skip CUDA until explicit setup confirms one.

#### Bump when CONDITIONAL_FLAGS changes so installs re-probe
`PROBE_VERSION`: Bump when `CONDITIONAL_FLAGS` changes so installed runtimes re-probe.

#### backend.json stores the last auto-detection result
`BackendChoice`: `backend.json`: the result of the last auto-detection.

#### Cache device probes until repair, backend change or failed launch; lock coalesces starts
`Installer.devices`: Cache successes and failures until repair, a backend change, or a failed launch.
Holding this lock during detection also coalesces simultaneous role starts.

#### Backend change during a 30 s probe marks cache stale instead of blocking settings
`Installer.devices_stale`: A backend change while a probe holds `devices` (up to 30 s) marks the
cache stale instead of blocking the settings thread.

#### CUDA has one installed build per toolkit
`Installer::record`: The installed build of `backend`. CUDA has one per toolkit.

#### Read the last auto-detection even if an older LokalBot saved it
`Installer::remembered_choice`: The last auto-detection, even by an older LokalBot.

#### Lists folders earlier LokalBot installed for other llama.cpp builds
`Installer::other_builds`: Folders an earlier LokalBot installed for another llama.cpp build.

#### Only a folder with install.json counts; staging or removed runtime does not
`Installer::other_build_installed`: Someone set up llama.cpp under another build. An interrupted install
leaves only a staging folder, and removing the runtime leaves nothing.

#### Background starts may use CUDA only if complete and device-verified
`Installer::cuda_ready`: A CUDA installation background starts may use: complete, and confirmed
by a device check during setup.

#### CUDA stays automatic until setup succeeds so built-in models keep working
`Installer::automatic`: Whether auto-detection picks the backend: `auto`, and CUDA until its
setup succeeds, so selecting CUDA never stops working built-in models.

#### Busy GPU or new driver does not make an intact install corrupt
`Installer::install`: A busy GPU or changed driver does not make an intact installation
corrupt. Startup and explicit repair validate execution separately.

#### Check library loading before any GPU check, since missing libraries fail every probe
`Installer::download_and_unpack`: Before any GPU check: a missing system library fails every one.

#### Keep verified CUDA files when only the final GPU check fails
`Installer::download_and_unpack`: A GPU filled by another app fails only the final check. Keep
the verified files: setup reports the failure, and a retry
repeats the check without downloading them again.

#### Progress excludes the companion archive when a system library probe succeeded
`Installer::download_and_unpack`: A successful system-library probe avoided the companion archive.

#### Reuse system CUDA libraries else place pinned ones; return device check separately
`Installer::prepare_cuda`: Reuses system CUDA libraries that pass a device check, else places the
pinned companion libraries beside `server`. Returns what to record and,
separately, the final device check, so callers can keep complete,
verified files when only that check fails.

#### Completed companion archive is always deleted; interrupted downloads can resume
`Installer::prepare_cuda`: A completed companion archive is temporary, including when extraction
or the final GPU probe fails. Interrupted downloads can still resume.

#### Re-detect after a good probe fails to launch; cache failed probes until retry
`Installer::launch_failed`: Re-detect after a previously successful probe fails to launch. Cache a
failed probe itself until the user retries setup or changes backend.

#### CUDA repair runs only from explicit setup, never background starts
`Installer::repair_cuda`: Only called by explicit setup/repair, never by a background server start.

#### Replace only optional math libraries; server folder may be in use on Windows
`Installer::repair_cuda`: Replace only the optional math libraries. The server folder
may be in use by another role, particularly on Windows.

#### File completeness and GPU availability differ; keep repaired files if GPU busy
`Installer::repair_cuda`: File completeness and GPU availability are different states.
Keep newly repaired files even if this GPU is currently busy.

#### Only a confirmed device lets background starts switch to CUDA
`Installer::repair_cuda`: Only a confirmed device lets background starts switch to CUDA.

#### Auto takes Vulkan only if it lists a real GPU; downloads optional
`Installer::resolve`: The backend to run. `auto` takes Vulkan only when the Vulkan build
lists a real GPU (a loader alone, or a software rasterizer, is not one).
With `allow_download` false, only installed builds are considered.

#### Explicit setup installs CUDA; until it succeeds background starts stay automatic
`Installer::resolve`: Explicit setup installs CUDA. Until it succeeds, background starts
keep the automatic choice instead of failing.

#### Silent installs skip CUDA; its 800 MB download stays an explicit Settings step
`Installer::install_for_built_in_models`: Installs what built-in models run on without anyone asking: a selected
Vulkan or CPU, else the automatic choice. CUDA's download of up to 800 MB
stays an explicit step in Settings.

#### Do not refetch Vulkan build when an older build already found no GPU
`Installer::install_for_built_in_models`: An older build already looked for a GPU and found none, so don't
fetch the Vulkan build to look again.

#### Vulkan build fetched only to look for a GPU is removed; CPU choice remembered
`Installer::resolve_without_cuda`: Only fetched to look for a GPU; the choice is remembered.

#### Fully downloaded setup archive is removed on success and on final failure
`CompletedArchive`: Removes a fully downloaded setup archive on success and on final failure.

#### App-local VC++ deployment beside server, replaced on update or at later start if locked
`deploy_vc_runtime`: Copies the bundled Visual C++ runtime beside the server in `server_dir`,
Microsoft's app-local deployment: Windows loads it before any copy in
System32, so the server needs no Visual C++ Redistributable and never runs
against an older one. A copy that differs from the bundled one (after an
update) is replaced; one a running server holds is replaced at a later start.

#### VC++ DLLs count as found beside server or in System32; other systems need none
`vc_runtime_found`: Whether Windows finds every Visual C++ runtime DLL for a server in
`server_dir`, beside it or installed in System32. Other systems need none.

#### Linux loader names the library; Windows only exits with DLL-not-found code
`missing_library`: What to install when the system could not load llama-server at all. The
Linux loader names the library on stderr; Windows only exits with
[`STATUS_DLL_NOT_FOUND`], and `vc_runtime_found` tells whether the Visual
C++ runtime, the one DLL set outside the runtime folder it needs, is there.

#### Parse the Linux loader's shared-library error line to name the missing library
`missing_library`: "…/llama-server: error while loading shared libraries: libgomp.so.1:
cannot open shared object file: No such file or directory"

#### Fail with what to install so setup never records an unstartable runtime
`check_loads`: Fails with what to install when the system cannot load `binary`, so setup
never records a runtime that cannot start.

#### Freshly unpacked binary may be busy while another thread's fork holds it open
`check_loads`: Just unpacked, it can't run while a process forked by another thread
still holds the file open from when it was being written.

#### Require a real device from this backend, not a CPU-only successful exit
`probe_gpu`: A real device from this backend, never a CPU-only successful exit.

#### Marker file lets later runs stop orphan helpers and CLI reach server; 0600 holds token
`ServerMarker`: `<root>/llama-server-<port>.json`: lets a later run recognize (and stop)
a helper an earlier run left behind, and lets the CLI reach the app's
server. Written 0600 on Unix; it holds the bearer token.

#### gpu_offloaded set only after startup confirms GPU layers; older markers cannot prove CUDA
`ServerMarker.gpu_offloaded`: Only set after startup confirms model layers on the GPU. Older markers
cannot establish that a CUDA server is really accelerated.

#### Token is 64 lowercase hex characters from two UUIDs, matching macOS
`new_token`: 64 lowercase hex characters from two random UUIDs, as on macOS.

#### Keep all stderr before ready; afterwards only crash lines to avoid private text
`OutputTail`: The tail of llama-server's stderr (`LlamaServerOutputTail`). Before the
first healthy check every line is kept so a failed start can say why;
afterwards only crash lines, since request errors can echo private text.

#### Strip the llama.cpp timestamp and level prefix from log lines
`OutputTail::keep`: "0.00.077.284 E gguf_init_from_reader: …": drop the time and level.

#### child is None for a helper adopted or borrowed rather than spawned
`Running.child`: `None` for a helper adopted from an earlier run or borrowed from a live one.

#### Borrowed helper belongs to a live LokalBot and is never stopped here
`Running.borrowed`: A live LokalBot elsewhere owns it: never stopped from here.

#### Held-open leases last as long as a task is open; nobody waits for them
`ServerState.held_open`: How many of those are kept for as long as a task is open, not for one
request. Nobody waits for these to end.

#### desired is the model lease() starts when nothing is loaded
`ServerState.desired`: The model `lease()` starts when nothing is loaded.

#### Dropping the last lease starts the idle timer
`Lease`: Keeps a server loaded; dropping the last lease starts the idle timer.

#### Root URL serves /health, /tokenize and /props
`Lease::root_url`: `http://127.0.0.1:<port>`, for `/health`, `/tokenize` and `/props`.

#### On unreachable request, forget a dead server so next lease starts fresh
`Lease::mark_unreachable`: A request could not reach the server: if it has died, forget it so
the next lease starts a fresh one.

#### A model switch waits until every lease on the current model is released
`LlamaServer::lease_model`: Leases `entry`, starting (or switching to) it as needed. A switch waits
until every lease on the current model is released.

#### Task lease fails other-model requests instead of waiting for an unclosed task
`LlamaServer::lease_model_for_task`: [`Self::lease_model`] for a lease kept while a task stays open. A
request for another model fails while it is held, instead of waiting
for a task that may never be closed.

#### Verification hashes the file once when no digest sidecar exists
`LlamaServer::lease_entry`: Hashes once when the file has no digest sidecar yet.

#### Stop is immediate; leases still held see the server restart
`LlamaServer::stop`: Stops the server now (leases still held will see it restart).

#### Existing leases finish before a backend preference change; generations are not interrupted
`ServerInner::lease_path`: Existing leases finish before a preference change starts
another backend; no active generation is interrupted.

#### An open task holds the loaded model indefinitely
`ServerInner::lease_path`: An open task holds what is loaded for as long as it stays
open, which may be for good.

#### Switch models once the current model's lease cohort finishes
`ServerInner::lease_path`: Another model is in use; switch once its cohort finishes.

#### Reuse a healthy offloaded CUDA helper because GPU may lack VRAM for a probe
`ServerInner::launch`: Reuse a healthy, already-offloaded helper before creating another
CUDA context. Its GPU may have no free VRAM for a new probe.

#### b11474 renamed --no-webui to --no-ui, keeping the old name as alias
`ServerInner::launch`: b11474 renamed `--no-webui` to `--no-ui` and keeps the old name as an alias.

#### code is the exit code of a server that exited during startup
`ServerInner::launch`: `code`: the exit code of a server that exited during startup.

#### CUDA gets a 10 minute load window because PTX compiles take about 50 s
`ServerInner::launch`: Loading a large model can take a while. On GPUs without prebuilt
CUDA kernels the driver first compiles PTX, ~50 s on a Titan Xp;
later starts reuse its cache.

#### Startup log lines are cleared once ready since they only explain failed starts
`ServerInner::launch`: Startup lines only explain a failed start.

#### Reuse matching healthy helper (adopt or borrow); stop mismatched orphans
`ServerInner::reclaim`: Deals with a helper recorded on this port. A healthy one with the same
configuration is reused: adopted when its LokalBot is gone, borrowed
when that LokalBot still runs. A mismatched orphan is stopped.

#### b12359 hides offload evidence at verbosity 3, so use 4
`cuda_launch_args`: b12359 hides offload evidence at verbosity 3. Preserve plain startup logs.

#### Runtime storage stays visible even when another backend is selected
`RuntimeStorage`: Runtime storage remains visible even when another backend is selected.

#### Manager is cheap to clone and Send+Sync; clones control the same servers
`RuntimeManager`: The four role servers and the runtime they share. Cheap to clone and
`Send + Sync`; every clone controls the same servers.

#### Construction does no download and starts no process
`RuntimeManager::new`: Cheap: no download, no process start.

#### Running servers keep their backend until they restart
`RuntimeManager::set_backend_preference`: Applies a changed `llamaBackend` setting (`auto`, `cuda`, `vulkan`, `cpu`).
Running servers keep their backend until they restart.

#### Auto may fetch Vulkan to look for a GPU, then CPU
`RuntimeManager::ensure_runtime`: Downloads and installs the runtime the setting asks for (`auto` may
fetch the Vulkan build to look for a GPU, then the CPU build).

#### Update pending when an older build exists and nothing usable is installed
`RuntimeManager::update_pending`: An update moved LokalBot to another llama.cpp build: one was set up
before, and nothing built-in models can run on now is installed.

#### Unrequested installs never download CUDA, unlike ensure_runtime
`RuntimeManager::install_for_built_in_models`: Installs what built-in models run on, for work nobody explicitly asked
to set up. Unlike [`Self::ensure_runtime`], it never downloads CUDA.

#### Remove older builds once usable; skip busy folders; report lost CUDA setup
`RuntimeManager::remove_other_builds`: Removes what earlier versions installed for other llama.cpp builds, and
their interrupted downloads, once built-in models can run without them.
A folder a helper still runs from stays until a later launch, and so
does one Windows won't delete yet. Returns whether this took away a
CUDA setup that's still selected, which has to be repeated.

#### Explicit choice needs its own complete install; CUDA needs a passed device check
`RuntimeManager::installed_backend`: The selected backend when installed. Auto considers Vulkan and CPU;
an explicit choice must have its own complete installation, and CUDA
a setup whose device check succeeded.

#### CUDA keeps the automatic choice until its setup succeeds
`RuntimeManager::usable_backend`: The backend built-in models can run on now without a download. CUDA
keeps the automatic choice until its setup succeeds.

#### Agent Mode task keeps its model loaded until the task closes
`RuntimeManager::main_server_for_task`: The Think server for an Agent Mode task, which keeps its model loaded
until the task is closed. See [`LlamaServer::lease_model_for_task`].

#### Media embedder requires the projector to be downloaded
`RuntimeManager::media_embedder_server`: Leases the embedder with its projector, which must be downloaded.

#### Files kept after failed device check must not switch roles to CUDA
`tests::cuda_selection_keeps_the_automatic_backend_until_setup_succeeds`: Files kept after a failed final device check do not switch roles.

#### Offload log line fixture captured from b11669 on NVIDIA L4 at verbosity 4
`tests::offload_confirmation_survives_startup_log_truncation`: Captured from b11669 on an NVIDIA L4 with --log-verbosity 4.

#### Fresh script can't run while another test's fork still holds it open
`tests::wait_until_runnable`: A script that was just written can't run while a process another test
forked meanwhile still holds it open.

#### Fake archive passes download via pinned size and sidecar digest; padding unread
`tests::seed_archive`: Stands in for a downloaded release archive: `download` accepts a file
of the pinned size whose digest sidecar matches, and nothing reads the
sparse padding after the gzip stream.

#### Windows library archives keep their name across builds
`tests::folder_and_archive_names_give_their_build`: Windows' library archives keep their name across builds.

#### Test calls download_and_unpack directly because install checks for an NVIDIA driver
`tests::fresh_cuda_files_survive_a_failed_final_probe`: `install` checks the NVIDIA driver first; no test machine has one.

#### Loader error fixture captured from b11669 in ubuntu:24.04 without libgomp1
`tests::missing_system_libraries_say_what_to_install`: From b11669 in an ubuntu:24.04 container without libgomp1.

#### Use a free port so tests never bind a release port
`tests::startup_failure_names_a_missing_system_library`: A free port, so this test never binds a release port.

#### Fake running server has no process behind it that a test could stop
`tests::running_server`: A Think server that counts as running `model`, with no process behind
it that a test could stop.

#### Fixture binary cannot run; GPU availability is deliberately irrelevant to reuse
`tests::intact_cuda_install_is_reused_without_probing_or_downloading`: The fixture binary cannot execute. GPU availability is deliberately irrelevant.

#### Separate ServerInner keeps the test off release ports
`tests::healthy_cuda_helper_is_reclaimed_before_a_failed_probe`: Build a separate inner so this test never binds a release port.

### `LinuxWindows/crates/lokalbot-ai/src/runtime/cuda.rs`

#### CUDA builds: driver system-managed; prebuilt kernels vs PTX rules decide which build runs
Optional CUDA runtimes. The NVIDIA driver stays system-managed; the math
libraries are reused from the system when the actual backend loads.

Two upstream builds cover different GPUs and drivers. A driver runs a
build's prebuilt kernels when it supports the same CUDA major version, but
compiles PTX only from a toolkit no newer than itself. CUDA 13.5 has
prebuilt kernels for 8.6, 8.9 and 12.x and PTX from Turing (7.5); the
CUDA 12 builds add PTX for Maxwell, Pascal and Volta.
https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html

#### Companion archive reuses RuntimeAsset but is never selected as a runtime
`Build.libraries`: RuntimeAsset also describes this companion archive; it is never
selected independently as an executable runtime.

#### toolkit is version as cuDriverGetVersion reports; PTX needs that driver
`Build.toolkit`: `version` as `cuDriverGetVersion` reports it. PTX needs this driver.

#### Builds ordered newest first; selection takes first build all GPUs can run
`BUILDS`: Newest first: selection takes the first build every GPU can run.

#### Remembers last selected build to estimate download size
`SELECTED`: The build the last setup selected, for download estimates.

#### LOKALBOT_CUDA_RUNTIME lets support or validation force a CUDA build
`OVERRIDE`: Lets support or validation force one build, e.g. `LOKALBOT_CUDA_RUNTIME=12.8`.

#### Archives differ in layout; move only the three pinned libraries, never driver files
`Build::place_libraries`: Both upstream archives use their own layout. Move only the three pinned
runtime libraries next to llama-server, never a driver or a system file.

#### Check driver and GPUs before downloading, pick newest build all GPUs run
`select`: Checks the driver and GPUs before fetching hundreds of MB, then picks the
newest build every NVIDIA GPU here can run. The bounded llama-server
device probe and model offload still decide whether it works.

#### Unknown capabilities allow only builds whose PTX the driver can compile
`choose`: Without known compute capabilities, only a build whose PTX this driver
can compile is safe.

#### Unsafe block loads driver and keeps library alive while function pointer is used
`driver_version`: SAFETY: load the installed CUDA driver and call its documented version
query, retaining the library until the function pointer is no longer used.

#### None when nvidia-smi is missing or too old to report capability
`compute_capabilities`: Every NVIDIA GPU's compute capability, or `None` when `nvidia-smi` is
missing or too old to report it.

#### Search system loader and toolkit paths only; a device probe decides usability
`library_dirs`: Use normal system loader paths plus explicit toolkit locations. Never
search another application's private runtime. A real device probe, not
file presence, decides whether these libraries are usable.

#### Turing and A100 have only PTX in CUDA 13.5, so older 13.x drivers use CUDA 12
`tests::ptx_needs_a_driver_as_new_as_the_toolkit`: Turing and A100 have only PTX in CUDA 13.5: a 13.0-13.4 driver
cannot compile it, so they get the CUDA 12 build.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
