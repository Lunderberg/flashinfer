/*
 * Copyright (c) 2023 by FlashInfer team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <flashinfer/prefill_attention_decl.cuh>

#include "flashinfer_ops.h"
#include "pytorch_extension_utils.h"

using namespace flashinfer;

std::vector<torch::Tensor> single_prefill_with_kv_cache(
    torch::Tensor q, torch::Tensor k, torch::Tensor v, torch::Tensor tmp, bool causal,
    unsigned int layout, unsigned int pos_encoding_mode, bool allow_fp16_qk_reduction,
    float logits_soft_cap, float sm_scale, float rope_scale, float rope_theta, bool return_lse) {
  CHECK_INPUT(q);
  CHECK_INPUT(k);
  CHECK_INPUT(v);
  CHECK_DIM(3, q);
  CHECK_DIM(3, k);
  CHECK_DIM(3, v);
  CHECK_SHAPE(k, v);
  CHECK_EQ(q.size(2), k.size(2));
  CHECK_EQ(q.scalar_type(), k.scalar_type());
  CHECK_EQ(q.scalar_type(), v.scalar_type());
  unsigned int head_dim = q.size(2);
  unsigned int kv_len, qo_len, num_kv_heads, num_qo_heads;
  QKVLayout kv_layout = static_cast<QKVLayout>(layout);
  qo_len = q.size(0);
  num_qo_heads = q.size(1);
  if (kv_layout == QKVLayout::kNHD) {
    kv_len = k.size(0);
    num_kv_heads = k.size(1);
  } else {
    kv_len = k.size(1);
    num_kv_heads = k.size(0);
  }
  CHECK_GQA_HEAD_DIVISIBLE(num_qo_heads, num_kv_heads);
  cudaStream_t torch_current_stream = c10::cuda::getCurrentCUDAStream();
  auto o = torch::empty_like(q, q.options());
  torch::Tensor lse = torch::empty({0});
  if (return_lse) {
    lse = torch::empty({qo_len, num_qo_heads}, q.options().dtype(torch::kFloat32));
  }

  const MaskMode mask_mode = causal ? MaskMode::kCausal : MaskMode::kNone;
  TORCH_CHECK(logits_soft_cap >= 0.f, "logits_soft_cap must be non-negative");
  const LogitsPostHook logits_post_hook =
      logits_soft_cap > 0.f ? LogitsPostHook::kSoftCap : LogitsPostHook::kNone;

  bool success = DISPATCH_PYTORCH_DTYPE_TO_CTYPE(q.scalar_type(), c_type, [&] {
    return DISPATCH_head_dim(head_dim, HEAD_DIM, [&] {
      return DISPATCH_mask_mode(mask_mode, MASK_MODE, [&] {
        return DISPATCH_logits_post_hook(logits_post_hook, LOGITS_POST_HOOK, [&] {
          return DISPATCH_kv_layout(kv_layout, KV_LAYOUT, [&] {
            return DISPATCH_allow_fp16_qk_reduction(
                allow_fp16_qk_reduction, ALLOW_FP16_QK_REDUCTION, [&] {
                  return DISPATCH_pos_encoding_mode(
                      PosEncodingMode(pos_encoding_mode), POS_ENCODING_MODE, [&] {
                        cudaError_t status =
                            SinglePrefillWithKVCacheDispatched<HEAD_DIM, LOGITS_POST_HOOK,
                                                               KV_LAYOUT, POS_ENCODING_MODE,
                                                               ALLOW_FP16_QK_REDUCTION, MASK_MODE>(
                                static_cast<c_type*>(q.data_ptr()),
                                static_cast<c_type*>(k.data_ptr()),
                                static_cast<c_type*>(v.data_ptr()),
                                /*custom_mask=*/nullptr, static_cast<c_type*>(o.data_ptr()),
                                static_cast<c_type*>(tmp.data_ptr()),
                                /*lse=*/return_lse ? static_cast<float*>(lse.data_ptr()) : nullptr,
                                num_qo_heads, num_kv_heads, qo_len, kv_len, logits_soft_cap,
                                sm_scale, rope_scale, rope_theta, torch_current_stream);
                        TORCH_CHECK(status == cudaSuccess,
                                    "SinglePrefillWithKVCache kernel launch failed, error: " +
                                        std::string(cudaGetErrorString(status)));
                        return true;
                      });
                });
          });
        });
      });
    });
  });

  if (return_lse) {
    return {o, lse};
  } else {
    return {o};
  }
}

std::vector<torch::Tensor> single_prefill_with_kv_cache_custom_mask(
    torch::Tensor q, torch::Tensor k, torch::Tensor v, torch::Tensor packed_custom_mask,
    torch::Tensor tmp, unsigned int layout, unsigned int pos_encoding_mode,
    bool allow_fp16_qk_reduction, float logits_soft_cap, float sm_scale, float rope_scale,
    float rope_theta, bool return_lse) {
  CHECK_INPUT(q);
  CHECK_INPUT(k);
  CHECK_INPUT(v);
  CHECK_INPUT(packed_custom_mask);
  CHECK_DIM(3, q);
  CHECK_DIM(3, k);
  CHECK_DIM(3, v);
  CHECK_DIM(1, packed_custom_mask);
  CHECK_SHAPE(k, v);
  CHECK_EQ(q.size(2), k.size(2));
  // packed_custom_mask must be uint8
  TORCH_CHECK(packed_custom_mask.scalar_type() == torch::kUInt8,
              "packed_custom_mask must be uint8");
  unsigned int head_dim = q.size(2);
  unsigned int kv_len, qo_len, num_kv_heads, num_qo_heads;
  QKVLayout kv_layout = static_cast<QKVLayout>(layout);
  qo_len = q.size(0);
  num_qo_heads = q.size(1);
  if (kv_layout == QKVLayout::kNHD) {
    kv_len = k.size(0);
    num_kv_heads = k.size(1);
  } else {
    kv_len = k.size(1);
    num_kv_heads = k.size(0);
  }
  CHECK_GQA_HEAD_DIVISIBLE(num_qo_heads, num_kv_heads);
  cudaStream_t torch_current_stream = c10::cuda::getCurrentCUDAStream();
  auto o = torch::empty_like(q, q.options());
  torch::Tensor lse = torch::empty({0});
  if (return_lse) {
    lse = torch::empty({qo_len, num_qo_heads}, q.options().dtype(torch::kFloat32));
  }

  constexpr MaskMode MASK_MODE = MaskMode::kCustom;
  TORCH_CHECK(logits_soft_cap >= 0.f, "logits_soft_cap must be non-negative");
  const LogitsPostHook logits_post_hook =
      logits_soft_cap > 0.f ? LogitsPostHook::kSoftCap : LogitsPostHook::kNone;

  bool success = DISPATCH_PYTORCH_DTYPE_TO_CTYPE(q.scalar_type(), c_type, [&] {
    return DISPATCH_head_dim(head_dim, HEAD_DIM, [&] {
      return DISPATCH_logits_post_hook(logits_post_hook, LOGITS_POST_HOOK, [&] {
        return DISPATCH_kv_layout(kv_layout, KV_LAYOUT, [&] {
          return DISPATCH_allow_fp16_qk_reduction(
              allow_fp16_qk_reduction, ALLOW_FP16_QK_REDUCTION, [&] {
                return DISPATCH_pos_encoding_mode(
                    PosEncodingMode(pos_encoding_mode), POS_ENCODING_MODE, [&] {
                      cudaError_t status = SinglePrefillWithKVCacheDispatched<
                          HEAD_DIM, LOGITS_POST_HOOK, KV_LAYOUT, POS_ENCODING_MODE,
                          ALLOW_FP16_QK_REDUCTION, MASK_MODE>(
                          static_cast<c_type*>(q.data_ptr()), static_cast<c_type*>(k.data_ptr()),
                          static_cast<c_type*>(v.data_ptr()),
                          static_cast<uint8_t*>(packed_custom_mask.data_ptr()),
                          static_cast<c_type*>(o.data_ptr()), static_cast<c_type*>(tmp.data_ptr()),
                          /*lse=*/return_lse ? static_cast<float*>(lse.data_ptr()) : nullptr,
                          num_qo_heads, num_kv_heads, qo_len, kv_len, logits_soft_cap, sm_scale,
                          rope_scale, rope_theta, torch_current_stream);
                      TORCH_CHECK(status == cudaSuccess,
                                  "SinglePrefillWithKVCache kernel launch failed, error: " +
                                      std::string(cudaGetErrorString(status)));
                      return true;
                    });
              });
        });
      });
    });
  });

  if (return_lse) {
    return {o, lse};
  } else {
    return {o};
  }
}
