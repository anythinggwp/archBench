#include <benchmark/benchmark.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <numeric>
#include <random>
#include <unordered_map>
#include <vector>

#if defined(__x86_64__) || defined(__i386__)
#include <wmmintrin.h>   // AES-NI
#include <emmintrin.h>
#endif

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace
{
constexpr size_t kBlockSize = 16;
constexpr size_t kAES128Rounds = 10;

static const uint8_t kSBox[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static const uint8_t kRcon[10] = {
    0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1B,0x36
};

inline uint8_t xtime(uint8_t x)
{
    return static_cast<uint8_t>((x << 1) ^ ((x & 0x80) ? 0x1B : 0x00));
}

inline uint8_t mul2(uint8_t x) { return xtime(x); }
inline uint8_t mul3(uint8_t x) { return static_cast<uint8_t>(xtime(x) ^ x); }

void sub_bytes(uint8_t s[16])
{
    for (int i = 0; i < 16; ++i)
        s[i] = kSBox[s[i]];
}

void shift_rows(uint8_t s[16])
{
    uint8_t t[16];
    t[0]  = s[0];  t[1]  = s[5];  t[2]  = s[10]; t[3]  = s[15];
    t[4]  = s[4];  t[5]  = s[9];  t[6]  = s[14]; t[7]  = s[3];
    t[8]  = s[8];  t[9]  = s[13]; t[10] = s[2];  t[11] = s[7];
    t[12] = s[12]; t[13] = s[1];  t[14] = s[6];  t[15] = s[11];
    std::memcpy(s, t, 16);
}

void mix_columns(uint8_t s[16])
{
    for (int c = 0; c < 4; ++c)
    {
        const int i = 4 * c;
        const uint8_t s0 = s[i + 0];
        const uint8_t s1 = s[i + 1];
        const uint8_t s2 = s[i + 2];
        const uint8_t s3 = s[i + 3];

        s[i + 0] = static_cast<uint8_t>(mul2(s0) ^ mul3(s1) ^ s2 ^ s3);
        s[i + 1] = static_cast<uint8_t>(s0 ^ mul2(s1) ^ mul3(s2) ^ s3);
        s[i + 2] = static_cast<uint8_t>(s0 ^ s1 ^ mul2(s2) ^ mul3(s3));
        s[i + 3] = static_cast<uint8_t>(mul3(s0) ^ s1 ^ s2 ^ mul2(s3));
    }
}

void add_round_key(uint8_t s[16], const uint8_t rk[16])
{
    for (int i = 0; i < 16; ++i)
        s[i] ^= rk[i];
}

void aes128_expand_key(const uint8_t key[16], uint8_t round_keys[11][16])
{
    std::memcpy(round_keys[0], key, 16);

    for (int round = 1; round <= 10; ++round)
    {
        uint8_t temp[4];
        temp[0] = round_keys[round - 1][13];
        temp[1] = round_keys[round - 1][14];
        temp[2] = round_keys[round - 1][15];
        temp[3] = round_keys[round - 1][12];

        for (int i = 0; i < 4; ++i)
            temp[i] = kSBox[temp[i]];

        temp[0] ^= kRcon[round - 1];

        for (int i = 0; i < 4; ++i)
            round_keys[round][i] = static_cast<uint8_t>(round_keys[round - 1][i] ^ temp[i]);

        for (int i = 4; i < 16; ++i)
            round_keys[round][i] = static_cast<uint8_t>(round_keys[round - 1][i] ^ round_keys[round][i - 4]);
    }
}

void aes128_encrypt_block_scalar(const uint8_t in[16], uint8_t out[16], const uint8_t round_keys[11][16])
{
    uint8_t state[16];
    std::memcpy(state, in, 16);

    add_round_key(state, round_keys[0]);

    for (int round = 1; round < 10; ++round)
    {
        sub_bytes(state);
        shift_rows(state);
        mix_columns(state);
        add_round_key(state, round_keys[round]);
    }

    sub_bytes(state);
    shift_rows(state);
    add_round_key(state, round_keys[10]);

    std::memcpy(out, state, 16);
}

void aes128_encrypt_buffer_scalar(
    uint8_t* dst,
    const uint8_t* src,
    size_t bytes,
    const uint8_t round_keys[11][16])
{
    const size_t blocks = bytes / kBlockSize;
    for (size_t i = 0; i < blocks; ++i)
        aes128_encrypt_block_scalar(src + i * 16, dst + i * 16, round_keys);
}

#if defined(__AES__) && (defined(__x86_64__) || defined(__i386__))
void aes128_encrypt_buffer_aesni(
    uint8_t* dst,
    const uint8_t* src,
    size_t bytes,
    const uint8_t round_keys[11][16])
{
    __m128i rk[11];
    for (int i = 0; i < 11; ++i)
        rk[i] = _mm_loadu_si128(reinterpret_cast<const __m128i*>(round_keys[i]));

    const size_t blocks = bytes / kBlockSize;
    for (size_t i = 0; i < blocks; ++i)
    {
        __m128i m = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + i * 16));
        m = _mm_xor_si128(m, rk[0]);
        for (int round = 1; round < 10; ++round)
            m = _mm_aesenc_si128(m, rk[round]);
        m = _mm_aesenclast_si128(m, rk[10]);
        _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + i * 16), m);
    }
}
#endif

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRYPTO)
void aes128_encrypt_buffer_armv8crypto(
    uint8_t* dst,
    const uint8_t* src,
    size_t bytes,
    const uint8_t round_keys[11][16])
{
    uint8x16_t rk[11];
    for (int i = 0; i < 11; ++i)
        rk[i] = vld1q_u8(round_keys[i]);

    const uint8x16_t zero = vdupq_n_u8(0);
    const size_t blocks = bytes / kBlockSize;

    for (size_t i = 0; i < blocks; ++i)
    {
        uint8x16_t m = vld1q_u8(src + i * 16);
        m = veorq_u8(m, rk[0]);

        for (int round = 1; round < 10; ++round)
        {
            m = vaeseq_u8(m, zero);
            m = vaesmcq_u8(m);
            m = veorq_u8(m, rk[round]);
        }

        m = vaeseq_u8(m, zero);
        m = veorq_u8(m, rk[10]);

        vst1q_u8(dst + i * 16, m);
    }
}
#endif

struct Fixture : public benchmark::Fixture
{
    std::vector<uint64_t> keys;
    std::unordered_map<uint64_t, double> hash_index;
    std::map<uint64_t, double> btree_index;

    std::vector<uint8_t> plain;
    std::vector<uint8_t> cipher;

    uint8_t* plain_aligned = nullptr;
    uint8_t* cipher_aligned = nullptr;

    size_t bytes = 0;
    bool alloc_ok = true;

    alignas(16) uint8_t aes_key[16] = {
        0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,
        0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c
    };

    alignas(16) uint8_t round_keys[11][16] = {};

    static uint8_t* aligned_alloc64(size_t count)
    {
#if defined(_MSC_VER)
        return static_cast<uint8_t*>(_aligned_malloc(count, 64));
#else
        void* ptr = nullptr;
        if (posix_memalign(&ptr, 64, count) != 0)
            return nullptr;
        return static_cast<uint8_t*>(ptr);
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

        bytes = std::max<size_t>(N, kBlockSize);
        bytes = (bytes / kBlockSize) * kBlockSize;
        if (bytes == 0)
            bytes = kBlockSize;

        plain.resize(bytes);
        cipher.resize(bytes);

        plain_aligned = aligned_alloc64(bytes);
        cipher_aligned = aligned_alloc64(bytes);

        if (!plain_aligned || !cipher_aligned)
        {
            alloc_ok = false;
            return;
        }

        for (size_t i = 0; i < bytes; ++i)
        {
            const uint8_t v = static_cast<uint8_t>((i * 131u + 17u) & 0xFFu);
            plain[i] = v;
            cipher[i] = 0;
            plain_aligned[i] = v;
            cipher_aligned[i] = 0;
        }

        aes128_expand_key(aes_key, round_keys);
    }

    void TearDown(const ::benchmark::State&) override
    {
        aligned_free64(plain_aligned);
        aligned_free64(cipher_aligned);

        plain_aligned = nullptr;
        cipher_aligned = nullptr;

        plain.clear();
        cipher.clear();

        hash_index.clear();
        btree_index.clear();
        keys.clear();
    }
};

BENCHMARK_DEFINE_F(Fixture, AES128Scalar)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("aligned allocation failed");
        return;
    }

    for (auto _ : state)
    {
        aes128_encrypt_buffer_scalar(cipher.data(), plain.data(), bytes, round_keys);
        benchmark::DoNotOptimize(cipher.data());
        benchmark::ClobberMemory();
    }

    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(bytes));
    state.counters["bytes_per_iter"] = static_cast<double>(bytes);
}
BENCHMARK_REGISTER_F(Fixture, AES128Scalar)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);

#if defined(__AES__) && (defined(__x86_64__) || defined(__i386__))
BENCHMARK_DEFINE_F(Fixture, AES128AESNI)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("aligned allocation failed");
        return;
    }

    for (auto _ : state)
    {
        aes128_encrypt_buffer_aesni(cipher_aligned, plain_aligned, bytes, round_keys);
        benchmark::DoNotOptimize(cipher_aligned);
        benchmark::ClobberMemory();
    }

    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(bytes));
    state.counters["bytes_per_iter"] = static_cast<double>(bytes);
}
BENCHMARK_REGISTER_F(Fixture, AES128AESNI)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);
#endif

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRYPTO)
BENCHMARK_DEFINE_F(Fixture, AES128ARMv8Crypto)(benchmark::State& state)
{
    if (!alloc_ok)
    {
        state.SkipWithError("aligned allocation failed");
        return;
    }

    for (auto _ : state)
    {
        aes128_encrypt_buffer_armv8crypto(cipher_aligned, plain_aligned, bytes, round_keys);
        benchmark::DoNotOptimize(cipher_aligned);
        benchmark::ClobberMemory();
    }

    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * static_cast<int64_t>(bytes));
    state.counters["bytes_per_iter"] = static_cast<double>(bytes);
}
BENCHMARK_REGISTER_F(Fixture, AES128ARMv8Crypto)
    ->RangeMultiplier(4)
    ->Range(1 << 10, 1 << 24);
#endif
}

BENCHMARK_MAIN();