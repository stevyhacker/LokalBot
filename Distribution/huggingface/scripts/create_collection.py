#!/usr/bin/env python3
"""Create or sync LokalBot's public Hugging Face model collection.

The collection mirrors the v0.14.0 stack: items missing from ``ITEMS`` are
removed, notes are rewritten, and positions follow the order below.
"""

from huggingface_hub import (
    HfApi,
    add_collection_item,
    create_collection,
    delete_collection_item,
    get_collection,
    update_collection_item,
    update_collection_metadata,
)
from huggingface_hub.errors import HfHubHTTPError

NAMESPACE = "stevyhacker"
TITLE = "LokalBot recommended local stack"
DESCRIPTION = (
    "LokalBot v0.14.0 local stack: 4 Apache-2.0 fine-tunes + Nemotron 3 & "
    "EmbeddingGemma 2 (~9.6 GB). https://github.com/stevyhacker/lokalbot"
)

ITEMS = [
    (
        "stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF",
        "Default Mac transcription (v3, 2.52 GB GGUF Q8_0 + mmproj). Fine-tune of Qwen/Qwen3-ASR-1.7B: "
        "9.79% AMI ihm, 24.41% sdm, 100% clean silence, -24.3 pp code-switch WER, 31.7x RT. Apache-2.0.",
    ),
    (
        "stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF",
        "Compact transcription (v1, 1.02 GB GGUF Q8_0 + stock mmproj). Fine-tune of Qwen/Qwen3-ASR-0.6B: "
        "10.72% AMI ihm, -21.7 pp South Slavic WER, 100% clean silence, 52.7x RT. Apache-2.0.",
    ),
    (
        "FluidInference/nemotron-3-diarization-coreml",
        "Default speaker diarization. Core ML offline model (0.20 GB) of nvidia/Nemotron-3-Diarization "
        "via FluidAudio. 14.56% DER vs 43.44% for Pyannote on AMI, 500x RT. OpenMDW-1.1.",
    ),
    (
        "stevyhacker/Qwen3.5-4B-LokalBot-GGUF",
        "Default Think model (v4, 2.74 GB Q4_K_M). Fine-tune of Qwen/Qwen3.5-4B: 118/120 memory retention, "
        "45% Blind21 decision overlap, 60.6% fewer rejections, 1.78x faster, 6/6 tools. Apache-2.0.",
    ),
    (
        "ggml-org/embeddinggemma-2-GGUF",
        "Default semantic search (0.31 GB Q8_0) on llama-server. 39 ms p50 hybrid query and 0.280 R@1 "
        "across 232 QMSum meetings (43/48 top-1 on multilingual EN/SR probe). Apache-2.0.",
    ),
    (
        "stevyhacker/Gemma-4-E2B-LokalBot-GGUF",
        "Default inline autocomplete (v4, 3.85 GB i1-Q6_K). Fine-tune of google/gemma-4-E2B: 56/56 "
        "memory+visible grounding, 52.2% precision (80.0% email), 20.2 ms boundary median. Apache-2.0.",
    ),
]

VERIFICATION = {
    "stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF": (
        "Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf",
        "mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf",
    ),
    "stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF": (
        "Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf",
        "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf",
    ),
    "FluidInference/nemotron-3-diarization-coreml": ("Nemotron3Diarizer_offline.mlmodelc",),
    "stevyhacker/Qwen3.5-4B-LokalBot-GGUF": ("Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf",),
    "ggml-org/embeddinggemma-2-GGUF": ("Q8_0",),
    "stevyhacker/Gemma-4-E2B-LokalBot-GGUF": ("Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf",),
}


def main() -> None:
    if len(DESCRIPTION) >= 150:
        raise RuntimeError(
            "Hugging Face Collection descriptions must be under 150 characters"
        )

    api = HfApi()
    username = api.whoami()["name"]
    if username != NAMESPACE:
        raise RuntimeError(f"Authenticated as {username!r}; expected {NAMESPACE!r}")

    for repo_id, expected_fragments in VERIFICATION.items():
        info = api.model_info(repo_id, files_metadata=False)
        filenames = [sibling.rfilename for sibling in info.siblings]
        missing = [
            fragment
            for fragment in expected_fragments
            if not any(fragment in filename for filename in filenames)
        ]
        if missing:
            raise RuntimeError(f"{repo_id} is missing expected files: {missing}")

    slug = create_collection(
        title=TITLE,
        namespace=NAMESPACE,
        description=DESCRIPTION,
        private=False,
        exists_ok=True,
    ).slug

    try:
        update_collection_metadata(slug, description=DESCRIPTION)
    except HfHubHTTPError as error:
        print(f"warning: description not updated ({error.response.status_code}); set it in the web UI")

    for repo_id, note in ITEMS:
        add_collection_item(slug, item_id=repo_id, item_type="model", note=note, exists_ok=True)

    wanted = {repo_id for repo_id, _ in ITEMS}
    for item in get_collection(slug).items:
        if item.item_id not in wanted:
            delete_collection_item(slug, item.item_object_id)

    current = {item.item_id: item for item in get_collection(slug).items}
    for position, (repo_id, note) in enumerate(ITEMS):
        update_collection_item(slug, current[repo_id].item_object_id, note=note, position=position)

    print(f"https://huggingface.co/collections/{slug}")


if __name__ == "__main__":
    main()
