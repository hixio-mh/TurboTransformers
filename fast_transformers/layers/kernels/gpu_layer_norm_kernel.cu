#include <cuda_runtime.h>
#include <immintrin.h>
#include <numeric>
#include "fast_transformers/layers/kernels/gpu_common.h"
#include "fast_transformers/layers/kernels/gpu_layer_norm_kernel.h"

namespace fast_transformers {
namespace layers {
namespace kernels {

inline __device__ void get_mean_variance(float val, float* s_mean,
                                         float* s_variance, int n, int tid) {
  float sum1 = val, sum2 = val * val;
  blockReduceSum_Elem2(&sum1, &sum2);
  float mean = sum1 / n;
  float mean_2 = sum2 / n;

  if (tid == 0) {
    *s_mean = mean;
    *s_variance = rsqrtf(mean_2 - mean * mean + 1e-6f);
  }
  __syncthreads();
}

template <bool isAdd>
static __global__ void layer_norm_kernel(float* out, const float* input,
                                         const float* bias, const float* gamma,
                                         const float* beta, int m, int n) {
  int tid = threadIdx.x;
  int offset = blockIdx.x * n + tid;
  __shared__ float s_mean;
  __shared__ float s_variance;

  float local_out = 0.0f;
  if (isAdd) {
    local_out = out[offset] + input[offset] + __ldg(&bias[tid]);
  } else {
    local_out = (out[offset]);
  }

  get_mean_variance(local_out, &s_mean, &s_variance, n, tid);
  out[offset] = (local_out - s_mean) * s_variance * __ldg(&gamma[tid]) +
                __ldg(&beta[tid]);
}

template <bool isAdd>
static __global__ void layer_norm_kernel_nvidia(float* out, const float* input,
                                                const float* bias,
                                                const float* gamma,
                                                const float* beta, int m,
                                                int n) {
  int tid = threadIdx.x;

  __shared__ float s_mean;
  __shared__ float s_variance;
  float mean = 0.0f;
  float variance = 0.0f;

  float local_out = 0.0f;
  if (isAdd) {
    for (int i = tid; i < n; i += blockDim.x)
      local_out += (float)(out[blockIdx.x * n + i] + input[blockIdx.x * n + i] +
                           __ldg(&bias[i]));
  } else {
    for (int i = tid; i < n; i += blockDim.x)
      local_out = input[blockIdx.x * n + i];
  }

  mean = blockReduceSum(local_out);
  if (threadIdx.x == 0) s_mean = mean / n;
  __syncthreads();

  variance = blockReduceSum((local_out - s_mean) * (local_out - s_mean));
  if (threadIdx.x == 0) s_variance = variance / n + 1e-6f;
  __syncthreads();

  for (int i = tid; i < n; i += blockDim.x)
    out[blockIdx.x * n + i] =
        (float)(((local_out - s_mean) * rsqrtf(s_variance)) *
                    (float)(__ldg(&gamma[i])) +
                (float)(__ldg(&beta[i])));
}

template <>
void GPUAddBiasLayerNorm(float* out, const float* input, const float* bias,
                         const float* gamma, const float* beta, int m, int n,
                         cudaStream_t stream) {
  dim3 block(n);
  if (block.x > 1024) {
    throw std::runtime_error(
        "GPUAddBiasLayerNorm thread block size large than 1024");
  }
  dim3 grid(m);
  layer_norm_kernel<true>
      <<<grid, block, 0, stream>>>(out, input, bias, gamma, beta, m, n);
}

template <>
void GPULayerNorm(float* out, const float* gamma, const float* beta, int m,
                  int n, cudaStream_t stream) {
  dim3 block(n);
  if (block.x > 1024) {
    throw std::runtime_error(
        "GPUAddBiasLayerNorm thread block size large than 1024");
  }
  float* dummy = nullptr;

  dim3 grid(m);
  layer_norm_kernel<false>
      <<<grid, block, 0, stream>>>(out, out, dummy, gamma, beta, m, n);
}

}  // namespace kernels
}  // namespace layers
}  // namespace fast_transformers
