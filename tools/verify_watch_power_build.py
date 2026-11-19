"""Verify the DFS-only candidate against a separately built stable baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

BASELINE = "13b851e24fb211744c41f0b2eb441f9f0ec209ae"
parser = argparse.ArgumentParser()
parser.add_argument("--baseline-project", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
candidate = repo / "firmware/watch"
baseline = args.baseline_project.resolve()

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def config(path):
    result = {}
    for line in path.read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value.strip('"')
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            result[line[2:-11]] = "n"
    return result

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

a, b = config(baseline / "sdkconfig"), config(candidate / "sdkconfig")
require(a.get("CONFIG_PM_ENABLE", "n") == "n", "Unexpected stable PM configuration")
require(b.get("CONFIG_PM_ENABLE") == "y", "Candidate PM support is missing")
require(b.get("CONFIG_PM_DFS_INIT_AUTO") == "y", "Candidate startup DFS is missing")
require(b.get("CONFIG_FREERTOS_USE_TICKLESS_IDLE", "n") == "n",
        "This candidate must not enable automatic light sleep")
require(b.get("CONFIG_IDF_TARGET") == "esp32s3", "Wrong chip target")
protected_prefixes = (
    "CONFIG_BT_", "CONFIG_ESP_DEFAULT_CPU_FREQ", "CONFIG_ESPTOOLPY_",
    "CONFIG_PARTITION_TABLE", "CONFIG_ESP_CONSOLE",
)
protected_keys = {"CONFIG_FREERTOS_HZ", "CONFIG_FREERTOS_USE_TICKLESS_IDLE"}
for key in sorted(set(a) | set(b)):
    if key in protected_keys or key.startswith(protected_prefixes):
        require(a.get(key, "n") == b.get(key, "n"), "Protected config changed: " + key)

allowed = {
    "firmware/watch/sdkconfig.defaults", "firmware/watch/POWER-CANDIDATE.md",
    "firmware/watch/POWER-CANDIDATE-RESULTS.md",
    ".github/workflows/build-watch.yml", "tools/verify_watch_power_build.py",
}
changed = subprocess.check_output(
    ["git", "diff", "--name-only", BASELINE, "HEAD"], cwd=repo, text=True
).splitlines()
require(set(changed) <= allowed, "Unexpected source changes: " + str(set(changed) - allowed))
for source in (baseline / "main").rglob("*"):
    if source.is_file():
        relative = source.relative_to(baseline)
        require(sha(source) == sha(candidate / relative), "Control source changed: " + str(relative))
require(sha(baseline / "build/partition_table/partition-table.bin")
        == sha(candidate / "build/partition_table/partition-table.bin"), "Partition table changed")

head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
args.output.mkdir(parents=True, exist_ok=True)
for label, project, revision in (("baseline", baseline, BASELINE), ("candidate", candidate, head)):
    dest = args.output / label
    for relative in (
        "agent_relay_watch.bin", "agent_relay_watch.elf", "flasher_args.json",
        "bootloader/bootloader.bin", "partition_table/partition-table.bin",
    ):
        source = project / "build" / relative
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    shutil.copy2(project / "sdkconfig", dest / "sdkconfig")
    metadata = {
        "conclusion": "success", "headSha": revision, "baselineSha": BASELINE,
        "sdk": "ESP-IDF v5.5.1", "hardwareVerified": False,
        "powerMeasured": False, "responseVerified": False,
    }
    (dest / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
report = {
    "baselineSha": BASELINE, "candidateSha": head, "sourceFilesChanged": changed,
    "protectedConfigUnchanged": True, "controlSourcesUnchanged": True,
    "partitionTableUnchanged": True,
    "baselineCPUFrequencyMHz": a.get("CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ"),
    "candidateCPUFrequencyMHz": b.get("CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ"),
    "baselineBluetoothModemSleep": a.get("CONFIG_BT_CTRL_MODEM_SLEEP", "n"),
    "candidateBluetoothModemSleep": b.get("CONFIG_BT_CTRL_MODEM_SLEEP", "n"),
    "candidateTicklessIdle": b.get("CONFIG_FREERTOS_USE_TICKLESS_IDLE", "n"),
    "configChanges": {key: {"baseline": a.get(key, "n"), "candidate": b.get(key, "n")}
                      for key in sorted(set(a) | set(b)) if a.get(key, "n") != b.get(key, "n")},
    "hardwareAcceptance": "NOT RUN: power, haptic latency, locked-phone gestures and reconnect",
}
(args.output / "guard-report.json").write_text(json.dumps(report, indent=2) + "\n")
hashes = {str(path.relative_to(args.output)): sha(path)
          for path in sorted(args.output.rglob("*")) if path.is_file()}
(args.output / "SHA256SUMS.json").write_text(json.dumps(hashes, indent=2) + "\n")
print(json.dumps(report, indent=2))
