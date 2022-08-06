.SUFFIXES:

# If PYSTON_USE_SYS_BINS=1 is set we don't build clang and bolt instead we are using supplied ones.
ifeq ($(PYSTON_USE_SYS_BINS),1)
BOLT:=$(shell which llvm-bolt)
CLANG:=$(shell which clang)
LLVM_LINK:=$(shell which llvm-link)
LLVM_PROFDATA:=$(shell which llvm-profdata)
MERGE_FDATA:=$(shell which merge-fdata)
PERF2BOLT:=$(shell which perf2bolt)
RELEASE:=

ifeq ($(LLVM_LINK),)
$(error "Please install the llvm toolchain")
endif
else
BOLT:=$(abspath /home/kmod/pyston2/build/bolt/bin/llvm-bolt)
CLANG:=$(abspath /home/kmod/pyston2/build/Release/llvm/bin/clang)
LLVM_LINK:=$(abspath /home/kmod/pyston2/build/Release/llvm/bin/llvm-link)
LLVM_PROFDATA:=$(abspath /home/kmod/pyston2/build/Release/llvm/bin/llvm-profdata)
MERGE_FDATA:=$(abspath /home/kmod/pyston2/build/bolt/bin/merge-fdata)
PERF2BOLT:=$(abspath /home/kmod/pyston2/build/bolt/bin/perf2bolt)
RELEASE:=$(shell lsb_release -sr)
endif

GDB:=gdb
.DEFAULT_GOAL:=all

PYTHON_MAJOR:=3
PYTHON_MINOR:=8
PYSTON_MAJOR:=2
PYSTON_MINOR:=3

RELEASE_PREFIX?=/usr

ARCH:=$(shell uname -m)

-include Makefile.local

.PHONY: all
all: pyston3

pyston3: build/opt_env/bin/python
	ln -sf $< $@

.PHONY: clean
clean:
	rm -rf build/*_env build/*_build build/*_install build/aot* build/cpython_bc

tune: build/system_env/bin/python
	PYTHONPATH=pyston/tools build/system_env/bin/python -c "import tune; tune.tune()"
tune_reset: build/system_env/bin/python
	PYTHONPATH=pyston/tools build/system_env/bin/python -c "import tune; tune.untune()"

build/PartialDebug/Makefile:
	mkdir -p build/PartialDebug
	cd build/PartialDebug; CC=clang CXX=clang++ cmake ../../pyston/ -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=PartialDebug -DLLVM_ENABLE_PROJECTS=clang -DCLANG_INCLUDE_TESTS=0 -DCOMPILER_RT_INCLUDE_TESTS=0 -DLLVM_INCLUDE_TESTS=0 -DCOMPILER_RT_BUILD_SANITIZERS=0

build/Debug/Makefile:
	mkdir -p build/Debug
	cd build/Debug; CC=clang CXX=clang++ cmake ../../pyston/ -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug -DLLVM_ENABLE_PROJECTS=clang -DCLANG_INCLUDE_TESTS=0 -DCOMPILER_RT_INCLUDE_TESTS=0 -DLLVM_INCLUDE_TESTS=0 -DCOMPILER_RT_BUILD_SANITIZERS=0

# this flags are what the default debian/ubuntu cpython uses
CPYTHON_EXTRA_CFLAGS:=-fstack-protector -specs=/home/kmod/pyston/pyston/tools/no-pie-compile.specs -D_FORTIFY_SOURCE=2
CPYTHON_EXTRA_LDFLAGS:=-specs=/home/kmod/pyston/pyston/tools/no-pie-link.specs -Wl,-z,relro

PROFILE_TASK_MULTIPROCESS:=-j 0
ifeq ($(ARCH),aarch64)
# multiprocessed PGO run is failing for optshared on ARM64
PROFILE_TASK_MULTIPROCESS:=-j 1
endif
PROFILE_TASK:=../../Lib/test/regrtest.py $(PROFILE_TASK_MULTIPROCESS) -unone,decimal -x test_posix test_asyncio test_cmd_line_script test_compiler test_concurrent_futures test_ctypes test_dbm_dumb test_dbm_ndbm test_distutils test_ensurepip test_ftplib test_gdb test_httplib test_imaplib test_ioctl test_linuxaudiodev test_multiprocessing test_nntplib test_ossaudiodev test_poplib test_pydoc test_signal test_socket test_socketserver test_ssl test_subprocess test_sundry test_thread test_threaded_import test_threadedtempfile test_threading test_threading_local test_threadsignals test_venv test_zipimport_support || true

MAKEFILE_DEPENDENCIES:=Makefile.pre.in configure

VIRTUALENV:=build/bootstrap_env/bin/virtualenv
$(VIRTUALENV):
	virtualenv -p python3 build/bootstrap_env
	build/bootstrap_env/bin/pip install virtualenv

build/system_env/bin/python: | $(VIRTUALENV)
	$(VIRTUALENV) -p python$(PYTHON_MAJOR).$(PYTHON_MINOR) build/system_env
	build/system_env/bin/pip install six pyperf cython || (rm -rf build/system_env; false)
build/systemdbg_env/bin/python: | $(VIRTUALENV)
	$(VIRTUALENV) -p python$(PYTHON_MAJOR).$(PYTHON_MINOR)-dbg build/systemdbg_env
build/pypy_env/bin/python: | $(VIRTUALENV)
	$(VIRTUALENV) -p pypy3 build/pypy_env

EXTRA_BOLT_OPTS:=
ifeq ($(RELEASE),16.04)
else ifeq ($(RELEASE),18.04)
else ifeq ($(CONDA_BUILD),1)
else
EXTRA_BOLT_OPTS:=-frame-opt=hot
endif

# Usage:
# $(call make_cpython_build,NAME,CONFIGURE_LINE,AOT_DEPENDENCY,DESTDIR,BOLT:[|binary|so],PREFIX)
define make_cpython_build
$(eval

$(eval _PREFIX:=$(if $(6),$(6),/usr))

build/$(1)_build/Makefile: $(MAKEFILE_DEPENDENCIES)
	mkdir -p build/$(1)_build
	cd build/$(1)_build; $(2)

build/$(1)_build/pyston: build/$(1)_build/Makefile $(wildcard */*.c) $(wildcard */*.h)
	cd build/$(1)_build; CLANG=$(CLANG) LLVM_PROFDATA=$(LLVM_PROFDATA) $$(MAKE)
	touch $$@ # some cpython .c files don't affect the python executable

build/$(1)_install$(_PREFIX)/bin/python3: build/$(1)_build/pyston
	cd build/$(1)_build; CLANG=$(CLANG) LLVM_PROFDATA=$(LLVM_PROFDATA) $$(MAKE) install DESTDIR=$(4) $(if $(findstring so,$(5)),INSTSONAME=libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.prebolt)

$(1): build/$(1)_env/bin/python

ifeq ($(5),binary)

build/$(1)_install$(_PREFIX)/bin/python3.bolt.fdata: build/$(1)_install$(_PREFIX)/bin/python3 $(BOLT) | $(VIRTUALENV)
	rm -rf /tmp/tmp_env_$(1)
	rm $$<.bolt*.fdata || true
	$(BOLT) $$< -instrument -instrumentation-file-append-pid -instrumentation-file=$$(abspath build/$(1)_install$(_PREFIX)/bin/python3.bolt) -o $$<.bolt_inst
	$(VIRTUALENV) -p $$<.bolt_inst /tmp/tmp_env_$(1)
	/tmp/tmp_env_$(1)/bin/pip install -r /home/kmod/pyston/pyston/pgo_requirements.txt
	/tmp/tmp_env_$(1)/bin/python3 /home/kmod/pyston/pyston/run_profile_task.py
	$(MERGE_FDATA) $$<.*.fdata > $$@

build/$(1)_install$(_PREFIX)/bin/python3.bolt: build/$(1)_install$(_PREFIX)/bin/python3.bolt.fdata
	$(BOLT) build/$(1)_install$(_PREFIX)/bin/python3 -o $$@ -data=$$< -update-debug-sections -reorder-blocks=cache+ -reorder-functions=hfsort+ -split-functions=3 -icf=1 -inline-all -split-eh -reorder-functions-use-hot-size -peepholes=all -jump-tables=aggressive -inline-ap -indirect-call-promotion=all -dyno-stats -use-gnu-stack $(EXTRA_BOLT_OPTS)

build/$(1)_env/bin/python: build/$(1)_install$(_PREFIX)/bin/python3.bolt | $(VIRTUALENV)
	$(VIRTUALENV) -p $$< build/$(1)_env
	touch $$@

else

build/$(1)_env/bin/python: build/$(1)_install$(_PREFIX)/bin/python3 | $(VIRTUALENV)
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$$(abspath build/$(1)_install$(_PREFIX)/lib) $(VIRTUALENV) -p $$< build/$(1)_env
	touch $$@

endif

ifeq ($(5),so)

# Bolt-on-.so strategy:
# We install the .so as libpython.so.prebolt,
# Instrument it to .bolt_inst
# then LD_PRELOAD it into the pyston executable to force it to load,
# then run our perf task,
# then output the bolt'd file to the proper place
build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.fdata: build/$(1)_install$(_PREFIX)/bin/python3
	rm -rf /tmp/tmp_env_$(1)
	$(BOLT) $$(abspath build/$(1)_install$(_PREFIX)/lib)/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.prebolt -instrument -instrumentation-file-append-pid -instrumentation-file=$$(abspath build/$(1)_install$(_PREFIX)/lib)/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0 -o $$(abspath build/$(1)_install$(_PREFIX)/lib)/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.bolt_inst -skip-funcs="_PyEval_EvalFrameDefault,_PyEval_EvalFrame_AOT_Interpreter.*"
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$$(abspath build/$(1)_install$(_PREFIX)/lib) LD_PRELOAD=libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.bolt_inst $(VIRTUALENV) -p $$< /tmp/tmp_env_$(1)
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$$(abspath build/$(1)_install$(_PREFIX)/lib) LD_PRELOAD=libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.bolt_inst /tmp/tmp_env_$(1)/bin/pip install -r /home/kmod/pyston/pyston/pgo_requirements.txt
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$$(abspath build/$(1)_install$(_PREFIX)/lib) LD_PRELOAD=libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.bolt_inst /tmp/tmp_env_$(1)/bin/python3 pyston/run_profile_task.py
	$(MERGE_FDATA) $$(abspath build/$(1)_install$(_PREFIX)/lib)/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.*.fdata > $$@

build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0: build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.fdata
	$(BOLT) build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0.prebolt -o $$@ -data=$$< -update-debug-sections -reorder-blocks=cache+ -reorder-functions=hfsort+ -split-functions=3 -icf=1 -inline-all -split-eh -reorder-functions-use-hot-size -peepholes=all -jump-tables=aggressive -inline-ap -indirect-call-promotion=all -dyno-stats -use-gnu-stack -jump-tables=none $(EXTRA_BOLT_OPTS)
	bash -c "cd build/$(1)_install$(_PREFIX)/lib; ln -sf libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so{.1.0,}"

build/$(1)_env/bin/python: build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0

else ifneq ($(findstring enable-shared,$(2)),)

build/$(1)_install$(_PREFIX)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0: build/$(1)_install$(_PREFIX)/bin/python3

endif

build/$(1)_env/update.stamp: pyston/benchmark_requirements.txt pyston/benchmark_requirements_nonpypy.txt | build/$(1)_env/bin/python
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$(abspath build/$(1)_install$(_PREFIX)/lib) build/$(1)_env/bin/pip install -r pyston/benchmark_requirements.txt -r pyston/benchmark_requirements_nonpypy.txt
	touch $$@

%_$(1): %.py build/$(1)_env/update.stamp
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$(abspath build/$(1)_install$(_PREFIX)/lib) time build/$(1)_env/bin/python3 $$< $$(ARGS)

dbg_%_$(1): %.py build/$(1)_env/update.stamp
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$(abspath build/$(1)_install$(_PREFIX)/lib) gdb --args build/$(1)_env/bin/python3 $$< $$(ARGS)

perf_%_$(1): %.py build/$(1)_env/update.stamp
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$(abspath build/$(1)_install$(_PREFIX)/lib) JIT_PERF_MAP=1 perf record -g ./build/$(1)_env/bin/python3 $$< $$(ARGS)
	$$(MAKE) perf_report

pyperf_%_$(1): %.py ./build/$(1)_env/update.stamp build/system_env/bin/python
	LD_LIBRARY_PATH=$${LD_LIBRARY_PATH}:$(abspath build/$(1)_install$(_PREFIX)/lib) $$(PYPERF) build/$(1)_env/bin/python3 $$< $$(ARGS)

# UNSAFE build target
# If you're making changes to cpython but don't want to rebuild the traces or anything beyond the python binary,
# you can call this target for a much faster build.
# Skips bc_build, aot_gen, and $(1)_install
# If you want to run the skipped steps, you will have to touch a file before doing a (safe) rebuild
unsafe_$(1):
	$(MAKE) -C build/$(1)_build
	/bin/cp build/$(1)_build/pyston build/$(1)_install$(_PREFIX)/bin/python$(PYTHON_MAJOR).$(PYTHON_MINOR)

cpython_testsuite_$(1): build/$(1)_build/pyston
	+OPENSSL_CONF=$(abspath pyston/test/openssl_dev.cnf) $(MAKE) -C build/$(1)_build test

)
endef

BOLT_DISABLED_IN_ENVIRONMENT:=0

# Allow forcefully disabling BOLT even on x86_64 by setting USE_BOLT=0
ifeq ($(USE_BOLT),0)
	BOLT_DISABLED_IN_ENVIRONMENT:=1
endif

CPYTHON_EXTRA_CFLAGS_FOR_BOLT:=
CPYTHON_EXTRA_LDFLAGS_FOR_BOLT:=
BOLT_BINARY_ENABLE:=
BOLT_SO_ENABLE:=
USE_BOLT:=0

ifeq ($(BOLT_DISABLED_IN_ENVIRONMENT),0)
	# we only use BOLT on x86_64
	ifeq ($(ARCH),x86_64)
		CPYTHON_EXTRA_CFLAGS_FOR_BOLT:=-fno-reorder-blocks-and-partition
		CPYTHON_EXTRA_LDFLAGS_FOR_BOLT:=-Wl,--emit-relocs
		BOLT_BINARY_ENABLE:=binary
		BOLT_SO_ENABLE:=so
		USE_BOLT:=1
	endif
endif

$(call make_cpython_build,unopt,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/unopt_install/usr) --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot/aot_all.bc,,)
$(call make_cpython_build,unoptshared,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/unoptshared_install/usr) --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS) --enable-shared,build/aot_pic/aot_all.bc,,)
$(call make_cpython_build,opt,PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/opt_install/usr) --enable-optimizations --with-lto --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot/aot_all.bc,,$(BOLT_BINARY_ENABLE))
$(call make_cpython_build,optshared,PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/optshared_install/usr) --enable-optimizations --with-lto --disable-debugging-features --enable-shared --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot_pic/aot_all.bc,,$(BOLT_SO_ENABLE))
$(call make_cpython_build,releaseunopt,PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(RELEASE_PREFIX) --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot/aot_all.bc,$(abspath build/releaseunopt_install),,$(RELEASE_PREFIX))
$(call make_cpython_build,releaseunoptshared,PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(RELEASE_PREFIX) --disable-debugging-features --enable-shared --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot_pic/aot_all.bc,$(abspath build/releaseunoptshared_install),,$(RELEASE_PREFIX))
$(call make_cpython_build,release,      PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(RELEASE_PREFIX) --enable-optimizations --with-lto --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot/aot_all.bc,$(abspath build/release_install),$(BOLT_BINARY_ENABLE),$(RELEASE_PREFIX))
$(call make_cpython_build,releaseshared,PROFILE_TASK="$(PROFILE_TASK)" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(RELEASE_PREFIX) --enable-optimizations --with-lto --disable-debugging-features --enable-shared --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot_pic/aot_all.bc,$(abspath build/releaseshared_install),$(BOLT_SO_ENABLE),$(RELEASE_PREFIX))
# We have to --disable-debugging-features for consistency with the bc build
# If we had a separate bc-dbg build then we could change this
$(call make_cpython_build,dbg,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/dbg_install/usr) --with-pydebug --disable-debugging-features --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot/aot_all.bc)
$(call make_cpython_build,dbgshared,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS) $(CPYTHON_EXTRA_CFLAGS_FOR_BOLT)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS) $(CPYTHON_EXTRA_LDFLAGS_FOR_BOLT)" ../../configure --prefix=$(abspath build/dbgshared_install/usr) --with-pydebug --disable-debugging-features --enable-shared --enable-configure $(CONFIGURE_EXTRA_FLAGS),build/aot_pic/aot_all.bc)
$(call make_cpython_build,stock,PROFILE_TASK="$(PROFILE_TASK) || true" CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS)" ../../configure --prefix=$(abspath build/stock_install/usr) --enable-optimizations --with-lto --disable-pyston --enable-configure $(CONFIGURE_EXTRA_FLAGS),)
$(call make_cpython_build,stockunopt,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS)" ../../configure --prefix=$(abspath build/stockunopt_install/usr) --disable-pyston --enable-configure $(CONFIGURE_EXTRA_FLAGS),)
$(call make_cpython_build,stockdbg,CFLAGS_NODIST="$(CPYTHON_EXTRA_CFLAGS)" LDFLAGS_NODIST="$(CPYTHON_EXTRA_LDFLAGS)" ../../configure --prefix=$(abspath build/stockdbg_install/usr) --disable-pyston --with-pydebug --enable-configure $(CONFIGURE_EXTRA_FLAGS),)

# Usage: $(call combine_builds,NAME,PREFIX)
define combine_builds
$(eval
build/$(1)_install$(2)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0: build/$(1)shared_install$(2)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0 | build/$(1)_install$(2)/bin/python3
	bash -c "cp build/$(1){shared,}_install$(2)/lib/python$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR)/_sysconfigdata_$(if $(findstring dbg,$(1)),d,)_linux_$(ARCH)-linux-gnu.py"
	bash -c "cp build/$(1){shared,}_install$(2)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR)$(if $(findstring dbg,$(1)),d,).so.1.0"
	bash -c "cp -P build/$(1){shared,}_install$(2)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR)$(if $(findstring dbg,$(1)),d,).so"
build/$(1)_env/bin/python: build/$(1)_install$(2)/lib/libpython$(PYTHON_MAJOR).$(PYTHON_MINOR)-pyston$(PYSTON_MAJOR).$(PYSTON_MINOR).so.1.0
)
endef

$(call combine_builds,unopt,/usr)
$(call combine_builds,releaseunopt,$(RELEASE_PREFIX))
$(call combine_builds,opt,/usr)
$(call combine_builds,release,$(RELEASE_PREFIX))
$(call combine_builds,dbg,/usr)

ONLY?=null

PYPERF:=build/system_env/bin/pyperf command -w 0 -l 1 -p 1 -n $(or $(N),$(N),3) -v --affinity 0


BC_BENCH_ENV:=build/bc_env/update.stamp
SYSTEM_BENCH_ENV:=build/system_env/update.stamp
SYSTEMDBG_BENCH_ENV:=build/systemdbg_env/update.stamp
PYPY_BENCH_ENV:=build/pypy_env/update.stamp
$(BC_BENCH_ENV): pyston/benchmark_requirements.txt pyston/benchmark_requirements_nonpypy.txt | build/bc_env/bin/python
	build/bc_env/bin/pip install -r pyston/benchmark_requirements.txt -r pyston/benchmark_requirements_nonpypy.txt
	touch $@
$(SYSTEM_BENCH_ENV): pyston/benchmark_requirements.txt pyston/benchmark_requirements_nonpypy.txt | build/system_env/bin/python
	build/system_env/bin/pip install -r pyston/benchmark_requirements.txt -r pyston/benchmark_requirements_nonpypy.txt
	touch $@
$(SYSTEMDBG_BENCH_ENV): pyston/benchmark_requirements.txt pyston/benchmark_requirements_nonpypy.txt | build/systemdbg_env/bin/python
	build/systemdbg_env/bin/pip install -r pyston/benchmark_requirements.txt -r pyston/benchmark_requirements_nonpypy.txt
	touch $@
$(PYPY_BENCH_ENV): pyston/benchmark_requirements.txt | build/pypy_env/bin/python
	build/pypy_env/bin/pip install -r pyston/benchmark_requirements.txt
	touch $@
update_envs:
	for i in bc unopt opt stock stockunopt stockdbg system systemdbg pypy; do build/$${i}_env/bin/pip install -r pyston/benchmark_requirements.txt & done; wait

%_bc: %.py $(BC_BENCH_ENV)
	time build/bc_env/bin/python3 $< $(ARGS)
%_system: %.py $(SYSTEM_BENCH_ENV)
	time build/system_env/bin/python3 $< $(ARGS)
%_system_dbg: %.py $(SYSTEMDBG_BENCH_ENV)
	time build/systemdbg_env/bin/python3 $< $(ARGS)
%_pypy: %.py $(PYPY_BENCH_ENV)
	time build/pypy_env/bin/python3 $< $(ARGS)


perf_report:
	perf report -n --no-children --objdump=pyston/tools/perf_jit.py
perf_%: perf_%_opt
perf_%_system: %.py $(SYSTEM_BENCH_ENV)
	JIT_PERF_MAP=1 perf record -g ./build/system_env/bin/python3 $< $(ARGS)
	$(MAKE) perf_report

multi_unopt: pyston/run_profile_task_unopt
multi_opt: pyston/run_profile_task_opt
multi_stock: pyston/run_profile_task_stock
multi_stockunopt: pyston/run_profile_task_stockunopt
multi_system: pyston/run_profile_task_system
pyperf_multi_unopt: pyston/pyperf_run_profile_task_unopt
pyperf_multi_opt: pyston/pyperf_run_profile_task_opt
pyperf_multi_stock: pyston/pyperf_run_profile_task_stock
pyperf_multi_system: pyston/pyperf_run_profile_task_system
perf_multi_unopt: pyston/perf_run_profile_task_unopt
perf_multi_opt: pyston/perf_run_profile_task_opt

OPT_BENCH_ENV:=build/opt_env/update.stamp

measure: $(OPT_BENCH_ENV) build/system_env/bin/python
	rm -f results.json
	@# Run the command a second time with output if it failed:
	$(MAKE) tune > /dev/null || $(MAKE) tune
	$(PYPERF) -n $(or $(N),$(N),5) -o results.json ./build/opt_env/bin/python3 pyston/run_profile_task.py
	$(MAKE) tune_reset > /dev/null
measure_%: %.py $(OPT_BENCH_ENV) build/system_env/bin/python
	rm -f results.json
	$(MAKE) tune > /dev/null || $(MAKE) tune
	$(PYPERF) -n $(or $(N),$(N),5) -o results.json ./build/opt_env/bin/python $<
	$(MAKE) tune_reset > /dev/null
measure_append: $(OPT_BENCH_ENV) build/system_env/bin/python
	$(MAKE) tune > /dev/null || $(MAKE) tune
	$(PYPERF) -n $(or $(N),$(N),1) --append results.json ./build/opt_env/bin/python3 pyston/run_profile_task.py
	$(MAKE) tune_reset > /dev/null
compare: build/system_env/bin/python
	build/system_env/bin/pyperf compare_to -v $(ARGS) results.json

pyperf_%_bc: %.py $(BC_BENCH_ENV) build/system_env/bin/python
	$(PYPERF) build/bc_env/bin/python3 $< $(ARGS)
pyperf_%_system: %.py $(SYSTEM_BENCH_ENV) build/system_env/bin/python
	$(PYPERF) build/system_env/bin/python3 $< $(ARGS)
pyperf_%_pypy: %.py $(PYPY_BENCH_ENV) build/system_env/bin/python
	$(PYPERF) build/pypy_env/bin/python3 $< $(ARGS)

dbg_%: dbg_%_dbg


unsafe_% unsafe_%_unopt: %.py unsafe_unopt
	time build/unopt_env/bin/python3 $< $(ARGS)
unsafe_dbg_%: %.py unsafe_unopt
	gdb --args build/unopt_env/bin/python3 $< $(ARGS)
unsafe_perf_%: %.py unsafe_unopt
	JIT_PERF_MAP=1 perf record -g build/unopt_env/bin/python3 $< $(ARGS)
	$(MAKE) perf_report
unsafe_perfstat_%: %.py unsafe_unopt
	perf stat -ddd build/unopt_env/bin/python3 $< $(ARGS)
unsafe_pyperf_%: %.py unsafe_unopt
	$(PYPERF) build/unopt_env/bin/python3 $< $(ARGS)
unsafe_test: unsafe_unopt
	$(MAKE) _runtests

test_opt: build_release build/bc_build/pyston aot/all.bc
	LD_LIBRARY_PATH=build/Release/nitrous:build/Release/pystol build/bc_build/pyston -u pyston/tools/test_optimize.py test.c test
dbg_test_opt: build_dbg build/bc_build/pyston aot/all.bc
	LD_LIBRARY_PATH=build/PartialDebug/nitrous:build/PartialDebug/pystol gdb --args build/bc_build/pyston -u pyston/tools/test_optimize.py test.c test

.PHONY: test dbg_test _runtests test_%
_expected: python/test/external/test_django.expected python/test/external/test_six.expected python/test/external/test_requests.expected python/test/external/test_numpy.expected python/test/external/test_setuptools.expected python/test/external/test_urllib3.expected

# args: test_suffix test_binary
define make_test_build
$(eval
pyston/test/external/test_%.$(1): pyston/test/external/test_%.py $(2) | $(VIRTUALENV)
	OPENSSL_CONF=$(abspath pyston/test/openssl_dev.cnf) bash -c "set -o pipefail; $(2) -u $$< 2>&1 | tee $$@_"
	mv $$@_ $$@
)
endef

$(call make_test_build,expected,build/system_env/bin/python)
.PRECIOUS: pyston/test/external/test_%.expected pyston/test/external/test_%.output
$(call make_test_build,output,build/unopt_env/bin/python)

.PRECIOUS: pyston/test/external/test_%.optoutput
$(call make_test_build,optoutput,build/opt_env/bin/python)

$(call make_test_build,dbgexpected,build/stockdbg_env/bin/python)
.PRECIOUS: pyston/test/external/test_%.dbgexpected pyston/test/external/test_%.dbgoutput
$(call make_test_build,dbgoutput,build/dbg_env/bin/python)

test_%: pyston/test/external/test_%.expected pyston/test/external/test_%.output
	build/system_env/bin/python pyston/test/external/helpers.py compare $< $(patsubst %.expected,%.output,$<)

testopt_%: pyston/test/external/test_%.expected pyston/test/external/test_%.optoutput
	build/system_env/bin/python pyston/test/external/helpers.py compare $< $(patsubst %.expected,%.output,$<)

testdbg_%: pyston/test/external/test_%.dbgexpected pyston/test/external/test_%.dbgoutput
	build/system_env/bin/python pyston/test/external/helpers.py compare $< $(patsubst %.dbgexpected,%.dbgoutput,$<)

TESTFILES:=$(wildcard pyston/test/*.py)
tests: $(patsubst %.py,%_unopt,$(TESTFILES))
tests_dbg: $(patsubst %.py,%_dbg,$(TESTFILES))
tests_opt: $(patsubst %.py,%_opt,$(TESTFILES))

EXTERNAL_TESTSUITES:=django urllib3 setuptools six requests sqlalchemy pandas numpy
testsuites: $(patsubst %,test_%,$(EXTERNAL_TESTSUITES))
testsuites_dbg: $(patsubst %,testdbg_%,$(EXTERNAL_TESTSUITES))
testsuites_opt: $(patsubst %,testopt_%,$(EXTERNAL_TESTSUITES))

cpython_testsuite: cpython_testsuite_unopt
cpython_testsuite_bc: build/bc_build/pyston
	OPENSSL_CONF=$(abspath pyston/test/openssl_dev.cnf) $(MAKE) -C build/bc_build test

# Note: cpython_testsuite is itself parallel so we might need to run it not in parallel
# with the other tests
_runtests: tests testsuites cpython_testsuite
_runtestsdbg: tests_dbg testsuites_dbg cpython_testsuite_dbg
_runtestsopt: tests_opt testsuites_opt cpython_testsuite_opt

test: build/system_env/bin/python build/unopt_env/bin/python
	rm -f $(wildcard pyston/test/external/*.output)
	$(MAKE) _runtests
	JIT_MAX_MEM=50000 build/unopt_env/bin/python pyston/test/jit_limit.py
	JIT_MAX_MEM=50000 build/unopt_env/bin/python pyston/test/jit_osr_limit.py
	JIT_MIN_RUNS=0 $(MAKE) tests cpython_testsuite
	JIT_MIN_RUNS=50 $(MAKE) tests cpython_testsuite
	JIT_MIN_RUNS=9999999999 $(MAKE) tests cpython_testsuite
	rm -f $(wildcard pyston/test/external/*.output)

stocktest: build/stockunopt_build/python
	$(MAKE) -C build/stockunopt_build test
dbg_test: python/test/dbg_method_call_unopt


.PHONY: package
package:
ifeq ($(USE_BOLT),1)
	# llvm-bolt must be build outside of dpkg-buildpackage or it will segfault
	$(MAKE) bolt
endif
ifeq ($(RELEASE),16.04)
	# 16.04 needs this file but on newer ubuntu versions it will make it fail
	echo 10 > pyston/debian/compat
	cd pyston; DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -d
else
	cd pyston; DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage --build=binary --no-sign --jobs=auto -d
endif

bench: $(OPT_BENCH_ENV) $(SYSTEM_BENCH_ENV)
	$(MAKE) -C pyston/tools/benchmarks_runner quick_analyze

full_bench: $(OPT_BENCH_ENV) $(SYSTEM_BENCH_ENV) $(PYPY_BENCH_ENV)
	$(MAKE) -C pyston/tools/benchmarks_runner analyze

tags:
	ctags -R --exclude=pyston --exclude=build .
