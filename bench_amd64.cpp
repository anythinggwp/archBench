#include <benchmark/benchmark.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <immintrin.h>
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

    double *A_simd = nullptr;
    double *B_simd = nullptr;
    double *C_simd = nullptr;

    size_t matrix_size = 0;

    static double *aligned_alloc64(size_t count)
    {
#if defined(_MSC_VER)
        return static_cast<double *>(_aligned_malloc(count * sizeof(double), 64));
#else
        void *ptr = nullptr;
        if (posix_memalign(&ptr, 64, count * sizeof(double)) != 0)
            return nullptr;
        return static_cast<double *>(ptr);
#endif
    }

    static void aligned_free64(void *ptr)
    {
#if defined(_MSC_VER)
        _aligned_free(ptr);
#else
        free(ptr);
#endif
    }

    void SetUp(const ::benchmark::State &state) override
    {
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

        matrix_size = std::max<size_t>(static_cast<size_t>(std::sqrt(static_cast<double>(N))), 4);
        const size_t M = matrix_size * matrix_size;

        A.resize(M);
        B.resize(M);
        C.resize(M);

        A_simd = aligned_alloc64(M);
        B_simd = aligned_alloc64(M);
        C_simd = aligned_alloc64(M);

        if (!A_simd || !B_simd || !C_simd)
        {
            // state.SkipWithError("aligned allocation failed");
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

    void TearDown(const ::benchmark::State &) override
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

static inline void add_scalar(double *dst, const double *a, const double *b, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        dst[i] = a[i] + b[i];
}

#if defined(__AVX2__)
static inline void add_avx2(double *dst, const double *a, const double *b, size_t n)
{
    size_t i = 0;

    // 4 double за итерацию
    for (; i + 4 <= n; i += 4)
    {
        __m256d va = _mm256_load_pd(a + i);
        __m256d vb = _mm256_load_pd(b + i);
        __m256d vc = _mm256_add_pd(va, vb);
        _mm256_store_pd(dst + i, vc);
    }

    for (; i < n; ++i)
        dst[i] = a[i] + b[i];
}
#endif

BENCHMARK_DEFINE_F(Fixture, MatrixAddScalar)(benchmark::State &state)
{
    const size_t M = matrix_size * matrix_size;

    for (auto _ : state)
    {
        add_scalar(C.data(), A.data(), B.data(), M);
        benchmark::DoNotOptimize(C.data());
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(M));
    state.counters["elements"] = static_cast<double>(M);
    state.counters["bytes"] = benchmark::Counter(
        static_cast<double>(state.iterations()) * static_cast<double>(M) * 3.0 * sizeof(double),
        benchmark::Counter::kIsRate);
}
BENCHMARK_REGISTER_F(Fixture, MatrixAddScalar)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);

#if defined(__AVX2__)
BENCHMARK_DEFINE_F(Fixture, MatrixAddAVX2)(benchmark::State &state)
{
    const size_t M = matrix_size * matrix_size;

    for (auto _ : state)
    {
        add_avx2(C_simd, A_simd, B_simd, M);
        benchmark::DoNotOptimize(C_simd);
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(M));
    state.counters["elements"] = static_cast<double>(M);
    state.counters["bytes"] = benchmark::Counter(
        static_cast<double>(state.iterations()) * static_cast<double>(M) * 3.0 * sizeof(double),
        benchmark::Counter::kIsRate);
}
BENCHMARK_REGISTER_F(Fixture, MatrixAddAVX2)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);
#endif

BENCHMARK_MAIN();