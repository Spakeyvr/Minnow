# ChatLLM MLX Swift fork

This directory vendors `mlx-swift` 0.30.6 (upstream revision
`6ba4827fb82c97d012eec9ab4b2de21f85c3b33d`) so ChatLLM can carry narrowly
scoped CoreSimulator Metal compatibility fixes.

The fork preserves the physical-device MLX path. Simulator-specific changes:

- derive the host Apple GPU architecture before MLX initializes;
- use standalone Metal buffers because CoreSimulator does not implement MLX's
  `MTLHeap` allocation path;
- size generic dispatches to the pipeline's reported threadgroup limit;
- use unfused GPU attention where the fused kernel requires 1024 threads; and
- precompile the float16 Qwen embedding lookup used after simulator weight
  normalization;
- disable NAX kernels, whose MetalPerformancePrimitives headers are unavailable
  to CoreSimulator's runtime Metal compiler.

ChatLLM's simulator loader widens only BF16 floating parameters to FP32 on CPU
before inference. The quantized integer weight storage remains packed. This
avoids fatal BF16 runtime-kernel compilation in CoreSimulator; physical devices
retain native BF16 and NAX paths.

Xcode 27 compatibility patches:

- async device/stream/state helpers use `nonisolated(nonsending)` closures for
  the non-deprecated `TaskLocal.withValue` overload;
- optional module/parameter wrappers explicitly preserve nested Optional values;
- Metal template recursion uses C++14 specialization, and constant attention
  branches use valid C++14 `if` statements;
- shared Metal constants are annotated as potentially unused in individual JIT
  compilation units; generated copies are kept in sync;
- fmt defers its standard string-view constraint to conversion, avoiding an
  unsupported `std::char_traits` instantiation for its internal UTF-8 enum;
- only Cmlx opts out of Xcode's additional `-Wshorten-64-to-32` diagnostic. MLX's
  upstream dimension API mixes 32-bit dimensions and 64-bit element counts.
  This preserves upstream arithmetic; it does not repair or audit every narrowing
  conversion. Other diagnostics, including deprecations, remain enabled.

The sibling `mlx-swift-lm` patches use the current attention-mask API, remove an
unused vision binding, and decode tool JSON through the existing Sendable
`JSONValue` representation instead of passing unconstrained `Any` across actors.

Decode throughput patches in `mlx-swift-lm`:

- repetition and presence penalties keep sampled tokens on the GPU. Upstream
  reads each token back with `item()` inside `TokenIterator.step`, which blocks
  on the whole forward pass and defeats `asyncEval` pipelining (about 28% of
  decode throughput with Qwen 3.5 sampling). A repetition penalty of exactly 1
  builds no processor;
- `FilteredSampler` applies top-k by slicing the sorted tail instead of masking
  the vocabulary with a rank array rebuilt on the CPU every token;
- RotorQuant decode attention spreads the exact (unquantized) tail across
  parallel blocks instead of one SIMD group per KV head, and passes buffer
  capacities at runtime so cache growth does not compile new Metal pipelines;
- the fused RotorQuant decode kernel accepts any IsoQuant head dimension that
  is a multiple of 4 up to 256, and up to 8-way GQA at D <= 128. Upstream's
  128/256-only guard sent LFM2.5 (D=64) through a full dequantize of the
  compressed history on every token;
- IsoQuant quantize/pack and unpack/dequantize run as Metal kernels instead
  of MLX-op chains whose uint32 bit-stream intermediates were many times the
  dense KV size, and a flush sizes compressed storage once instead of per
  64-row chunk. This removes the first-decode stall after a long prompt and
  the transient spike when a later turn's prefill reads compressed history;
- the unpack kernel writes the exact tail after the restored rows, so
  attention over compressed history no longer holds a second, concatenated
  copy. Its read of the tail also orders each layer's restore after the layer
  before it, so MLX does not restore every layer's history at once;
- `RotorQuantConfiguration.prefillExactLimit` (ChatLLM uses 4,096 tokens)
  compresses the rows before each prefill chunk once the cached context passes
  the limit, keeping the newest `exactBufferSize` rows exact. The decision uses
  only saved state, so a restored prompt prefix compresses like the live cache.
  Upstream kept the whole prompt dense until the first decode. Chunks past the
  limit attend to compressed history. The limit is saved as an optional 15th `metaState` value,
  and 14-value prompt caches still load.
- the presence penalty keeps a vocabulary-sized penalty vector instead of an
  index list that grew (and was copied) every token, so its per-token cost is
  one scatter and one subtraction regardless of output length;
- `TokenIterator` evaluates each cache layer's backing buffers
  (`innerState()`) after every step instead of `state`, whose getters build
  new slice arrays per layer per token, and RotorQuant's exact-tail storage
  check compares dimensions before building shape arrays.

Prompt-cache patches in `mlx-swift-lm`:

- Qwen 3.5 text prefill numbers positions from the KV cache offset. Upstream
  reset them to 0 for every `prepare`, so a turn appended to an existing cache
  (a reused chat session or a restored prompt prefix) was embedded at the wrong
  M-RoPE positions while decode used absolute ones;
- `ChatSession` can start from an existing KV cache, which ChatLLM uses to
  restore a saved system-prompt prefix (`MLXPromptPrefixCache`);
- `loadPromptCache` applies a RotorQuant layer's `metaState` before its
  `state`, so its quantizers are built once with the saved bit widths instead
  of first with the defaults.

Cancellation patches in `mlx-swift-lm`:

- the chunked text prefill in `LLMModel.prepare` and Qwen 3.5's `prepare`
  calls `Task.checkCancellation()` between chunks. Stopping a response during
  a long prefill otherwise kept the GPU and the model container busy for
  seconds; the prompt-prefix prefill and prefill tuning stop the same way.

Regression coverage lives in `ChatLLMTests+LFM.swift`; the opt-in real model tests
and their simulator setup are documented in the root README. Reassess these
patches against upstream before updating either dependency.
