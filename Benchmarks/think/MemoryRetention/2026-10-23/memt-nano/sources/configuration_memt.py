"""Standalone configuration for the published Qwen MoE + MemT model."""

import math
from copy import deepcopy

from transformers import PretrainedConfig
from transformers.models.qwen3_5_moe.configuration_qwen3_5_moe import (
    Qwen3_5MoeTextConfig,
)

_REQUIRED = {
    "memory_update_mode": "token",
    "gdn_version": "stable_gdn2",
    "memory_use_short_conv": False,
    "memory_head_mode": "mha",
    "memory_read_scale": "k_inv_sqrt",
    "linear_attention_state_policy": "reset_per_chunk",
    "chunk_tokens": 2048,
    "tail_policy": "commit",
    "output_gate_type": "silu",
    "stable_gdn2_sqrt_erase_gate": True,
    "backbone_gdn_override": False,
}
_EXTRA = {
    "num_memory_heads",
    "num_kv_heads",
    "output_gate_bias",
    "output_gate_softcap_enabled",
    "output_gate_softcap_limit",
}


class MemTQwen3_5MoeConfig(PretrainedConfig):
    model_type = "memt_qwen3_5_moe"
    has_no_defaults_at_init = True

    def __init__(self, backbone_configs=None, memt=None, **kwargs):
        if not isinstance(backbone_configs, dict) or not isinstance(memt, dict):
            raise TypeError("backbone_configs and memt are required objects")
        unknown = set(memt) - set(_REQUIRED) - _EXTRA
        missing = (set(_REQUIRED) | _EXTRA) - set(memt)
        if unknown or missing:
            raise ValueError(f"unknown MemT fields {sorted(unknown)}; missing {sorted(missing)}")
        for key, expected in _REQUIRED.items():
            if type(memt[key]) is not type(expected) or memt[key] != expected:
                raise ValueError(f"Unsupported memt.{key}: {memt[key]!r}")
        for key in ("output_gate_bias", "output_gate_softcap_enabled"):
            if type(memt[key]) is not bool:
                raise ValueError(f"memt.{key} must be bool")
        value = memt["output_gate_softcap_limit"]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value <= 0
        ):
            raise ValueError("memt.output_gate_softcap_limit must be positive and finite")
        text = deepcopy(backbone_configs.get("text_config", backbone_configs))
        if text.get("model_type") != "qwen3_5_moe_text":
            raise ValueError("This release requires qwen3_5_moe_text backbone")
        self.backbone_configs = deepcopy(backbone_configs)
        self.memt = deepcopy(memt)
        for key in ("num_memory_heads", "num_kv_heads"):
            if type(memt[key]) is not int or memt[key] != text["num_attention_heads"]:
                raise ValueError(f"memt.{key} must match backbone query heads")
        for key in kwargs:
            if key in (
                "memory_configs",
                "metis_settings",
                "sglang_metis_native_overlay",
            ):
                raise ValueError(f"Legacy configuration field {key}")
        kwargs.setdefault("bos_token_id", text.get("bos_token_id"))
        kwargs.setdefault("eos_token_id", text.get("eos_token_id"))
        kwargs.setdefault("pad_token_id", text.get("pad_token_id"))
        kwargs.setdefault("tie_word_embeddings", False)
        super().__init__(**kwargs)
        self.vocab_size = text["vocab_size"]
        self.hidden_size = text["hidden_size"]
        self.num_hidden_layers = text["num_hidden_layers"]
        self.initializer_range = text.get("initializer_range", 0.02)
        self.use_cache = kwargs.get("use_cache", True)
        self.is_encoder_decoder = False

    @classmethod
    def from_dict(cls, config_dict, **kwargs):
        # PretrainedConfig applies kwargs after construction. Reconstruct the
        # merged config so semantic overrides cannot bypass validation.
        result = super().from_dict(deepcopy(config_dict), **kwargs)
        config = result[0] if isinstance(result, tuple) else result
        cls(**config.to_dict())
        return result

    def get_text_config(self, decoder=False, encoder=False):
        text = Qwen3_5MoeTextConfig(
            **deepcopy(self.backbone_configs.get("text_config", self.backbone_configs))
        )
        text._attn_implementation = self._attn_implementation or "sdpa"
        text._experts_implementation = self._experts_implementation
        return text


MemTQwen3_5MoeConfig.register_for_auto_class()
