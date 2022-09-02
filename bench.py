import os
import pyperf
import _testcapi
runner = pyperf.Runner()

func_name = os.environ["BENCH_FUNC"]
runner.bench_time_func('tuple_new', getattr(_testcapi, func_name))
