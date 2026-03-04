build:
	g++ -O3 -march=native -std=c++20 main.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-e2k:
	lcc -O3 main.cpp -lbenchmark -lpthread -o benchmark_db