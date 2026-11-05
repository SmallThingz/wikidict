#!/usr/bin/env python3
"""Check an installed Linux entry pair and run its isolated native smoke path."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(command, env, root, label, timeout=45):
    stdout_path = root / (label + ".stdout")
    stderr_path = root / (label + ".stderr")
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        result = subprocess.run(command, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{command!r} exited {result.returncode}; see {stdout_path} and {stderr_path}")
    return stdout_path.read_bytes(), stderr_path.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--bin-dir", type=Path, help="installed directory containing wikidict and wikidict-gio")
    source.add_argument("--install-from", type=Path, help="CMake build directory to install into the temporary root")
    parser.add_argument("bootstrap", type=Path, help="test-only Qt settings preload shared library")
    parser.add_argument("fixture", type=Path, help="tests/fixtures directory")
    parser.add_argument("tmp_root", type=Path, help="task-specific temporary directory")
    args = parser.parse_args()
    args.tmp_root.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="unified-entry-", dir=args.tmp_root.resolve()))
    try:
        bootstrap = args.bootstrap.resolve(strict=True)
        env = os.environ.copy()
        for name in ("DESTDIR", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_DEBUG_OUTPUT", "LD_DEBUG"):
            env.pop(name, None)
        if args.install_from:
            prefix = root / "install"
            command = ["cmake", "--install", str(args.install_from.resolve()), "--prefix", str(prefix)]
            run(command, env, root, "install1")
            run(command, env, root, "install2")
            relocated = root / "relocated"
            prefix.rename(relocated)
            prefix = relocated
            bin_dir = prefix / "bin"
            old_product = bin_dir / "dict-qt"
            if old_product.is_file() and not old_product.is_symlink():
                raise RuntimeError("installation contains a regular dict-qt executable")
        else:
            bin_dir = args.bin_dir.absolute()
        binary = bin_dir / "wikidict"
        gui = bin_dir / "wikidict-gio"
        if not gui.is_symlink() or os.readlink(gui) != "wikidict" or not os.path.samefile(binary, gui):
            raise RuntimeError("wikidict-gio must be a symlink to the installed wikidict")
        fixture = root / "fixture"
        shutil.copytree(args.fixture, fixture)
        for name, value in {"XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache",
                            "XDG_DATA_HOME": "data", "XDG_CONFIG_DIRS": "config-system",
                            "XDG_DATA_DIRS": "data-system"}.items():
            path = root / value
            path.mkdir()
            env[name] = str(path)
        for name in ("LD_PRELOAD", "LD_LIBRARY_PATH", "LD_DEBUG_OUTPUT"):
            env.pop(name, None)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORM", "QT_QPA_PLATFORM_PLUGIN_PATH"):
            env.pop(name, None)
        env["LD_DEBUG"] = "libs"
        dynamic, _ = run(["readelf", "-d", str(binary)], env, root, "readelf")
        if b"libQt" in dynamic or b"libwikidict-gui" in dynamic:
            raise RuntimeError("CLI has a direct Qt or GUI shared-library dependency")
        gui_library = bin_dir.parent / "lib/libwikidict-gui.so"
        gui_dynamic, _ = run(["readelf", "-d", str(gui_library)], env, root, "gui-readelf")
        if not re.search(rb"\(NEEDED\)[^\n]*\[libQt6Svg\.so(?:\.[^\]]*)?\]", gui_dynamic):
            raise RuntimeError("GUI must declare its system QtSvg runtime dependency")
        rpaths = re.findall(rb"\((?:RUNPATH|RPATH)\)[^\n]*\[([^\]]*)\]", gui_dynamic)
        if rpaths != [b"$ORIGIN"] or re.search(rb"\(NEEDED\)[^\n]*\[/", gui_dynamic):
            raise RuntimeError("GUI dependencies must resolve through the installed library directory or system paths")
        cli_out, cli_err = run([str(binary), "--help"], env, root, "cli-help")
        if not cli_out.strip() or b"libQt" in cli_err or b"libwikidict-gui" in cli_err:
            raise RuntimeError("CLI help was empty or loaded Qt/the GUI component")
        settings = root / "settings"
        settings.mkdir()
        env["WIKIDICT_TEST_SETTINGS_ROOT"] = str(settings)
        env["LD_PRELOAD"] = str(bootstrap)
        env["QT_QPA_PLATFORM"] = "offscreen"
        _, smoke_err = run([str(gui), "--smoke", "--root", str(fixture), "cat"], env, root, "gui-smoke")
        if not (settings / "bootstrap-ok").is_file():
            raise RuntimeError("settings bootstrap did not run")
        if b"libQt6Svg" not in smoke_err:
            raise RuntimeError("installed GUI did not resolve the system QtSvg runtime")
        if b"libwikidict-gui" not in smoke_err:
            raise RuntimeError("GUI symlink did not load the GUI component")
    except Exception:
        print(f"Qualification failed; evidence retained at {root}", flush=True)
        raise
    shutil.rmtree(root)
    print("installed symlink, library paths, headless CLI and isolated GUI startup smoke passed")


if __name__ == "__main__":
    main()
