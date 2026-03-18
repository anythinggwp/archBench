build:
	g++ -O3 -march=native -std=c++20 main.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-test:
	g++ -O3 -march=native -std=c++20 test.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-hash:
	g++ -O3 -march=native -std=c++20 bench_hash.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-hash-e2k:
	l++ -O3 -DBENCHMARK_HAS_NO_INLINE_ASSEMBLY -std=c++11 bench_hash.cpp \
	-leml -lbenchmark -lpthread -o benchmark_db
build-base-ops:
	g++ -O3 -march=native -std=c++11 bench_base_ops.cpp \
    -lbenchmark -lpthread -o benchmark_db
run-base-ops-json:
	./benchmark_db \
	--benchmark_repetitions=10 \
	--benchmark_report_aggregates_only=true \
	--benchmark_out=base_ops.json \
	--benchmark_out_format=json
build-base-ops-e2k:
	l++ -O3 -std=c++11 -DBENCHMARK_HAS_NO_INLINE_ASSEMBLY bench_base_ops.cpp \
	-leml -lbenchmark -lpthread -o benchmark_db
build-encrypt:
	g++ -O3 -march=native -std=c++20 bench_encrypt.cpp \
    -lbenchmark -lpthread -o benchmark_db
build-amd64:
	g++ -O3 -march=native -std=c++20 bench_arm64.cpp \
	-lbenchmark -lpthread -o benchmark_db
disable-cpu-boost-amd64:
	echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost
	sudo cpupower frequency-set --governor performance
enable-cpu-boost-amd64:
	echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost
	sudo cpupower frequency-set --governor ondemand
build-e2k:
	l++ -O3 -DBENCHMARK_HAS_NO_INLINE_ASSEMBLY bench_e2k.cpp -leml -lbenchmark -lpthread -o benchmark_db