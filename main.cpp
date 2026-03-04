#include <benchmark/benchmark.h>
#include <unordered_map>
#include <map>
#include <vector>
#include <random>
#include <algorithm>

struct Fixture : public benchmark::Fixture {
    std::vector<uint64_t> keys;
    std::unordered_map<uint64_t, double> hash_index;
    std::map<uint64_t, double> btree_index;

    void SetUp(const ::benchmark::State& state) {
        size_t N = state.range(0);

        keys.resize(N);
        std::iota(keys.begin(), keys.end(), 0);

        std::mt19937_64 rng(42);
        std::shuffle(keys.begin(), keys.end(), rng);

        hash_index.reserve(N);

        for (size_t i = 0; i < N; ++i) {
            hash_index[keys[i]] = double(keys[i]);
            btree_index[keys[i]] = double(keys[i]);
        }
    }

    void TearDown(const ::benchmark::State&) {
        hash_index.clear();
        btree_index.clear();
        keys.clear();
    }
};

//
// INSERT (batch)
//
BENCHMARK_DEFINE_F(Fixture, InsertHash)(benchmark::State& state) {
    size_t N = state.range(0);

    for (auto _ : state) {
        state.PauseTiming();
        hash_index.clear();
        state.ResumeTiming();

        for (size_t i = 0; i < N; ++i) {
            hash_index[keys[i]] = double(keys[i]);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, InsertHash)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// POINT LOOKUP (HASH)
//
BENCHMARK_DEFINE_F(Fixture, SelectHash)(benchmark::State& state) {
    size_t N = state.range(0);

    for (auto _ : state) {
        for (size_t i = 0; i < N; ++i) {
            auto it = hash_index.find(keys[i]);
            benchmark::DoNotOptimize(it);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, SelectHash)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// POINT LOOKUP (BTREE)
//
BENCHMARK_DEFINE_F(Fixture, SelectBTree)(benchmark::State& state) {
    size_t N = state.range(0);

    for (auto _ : state) {
        for (size_t i = 0; i < N; ++i) {
            auto it = btree_index.find(keys[i]);
            benchmark::DoNotOptimize(it);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, SelectBTree)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// RANGE SCAN (25% диапазона)
//
BENCHMARK_DEFINE_F(Fixture, RangeScanBTree)(benchmark::State& state) {
    size_t N = state.range(0);
    size_t from = N / 4;
    size_t to   = N / 2;

    for (auto _ : state) {
        auto start = btree_index.lower_bound(from);
        auto end   = btree_index.upper_bound(to);

        for (auto it = start; it != end; ++it) {
            benchmark::DoNotOptimize(it->second);
        }
    }
}
BENCHMARK_REGISTER_F(Fixture, RangeScanBTree)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// UPDATE
//
BENCHMARK_DEFINE_F(Fixture, UpdateHash)(benchmark::State& state) {
    size_t N = state.range(0);

    for (auto _ : state) {
        for (size_t i = 0; i < N; ++i) {
            hash_index[keys[i]] += 1.0;
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, UpdateHash)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// DELETE
//
BENCHMARK_DEFINE_F(Fixture, DeleteHash)(benchmark::State& state) {
    size_t N = state.range(0);

    for (auto _ : state) {
        state.PauseTiming();
        hash_index.clear();
        for (size_t i = 0; i < N; ++i)
            hash_index[keys[i]] = double(keys[i]);
        state.ResumeTiming();

        for (size_t i = 0; i < N; ++i) {
            hash_index.erase(keys[i]);
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, DeleteHash)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20);

//
// 80/20 READ-WRITE WORKLOAD
//
BENCHMARK_DEFINE_F(Fixture, Mixed80_20)(benchmark::State& state) {
    size_t N = state.range(0);
    std::mt19937_64 rng(123);
    std::uniform_int_distribution<size_t> dist(0, N-1);

    for (auto _ : state) {
        for (size_t i = 0; i < N; ++i) {
            if (i % 5 == 0) { // 20% writes
                hash_index[keys[i]] += 1.0;
            } else { // 80% reads
                auto it = hash_index.find(keys[dist(rng)]);
                benchmark::DoNotOptimize(it);
            }
        }
    }

    state.SetItemsProcessed(int64_t(state.iterations()) * N);
}
BENCHMARK_REGISTER_F(Fixture, Mixed80_20)
    ->RangeMultiplier(4)
    ->Range(1<<10, 1<<20)
    ->Threads(1)
    ->Threads(4)
    ->Threads(8);

BENCHMARK_MAIN();