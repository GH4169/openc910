lsu_src := $(abspath tests/cases/lsu_smoke)
lsu_out := $(abspath work/lsu-smoke-make)
lsu_flow := $(lsu_src)/flow.sh
lsu_layout := $(lsu_src)/lsu-stage.gtkw

LSU_GTKWAVE ?= gtkwave
LSU_DESKTOP ?= $(wildcard $(HOME)/.local/bin/codex-desktop)

# One scope per step. The lock serializes builds and runs in this directory.
lsu_limited = systemd-run --user --scope --quiet \
	-p CPUQuota=80% -p MemoryHigh=2200M -p MemoryMax=2560M \
	-p MemorySwapMax=256M -p TasksMax=32 \
	flock "$(lsu_out)/.lock" taskset -c "$$(awk '/Cpus_allowed_list/ {n=split($$2, cpus, /[,-]/); print cpus[n]}' /proc/self/status)" \
	nice -n 12 ionice -c 2 -n 7

.PHONY: lsu-build lsu-compile lsu-run lsu-wave

$(lsu_out):
	@mkdir -p "$@"

lsu-build lsu-compile lsu-run: | $(lsu_out)
	@$(lsu_limited) bash "$(lsu_flow)" "$@" "$(lsu_out)"

lsu-wave:
	@test -s "$(lsu_out)/lsu.fst" && grep -Fxq "TEST PASS" "$(lsu_out)/run_case.report" || \
		{ echo "Run make lsu-run first." >&2; exit 1; }
	@test -f "$(lsu_out)/lsu-stage.gtkw" || cp "$(lsu_layout)" "$(lsu_out)/lsu-stage.gtkw"
	@$(if $(LSU_DESKTOP),"$(LSU_DESKTOP)" run) "$(LSU_GTKWAVE)" -c 1 -f "$(lsu_out)/lsu.fst" -a "$(lsu_out)/lsu-stage.gtkw"
