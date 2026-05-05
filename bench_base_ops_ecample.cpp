#include <benchmark/benchmark.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <numeric>
#include <random>
#include <vector>

struct PrimitiveOpsFixture : public benchmark::Fixture
{
    std::vector<uint64_t> A_u64;
    std::vector<uint64_t> B_u64;
    std::vector<uint64_t> C_u64;

    std::vector<double> A_f64;
    std::vector<double> B_f64;
    std::vector<double> C_f64;

    size_t N = 0;
    bool ok = true;

    void SetUp(const benchmark::State& state) override
    {
        ok = true;
        N = static_cast<size_t>(state.range(0));

        try
        {
            A_u64.resize(N);
            B_u64.resize(N);
            C_u64.resize(N);

            A_f64.resize(N);
            B_f64.resize(N);
            C_f64.resize(N);
        }
        catch (...)
        {
            ok = false;
            return;
        }

        std::mt19937_64 rng(42);
        std::uniform_int_distribution<uint64_t> du64(1, std::numeric_limits<uint32_t>::max());
        std::uniform_real_distribution<double> dd(1.0, 1000.0);

        for (size_t i = 0; i < N; ++i)
        {
            A_u64[i] = du64(rng);
            B_u64[i] = du64(rng); // без нулей, чтобы div/mod были корректны
            C_u64[i] = 0;

            A_f64[i] = dd(rng);
            B_f64[i] = dd(rng);   // без нулей
            C_f64[i] = 0.0;
        }
    }

    void TearDown(const benchmark::State&) override
    {
        A_u64.clear();
        B_u64.clear();
        C_u64.clear();

        A_f64.clear();
        B_f64.clear();
        C_f64.clear();
    }
};

static inline void set_common_counters(benchmark::State& state, size_t N, size_t elem_size)
{
    state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(N));
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(N * elem_size));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntAdd)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] + B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

#define REG_BENCH(name) \
    BENCHMARK_REGISTER_F(PrimitiveOpsFixture, name) \
        ->RangeMultiplier(2) \
        ->Range(1 << 10, 1 << 20)

REG_BENCH(IntAdd);

#undef REG_BENCH

BENCHMARK_MAIN();