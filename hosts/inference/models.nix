# The models this host can serve, each pinned to a Hugging Face commit and a
# sha256. `roles.inference.active` in configuration.nix picks the one served
# as `local`; only that one is downloaded and loaded.
#
# Every entry here is pinned to an upload from before 12 June 2026, when the
# pinned llama.cpp (b9608) was released, so it's known to load. Later
# re-uploads sometimes need a newer llama.cpp.
#
# Each model's sampling and thinking defaults are for voice: Home Assistant
# sends neither, and wants a quick answer. Clients that want the model to
# think ask for it per request in chat_template_kwargs (`enable_thinking`
# for Gemma and Qwen, `reasoning_effort` for gpt-oss).
{ ... }:
{
  roles.inference.models = {
    # 21B parameters, 3.6B active per token (MoE), MXFP4: about 12 GB of
    # weights, which leaves room for four 64K slots and Whisper. Pinned to the
    # conversion from before the July 2026 re-upload.
    gpt-oss-20b = {
      files = [
        {
          url = "https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/e1dc459feff949ff451ce107337a2026daa80df8/gpt-oss-20b-mxfp4.gguf";
          sha256 = "be37a636aca0fc1aae0d32325f82f6b4d21495f06823b5fbc1898ae0303e9935";
        }
      ];
      extraFlags = [
        # OpenAI's recommended sampling for gpt-oss.
        "--temp" "1.0"
        "--top-p" "1.0"
        # Low reasoning unless a request asks for more.
        "--chat-template-kwargs" ''{"reasoning_effort":"low"}''
      ];
    };

    # 26B parameters, about 4B active per token (128 experts, 8 used).
    # Unsloth's dynamic Q4_K_XL, 17.0 GB. Five of its 30 layers attend to the
    # whole context and the rest to the last 1024 tokens, so four 64K slots
    # take about 3,400 MiB of q8_0 cache: 21,014 MiB on the card in all, of
    # the 22,400 free beside Whisper.
    # Pinned to the 4 May 2026 upload, which has Google's updated chat
    # template (llama.cpp doesn't need its old-template workarounds for it).
    gemma-4-26b-a4b = {
      files = [
        {
          url = "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/3365c68df1a83799b846d05324ebfadbb8cc70b3/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
          sha256 = "453cf049ba87a29b9ed5739087b84b7fa0265a4f2b11eefa2c77683dec6a8020";
        }
      ];
      extraFlags = [
        # Google's recommended sampling.
        "--temp" "1.0"
        "--top-p" "0.95"
        "--top-k" "64"
        "--min-p" "0"
        # llama-server asks every template to think unless told not to.
        "--chat-template-kwargs" ''{"enable_thinking":false}''
      ];
    };

    # 35B parameters, 3B active per token (256 experts, 8 used). Three of
    # every four layers are linear attention with a small fixed state, so its
    # KV cache is a quarter of a usual model's: four 64K slots take about
    # 3,000 MiB. Q4_K_M (20.4 GB) doesn't fit beside that and Whisper, so
    # this is Unsloth's dynamic IQ4_XS, 17.7 GB: 20,288 MiB on the card in
    # all. The model test chose it (docs/inference/REFERENCE.md).
    "qwen3.6-35b-a3b" = {
      files = [
        {
          url = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
          sha256 = "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3";
        }
      ];
      extraFlags = [
        # Qwen's recommended sampling without thinking. With thinking on, it
        # recommends --temp 1.0 and --top-p 0.95; clients that turn thinking
        # on can send those too.
        "--temp" "0.7"
        "--top-p" "0.8"
        "--top-k" "20"
        "--min-p" "0"
        "--presence-penalty" "1.5"
        # The template thinks unless told not to.
        "--chat-template-kwargs" ''{"enable_thinking":false}''
      ];
    };
  };
}
