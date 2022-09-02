set -eux

./python -m venv env
./env/bin/python -m pip install pyperf

BENCH_FUNC=bench1 ./env/bin/python bench.py -o baseline.json --inherit-environ BENCH_FUNC
BENCH_FUNC=bench2 ./env/bin/python bench.py -o nonzeroed.json --inherit-environ BENCH_FUNC
BENCH_FUNC=bench3 ./env/bin/python bench.py -o pack.json --inherit-environ BENCH_FUNC
BENCH_FUNC=bench4 ./env/bin/python bench.py -o fromarraysteal.json --inherit-environ BENCH_FUNC

./env/bin/python -m pyperf compare_to baseline.json nonzeroed.json
./env/bin/python -m pyperf compare_to baseline.json pack.json
./env/bin/python -m pyperf compare_to baseline.json fromarraysteal.json
