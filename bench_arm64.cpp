#include <benchmark/benchmark.h>

#include <algorithm>
#include <arm_neon.h>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <numeric>
#include <random>
#include <unordered_map>
#include <vector>

struct Fixture : public benchmark::Fixture
{
    std::vector<uint64_t> keys;
    std::unordered_map<uint64_t, double> hash_index;
    std::map<uint64_t, double> btree_index;

    std::vector<double> A;
    std::vector<double> B;
    std::vector<double> C;

    double* A_simd = nullptr;
    double* B_simd = nullptr;
    double* C_simd = nullptr;

    size_t matrix_size = 0;
    bool alloc_ok = true;

    static double* aligned_alloc64(size_t count)
    {
#if defined(_MSC_VER)
        return static_cast<double*>(_aligned_malloc(count * sizeof(double), 64));
#else
        void* ptr = nullptr;
        if (posix_memalign(&ptr, 64, count * sizeof(double)) != 0)
            return nullptr;
        return static_cast<double*>(ptr);
#endif
    }

    static void aligned_free64(void* ptr)
    {
#if defined(_MSC_VER)
        _aligned_free(ptr);
#else
        free(ptr);
#endif
    }

    void SetUp(const ::benchmark::State& state) override
    {
        alloc_ok = true;

        const size_t N = static_cast<size_t>(state.range(0));

        keys.resize(N);
        std::iota(keys.begin(), keys.end(), 0);

        std::mt19937_64 rng(42);
        std::shuffle(keys.begin(), keys.end(), rng);

        hash_index.clear();
        btree_index.clear();
        hash_index.reserve(N);

        for (size_t i = 0; i < N; ++i)
        {
            hash_index[keys[i]] = static_cast<double>(keys[i]);
            btree_index[keys[i]] = static_cast<double>(keys[i]);
        }

        matrix_size = std::max<size_t>(
            static_cast<size_t>(std::sqrt(static_cast<double>(N))), 4);

        const size_t M = matrix_size * matrix_size;

        A.resize(M);
        B.resize(M);
        C.resize(M);

        A_simd = aligned_alloc64(M);
        B_simd = aligned_alloc64(M);
        C_simd = aligned_alloc64(M);

        if (!A_simd || !B_simd || !C_simd)
        {
            alloc_ok = false;
            return;
        }

        for (size_t i = 0; i < M; ++i)
        {
            const double a = static_cast<double>(i);
            const double b = static_cast<double>(i % 7);

            A[i] = a;
            B[i] = b;
            C[i] = 0.0;

            A_simd[i] = a;
            B_simd[i] = b;
            C_simd[i] = 0.0;
        }
    }

    void TearDown(const ::benchmark::State&) override
    {
        aligned_free64(A_simd);
        aligned_free64(B_simd);
        aligned_free64(C_simd);

        A_simd = nullptr;
        B_simd = nullptr;
        C_simd = nullptr;

        hash_index.clear();
        btree_index.clear();
        keys.clear();
        A.clear();
        B.clear();
        C.clear();
    }
};

static inline void add_scalar(double* dst, const double* a, const double* b, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        dst[i] = a[i] + b[i];
}

#if defined(__aarch64__)
static inline void add_neon_f64(double* dst, const double* a, const double* b, size_t n)
{
    size_t i = 0;

    // float64x2_t = 2 double за итерацию
    for (; i + 2 <= n; i += 2)
    {
        float64x2_t va = vld1q_f64(a + i);
        float64x2_t vb = vld1q_f64(b + i);
        float64x2_t vc = vaddq_f64(va, vb);
        vst1q_f64(dst + i, vc);
    }

    for (; i < n; ++i)
        dst[i] = a[i] + b[i];
}
#endif

BENCHMARK_DEFINE_F(Fixture, MatrixAddScalar)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("aligned allocation failed");
        return;
    }

    const size_t M = matrix_size * matrix_size;

    for (auto _ : state)
    {
        add_scalar(C.data(), A.data(), B.data(), M);
        benchmark::DoNotOptimize(C.data());
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(M));

    state.counters["elements"] = static_cast<double>(M);
    state.counters["bytes"] = benchmark::Counter(
        static_cast<double>(state.iterations()) *
            static_cast<double>(M) * 3.0 * sizeof(double),
        benchmark::Counter::kIsRate);
}

BENCHMARK_REGISTER_F(Fixture, MatrixAddScalar)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);

#if defined(__aarch64__)
BENCHMARK_DEFINE_F(Fixture, MatrixAddNEON)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("aligned allocation failed");
        return;
    }

    const size_t M = matrix_size * matrix_size;

    for (auto _ : state)
    {
        add_neon_f64(C_simd, A_simd, B_simd, M);
        benchmark::DoNotOptimize(C_simd);
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(M));

    state.counters["elements"] = static_cast<double>(M);
    state.counters["bytes"] = benchmark::Counter(
        static_cast<double>(state.iterations()) *
            static_cast<double>(M) * 3.0 * sizeof(double),
        benchmark::Counter::kIsRate);
}

BENCHMARK_REGISTER_F(Fixture, MatrixAddNEON)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);
#endif

BENCHMARK_MAIN();