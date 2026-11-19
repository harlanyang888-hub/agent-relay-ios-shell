# DFS candidate validation status

Candidate commit was prepared from baseline `13b851e24fb211744c41f0b2eb441f9f0ec209ae`.

## Completed

- Host protocol regression: `watch protocol tests passed` using the command in
  `firmware/watch/README.md`.
- `git diff --check`: passed.
- Official ESP-IDF v5.5.1 source review: `components/esp_pm/Kconfig` defines
  automatic DFS with the default CPU maximum and XTAL minimum;
  `components/bt/controller/esp32s3/Kconfig.in` delegates to the shared
  controller Kconfig where Bluetooth modem sleep defaults off;
  the I2C master documentation describes APB-frequency locks around
  transactions for APB-clocked buses.

## Blocked locally

The `espressif/idf:v5.5.1` image is absent, `idf.py` is not installed on the
host, and the root filesystem had only 3.0 GB free at inspection. Pulling an
unmeasured multi-gigabyte image could exhaust the host disk, so it was not
attempted. Consequently there is no baseline/candidate generated `sdkconfig`
comparison, full firmware build, `.bin`, or `flasher_args.json` artifact yet.
No firmware was flashed and no device power or response measurements were
made.

User-provided observational context (not independently measured in this task):
3h00m07s standby changed 96% to 9%; aggregate platform audio was 96.48 s and
watch-side audio was 84.544 s.
