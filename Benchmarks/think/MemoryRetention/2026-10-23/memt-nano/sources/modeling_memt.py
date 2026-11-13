"""Qwen MoE with explicit MemT memory and independent text sessions.

Backbone computation and generation use Transformers 5.12.1. Only the trained
memory branch and its lifecycle are implemented here.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import tempfile
import threading
import uuid
from copy import deepcopy
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

import torch
import torch.nn.functional as F
from safetensors import safe_open
from safetensors.torch import save_file
from torch import nn
from transformers import GenerationMixin
from transformers.activations import ACT2FN
from transformers.modeling_outputs import CausalLMOutputWithPast
from transformers.modeling_utils import ALL_ATTENTION_FUNCTIONS
from transformers.models.qwen3_5_moe import modeling_qwen3_5_moe as qwen

from .configuration_memt import MemTQwen3_5MoeConfig


class MemTRMSNormGated(nn.Module):
    def __init__(self, head_dim, eps, config):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(head_dim))
        self.eps = eps
        self.softcap = config["output_gate_softcap_enabled"]
        self.limit = config["output_gate_softcap_limit"]

    def forward(self, value, gate):
        normalized = value.float() * torch.rsqrt(
            value.float().square().mean(-1, keepdim=True) + self.eps
        )
        normalized = self.weight * normalized.to(value.dtype)
        activated = F.silu(gate.float())
        if self.softcap:
            activated = self.limit * torch.tanh(activated / self.limit)
        return (normalized * activated).to(value.dtype)


class MemTMemory(nn.Module):
    """MHA memory with sqrt erase gating; reads never modify caller-owned FP32 states."""

    def __init__(self, config, hidden_size, num_heads, head_dim, rms_norm_eps=1e-6):
        super().__init__()
        self.num_heads, self.head_dim = num_heads, head_dim
        self.value_dim = num_heads * head_dim
        self.read_scale = head_dim**-0.5
        self.in_proj_rows = (self.value_dim,) * 5 + (head_dim, head_dim)
        self.in_proj = nn.Linear(hidden_size, sum(self.in_proj_rows), bias=False)
        self.f_down = nn.Linear(head_dim, self.value_dim, bias=False)
        self.g_down = nn.Linear(head_dim, self.value_dim, bias=config["output_gate_bias"])
        self.decay_bias = nn.Parameter(torch.empty(self.value_dim))
        self.decay_scale_log = nn.Parameter(torch.zeros(num_heads))
        self.o_norm = MemTRMSNormGated(head_dim, rms_norm_eps, config)
        self.reset_parameters()

    @torch.no_grad()
    def reset_parameters(self):
        for block in self.in_proj.weight.split(self.in_proj_rows, dim=0):
            nn.init.xavier_uniform_(block, gain=2**-2.5)
        nn.init.xavier_uniform_(self.f_down.weight, gain=2**-2.5)
        nn.init.xavier_uniform_(self.g_down.weight, gain=2**-2.5)
        if self.g_down.bias is not None:
            nn.init.zeros_(self.g_down.bias)
        nn.init.zeros_(self.decay_scale_log)
        half_life = (
            torch.empty_like(self.decay_bias).uniform_(math.log(2048), math.log(32768)).exp()
        )
        rate = math.log(2) / half_life
        self.decay_bias.copy_(rate + torch.log(-torch.expm1(-rate)))

    @staticmethod
    def _normalize(value, rounded):
        result = value.float() * torch.rsqrt(value.float().square().sum(-1, keepdim=True) + 1e-6)
        return result.to(value.dtype) if rounded else result

    def forward(self, hidden, state=None, commit=False, *, write_state=None):
        batch, length, _ = hidden.shape
        dim, width = self.head_dim, self.value_dim
        shape = (batch, length, self.num_heads, dim)
        if state is None and not commit:
            return hidden.new_zeros(batch, length, width), None
        snapshot = (
            hidden.new_zeros((batch, self.num_heads, dim, dim), dtype=torch.float32)
            if state is None
            else state
        )
        projected = F.linear(hidden, self.in_proj.weight[: 3 * width if commit else width])
        query = self._normalize(projected[..., :width].reshape(shape), commit)
        with torch.autocast(device_type=hidden.device.type, enabled=False):
            read = self.read_scale * torch.einsum(
                "blhk,bhkv->blhv", query.float(), snapshot.float()
            )
        gate = self.g_down(F.linear(hidden, self.in_proj.weight[-dim:])).reshape(shape)
        read = self.o_norm(read.to(gate.dtype), gate).reshape(batch, length, width)
        if not commit:
            return read, state
        key, value = (item.reshape(shape) for item in projected[..., width:].split(width, -1))
        key = self._normalize(key, True)
        b, w, f = F.linear(hidden, self.in_proj.weight[3 * width : -dim]).split(
            (width, width, dim), -1
        )
        sqrt_b = (0.5 * F.logsigmoid(b.float())).exp().to(b.dtype).reshape(shape)
        key = (key.float() * sqrt_b.float()).to(value.dtype).float()
        write_value = w.sigmoid().reshape(shape).float() * value.float()
        decay = (
            -self.decay_scale_log.float().exp().reshape(self.num_heads, 1)
            * F.softplus(self.f_down(f).float() + self.decay_bias.float()).reshape(shape)
        ).exp()
        updated = snapshot.float() if write_state is None else write_state.float()
        # The writer advances per event; every read in a QA keeps its frozen snapshot.
        for index in range(length):
            u = key[:, index]
            updated = updated * decay[:, index].unsqueeze(-1)
            erase = (u.unsqueeze(-1) * updated).sum(-2)
            updated = updated + u.unsqueeze(-1) * (write_value[:, index] - erase).unsqueeze(-2)
        return read, updated


def _device_dispatch(reference, accelerated):
    def operation(*args, **kwargs):
        tensor = args[0] if args else kwargs.get("q", kwargs.get("x"))
        implementation = accelerated if accelerated is not None and tensor.is_cuda else reference
        return implementation(*args, **kwargs)

    return operation


def _causal_convolution(x, weight, bias=None, activation=None, seq_idx=None):
    if x.is_cuda and qwen.causal_conv1d_fn is not None:
        return qwen.causal_conv1d_fn(x, weight, bias, activation=activation, seq_idx=seq_idx)
    result = F.conv1d(
        x, weight.unsqueeze(1), bias, padding=weight.shape[-1] - 1, groups=x.shape[1]
    )[..., : x.shape[-1]]
    return F.silu(result) if activation in ("silu", "swish") else result


class MemTGatedDeltaNet(qwen.Qwen3_5MoeGatedDeltaNet):
    """Device-safe construction; forward and GDN equations remain native.

    The optional upstream fused norm queries CUDA even during CPU/meta loading.
    Use the native PyTorch norm and select kernels on the actual tensor device.
    """

    def __init__(self, config, layer_idx):
        nn.Module.__init__(self)
        self.hidden_size = config.hidden_size
        self.num_v_heads = config.linear_num_value_heads
        self.num_k_heads = config.linear_num_key_heads
        self.head_k_dim = config.linear_key_head_dim
        self.head_v_dim = config.linear_value_head_dim
        self.key_dim = self.head_k_dim * self.num_k_heads
        self.value_dim = self.head_v_dim * self.num_v_heads
        self.conv_kernel_size = config.linear_conv_kernel_dim
        self.layer_idx = layer_idx
        self.activation = config.hidden_act
        self.act = ACT2FN[config.hidden_act]
        self.layer_norm_epsilon = config.rms_norm_eps
        self.conv_dim = self.key_dim * 2 + self.value_dim
        self.conv1d = nn.Conv1d(
            self.conv_dim,
            self.conv_dim,
            self.conv_kernel_size,
            groups=self.conv_dim,
            padding=self.conv_kernel_size - 1,
            bias=False,
        )
        self.dt_bias = nn.Parameter(torch.ones(self.num_v_heads))
        self.A_log = nn.Parameter(torch.empty(self.num_v_heads).uniform_(0, 16).log_())
        self.norm = qwen.Qwen3_5MoeRMSNormGated(self.head_v_dim, eps=self.layer_norm_epsilon)
        self.out_proj = nn.Linear(self.value_dim, self.hidden_size, bias=False)
        self.causal_conv1d_fn = _causal_convolution
        self.causal_conv1d_update = _device_dispatch(
            qwen.torch_causal_conv1d_update, qwen.causal_conv1d_update
        )
        self.chunk_gated_delta_rule = _device_dispatch(
            qwen.torch_chunk_gated_delta_rule, qwen.chunk_gated_delta_rule
        )
        self.recurrent_gated_delta_rule = _device_dispatch(
            qwen.torch_recurrent_gated_delta_rule, qwen.fused_recurrent_gated_delta_rule
        )
        self.in_proj_qkv = nn.Linear(
            self.hidden_size, 2 * self.key_dim + self.value_dim, bias=False
        )
        self.in_proj_z = nn.Linear(self.hidden_size, self.value_dim, bias=False)
        self.in_proj_b = nn.Linear(self.hidden_size, self.num_v_heads, bias=False)
        self.in_proj_a = nn.Linear(self.hidden_size, self.num_v_heads, bias=False)


@dataclass
class _MemoryCall:
    read: dict
    write: dict | None = None
    results: dict = field(default_factory=dict)


class MemTAttention(qwen.Qwen3_5MoeAttention):
    def __init__(self, text, layer_idx, memory_config):
        super().__init__(text, layer_idx)
        self.memt = MemTMemory(
            memory_config,
            text.hidden_size,
            text.num_attention_heads,
            text.head_dim,
            text.rms_norm_eps,
        )

    def forward(
        self,
        hidden_states,
        position_embeddings,
        attention_mask,
        past_key_values=None,
        memory_call=None,
        **kwargs,
    ):
        shape = hidden_states.shape[:-1]
        heads = (*shape, -1, self.head_dim)
        query, gate = (
            self.q_proj(hidden_states).view(*shape, -1, 2 * self.head_dim).chunk(2, dim=-1)
        )
        query = self.q_norm(query.reshape(heads)).transpose(1, 2)
        key = self.k_norm(self.k_proj(hidden_states).view(heads)).transpose(1, 2)
        value = self.v_proj(hidden_states).view(heads).transpose(1, 2)
        query, key = qwen.apply_rotary_pos_emb(query, key, *position_embeddings)
        if past_key_values is not None:
            key, value = past_key_values.update(key, value, self.layer_idx)
        attention = ALL_ATTENTION_FUNCTIONS.get_interface(
            self.config._attn_implementation, qwen.eager_attention_forward
        )
        output, weights = attention(
            self,
            query,
            key,
            value,
            attention_mask,
            dropout=self.attention_dropout if self.training else 0.0,
            scaling=self.scaling,
            **kwargs,
        )
        output = output.reshape(*shape, -1).contiguous() * torch.sigmoid(gate.reshape(*shape, -1))
        if memory_call is not None:
            state = memory_call.read.get(self.layer_idx)
            state = state.to(hidden_states.device) if state is not None else None
            commit = memory_call.write is not None
            writer = memory_call.write.get(self.layer_idx) if commit else None
            writer = writer.to(hidden_states.device) if writer is not None else None
            read, updated = self.memt(hidden_states, state, commit, write_state=writer)
            output = output + read.to(output.dtype)
            if commit:
                memory_call.results[self.layer_idx] = updated
        return self.o_proj(output), weights


class MemTDecoderLayer(qwen.Qwen3_5MoeDecoderLayer):
    def __init__(self, config, layer_idx, memory_config):
        nn.Module.__init__(self)
        self.hidden_size = config.hidden_size
        self.layer_type = config.layer_types[layer_idx]
        if self.layer_type == "linear_attention":
            self.linear_attn = MemTGatedDeltaNet(config, layer_idx)
        else:
            self.self_attn = MemTAttention(config, layer_idx, memory_config)
        self.mlp = qwen.Qwen3_5MoeSparseMoeBlock(config)
        self.input_layernorm = qwen.Qwen3_5MoeRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = qwen.Qwen3_5MoeRMSNorm(
            config.hidden_size, eps=config.rms_norm_eps
        )


class MemTTextModel(qwen.Qwen3_5MoeTextModel):
    @classmethod
    def _can_set_experts_implementation(cls):
        # Upstream source-file detection cannot see imported native experts.
        return True

    def __init__(self, config, memory_config):
        qwen.Qwen3_5MoePreTrainedModel.__init__(self, config)
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size, config.pad_token_id)
        self.layers = nn.ModuleList(
            [MemTDecoderLayer(config, i, memory_config) for i in range(config.num_hidden_layers)]
        )
        self.norm = qwen.Qwen3_5MoeRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.rotary_emb = qwen.Qwen3_5MoeTextRotaryEmbedding(config=config)
        self.gradient_checkpointing = False
        self.post_init()


class MemTBackbone(nn.Module):
    def __init__(self, text, memory_config):
        super().__init__()
        self.language_model = MemTTextModel(text, memory_config)


class MemTQwen3_5MoeForCausalLM(qwen.Qwen3_5MoePreTrainedModel, GenerationMixin):
    config_class = MemTQwen3_5MoeConfig
    base_model_prefix = "model"
    _no_split_modules: ClassVar[list[str]] = ["MemTDecoderLayer"]
    _tied_weights_keys: ClassVar[dict[str, str]] = {
        "lm_head.weight": "model.language_model.embed_tokens.weight"
    }

    @classmethod
    def _can_set_experts_implementation(cls):
        return True

    def __init__(self, config):
        super().__init__(config)
        text = config.get_text_config()
        self.model = MemTBackbone(text, config.memt)
        self.lm_head = nn.Linear(text.hidden_size, text.vocab_size, bias=False)
        self.post_init()

    def _init_weights(self, module):
        super()._init_weights(module)
        if isinstance(module, MemTMemory):
            module.reset_parameters()

    def get_input_embeddings(self):
        return self.model.language_model.embed_tokens

    def set_input_embeddings(self, value):
        self.model.language_model.embed_tokens = value

    def get_output_embeddings(self):
        return self.lm_head

    def set_output_embeddings(self, value):
        self.lm_head = value

    def forward(
        self,
        input_ids=None,
        attention_mask=None,
        position_ids=None,
        past_key_values=None,
        inputs_embeds=None,
        labels=None,
        use_cache=None,
        memory_state=None,
        logits_to_keep=0,
        return_dict=None,
        **kwargs,
    ):
        outputs = self.model.language_model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            position_ids=position_ids,
            past_key_values=past_key_values,
            inputs_embeds=inputs_embeds,
            use_cache=self.config.use_cache if use_cache is None else use_cache,
            memory_call=_MemoryCall(memory_state) if memory_state else None,
            return_dict=True,
            **kwargs,
        )
        sliced = slice(-logits_to_keep, None) if isinstance(logits_to_keep, int) else logits_to_keep
        logits = self.lm_head(outputs.last_hidden_state[:, sliced, :])
        loss = (
            None
            if labels is None
            else self.loss_function(logits, labels, self.config.vocab_size, **kwargs)
        )
        result = CausalLMOutputWithPast(
            loss=loss,
            logits=logits,
            past_key_values=outputs.past_key_values,
            hidden_states=outputs.hidden_states,
            attentions=outputs.attentions,
        )
        return (
            result
            if (self.config.return_dict if return_dict is None else return_dict)
            else result.to_tuple()
        )

    @torch.no_grad()
    def commit_memory(self, input_ids, memory_state=None, *, document=False):
        """Replay one unpadded QA or Document and return a new state dictionary.

        QA events retain one read snapshot and one native KV/GDN cache. Document
        chunks reset both domains. No input memory tensor is mutated.
        """
        if input_ids.ndim != 2 or input_ids.shape[0] != 1 or input_ids.shape[1] == 0:
            raise ValueError("commit_memory requires a nonempty [1, tokens] tensor")
        if input_ids.dtype != torch.long:
            raise TypeError("commit_memory requires integer token IDs (torch.long)")
        snapshot = {} if memory_state is None else memory_state
        if snapshot:
            text = self.config.get_text_config()
            layers = {i for i, kind in enumerate(text.layer_types) if kind == "full_attention"}
            if set(snapshot) != layers:
                raise ValueError("memory must contain every full-attention layer")
            shape = (1, text.num_attention_heads, text.head_dim, text.head_dim)
            if any(
                tuple(value.shape) != shape or value.dtype != torch.float32
                for value in snapshot.values()
            ):
                raise ValueError(
                    "memory states must have the model's [1, heads, K, V] shape and FP32 dtype"
                )
        candidate, cache = snapshot, None
        for event in input_ids.split(self.config.memt["chunk_tokens"], dim=1):
            if document:
                snapshot, cache = candidate, None
            call = _MemoryCall(snapshot, candidate)
            output = self.model.language_model(
                input_ids=event,
                past_key_values=cache,
                use_cache=True,
                memory_call=call,
                return_dict=True,
            )
            candidate, cache = call.results, output.past_key_values
        return candidate

    def create_session(self, tokenizer, *, system_prompt=None, tools=None, state=None):
        return MemTSession(self, tokenizer, system_prompt=system_prompt, tools=tools, state=state)


class MemTSessionError(RuntimeError):
    """A failed session operation, including any already-returnable answer."""

    def __init__(
        self,
        stage,
        reason,
        *,
        result=None,
        turn_retained=False,
        memory_updated=False,
        publication="not_published",
    ):
        super().__init__(f"{stage}: {reason}")
        self.stage = stage
        self.reason = str(reason)
        self.result = deepcopy(result or {})
        self.answer = self.result.get("answer")
        self.generation_completed = self.result.get("generation_completed", False)
        self.memory_updated = memory_updated
        self.turn_retained = turn_retained
        self.publication = publication


@dataclass
class _Turn:
    messages: list
    replay_ids: list
    enable_memory: bool
    enable_thinking: bool | None
    structured: bool
    generation_options: dict
    tool_calls: list = field(default_factory=list)


_TOOL_PATTERN = (
    r"<tool_call>\s*<function=(?P<name>[^<>\s]+)>\s*(?P<arguments>.*?)\s*</function>\s*</tool_call>"
)
_PARAMETER_PATTERN = r"<parameter=(?P<name>[^<>\s]+)>\n?(?P<value>.*?)\n?</parameter>"
_TOOL_SCHEMA = {
    "type": "array",
    "x-regex-iterator": _TOOL_PATTERN,
    "items": {
        "type": "object",
        "properties": {
            "name": {"type": "string"},
            "arguments": {
                "type": "array",
                "x-regex-iterator": _PARAMETER_PATTERN,
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "value": {"type": "string"},
                    },
                },
            },
        },
    },
}


class MemTSession:
    """Single-text-sequence session. Tools execute exclusively in caller code.

    Each operation is serialized within this session. Different sessions may use
    the same model sequentially; concurrent model execution is not coordinated.
    """

    def __init__(self, model, tokenizer, *, system_prompt=None, tools=None, state=None):
        if system_prompt is not None and not isinstance(system_prompt, str):
            raise TypeError("system_prompt must be text or None")
        if tools is not None and not isinstance(tools, list):
            raise TypeError("tools must be a list of function schemas")
        self.model, self.tokenizer = model, tokenizer
        self._system_prompt, self._tools = system_prompt, deepcopy(tools or [])
        self._functions = {}
        for tool in self._tools:
            function = tool["function"]
            name = function["name"]
            if tool.get("type", "function") != "function" or name in self._functions:
                raise ValueError("tools must have unique function names")
            self._functions[name] = function
        self._lock = threading.RLock()
        self._history, self._memory, self._pending = [], {}, None
        self._first_turn, self._closed = state is None, False
        if state is not None:
            self._memory = self._load_state(state)

    def _check_open(self):
        if self._closed:
            raise MemTSessionError("session", "session is closed; create a new session")

    @property
    def messages(self):
        """A detached view of the uncompressed conversation, excluding system."""
        with self._lock:
            turns = self._history + ([self._pending] if self._pending else [])
            return deepcopy([message for turn in turns for message in turn.messages])

    def _encode(self, text):
        return self.tokenizer.encode(text, add_special_tokens=False)

    def _tensor(self, ids):
        return torch.tensor(
            [ids],
            dtype=torch.long,
            device=self.model.get_input_embeddings().weight.device,
        )

    def _render(self, messages, *, generation=False, thinking=None, context=False):
        options = {"preserve_thinking": True}
        if thinking is not None:
            options["enable_thinking"] = thinking
        messages = list(messages)
        if context and self._system_prompt is not None:
            messages.insert(0, {"role": "system", "content": self._system_prompt})
        return self.tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=generation,
            tools=self._tools if context else None,
            **options,
        )

    def _validate_options(self, options):
        reserved = {
            "memory",
            "enable_memory",
            "memory_state",
            "past_key_values",
            "inputs",
            "input_ids",
            "inputs_embeds",
            "attention_mask",
            "position_ids",
            "streamer",
            "assistant_prefill",
            "continue_final_message",
            "enable_thinking",
            "return_dict",
            "preserve_thinking",
        }
        invalid = reserved.intersection(options)
        if invalid:
            raise ValueError(f"Session does not accept generation options: {sorted(invalid)}")
        config = options.get("generation_config") or self.model.generation_config
        if (options.get("num_return_sequences", config.num_return_sequences) or 1) != 1:
            raise ValueError("Session requires one returned sequence")

    def _parse_tools(self, content):
        if not self._tools or "<tool_call>" not in content:
            return []
        matches = list(re.finditer(_TOOL_PATTERN, content, flags=re.DOTALL))
        if not matches or re.sub(_TOOL_PATTERN, "", content, flags=re.DOTALL).count("<tool_call>"):
            raise ValueError("incomplete or malformed tool request")
        parsed = self.tokenizer.parse_response(content, schema=_TOOL_SCHEMA)
        calls = []
        for item, match in zip(parsed, matches):
            function = self._functions.get(item["name"])
            if function is None:
                raise ValueError(f"unknown tool: {item['name']}")
            if re.sub(_PARAMETER_PATTERN, "", match["arguments"], flags=re.DOTALL).strip():
                raise ValueError("malformed tool parameters")
            parameters = function.get("parameters", {})
            properties = parameters.get("properties", {})
            arguments = {}
            for argument in item.get("arguments") or []:
                name, value = argument["name"], argument["value"]
                if name in arguments:
                    raise ValueError(f"duplicate tool argument: {name}")
                if name not in properties and parameters.get("additionalProperties") is False:
                    raise ValueError(f"unknown tool argument: {name}")
                if properties.get(name, {}).get("type") != "string":
                    try:
                        value = json.loads(value)
                    except json.JSONDecodeError:
                        if properties.get(name, {}).get("type") is not None:
                            raise ValueError(f"invalid JSON tool argument: {name}") from None
                arguments[name] = value
            if set(parameters.get("required", [])) - arguments.keys():
                raise ValueError("missing required tool arguments")
            calls.append(
                {
                    "id": "call_" + uuid.uuid4().hex,
                    "type": "function",
                    "function": {"name": item["name"], "arguments": arguments},
                }
            )
        return calls

    @staticmethod
    def _without_thinking(text):
        if "</think>" in text:
            text = text.split("</think>", 1)[1].lstrip("\n")
        return re.sub(r"<think>.*?(?:</think>|$)", "", text, flags=re.DOTALL).lstrip("\n")

    def _generate(self, turn, memory):
        messages = [
            message for previous in self._history for message in previous.messages
        ] + turn.messages
        prompt = self._render(
            messages, generation=True, thinking=turn.enable_thinking, context=True
        )
        ids = self._encode(prompt)
        if len(ids) >= self.model.config.get_text_config().max_position_embeddings:
            raise ValueError("prompt exceeds the model context; no history was truncated")
        options = dict(turn.generation_options)
        options["return_dict_in_generate"] = True
        inputs = self._tensor(ids)
        requested_config = options.get("generation_config")
        # Match generate's unset-length checks before defaults are filled.
        default_lengths = {
            name: options.get(name) is None
            and (requested_config is None or getattr(requested_config, name) is None)
            and getattr(self.model.generation_config, name) is None
            for name in ("max_length", "min_length")
        }
        generation_config, _ = self.model._prepare_generation_config(
            requested_config,
            **{key: value for key, value in options.items() if key != "generation_config"},
        )
        generation_config = self.model._prepare_generated_length(
            generation_config=generation_config,
            has_default_max_length=default_lengths["max_length"],
            has_default_min_length=default_lengths["min_length"],
            model_input_name="input_ids",
            input_ids_length=len(ids),
            inputs_tensor=inputs,
        )
        # Keep generate's original inputs; the resolved copy is only for reporting.
        output = self.model.generate(
            inputs,
            attention_mask=torch.ones_like(inputs),
            memory_state=memory or None,
            **options,
        )
        generated = output.sequences[0, len(ids) :].tolist()
        if not generated:
            raise ValueError("generation returned no tokens")
        eos = generation_config.eos_token_id
        eos = [eos] if isinstance(eos, int) else list(eos or [])
        completed = generated[-1] in eos
        visible_ids = generated[:-1] if completed else generated
        raw = self.tokenizer.decode(visible_ids, skip_special_tokens=False)
        # The template supplies this opening tag, not the decoder output.
        body = ("<think>\n" + raw) if prompt.endswith("<think>\n") else raw
        answer = self._without_thinking(body) if turn.enable_thinking is False else body
        limit = generation_config.max_length - len(ids)
        finish_reason = "eos" if completed else ("length" if len(generated) >= limit else "stopped")
        result = {
            "answer": answer,
            "finish_reason": finish_reason,
            "generation_completed": completed,
            "turn_completed": completed,
            "memory_updated": False,
            "committed_turns": 0,
            "documents_imported": 0,
            "input_tokens": len(ids),
            "output_tokens": len(generated),
            "tool_calls": [],
            "requires_action": False,
        }
        calls = []
        if self._tools and "<tool_call>" in self._without_thinking(body):
            try:
                calls = self._parse_tools(self._without_thinking(body))
            except ValueError as error:
                if completed:
                    raise MemTSessionError("tool_parse", error, result=result) from error
        if calls:
            result.update(
                finish_reason="tool_calls",
                turn_completed=False,
                tool_calls=calls,
                requires_action=True,
            )
        # Prompt views are re-templated; replay keeps the exact generated IDs.
        turn.messages.append({"role": "assistant", "content": body})
        turn.replay_ids.extend(generated)
        turn.tool_calls = calls
        return result

    def _replay(self, turns, memory):
        candidate = memory
        for turn in turns:
            candidate = self.model.commit_memory(self._tensor(turn.replay_ids), candidate)
        return candidate

    def _finish(self, turn, result, memory):
        self._memory, self._first_turn = memory, False
        if turn.tool_calls:
            self._pending = turn
        else:
            self._pending = None
            self._history = self._history + [turn]
            if turn.enable_memory and result["generation_completed"]:
                turns = self._history
                try:
                    candidate = self._replay(turns, memory)
                except Exception as error:
                    raise MemTSessionError(
                        "replay", error, result=result, turn_retained=True
                    ) from error
                self._memory, self._history = candidate, []
                result.update(memory_updated=True, committed_turns=len(turns))
        return deepcopy(result) if turn.structured else result["answer"]

    def chat(
        self,
        query,
        *,
        memory=None,
        enable_memory=False,
        enable_thinking=None,
        return_dict=False,
        **generation_options,
    ):
        """Generate first, then optionally commit uncompressed turns including this one."""
        with self._lock:
            self._check_open()
            if self._pending is not None:
                raise MemTSessionError("input", "submit the pending tool results before a new chat")
            if not isinstance(query, str):
                raise TypeError(
                    "query must be text; multimodal messages and assistant prefill are unsupported"
                )
            if type(enable_memory) is not bool or type(return_dict) is not bool:
                raise TypeError("enable_memory and return_dict must be bool")
            if enable_thinking is not None and type(enable_thinking) is not bool:
                raise TypeError("enable_thinking must be bool or None")
            self._validate_options(generation_options)
            documents = [] if memory is None else ([memory] if isinstance(memory, str) else memory)
            if memory is not None and not self._first_turn:
                raise MemTSessionError("input", "documents are accepted only in the first chat")
            if not isinstance(documents, list) or not all(
                isinstance(item, str) for item in documents
            ):
                raise TypeError("memory must be text or a list of document strings")
            messages = [{"role": "user", "content": query}]
            turn = _Turn(
                messages,
                self._encode(self._render(messages, generation=True, thinking=enable_thinking)),
                enable_memory,
                enable_thinking,
                bool(self._tools) or return_dict,
                dict(generation_options),
            )
            candidate = self._memory
            try:
                for document in documents:
                    tokens = self._encode(self._render([{"role": "user", "content": document}]))
                    candidate = self.model.commit_memory(
                        self._tensor(tokens), candidate, document=True
                    )
            except Exception as error:
                raise MemTSessionError("document", error) from error
            try:
                result = self._generate(turn, candidate)
            except MemTSessionError:
                raise
            except Exception as error:
                raise MemTSessionError("generation", error) from error
            result["documents_imported"] = len(documents)
            return self._finish(turn, result, candidate)

    def submit_tool_results(self, results, **generation_options):
        """Accept all results of the pending assistant message in a single batch."""
        with self._lock:
            self._check_open()
            if self._pending is None:
                raise MemTSessionError("input", "there are no pending tool requests")
            self._validate_options(generation_options)
            calls = self._pending.tool_calls
            if not isinstance(results, list) or len(results) != len(calls):
                raise ValueError("supply exactly one result for every pending tool call")
            by_id = {}
            for result in results:
                if not isinstance(result, dict) or not isinstance(result.get("content"), str):
                    raise TypeError("tool results require tool_call_id and text content")
                identifier = result.get("tool_call_id")
                if identifier in by_id or identifier not in {call["id"] for call in calls}:
                    raise ValueError("duplicate or unknown tool_call_id")
                by_id[identifier] = result["content"]
            turn = deepcopy(self._pending)
            tool_messages = [
                {
                    "role": "tool",
                    "tool_call_id": call["id"],
                    "content": by_id[call["id"]],
                }
                for call in calls
            ]
            # Render only the newly supplied result group and assistant prefix.
            dummy = [{"role": "user", "content": ""}]
            prefix = self._render(dummy)
            suffix = self._render(
                dummy + tool_messages, generation=True, thinking=turn.enable_thinking
            )[len(prefix) :]
            turn.replay_ids.extend(self._encode("\n" + suffix))
            turn.messages.extend(tool_messages)
            turn.generation_options.update(generation_options)
            try:
                result = self._generate(turn, self._memory)
            except MemTSessionError as error:
                error.turn_retained = True
                raise
            except Exception as error:
                # Nothing is consumed: the caller may resubmit already computed results.
                raise MemTSessionError("generation", error, turn_retained=True) from error
            return self._finish(turn, result, self._memory)

    def _state_identity(self):
        identity = {
            "backbone": self.model.config.backbone_configs,
            "memt": self.model.config.memt,
            "codec": "qwen-text-raw-v1",
            "template": self.tokenizer.chat_template,
            "vocabulary": self.tokenizer.get_vocab(),
        }
        return hashlib.sha256(
            json.dumps(identity, sort_keys=True, ensure_ascii=True).encode()
        ).hexdigest()

    def _load_state(self, path):
        try:
            path = Path(path)
            text = self.model.config.get_text_config()
            layers = [
                index for index, kind in enumerate(text.layer_types) if kind == "full_attention"
            ]
            expected = {f"memory.{index}" for index in layers}
            memory = {}
            with safe_open(path, framework="pt", device="cpu") as source:
                metadata = source.metadata() or {}
                if (
                    metadata.get("format") != "memt-memory-v1"
                    or metadata.get("identity") != self._state_identity()
                ):
                    raise ValueError("incompatible memory format, model or tokenizer")
                keys = set(source.keys())
                if keys and keys != expected:
                    raise ValueError("memory layer set does not match the model")
                for index in layers if keys else []:
                    tensor = source.get_tensor(f"memory.{index}")
                    shape = (1, text.num_attention_heads, text.head_dim, text.head_dim)
                    if (
                        tuple(tensor.shape) != shape
                        or tensor.dtype != torch.float32
                        or not torch.isfinite(tensor).all()
                    ):
                        raise ValueError(f"invalid FP32 memory tensor for layer {index}")
                    device = self.model.model.language_model.layers[
                        index
                    ].self_attn.memt.in_proj.weight.device
                    memory[index] = tensor.to(device=device, copy=True)
            return memory
        except Exception as error:
            raise MemTSessionError("load", error) from error

    def save_state(self, path, *, overwrite=False):
        """Flush all plaintext turns, then atomically publish a memory-only file."""
        if type(overwrite) is not bool:
            raise TypeError("overwrite must be bool")
        with self._lock:
            self._check_open()
            if self._pending is not None:
                raise MemTSessionError("save", "cannot save while tool results are pending")
            path = Path(path)
            if not overwrite and os.path.lexists(path):
                raise MemTSessionError("save", f"file already exists: {path}")
            temporary, published, publishing = None, False, False
            try:
                candidate = self._replay(self._history, self._memory)
                tensors = {
                    f"memory.{index}": tensor.detach()
                    .to(device="cpu", dtype=torch.float32)
                    .contiguous()
                    for index, tensor in candidate.items()
                }
                descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
                os.close(descriptor)
                save_file(
                    tensors,
                    temporary,
                    metadata={
                        "format": "memt-memory-v1",
                        "identity": self._state_identity(),
                    },
                )
                with open(temporary, "rb") as handle:
                    os.fsync(handle.fileno())
                publishing = True
                if overwrite:
                    os.replace(temporary, path)
                else:
                    os.link(temporary, path)
                published = True
                # Publication precedes RAM adoption. A later failure closes this session.
                self._memory, self._history = candidate, []
                directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
                if os.path.exists(temporary):
                    os.unlink(temporary)
                temporary = None
            except Exception as error:
                uncertain = publishing and not published and not isinstance(error, FileExistsError)
                if published or uncertain:
                    self._closed = True
                failure = MemTSessionError(
                    "save_publish" if publishing else "save",
                    error,
                    turn_retained=not published and not uncertain,
                    memory_updated=published,
                    publication="published"
                    if published
                    else ("uncertain" if uncertain else "not_published"),
                )
                if temporary is not None and os.path.exists(temporary):
                    try:
                        os.unlink(temporary)
                    except OSError as cleanup_error:
                        failure.add_note(
                            f"Temporary snapshot retained at {temporary}: {cleanup_error}"
                        )
                raise failure from error
            return {"path": str(path), "publication": "published"}

    def reset(self):
        with self._lock:
            self._check_open()
            self._history, self._memory, self._pending = [], {}, None
            self._first_turn = True

    def close(self):
        with self._lock:
            self._history, self._memory, self._pending = [], {}, None
            self._closed = True


MemTQwen3_5MoeForCausalLM.register_for_auto_class("AutoModelForCausalLM")
