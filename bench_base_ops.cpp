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
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntSub)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] - B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntMul)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] * B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntDiv)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] / B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntMod)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] % B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BitAnd)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] & B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BitOr)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] | B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BitXor)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] ^ B_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BitNot)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = ~A_u64[i];

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, ShiftLeft)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] << (B_u64[i] & 31);

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, ShiftRight)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = A_u64[i] >> (B_u64[i] & 31);

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, CmpEq)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    uint64_t sum = 0;
    for (auto _ : state)
    {
        sum = 0;
        for (size_t i = 0; i < N; ++i)
            sum += (A_u64[i] == B_u64[i]);

        benchmark::DoNotOptimize(sum);
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, CmpGt)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    uint64_t sum = 0;
    for (auto _ : state)
    {
        sum = 0;
        for (size_t i = 0; i < N; ++i)
            sum += (A_u64[i] > B_u64[i]);

        benchmark::DoNotOptimize(sum);
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntMin)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = std::min(A_u64[i], B_u64[i]);

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, IntMax)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = std::max(A_u64[i], B_u64[i]);

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, FloatAdd)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_f64[i] = A_f64[i] + B_f64[i];

        benchmark::DoNotOptimize(C_f64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(double));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, FloatSub)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_f64[i] = A_f64[i] - B_f64[i];

        benchmark::DoNotOptimize(C_f64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(double));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, FloatMul)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_f64[i] = A_f64[i] * B_f64[i];

        benchmark::DoNotOptimize(C_f64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(double));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, FloatDiv)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_f64[i] = A_f64[i] / B_f64[i];

        benchmark::DoNotOptimize(C_f64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(double));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, LoadOnly)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    uint64_t acc = 0;
    for (auto _ : state)
    {
        acc = 0;
        for (size_t i = 0; i < N; ++i)
            acc += A_u64[i];

        benchmark::DoNotOptimize(acc);
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, StoreOnly)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
            C_u64[i] = static_cast<uint64_t>(i);

        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, CopyMem)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    for (auto _ : state)
    {
        std::memcpy(C_u64.data(), A_u64.data(), N * sizeof(uint64_t));
        benchmark::DoNotOptimize(C_u64.data());
        // benchmark::ClobberMemory();
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BranchPredictable)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    uint64_t acc = 0;
    for (auto _ : state)
    {
        acc = 0;
        for (size_t i = 0; i < N; ++i)
        {
            if ((i & 1023) != 0)
                acc += A_u64[i];
            else
                acc += B_u64[i];
        }

        benchmark::DoNotOptimize(acc);
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

BENCHMARK_DEFINE_F(PrimitiveOpsFixture, BranchUnpredictable)(benchmark::State& state)
{
    if (!ok) { state.SkipWithError("allocation failed"); return; }

    uint64_t acc = 0;
    for (auto _ : state)
    {
        acc = 0;
        for (size_t i = 0; i < N; ++i)
        {
            if (A_u64[i] & 1)
                acc += A_u64[i];
            else
                acc += B_u64[i];
        }

        benchmark::DoNotOptimize(acc);
    }

    set_common_counters(state, N, sizeof(uint64_t));
}

#define REG_BENCH(name) \
    BENCHMARK_REGISTER_F(PrimitiveOpsFixture, name) \
        ->RangeMultiplier(2) \
        ->Range(1 << 10, 1 << 20)

REG_BENCH(IntAdd);
REG_BENCH(IntSub);
REG_BENCH(IntMul);
REG_BENCH(IntDiv);
REG_BENCH(IntMod);
REG_BENCH(BitAnd);
REG_BENCH(BitOr);
REG_BENCH(BitXor);
REG_BENCH(BitNot);
REG_BENCH(ShiftLeft);
REG_BENCH(ShiftRight);
REG_BENCH(CmpEq);
REG_BENCH(CmpGt);
REG_BENCH(IntMin);
REG_BENCH(IntMax);
REG_BENCH(FloatAdd);
REG_BENCH(FloatSub);
REG_BENCH(FloatMul);
REG_BENCH(FloatDiv);
REG_BENCH(LoadOnly);
REG_BENCH(StoreOnly);
REG_BENCH(CopyMem);
REG_BENCH(BranchPredictable);
REG_BENCH(BranchUnpredictable);

#undef REG_BENCH

BENCHMARK_MAIN();