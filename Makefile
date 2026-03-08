build:
	g++ -O3 -march=native -std=c++20 main.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-e2k:
	l++ -O3 -DBENCHMARK_HAS_NO_INLINE_ASSEMBLY main.cpp -lbenchmark -lpthread -o benchmark_dbl++, 