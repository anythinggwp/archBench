#include <benchmark/benchmark.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

struct MatrixFixture : public benchmark::Fixture
{
    std::vector<double> A;
    std::vector<double> B;
    std::vector<double> C;

    size_t dim = 0;
    size_t elems = 0;
    bool alloc_ok = true;

    static constexpr size_t kL1BytesDefault = 32 * 1024; // 32 KB
    static constexpr size_t kMatricesCount = 3;          // A, B, C

    void init_data(size_t n)
    {
        dim = n;
        elems = dim * dim;

        A.resize(elems);
        B.resize(elems);
        C.resize(elems);

        for (size_t i = 0; i < elems; ++i)
        {
            A[i] = static_cast<double>(i);
            B[i] = static_cast<double>(i % 7);
            C[i] = 0.0;
        }
    }

    void SetUp(const benchmark::State& state) override
    {
        alloc_ok = true;
        const size_t n = static_cast<size_t>(state.range(0));

        try
        {
            init_data(n);
        }
        catch (...)
        {
            alloc_ok = false;
        }
    }

    void TearDown(const benchmark::State&) override
    {
        A.clear();
        B.clear();
        C.clear();
        A.shrink_to_fit();
        B.shrink_to_fit();
        C.shrink_to_fit();
    }
};

static inline void matrix_add_scalar(double* dst, const double* a, const double* b, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        dst[i] = a[i] + b[i];
}

// Рабочий набор: A + B + C должен помещаться в L1.
// Для double: 8 байт.
// Значит 3 * N * N * 8 <= L1.
//
// Для 32 KB L1:
// N^2 <= 32768 / 24 = 1365
// N <= 36
//
// Берем безопасные размеры до 32.
BENCHMARK_DEFINE_F(MatrixFixture, MatrixAdd_L1Fit)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("allocation failed");
        return;
    }

    for (auto _ : state)
    {
        matrix_add_scalar(C.data(), A.data(), B.data(), elems);
        benchmark::DoNotOptimize(C.data());
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(elems));
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(elems * 3 * sizeof(double)));
}

BENCHMARK_REGISTER_F(MatrixFixture, MatrixAdd_L1Fit)
    ->Arg(8)
    ->Arg(16)
    ->Arg(24)
    ->Arg(32);

// Выходим за L1.
// Для 32 KB L1 уже 40x40x3x8 = 38,400 байт > 32 KB.
// Дадим несколько размеров выше границы.
BENCHMARK_DEFINE_F(MatrixFixture, MatrixAdd_OverL1)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("allocation failed");
        return;
    }

    for (auto _ : state)
    {
        matrix_add_scalar(C.data(), A.data(), B.data(), elems);
        benchmark::DoNotOptimize(C.data());
        benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(elems));
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(elems * 3 * sizeof(double)));
}

BENCHMARK_REGISTER_F(MatrixFixture, MatrixAdd_OverL1)
    ->Arg(40)
    ->Arg(48)
    ->Arg(64)
    ->Arg(96)
    ->Arg(128);

BENCHMARK_MAIN();