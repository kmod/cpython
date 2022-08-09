set -x

sudo python3 -m pyperf system tune
flock /tmp python3 -m pyperformance run --python ./python.nobolt --rigorous --manifest ~/pyston/macrobenchmarks/benchmarks/WEB_MANIFEST -o nobolt_macrobenchmarks.json -b djangocms,flaskblogging
flock /tmp python3 -m pyperformance run --python ./python --rigorous --manifest ~/pyston/macrobenchmarks/benchmarks/WEB_MANIFEST -o bolt_macrobenchmarks.json -b djangocms,flaskblogging
python3 -m pyperf compare_to {no,}bolt_macrobenchmarks.json

flock /tmp python3 -m pyperformance run --python ./python.nobolt -o nobolt_pyperformance.json
flock /tmp python3 -m pyperformance run --python ./python -o bolt_pyperformance.json

sudo python3.8 -m pyperf system reset

python3 -m pyperf compare_to {no,}bolt_pyperformance.json --table
python3 -m pyperf compare_to {no,}bolt_macrobenchmarks.json --table
