#!/usr/bin/env bash
set -euo pipefail

stage=$1
out=$2
src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cache="$HOME/.cache/openc910/ubuntu-packages/root/usr"

riscv_as=$(command -v riscv64-unknown-elf-as || true)
riscv=${LSU_RISCV_PREFIX:-${riscv_as%as}}
riscv=${riscv:-$cache/bin/riscv64-unknown-elf-}
iverilog=${LSU_IVERILOG:-$(command -v iverilog || true)}
iverilog=${iverilog:-$cache/bin/iverilog}
vvp=${LSU_VVP:-$(command -v vvp || true)}
vvp=${vvp:-$cache/bin/vvp}
ivl_flags=()
if [[ $iverilog == "$cache/bin/iverilog" ]]; then
  ivl_flags+=("-B$cache/lib/$(uname -m)-linux-gnu/ivl")
fi

log_limits() {
  local scope
  scope="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
  printf 'CPU quota: '
  cat "$scope/cpu.max"
  printf 'CPU affinity: '
  awk '/Cpus_allowed_list/ {print $2}' /proc/self/status
  printf 'Peak cgroup memory (bytes): '
  cat "$scope/memory.peak"
  printf 'Memory cap (bytes): '
  cat "$scope/memory.max"
}

cd "$out"
case "$stage" in
  lsu-build)
    echo "Building LSU smoke program in $out"
    "${riscv}as" -march=rv64ima_zicsr -mabi=lp64 -o lsu_smoke.o "$src/lsu_smoke.S"
    "${riscv}ld" --no-relax -Ttext=0 -Tdata=0x40000 -e _start -o lsu_smoke.elf lsu_smoke.o
    "${riscv}objdump" -d lsu_smoke.elf > lsu_smoke.dis
    "${riscv}objcopy" -O binary --only-section=.text lsu_smoke.elf text.bin
    "${riscv}objcopy" -O binary --only-section=.data lsu_smoke.elf data.bin
    { xxd -p -c4 text.bin; printf '@ffff\n00000000\n'; } > inst.pat
    { xxd -p -c4 data.bin; printf '@ffff\n00000000\n'; } > data.pat
    ;;
  lsu-compile)
    echo "Compiling C910 RTL. Log: $out/compile.log"
    if ! (
      cd ..
      export CODE_BASE_PATH
      CODE_BASE_PATH=$(realpath ../../C910_RTL_FACTORY)
      /usr/bin/time -f 'Elapsed %e s, peak process RSS %M KiB' timeout 900s \
        "$iverilog" "${ivl_flags[@]}" -g2012 -Diverilog=1 -DIVERILOG_SIM -DNO_DUMP \
        -s tb -s lsu_dump -f "$CODE_BASE_PATH/gen_rtl/filelists/C910_asic_rtl.fl" \
        -c ../logical/filelists/smart.fl -c ../logical/filelists/tb.fl \
        -o "$out/xuantie_core.vvp.tmp" "$src/lsu_dump.v"
    ) > compile.log 2>&1; then
      tail -40 compile.log >&2
      rm -f xuantie_core.vvp.tmp
      exit 1
    fi
    mv xuantie_core.vvp.tmp xuantie_core.vvp
    log_limits >> compile.log
    ;;
  lsu-run)
    if [[ ! -s lsu_smoke.elf || ! -s inst.pat || ! -s data.pat ]]; then
      echo "Run make lsu-build first." >&2
      exit 1
    fi
    if [[ ! -s xuantie_core.vvp ]]; then
      echo "Run make lsu-compile first." >&2
      exit 1
    fi
    symbols=$("${riscv}nm" lsu_smoke.elf)
    pass_pc=$(awk '$3 == "lsu_test_pass" {print $1}' <<< "$symbols")
    fail_pc=$(awk '$3 == "lsu_test_fail" {print $1}' <<< "$symbols")
    if [[ -z $pass_pc || -z $fail_pc ]]; then
      echo "Missing pass or fail label in lsu_smoke.elf." >&2
      exit 1
    fi

    echo "Running LSU smoke test. Log: $out/simulation.log"
    rm -f run_case.report lsu.fst
    if ! /usr/bin/time -f 'Elapsed %e s, peak process RSS %M KiB' \
      timeout 480s "$vvp" xuantie_core.vvp -fst "+pass_pc=$pass_pc" "+fail_pc=$fail_pc" \
      > simulation.log 2>&1; then
      tail -40 simulation.log >&2
      exit 1
    fi
    log_limits >> simulation.log
    grep -Fq 'TEST PASS: Core 0 retired success PC ' simulation.log
    grep -Fxq 'TEST PASS' run_case.report
    test -s lsu.fst
    printf 'TEST PASS. Waveform: %s/lsu.fst\n' "$out"
    ;;
  *)
    echo "Unknown LSU stage: $stage" >&2
    exit 2
    ;;
esac
