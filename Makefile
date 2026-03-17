build:
	g++ -O3 -march=native -std=c++20 main.cpp \
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