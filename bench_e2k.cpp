#include <benchmark/benchmark.h>
#include <unordered_map>
#include <map>
#include <vector>
#include <random>
#include <algorithm>
#include <eml.h>

struct Fixture : public benchmark::Fixture
{
    std::vector<uint64_t> keys;
    std::unordered_map<uint64_t, double> hash_index;
    std::map<uint64_t, double> btree_index;

    std::vector<double> A;
    std::vector<double> B;
    std::vector<double> C;

    size_t matrix_size;

    void SetUp(const ::benchmark::State &state)
    {
        size_t N = state.range(0);

        keys.resize(N);
        std::iota(keys.begin(), keys.end(), 0);

        std::mt19937_64 rng(42);
        std::shuffle(keys.begin(), keys.end(), rng);

        hash_index.reserve(N);

        for (size_t i = 0; i < N; ++i)
        {
            hash_index[keys[i]] = double(keys[i]);
            btree_index[keys[i]] = double(keys[i]);
        }

        // матрицы
        matrix_size = std::sqrt(N);
        matrix_size = std::max<size_t>(matrix_size, 4);

        size_t M = matrix_size * matrix_size;

        A.resize(M);
        B.resize(M);
        C.resize(M);

        for (size_t i = 0; i < M; i++)
        {
            A[i] = double(i);
            B[i] = double(i % 7);
        }
    }

    void TearDown(const ::benchmark::State &)
    {
        hash_index.clear();
        btree_index.clear();
        keys.clear();
        A.clear();
        B.clear();
        C.clear();
    }
};

//
// matrix addition
//
BENCHMARK_DEFINE_F(Fixture, MatrixAdd)(benchmark::State &state)
{
    size_t M = matrix_size * matrix_size;
    std::vector<double> C_add1(M); // отдельный буфер для этого теста
    for (auto _ : state)
    {
        for (size_t i = 0; i < M; ++i)
        {
            eml_add(&C_add1[0], &A[0], &B[0], M);
        }

        benchmark::DoNotOptimize(C_add1.data());
        // benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * M);
}
BENCHMARK_REGISTER_F(Fixture, MatrixAdd)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

// matrix add 2
BENCHMARK_DEFINE_F(Fixture, MatrixAdd_2)(benchmark::State &state)
{
    size_t M = matrix_size * matrix_size;
    std::vector<double> C_add2(M); // отдельный буфер для этого теста
    for (auto _ : state)
    {
        for (size_t i = 0; i < M; i += 4)
        {
            C_add2[i] = A[i] + B[i];
            C_add2[i + 1] = A[i + 1] + B[i + 1];
            C_add2[i + 2] = A[i + 2] + B[i + 2];
            C_add2[i + 3] = A[i + 3] + B[i + 3];
        }

        benchmark::DoNotOptimize(C_add2.data());
        // benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * M);
}
BENCHMARK_REGISTER_F(Fixture, MatrixAdd_2)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);
//
// scalar product
//
BENCHMARK_DEFINE_F(Fixture, DotProduct)(benchmark::State &state)
{
    size_t M = matrix_size * matrix_size;

    for (auto _ : state)
    {
        double sum = 0.0;

        for (size_t i = 0; i < M; ++i)
        {
            sum += A[i] * B[i];
        }

        benchmark::DoNotOptimize(sum);
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * M);
}
BENCHMARK_REGISTER_F(Fixture, DotProduct)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// matrix transposition
//
BENCHMARK_DEFINE_F(Fixture, MatrixTranspose)(benchmark::State &state)
{
    size_t N = matrix_size;

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; i++)
        {
            for (size_t j = 0; j < N; j++)
            {
                C[j * N + i] = A[i * N + j];
            }
        }

        benchmark::DoNotOptimize(C.data());
        // benchmark::ClobberMemory();
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N * N);
}
BENCHMARK_REGISTER_F(Fixture, MatrixTranspose)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// Matrix multiplication (O(n³))
//
BENCHMARK_DEFINE_F(Fixture, MatrixMultiply)(benchmark::State &state)
{
    size_t N = matrix_size;

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; i++)
        {
            for (size_t j = 0; j < N; j++)
            {
                double sum = 0.0;

                for (size_t k = 0; k < N; k++)
                {
                    sum += A[i * N + k] * B[k * N + j];
                }

                C[i * N + j] = sum;
            }
        }

        benchmark::DoNotOptimize(C.data());
        // benchmark::ClobberMemory();
    }

    // количество обработанных элементов
    state.SetItemsProcessed(int64_t(state.iterations()) * N * N);
}
BENCHMARK_REGISTER_F(Fixture, MatrixMultiply)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);
//
// INSERT (batch)
//
BENCHMARK_DEFINE_F(Fixture, InsertHash)(benchmark::State &state)
{
    size_t N = state.range(0);

    for (auto _ : state)
    {
        state.PauseTiming();
        hash_index.clear();
        state.ResumeTiming();

        for (size_t i = 0; i < N; ++i)
        {
            hash_index[keys[i]] = double(keys[i]);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, InsertHash)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// POINT LOOKUP (HASH)
//
BENCHMARK_DEFINE_F(Fixture, SelectHash)(benchmark::State &state)
{
    size_t N = state.range(0);

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
        {
            auto it = hash_index.find(keys[i]);
            benchmark::DoNotOptimize(it);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, SelectHash)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// POINT LOOKUP (BTREE)
//
BENCHMARK_DEFINE_F(Fixture, SelectBTree)(benchmark::State &state)
{
    size_t N = state.range(0);

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
        {
            auto it = btree_index.find(keys[i]);
            benchmark::DoNotOptimize(it);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, SelectBTree)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// RANGE SCAN (25% диапазона)
//
BENCHMARK_DEFINE_F(Fixture, RangeScanBTree)(benchmark::State &state)
{
    size_t N = state.range(0);
    size_t from = N / 4;
    size_t to = N / 2;

    for (auto _ : state)
    {
        auto start = btree_index.lower_bound(from);
        auto end = btree_index.upper_bound(to);

        for (auto it = start; it != end; ++it)
        {
            benchmark::DoNotOptimize(it->second);
        }
    }
}
BENCHMARK_REGISTER_F(Fixture, RangeScanBTree)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// UPDATE
//
BENCHMARK_DEFINE_F(Fixture, UpdateHash)(benchmark::State &state)
{
    size_t N = state.range(0);

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
        {
            hash_index[keys[i]] += 1.0;
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, UpdateHash)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// DELETE
//
BENCHMARK_DEFINE_F(Fixture, DeleteHash)(benchmark::State &state)
{
    size_t N = state.range(0);

    for (auto _ : state)
    {
        state.PauseTiming();
        hash_index.clear();
        for (size_t i = 0; i < N; ++i)
            hash_index[keys[i]] = double(keys[i]);
        state.ResumeTiming();

        for (size_t i = 0; i < N; ++i)
        {
            hash_index.erase(keys[i]);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, DeleteHash)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20);

//
// 80/20 READ-WRITE WORKLOAD
//
BENCHMARK_DEFINE_F(Fixture, Mixed80_20)(benchmark::State &state)
{
    size_t N = state.range(0);
    std::mt19937_64 rng(123);
    std::uniform_int_distribution<size_t> dist(0, N - 1);

    for (auto _ : state)
    {
        for (size_t i = 0; i < N; ++i)
        {
            if (i % 5 == 0)
            { // 20% writes
                hash_index[keys[i]] += 1.0;
            }
            else
            { // 80% reads
                auto it = hash_index.find(keys[dist(rng)]);
                benchmark::DoNotOptimize(it);
            }
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, Mixed80_20)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 20)
    ->Threads(1);

BENCHMARK_MAIN();