#!/usr/bin/env python3
"""
rock5b-npu-test.py
Tests NPU acceleration on a Rock 5B with mainline kernel >=6.18
and the Rocket driver (DRM accel subsystem) + Mesa Teflon TFLite delegate.

Usage:
    python3 rock5b-npu-test.py                      # Full test (default: large model)
    python3 rock5b-npu-test.py --preset small        # Small model (MobileNet v2)
    python3 rock5b-npu-test.py --preset xlarge       # Extra large (Inception v4)
    python3 rock5b-npu-test.py --check-only          # System check only, no inference
    python3 rock5b-npu-test.py --model /path/to.tflite  # Custom model

Rocket stack:
    Kernel:    rocket.ko -> /dev/accel/accel0
    Userspace: Mesa Teflon TFLite delegate (libteflon.so)
    Models:    Standard .tflite (no .rknn needed)

Manual preparation on the board:
    # 1. Kernel: Armbian edge >=6.18 with Rocket driver
    #    sudo armbian-config --cmd KER001   (select edge-rockchip64)

    # 2. Python dependencies
    #    apt install python3-pip libdrm2
    #    pip install --break-system-packages tensorflow-aarch64 numpy
    #    (tflite-runtime has no aarch64/Python 3.12 wheel on PyPI,
    #     so tensorflow-aarch64 is used as fallback)

    # 3. Teflon delegate (Mesa 25.3+ with Rocket support)
    #    The Ubuntu Noble apt package "mesa-teflon-delegate" only contains
    #    Etnaviv support (VeriSilicon VIPNano), NOT Rocket/RK3588.
    #
    #    Option A — Pre-built von GitHub Release (gh CLI):
    #    gh release download teflon-v25.3.5 --repo vroomfondel/sbcstuff -p 'libteflon.so' -D /usr/local/lib/teflon/
    #    chmod 755 /usr/local/lib/teflon/libteflon.so
    #
    #    Option A — Pre-built von GitHub Release (curl):
    #    mkdir -p /usr/local/lib/teflon
    #    curl -fLo /usr/local/lib/teflon/libteflon.so \
    #      https://github.com/vroomfondel/sbcstuff/releases/download/teflon-v25.3.5/libteflon.so
    #    chmod 755 /usr/local/lib/teflon/libteflon.so
    #
    #    Option B — Build-Script (baut Mesa 25.3.5 aus Source):
    #    sudo ./build-mesa-teflon.sh
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable
    from typing import TypedDict

    import numpy
    from tensorflow.lite.python.interpreter import Interpreter as _TFInterpreter

    class BenchmarkResult(TypedDict):
        mean_ms: float
        median_ms: float
        min_ms: float
        max_ms: float
        std_ms: float
        num_runs: int
        output_shape: tuple[int, ...]
        output_sample: list[float]

    class SystemInfo(TypedDict):
        kernel_ok: bool
        rocket_loaded: bool
        accel_dev: str | None
        devfreq: dict[str, str] | None
        teflon_path: str | None


APT_DEPENDENCIES = ["python3-pip", "libdrm2"]


def _ensure_apt_packages() -> None:
    """Stelle sicher, dass benötigte apt-Pakete installiert sind."""
    import subprocess as _sp
    import sys

    missing = []
    for pkg in APT_DEPENDENCIES:
        result = _sp.run(
            ["dpkg", "-s", pkg],
            capture_output=True,
        )
        if result.returncode != 0:
            missing.append(pkg)

    if not missing:
        return

    print(f"  \033[0;36mℹ\033[0m Installiere fehlende Pakete: {', '.join(missing)} ...")
    try:
        _sp.check_call(["apt-get", "install", "-y"] + missing)
    except FileNotFoundError, _sp.CalledProcessError:
        print(f"  \033[0;31m✘\033[0m apt-Installation fehlgeschlagen: {', '.join(missing)}")
        print(f"  \033[0;36mℹ\033[0m Manuell: sudo apt install {' '.join(missing)}")
        sys.exit(1)


def _ensure_pip() -> None:
    """Stelle sicher, dass pip verfügbar ist — ggf. per apt nachinstallieren."""
    import subprocess as _sp
    import sys

    result = _sp.run(
        [sys.executable, "-m", "pip", "--version"],
        capture_output=True,
    )
    if result.returncode == 0:
        return

    _ensure_apt_packages()

    # Nochmal prüfen nach apt install
    result = _sp.run(
        [sys.executable, "-m", "pip", "--version"],
        capture_output=True,
    )
    if result.returncode != 0:
        print("  \033[0;31m✘\033[0m pip nach Installation immer noch nicht verfügbar")
        sys.exit(1)


def install_and_import(packagename: str, pipname: str) -> None:
    import importlib
    import subprocess as _sp
    import sys

    try:
        globals()[packagename] = importlib.import_module(packagename)
        return
    except ImportError:
        pass

    print(f"  \033[0;36mℹ\033[0m {packagename} nicht gefunden — installiere {pipname} via pip ...")
    _ensure_pip()
    try:
        _sp.check_call(
            [sys.executable, "-m", "pip", "install", "--break-system-packages", pipname],
        )
    except _sp.CalledProcessError:
        print(f"  \033[0;31m✘\033[0m Installation von {pipname} fehlgeschlagen")
        print(f"  \033[0;36mℹ\033[0m Manuell versuchen: pip install --break-system-packages {pipname}")
        sys.exit(1)

    globals()[packagename] = importlib.import_module(packagename)


_ensure_apt_packages()
install_and_import(packagename="tensorflow", pipname="tensorflow-aarch64")
install_and_import(packagename="numpy", pipname="numpy")

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

# -- Colors --------------------------------------------------------------------
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
NC = "\033[0m"


def ok(msg: str) -> None:
    print(f"  {GREEN}✔{NC} {msg}")


def fail(msg: str) -> None:
    print(f"  {RED}✘{NC} {msg}")


def warn(msg: str) -> None:
    print(f"  {YELLOW}⚠{NC} {msg}")


def info(msg: str) -> None:
    print(f"  {CYAN}ℹ{NC} {msg}")


def header(msg: str) -> None:
    print(f"\n{BOLD}══ {msg} ══{NC}")


# -- Configuration -------------------------------------------------------------
# Model presets (all INT8 quantized .tflite from google-coral/test_data)
CORAL_BASE_URL = "https://raw.githubusercontent.com/google-coral/test_data/master"
MODEL_PRESETS = {
    "small": {
        "file": "mobilenet_v2_1.0_224_quant.tflite",
        "desc": "MobileNet v2 (~3.4 MB, schnell, wenig Rechenaufwand)",
    },
    "medium": {
        "file": "mobilenet_v1_1.0_224_quant.tflite",
        "desc": "MobileNet v1 (~4.3 MB, mittlerer Rechenaufwand)",
    },
    "large": {
        "file": "ssd_mobilenet_v2_coco_quant_postprocess.tflite",
        "desc": "SSD MobileNet v2 Object Detection (~6.5 MB, hoher Rechenaufwand)",
    },
    "xlarge": {
        "file": "inception_v1_224_quant.tflite",
        "desc": "Inception v1 (~6.4 MB, hoher Rechenaufwand)",
    },
    "xxlarge": {
        "file": "inception_v2_224_quant.tflite",
        "desc": "Inception v2 (~11 MB, sehr hoher Rechenaufwand)",
    },
}
DEFAULT_MODEL_PRESET = "large"
CACHE_DIR = Path.home() / ".cache" / "rock5b-npu-test"

# Teflon delegate search paths
TEFLON_SEARCH_PATHS = [
    "/usr/local/lib/teflon/libteflon.so",
    "/usr/lib/teflon/libteflon.so",
    "/usr/lib/aarch64-linux-gnu/libteflon.so",
    "/usr/lib/libteflon.so",
    "/usr/local/lib/libteflon.so",
    "/usr/lib/aarch64-linux-gnu/libtfldelegateprovider_teflon.so",
]


# Benchmark parameters
CPU_WARMUP_RUNS = 5  # CPU warmup iterations
NPU_WARMUP_RUNS = 20  # NPU warmup iterations (Rocket braucht mehr)
BENCHMARK_NUM_RUNS = 50  # Fallback if model size unknown
CPU_NUM_THREADS = 4  # Threads for CPU interpreter (XNNPACK)

# Dynamic run count based on model file size
#   < 5 MB  → 100 runs  (kleine Models, schnelle Inference)
#   5-20 MB → 50 runs   (mittlere Models)
#   > 20 MB → 20 runs   (große Models, langsame Inference)
MODEL_SIZE_THRESHOLDS = [
    (5 * 1024 * 1024, 100),
    (20 * 1024 * 1024, 50),
]
MODEL_SIZE_FALLBACK_RUNS = 20

# Subprocess timeouts (seconds)
SUBPROCESS_TIMEOUT = 120  # Timeout for subprocess calls (ldconfig/dmesg/journalctl)

# dmesg keywords for NPU detection
DMESG_KEYWORDS = ("rocket", "rknn", "rknpu", "accel")

# Output
DMESG_DISPLAY_LIMIT = 5  # Number of dmesg lines to display
OUTPUT_SAMPLE_SIZE = 5  # Number of output values for comparison

# Comparison thresholds
NPU_SPEEDUP_THRESHOLD_FAST = 1.2  # Above this speedup NPU counts as "faster"
NPU_SPEEDUP_THRESHOLD_SIMILAR = 0.8  # Below this value NPU counts as "slower"
OUTPUT_COMPARISON_TOLERANCE = 2  # Absolute tolerance for output comparison


def num_runs_for_model(model_path: Path) -> int:
    """Bestimme Anzahl Benchmark-Runs anhand der Modelgröße."""
    try:
        size = model_path.stat().st_size
    except OSError:
        return BENCHMARK_NUM_RUNS
    for threshold, runs in MODEL_SIZE_THRESHOLDS:
        if size < threshold:
            return runs
    return MODEL_SIZE_FALLBACK_RUNS


def download_model(preset: str) -> Path:
    """Download a preset model (quantized, INT8) for benchmarking."""
    model_info = MODEL_PRESETS[preset]
    filename = model_info["file"]
    model_path = CACHE_DIR / filename

    if model_path.exists():
        info(f"Model cached: {model_path}")
        return model_path

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    url = f"{CORAL_BASE_URL}/{filename}"

    info(f"Lade {model_info['desc']} ...")
    urllib.request.urlretrieve(url, model_path)

    if not model_path.exists():
        fail("Download fehlgeschlagen")
        sys.exit(1)

    ok(f"Model gespeichert: {model_path} ({model_path.stat().st_size // 1024} KB)")
    return model_path


# -- System checks -------------------------------------------------------------


def check_kernel() -> tuple[str, bool]:
    """Check kernel version and whether Rocket support is expected."""
    ver = platform.release()
    match = re.match(r"(\d+)\.(\d+)", ver)
    if not match:
        return ver, False
    major, minor = int(match.group(1)), int(match.group(2))
    return ver, (major > 6) or (major == 6 and minor >= 18)


def check_accel_device() -> str | None:
    """Check whether /dev/accel/accel0 exists (Rocket DRM accel)."""
    dev = Path("/dev/accel/accel0")
    if dev.exists():
        return str(dev)
    # Fallback: look for other accel devices
    accel_dir = Path("/dev/accel")
    if accel_dir.is_dir():
        devices = sorted(accel_dir.iterdir())
        if devices:
            return str(devices[0])
    return None


def check_rocket_module() -> bool:
    """Check whether the rocket kernel module is loaded or built-in."""
    # Loaded?
    modules_path = Path("/proc/modules")
    if modules_path.exists():
        content = modules_path.read_text()
        if re.search(r"^rocket\s", content, re.MULTILINE):
            return True

    # Built-in?
    kernel_ver = platform.release()
    builtin_path = Path(f"/lib/modules/{kernel_ver}/modules.builtin")
    if builtin_path.exists():
        content = builtin_path.read_text()
        if "rocket.ko" in content:
            return True

    return False


def check_npu_devfreq() -> dict | None:
    """Read NPU DevFreq info (frequency, governor)."""
    devfreq_base = Path("/sys/class/devfreq")
    npu_path = None

    # RK3588 NPU MMIO: fdab0000.npu
    for d in devfreq_base.iterdir() if devfreq_base.is_dir() else []:
        if "npu" in d.name.lower() or "fdab0000" in d.name:
            npu_path = d
            break

    if not npu_path:
        return None

    result = {}
    for attr in ("cur_freq", "max_freq", "min_freq", "governor", "available_frequencies"):
        f = npu_path / attr
        if f.exists():
            result[attr] = f.read_text().strip()

    return result


def find_teflon_delegate() -> str | None:
    """Search for the Teflon TFLite delegate shared library."""
    for p in TEFLON_SEARCH_PATHS:
        if Path(p).exists():
            return p

    # ldconfig search
    try:
        result = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
        for line in result.stdout.splitlines():
            if "teflon" in line.lower():
                parts = line.split("=>")
                if len(parts) == 2:
                    return parts[1].strip()
    except subprocess.TimeoutExpired, FileNotFoundError:
        pass

    return None


def check_dmesg_rocket() -> list[str]:
    """Search for Rocket-related messages in dmesg, fallback to journalctl."""
    for cmd in (["dmesg"], ["journalctl", "-k", "-b", "0", "--no-pager"]):
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
            lines = []
            for line in result.stdout.splitlines():
                if any(kw in line.lower() for kw in DMESG_KEYWORDS):
                    lines.append(line.strip())
            if lines:
                return lines
        except subprocess.TimeoutExpired, FileNotFoundError, PermissionError:
            continue
    return []


def run_system_checks() -> SystemInfo:
    """Run all system checks."""
    header("System Overview")

    kernel_ver, kernel_ok = check_kernel()
    if kernel_ok:
        ok(f"Kernel {kernel_ver} — Rocket NPU support expected")
    else:
        warn(f"Kernel {kernel_ver} — Rocket requires >=6.18")

    arch = platform.machine()
    if arch == "aarch64":
        ok(f"Architecture: {arch}")
    else:
        fail(f"Architecture: {arch} — Rock 5B is aarch64")

    header("NPU Hardware (Rocket)")

    # Kernel module
    rocket_loaded = check_rocket_module()
    if rocket_loaded:
        ok("Rocket kernel module loaded/built-in")
    else:
        fail("Rocket kernel module NOT found")
        info("Try: sudo modprobe rocket")

    # Device node
    accel_dev = check_accel_device()
    if accel_dev:
        ok(f"Accel device: {accel_dev}")
        # Check permissions
        if os.access(accel_dev, os.R_OK | os.W_OK):
            ok(f"Access to {accel_dev} — OK")
        else:
            warn(f"No R/W access to {accel_dev}")
            info("Try: sudo chmod 666 /dev/accel/accel0")
            info("Or: sudo usermod -aG render $USER")
    else:
        fail("/dev/accel/accel* not found")
        info("Rocket driver not active or no RK3588 NPU in device tree")

    # DevFreq
    devfreq = check_npu_devfreq()
    if devfreq:
        cur = devfreq.get("cur_freq", "?")
        max_f = devfreq.get("max_freq", "?")
        gov = devfreq.get("governor", "?")
        # Convert frequencies to MHz (devfreq reports Hz)
        try:
            cur_mhz = int(cur) // 1_000_000
            max_mhz = int(max_f) // 1_000_000
            ok(f"NPU DevFreq: {cur_mhz} MHz / max {max_mhz} MHz (governor: {gov})")
        except ValueError, TypeError:
            ok(f"NPU DevFreq: cur={cur} max={max_f} governor={gov}")
    else:
        warn("NPU DevFreq not found (fdab0000.npu)")

    # dmesg
    dmesg_lines = check_dmesg_rocket()
    if dmesg_lines:
        ok(f"{len(dmesg_lines)} Rocket/NPU messages in dmesg")
        for line in dmesg_lines[:DMESG_DISPLAY_LIMIT]:
            info(f"  {line}")
        if len(dmesg_lines) > DMESG_DISPLAY_LIMIT:
            info(f"  ... and {len(dmesg_lines) - DMESG_DISPLAY_LIMIT} more")
    else:
        if os.geteuid() == 0:
            warn("No Rocket/NPU messages in dmesg (keywords: " + ", ".join(DMESG_KEYWORDS) + ")")
        else:
            warn("No Rocket/NPU messages in dmesg (possibly missing permissions)")

    header("Teflon Delegate (Userspace)")

    teflon_path = find_teflon_delegate()
    if teflon_path:
        ok(f"Teflon delegate: {teflon_path}")
    else:
        fail("Teflon delegate (libteflon.so) not found")
        info("Mesa Teflon must be installed for NPU acceleration")
        info("Option 1 — Build-Script (empfohlen):")
        info("  sudo ./build-mesa-teflon.sh")
        info("Option 2 — Pre-built von GitHub Release:")
        info(
            "  gh release download teflon-v25.3.5 --repo vroomfondel/sbcstuff -p 'libteflon.so' -D /usr/local/lib/teflon/"
        )
        info("  chmod 755 /usr/local/lib/teflon/libteflon.so")
        info("Option 3 — Pre-built von GitHub Release (curl):")
        info("  mkdir -p /usr/local/lib/teflon")
        info("  curl -fLo /usr/local/lib/teflon/libteflon.so \\")
        info("    https://github.com/vroomfondel/sbcstuff/releases/download/teflon-v25.3.5/libteflon.so")
        info("  chmod 755 /usr/local/lib/teflon/libteflon.so")
        sys.exit(1)

    return {
        "kernel_ok": kernel_ok,
        "rocket_loaded": rocket_loaded,
        "accel_dev": accel_dev,
        "devfreq": devfreq,
        "teflon_path": teflon_path,
    }


# -- Inference benchmark -------------------------------------------------------


def load_tflite_runtime() -> tuple[type[_TFInterpreter], Callable[[str], object]]:
    """Import tflite-runtime or tensorflow.lite."""
    try:
        from tflite_runtime.interpreter import Interpreter, load_delegate

        return Interpreter, load_delegate
    except ImportError:
        pass

    try:
        from tensorflow.lite.python.interpreter import Interpreter
        from tensorflow.lite.python.interpreter import load_delegate

        return Interpreter, load_delegate
    except ImportError:
        pass

    fail("Neither tflite-runtime nor tensorflow found")
    info("Install with: pip install tensorflow-aarch64 numpy")
    sys.exit(1)


def create_test_input(input_details: list[dict[str, object]]) -> numpy.ndarray:
    """Create a random test input matching the model's expected shape."""
    import numpy as np

    shape: tuple[int, ...] = input_details[0]["shape"]  # type: ignore[assignment]
    dtype: type[np.generic] = input_details[0]["dtype"]  # type: ignore[assignment]
    info(f"Input shape: {shape}, dtype: {dtype.__name__}")

    if dtype == np.uint8:
        return np.random.randint(0, 256, size=shape, dtype=np.uint8)
    elif dtype == np.int8:
        return np.random.randint(-128, 127, size=shape, dtype=np.int8)
    else:
        return np.random.rand(*shape).astype(dtype)


def benchmark_inference(
    interpreter: _TFInterpreter,
    input_data: numpy.ndarray,
    num_warmup: int = CPU_WARMUP_RUNS,
    num_runs: int = BENCHMARK_NUM_RUNS,
) -> BenchmarkResult:
    """Run inference benchmark and return timing statistics."""
    import numpy as np

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    interpreter.set_tensor(input_details[0]["index"], input_data)

    # Warmup
    for _ in range(num_warmup):
        interpreter.invoke()

    # Benchmark
    times = []
    for _ in range(num_runs):
        start = time.perf_counter()
        interpreter.invoke()
        elapsed = (time.perf_counter() - start) * 1000  # ms
        times.append(elapsed)

    output = interpreter.get_tensor(output_details[0]["index"])

    return {
        "mean_ms": float(np.mean(times)),
        "median_ms": float(np.median(times)),
        "min_ms": float(np.min(times)),
        "max_ms": float(np.max(times)),
        "std_ms": float(np.std(times)),
        "num_runs": num_runs,
        "output_shape": output.shape,
        "output_sample": output.flatten()[:OUTPUT_SAMPLE_SIZE].tolist(),
    }


def _npu_worker(
    model_path: str,
    teflon_path: str,
    input_bytes: bytes,
    input_shape: tuple,
    input_dtype: str,
    num_runs: int,
    result_file: str,
) -> None:
    """Child process: run NPU inference and write results to a temp file."""
    import json
    import numpy as np

    Interpreter, load_delegate = load_tflite_runtime()
    input_data = np.frombuffer(input_bytes, dtype=input_dtype).reshape(input_shape)

    delegate = load_delegate(teflon_path)
    npu_interp = Interpreter(
        model_path=model_path,
        experimental_delegates=[delegate],
    )
    npu_interp.allocate_tensors()
    result = benchmark_inference(npu_interp, input_data, num_warmup=NPU_WARMUP_RUNS, num_runs=num_runs)
    # numpy types are not JSON-serializable — convert for json.dump
    serializable: dict[str, object] = {**result, "output_shape": list(result["output_shape"])}

    with open(result_file, "w") as f:
        json.dump(serializable, f)


def _run_npu_benchmark_isolated(
    model_path: Path, teflon_path: str, input_data: numpy.ndarray, num_runs: int
) -> BenchmarkResult | None:
    """Run NPU benchmark in a child process to survive driver crashes."""
    import json
    import multiprocessing
    import tempfile

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tmp:
        result_file = tmp.name

    try:
        proc = multiprocessing.Process(
            target=_npu_worker,
            args=(
                str(model_path),
                teflon_path,
                input_data.tobytes(),
                input_data.shape,
                str(input_data.dtype),
                num_runs,
                result_file,
            ),
        )
        proc.start()
        proc.join(timeout=300)

        if proc.is_alive():
            proc.kill()
            proc.join()
            fail("NPU Benchmark Timeout (300s)")
            return None

        exitcode = proc.exitcode
        if exitcode is None or exitcode != 0:
            fail(f"NPU Benchmark abgestürzt (Exit-Code {exitcode})")
            if exitcode is not None and exitcode < 0:
                import signal as _sig

                sig = -exitcode
                sig_name = _sig.Signals(sig).name if sig in _sig.Signals._value2member_map_ else str(sig)
                info(f"Signal: {sig_name} — Rocket-Treiber unterstützt dieses Model wahrscheinlich nicht")
            info("Tipp: --preset small oder ein anderes Model versuchen")
            return None

        with open(result_file) as f:
            result = json.load(f)
        result["output_shape"] = tuple(result["output_shape"])
        return result

    except Exception as e:
        fail(f"NPU Benchmark Fehler: {e}")
        return None
    finally:
        Path(result_file).unlink(missing_ok=True)


def run_inference_test(model_path: Path, sys_info: SystemInfo) -> None:
    """Run CPU and (if available) NPU inference and compare results."""
    import numpy as np

    Interpreter, load_delegate = load_tflite_runtime()

    header("Inference Benchmark")
    num_runs = num_runs_for_model(model_path)
    model_size_mb = model_path.stat().st_size / (1024 * 1024)
    info(f"Model: {model_path.name} ({model_size_mb:.1f} MB, n={num_runs})")

    # -- CPU baseline (XNNPACK) ------------------------------------------------
    info("Starting CPU benchmark (XNNPACK) ...")
    cpu_interp = Interpreter(model_path=str(model_path), num_threads=CPU_NUM_THREADS)
    cpu_interp.allocate_tensors()

    input_data = create_test_input(cpu_interp.get_input_details())
    cpu_result = benchmark_inference(cpu_interp, input_data, num_warmup=CPU_WARMUP_RUNS, num_runs=num_runs)

    ok(
        f"CPU:  {cpu_result['mean_ms']:.1f} ms ± {cpu_result['std_ms']:.1f} ms  "
        f"(median {cpu_result['median_ms']:.1f} ms, min {cpu_result['min_ms']:.1f} ms, "
        f"n={cpu_result['num_runs']})"
    )

    # -- NPU via Teflon delegate -----------------------------------------------
    teflon_path = sys_info.get("teflon_path")
    npu_result = None

    if teflon_path:
        info("Starting NPU benchmark (Teflon delegate) ...")
        npu_result = _run_npu_benchmark_isolated(model_path, teflon_path, input_data, num_runs)
        if npu_result:
            ok(
                f"NPU:  {npu_result['mean_ms']:.1f} ms ± {npu_result['std_ms']:.1f} ms  "
                f"(median {npu_result['median_ms']:.1f} ms, min {npu_result['min_ms']:.1f} ms, "
                f"n={npu_result['num_runs']})"
            )
    else:
        warn("Teflon delegate not available — skipping NPU benchmark")
        info("Only CPU results available")

    # -- Comparison ------------------------------------------------------------
    header("Result")

    if npu_result:
        speedup = cpu_result["mean_ms"] / npu_result["mean_ms"]
        if speedup > NPU_SPEEDUP_THRESHOLD_FAST:
            ok(f"NPU is {BOLD}{speedup:.1f}x faster{NC} than CPU")
        elif speedup > NPU_SPEEDUP_THRESHOLD_SIMILAR:
            warn(f"NPU and CPU perform similarly ({speedup:.1f}x)")
            info("Possible causes: model too small, delegate overhead, " "not all ops offloaded to NPU")
        else:
            fail(f"NPU is {1/speedup:.1f}x SLOWER than CPU")
            info("Teflon delegate may not be used correctly")

        # Output comparison (sanity check)
        cpu_out = np.array(cpu_result["output_sample"])
        npu_out = np.array(npu_result["output_sample"])
        if np.allclose(cpu_out, npu_out, atol=OUTPUT_COMPARISON_TOLERANCE):
            ok("Output comparison: CPU and NPU produce consistent results")
        else:
            warn(f"Output differs — CPU: {cpu_out}, NPU: {npu_out}")
            info("Minor deviations with quantized models are normal")
    else:
        info(f"CPU inference: {cpu_result['mean_ms']:.1f} ms per run")
        warn("No NPU comparison possible (Teflon not available)")

    print()


# -- Main ----------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description="Test NPU acceleration on Rock 5B (Rocket + Teflon)")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="System check only, no inference",
    )
    parser.add_argument(
        "--model",
        type=Path,
        help="Pfad zu einem eigenen .tflite Model",
    )
    preset_names = list(MODEL_PRESETS.keys())
    parser.add_argument(
        "--preset",
        choices=preset_names,
        default=DEFAULT_MODEL_PRESET,
        help=f"Model-Preset (default: {DEFAULT_MODEL_PRESET}). "
        + ", ".join(f"{k}: {v['desc']}" for k, v in MODEL_PRESETS.items()),
    )
    args = parser.parse_args()

    print(f"\n{BOLD}Rock 5B NPU Test (Rocket / Teflon){NC}")
    print(f"{'─' * 42}")

    sys_info = run_system_checks()

    if args.check_only:
        print()
        return

    # Determine model
    if args.model:
        if not args.model.exists():
            fail(f"Model nicht gefunden: {args.model}")
            sys.exit(1)
        model_path = args.model
    else:
        model_path = download_model(args.preset)

    run_inference_test(model_path, sys_info)


if __name__ == "__main__":
    main()
