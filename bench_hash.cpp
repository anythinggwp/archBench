#include <benchmark/benchmark.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <random>
#include <string>
#include <vector>

struct Entry
{
    std::string key;
    uint64_t value = 0;
    Entry* next = nullptr;
};

static inline uint64_t fnv1a64(const char* data, size_t len)
{
    uint64_t h = 14695981039346656037ull;
    for (size_t i = 0; i < len; ++i)
    {
        h ^= static_cast<uint8_t>(data[i]);
        h *= 1099511628211ull;
    }
    return h;
}

class ChainedHashTable
{
public:
    explicit ChainedHashTable(size_t bucket_count)
        : buckets_(bucket_count, nullptr)
    {
    }

    ~ChainedHashTable()
    {
        clear();
    }

    ChainedHashTable(const ChainedHashTable&) = delete;
    ChainedHashTable& operator=(const ChainedHashTable&) = delete;

    void insert(const std::string& key, uint64_t value)
    {
        const uint64_t h = fnv1a64(key.data(), key.size());
        const size_t idx = static_cast<size_t>(h % buckets_.size());

        Entry* e = new Entry{key, value, buckets_[idx]};
        buckets_[idx] = e;
    }

    const Entry* find(const std::string& key) const
    {
        const uint64_t h = fnv1a64(key.data(), key.size());
        const size_t idx = static_cast<size_t>(h % buckets_.size());

        Entry* cur = buckets_[idx];
        while (cur)
        {
            if (cur->key.size() == key.size() &&
                std::memcmp(cur->key.data(), key.data(), key.size()) == 0)
            {
                return cur;
            }
            cur = cur->next;
        }
        return nullptr;
    }

    const Entry* find_prehashed(const std::string& key, uint64_t h) const
    {
        const size_t idx = static_cast<size_t>(h % buckets_.size());

        Entry* cur = buckets_[idx];
        while (cur)
        {
            if (cur->key.size() == key.size() &&
                std::memcmp(cur->key.data(), key.data(), key.size()) == 0)
            {
                return cur;
            }
            cur = cur->next;
        }
        return nullptr;
    }

    size_t bucket_count() const
    {
        return buckets_.size();
    }

private:
    void clear()
    {
        for (Entry*& head : buckets_)
        {
            Entry* cur = head;
            while (cur)
            {
                Entry* next = cur->next;
                delete cur;
                cur = next;
            }
            head = nullptr;
        }
    }

    std::vector<Entry*> buckets_;
};

struct LookupFixture : public benchmark::Fixture
{
    std::vector<std::string> keys_hit;
    std::vector<std::string> keys_miss;
    std::vector<uint64_t> prehash_hit;

    ChainedHashTable* table = nullptr;

    size_t key_len = 16;
    size_t num_keys = 0;
    size_t query_index = 0;

    static std::string make_key(uint64_t x, size_t len)
    {
        static constexpr char alphabet[] =
            "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

        std::string s(len, '0');
        for (size_t i = 0; i < len; ++i)
        {
            s[i] = alphabet[(x + i * 17) % (sizeof(alphabet) - 1)];
            x = x * 1315423911u + 0x9e3779b97f4a7c15ull;
        }
        return s;
    }

    void SetUp(const benchmark::State& state) override
    {
        num_keys = static_cast<size_t>(state.range(0));
        key_len = static_cast<size_t>(state.range(1));
        query_index = 0;

        keys_hit.clear();
        keys_miss.clear();
        prehash_hit.clear();

        keys_hit.reserve(num_keys);
        keys_miss.reserve(num_keys);
        prehash_hit.reserve(num_keys);

        delete table;
        table = nullptr;

        // bucket_count близок к числу ключей -> умеренная load factor
        const size_t bucket_count = std::max<size_t>(num_keys * 2, 16);
        table = new ChainedHashTable(bucket_count);

        for (size_t i = 0; i < num_keys; ++i)
        {
            std::string key = make_key(i + 1, key_len);
            keys_hit.push_back(key);
            prehash_hit.push_back(fnv1a64(key.data(), key.size()));
            table->insert(keys_hit.back(), static_cast<uint64_t>(i));
        }

        for (size_t i = 0; i < num_keys; ++i)
        {
            keys_miss.push_back(make_key(i + num_keys + 1000000ull, key_len));
        }

        std::mt19937 rng(42);
        std::shuffle(keys_hit.begin(), keys_hit.end(), rng);
        std::shuffle(keys_miss.begin(), keys_miss.end(), rng);

        // prehash надо пересчитать после shuffle
        prehash_hit.clear();
        prehash_hit.reserve(num_keys);
        for (const auto& k : keys_hit)
            prehash_hit.push_back(fnv1a64(k.data(), k.size()));
    }

    void TearDown(const benchmark::State&) override
    {
        delete table;
        table = nullptr;
    }

    const std::string& next_hit_key()
    {
        const std::string& k = keys_hit[query_index];
        query_index = (query_index + 1) % keys_hit.size();
        return k;
    }

    const std::string& next_miss_key()
    {
        const std::string& k = keys_miss[query_index];
        query_index = (query_index + 1) % keys_miss.size();
        return k;
    }

    uint64_t next_hit_hash()
    {
        const uint64_t h = prehash_hit[query_index];
        query_index = (query_index + 1) % prehash_hit.size();
        return h;
    }
};

BENCHMARK_DEFINE_F(LookupFixture, HashOnly)(benchmark::State& state)
{
    for (auto _ : state)
    {
        const std::string& key = next_hit_key();
        uint64_t h = fnv1a64(key.data(), key.size());
        benchmark::DoNotOptimize(h);
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()));
}

BENCHMARK_DEFINE_F(LookupFixture, LookupHit_FullPath)(benchmark::State& state)
{
    for (auto _ : state)
    {
        const std::string& key = next_hit_key();
        const Entry* e = table->find(key);
        benchmark::DoNotOptimize(e);
        if (e)
            benchmark::DoNotOptimize(e->value);
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()));
}

BENCHMARK_DEFINE_F(LookupFixture, LookupMiss_FullPath)(benchmark::State& state)
{
    for (auto _ : state)
    {
        const std::string& key = next_miss_key();
        const Entry* e = table->find(key);
        benchmark::DoNotOptimize(e);
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()));
}

BENCHMARK_DEFINE_F(LookupFixture, LookupHit_Prehashed)(benchmark::State& state)
{
    for (auto _ : state)
    {
        const std::string& key = next_hit_key();
        const uint64_t h = next_hit_hash();
        const Entry* e = table->find_prehashed(key, h);
        benchmark::DoNotOptimize(e);
        if (e)
            benchmark::DoNotOptimize(e->value);
    }

    state.SetItemsProcessed(
        static_cast<int64_t>(state.iterations()));
}

// Дополнительный тест: очень длинные ключи сильнее нагружают hash/compare
BENCHMARK_REGISTER_F(LookupFixture, HashOnly)
    ->Args({1 << 10, 8})
    ->Args({1 << 10, 16})
    ->Args({1 << 10, 32})
    ->Args({1 << 10, 64})
    ->Args({1 << 16, 16});

BENCHMARK_REGISTER_F(LookupFixture, LookupHit_FullPath)
    ->Args({1 << 10, 8})
    ->Args({1 << 10, 16})
    ->Args({1 << 10, 32})
    ->Args({1 << 10, 64})
    ->Args({1 << 16, 16});

BENCHMARK_REGISTER_F(LookupFixture, LookupMiss_FullPath)
    ->Args({1 << 10, 8})
    ->Args({1 << 10, 16})
    ->Args({1 << 10, 32})
    ->Args({1 << 10, 64})
    ->Args({1 << 16, 16});

BENCHMARK_REGISTER_F(LookupFixture, LookupHit_Prehashed)
    ->Args({1 << 10, 8})
    ->Args({1 << 10, 16})
    ->Args({1 << 10, 32})
    ->Args({1 << 10, 64})
    ->Args({1 << 16, 16});

BENCHMARK_MAIN();