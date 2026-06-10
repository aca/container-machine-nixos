# Benchmark OrbStack vs Apple container machine

This documents a simple, repeatable benchmark for comparing an OrbStack Linux
machine with an Apple `container machine`.

The benchmark is intentionally small and uses tools that are normally available
in a base Linux system: `dd`, `sha256sum`, `awk`, and `date`.

## Machines Used

Examples below compare:

- OrbStack machine: `tsvm`
- Apple container machine: `nixos`

Replace those names if needed.

```sh
orbctl list
container machine ls
```

## Match Or Record Resources

For a fair CPU comparison, both machines should have the same CPU count and
similar memory. At minimum, record the actual allocation before comparing
results.

Inspect OrbStack:

```sh
orbctl config show
orb -m tsvm /bin/sh -lc 'export PATH=/run/current-system/sw/bin:/usr/bin:/bin:$PATH; uname -srmo; nproc; grep MemTotal /proc/meminfo'
```

Inspect Apple container machine:

```sh
container machine inspect nixos
container machine run -n nixos -- /bin/sh -lc 'export PATH=/run/current-system/sw/bin:/usr/bin:/bin:$PATH; uname -srmo; nproc; grep MemTotal /proc/meminfo'
```

Set Apple container machine CPU and memory:

```sh
container machine set -n nixos cpus=8 memory=32G
container machine stop nixos
container machine run -n nixos -- true
```

Set OrbStack global CPU and memory, if you want to match it to the container
machine:

```sh
orbctl config set cpu 8
orbctl config set memory_mib 32768
orbctl restart
```

Run the benchmarks sequentially. Do not run both machines at the same time, or
they will compete for host CPU and I/O.

## Benchmark Script

Save this as `/tmp/linux-bench.sh` inside each machine, or pipe it through the
runner commands in the next section.

```sh
set -eu

export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

printf 'env os='
uname -srmo
printf 'env nproc='
nproc
grep MemTotal /proc/meminfo

fmt_result() {
  name=$1
  mib=$2
  start=$3
  end=$4
  awk -v name="$name" -v mib="$mib" -v start="$start" -v end="$end" \
    'BEGIN { sec=(end-start)/1000000000; printf "%-18s %8.3f s %10.1f MiB/s\n", name, sec, mib/sec }'
}

run_case() {
  name=$1
  mib=$2
  start=$(date +%s%N)

  case "$name" in
    copy_8g)
      dd if=/dev/zero of=/dev/null bs=4M count=2048 status=none
      ;;
    sha256_4g)
      dd if=/dev/zero bs=4M count=1024 status=none | sha256sum >/dev/null
      ;;
    sha256_all)
      jobs=$(nproc)
      i=0
      while [ "$i" -lt "$jobs" ]; do
        (dd if=/dev/zero bs=4M count=256 status=none | sha256sum >/dev/null) &
        i=$((i + 1))
      done
      wait
      ;;
    write_direct_2g)
      tmp=/var/tmp/linux-bench.$$
      rm -f "$tmp"
      dd if=/dev/zero of="$tmp" bs=4M count=512 oflag=direct status=none
      sync
      ;;
    read_direct_2g)
      tmp=/var/tmp/linux-bench.$$
      if [ ! -f "$tmp" ]; then
        dd if=/dev/zero of="$tmp" bs=4M count=512 oflag=direct status=none
        sync
      fi
      dd if="$tmp" of=/dev/null bs=4M iflag=direct status=none
      rm -f "$tmp"
      ;;
  esac

  end=$(date +%s%N)
  fmt_result "$name" "$mib" "$start" "$end"
}

run_case copy_8g 8192
run_case sha256_4g 4096
run_case sha256_all $(( $(nproc) * 1024 ))
run_case write_direct_2g 2048
run_case read_direct_2g 2048
```

## Run Against Apple container machine

```sh
cat /tmp/linux-bench.sh | container machine run -i -n nixos -- /bin/sh -s
```

If you want to benchmark the Ubuntu machine instead:

```sh
cat /tmp/linux-bench.sh | container machine run -i -n ubuntu -- /bin/sh -s
```

## Run Against OrbStack

```sh
cat /tmp/linux-bench.sh | orb -m tsvm /bin/sh -s
```

## Interpreting Results

- `sha256_4g`: single pipeline CPU throughput. Good proxy for one busy task.
- `sha256_all`: parallel CPU throughput using `nproc` workers. This favors the
  machine with more vCPUs.
- `write_direct_2g` and `read_direct_2g`: direct I/O against `/var/tmp`, avoiding
  most page cache effects.
- `copy_8g`: memory/kernel copy path. It is often very fast and can be noisy.

Run each benchmark more than once and compare the median, not a single run.
Record `nproc`, `MemTotal`, and whether the target path is a virtual filesystem
or the VM disk.

## Known Caveats

- Apple `container machine run` can be flaky if you launch multiple commands
  concurrently against the same machine. Run benchmark commands sequentially.
- NixOS does not use `/usr/bin` or `/bin` as package locations. The benchmark
  script explicitly adds `/run/current-system/sw/bin` to `PATH`.
- OrbStack and Apple `container machine` may use different kernels and different
  filesystem mounts, so disk results are not purely storage-device results.
- If CPU counts differ, `sha256_all` is not a like-for-like comparison.
