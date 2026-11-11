#!/usr/bin/env python3
"""Check an installed Linux entry pair and run its isolated native smoke path."""
import argparse
import hashlib
import json
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


def runtime_inventory(prefix, env, root):
    """Inspect the installed closure, not build-tree exports or loader search hints."""
    manifest_path = prefix / "share/wikidict/qt-runtime.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema") != "wikidict.qt-runtime.v1":
        raise RuntimeError("missing private Qt runtime manifest")
    if (prefix / "bin/qt.conf").read_text() != "[Paths]\nPrefix=..\nLibraries=lib\nPlugins=lib/qt6/plugins\n":
        raise RuntimeError("installed Qt plugin lookup is not prefix-relative")
    libraries, plugins = manifest["libraries"], manifest["plugins"]
    if not libraries or not plugins:
        raise RuntimeError("empty installed Qt runtime inventory")
    paths, sonames, plugin_targets = {}, {}, set()
    for index, (row, plugin) in enumerate([(r, False) for r in libraries] + [(r, True) for r in plugins]):
        relative = row["path"]
        if not re.fullmatch(r"lib/(?:qt6/plugins/[a-z-]+/)?[A-Za-z0-9_.+-]+", relative):
            raise RuntimeError(f"invalid runtime path {relative!r}")
        path = prefix / relative
        if relative in paths or path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError(f"invalid or repeated runtime artifact {relative}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
            raise RuntimeError(f"runtime artifact hash differs: {relative}")
        dynamic, _ = run(["readelf", "-d", str(path)], env, root, f"runtime-elf-{index}")
        needed = [x.decode() for x in re.findall(rb"\(NEEDED\)[^\n]*\[([^\]]*)\]", dynamic)]
        soname = [x.decode() for x in re.findall(rb"\(SONAME\)[^\n]*\[([^\]]*)\]", dynamic)]
        rpath = [x.decode() for x in re.findall(rb"\((?:RUNPATH|RPATH)\)[^\n]*\[([^\]]*)\]", dynamic)]
        expected_rpath = "$ORIGIN/../../.." if plugin else "$ORIGIN"
        if needed != row["needed"] or soname != ([row["soname"]] if row["soname"] else []) or rpath != [expected_rpath]:
            raise RuntimeError(f"runtime ELF contract differs: {relative}")
        dependencies, _ = run(["ldd", str(path)], env, root, f"runtime-dependencies-{index}")
        if b"not found" in dependencies:
            raise RuntimeError(f"missing installed runtime dependency: {relative}")
        for name, resolved in re.findall(rb"(libQt[^\s]+)\s+=>\s+(\S+)", dependencies):
            if not Path(resolved.decode()).resolve(strict=True).is_relative_to((prefix / "lib").resolve()):
                raise RuntimeError(f"installed dependency escaped prefix: {name.decode()}")
        paths[relative] = row
        if plugin:
            plugin_targets.add(row["target"])
        else:
            name = row["soname"]
            if name in sonames or not re.fullmatch(r"libQt6\w+\.so\.6", name):
                raise RuntimeError("invalid/duplicate installed Qt SONAME")
            link = prefix / "lib" / name
            if not link.is_symlink() or os.readlink(link) != path.name or not os.path.samefile(path, link):
                raise RuntimeError(f"invalid Qt SONAME symlink {name}")
            sonames[name] = relative
    required = {"QWaylandIntegrationPlugin", "QWaylandXdgShellIntegrationPlugin", "QXcbIntegrationPlugin",
                "QSvgPlugin", "QSvgIconPlugin", "QFFmpegMediaPlugin", "QTlsBackendOpenSSLPlugin",
                "QJpegPlugin", "QGifPlugin", "QComposePlatformInputContextPlugin",
                "QIbusPlatformInputContextPlugin", "QOffscreenIntegrationPlugin"}
    if plugin_targets != required:
        raise RuntimeError("installed plugin inventory differs from selected desktop features")
    expected_libs = {prefix / r["path"] for r in libraries} | {prefix / "lib" / n for n in sonames}
    if set((prefix / "lib").glob("libQt*.so*")) != expected_libs:
        raise RuntimeError("unselected Qt library in installed prefix")
    if {p for p in (prefix / "lib/qt6/plugins").rglob("*") if p.is_file() or p.is_symlink()} != {prefix / r["path"] for r in plugins}:
        raise RuntimeError("unselected Qt plugin in installed prefix")
    for row in paths.values():
        for needed in row["needed"]:
            if "/" in needed or (needed.startswith("libQt") and needed not in sonames):
                raise RuntimeError(f"unresolved private Qt dependency {needed}")
    notices = manifest.get("notices", [])
    if not notices:
        raise RuntimeError("installed Qt notice inventory is empty")
    seen_notices = set()
    for row in notices:
        relative = row["path"]
        if not re.fullmatch(r"share/licenses/wikidict/qt/(qtbase|qtsvg|qtmultimedia)/(LICENSES|src)/[A-Za-z0-9_./+-]+", relative) or ".." in Path(relative).parts or relative in seen_notices:
            raise RuntimeError("invalid installed notice path")
        seen_notices.add(relative)
        path = prefix / relative
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(prefix.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
            raise RuntimeError(f"installed notice bytes differ: {relative}")
    return manifest, paths, sonames


def validate_loaded_runtime(stderr, prefix, paths, sonames):
    loaded = []
    plugin_names = {Path(name).name for name in paths if "/plugins/" in name}
    for raw in re.findall(rb"calling init:\s*([^\r\n]+)", stderr):
        path = Path(raw.decode(errors="strict").strip())
        if path.name.startswith("libQt") or "/qt6/plugins/" in str(path) or path.name in plugin_names | {"libwikidict-gui.so", "libwikidict-test-settings.so"}:
            real = path.resolve(strict=True)
            if not real.is_relative_to(prefix.resolve()):
                raise RuntimeError(f"loader used an external Qt/GUI runtime: {path}")
            relative = str(real.relative_to(prefix.resolve()))
            if relative not in paths and relative not in {"lib/libwikidict-gui.so", "lib/libwikidict-test-settings.so"}:
                raise RuntimeError(f"loader used an unlisted runtime: {path}")
            loaded.append(relative)
    required = {sonames["libQt6Core.so.6"], sonames["libQt6Gui.so.6"], sonames["libQt6Widgets.so.6"],
                sonames["libQt6Svg.so.6"], "lib/qt6/plugins/platforms/libqoffscreen.so",
                "lib/libwikidict-gui.so", "lib/libwikidict-test-settings.so"}
    if not required.issubset(loaded):
        raise RuntimeError(f"missing actual installed loader witnesses: {sorted(required - set(loaded))}")
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--bin-dir", type=Path, help="installed directory containing wikidict and wikidict-gio")
    source.add_argument("--install-from", type=Path, help="CMake build directory to install into the temporary root")
    parser.add_argument("--config", default="", help="selected CMake install configuration")
    parser.add_argument("--private-qt-runtime", action="store_true", help="validate the coherent bundled Qt runtime")
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
        # Build tools may need their qualified runtime; relocated app checks below stay isolated.
        install_env = dict(env)
        if "LD_LIBRARY_PATH" in os.environ:
            install_env["LD_LIBRARY_PATH"] = os.environ["LD_LIBRARY_PATH"]
        if args.install_from:
            prefix = root / "install"
            command = ["cmake", "--install", str(args.install_from.resolve()), "--prefix", str(prefix)]
            if args.config:
                command += ["--config", args.config]
            run(command, install_env, root, "install1", timeout=120)
            first_manifest = (prefix / "share/wikidict/qt-runtime.json").read_bytes() if args.private_qt_runtime else None
            if args.private_qt_runtime and (prefix / "lib/libwikidict-test-settings.so").exists():
                raise RuntimeError("ordinary runtime install shipped test support")
            run(command, install_env, root, "install2", timeout=120)
            if args.private_qt_runtime:
                if (prefix / "share/wikidict/qt-runtime.json").read_bytes() != first_manifest:
                    raise RuntimeError("repeat runtime install changed the inventory or artifact hashes")
                run(command + ["--component", "wikidict-test-support"], install_env, root, "install-test-support", timeout=120)
            relocated = root / "relocated"
            prefix.rename(relocated)
            prefix = relocated
            bin_dir = prefix / "bin"
            old_product = bin_dir / "dict-qt"
            if old_product.is_file() and not old_product.is_symlink():
                raise RuntimeError("installation contains a regular dict-qt executable")
        else:
            bin_dir = args.bin_dir.absolute()
        prefix = bin_dir.parent
        if args.private_qt_runtime:
            installed_bootstrap = prefix / "lib/libwikidict-test-settings.so"
            if args.bin_dir and bootstrap != installed_bootstrap.resolve(strict=True):
                raise RuntimeError("private runtime smoke requires test support installed inside this prefix")
            bootstrap = installed_bootstrap.resolve(strict=True)
        binary = bin_dir / "wikidict"
        gui = bin_dir / "wikidict-gio"
        if not gui.is_symlink() or os.readlink(gui) != "wikidict" or not os.path.samefile(binary, gui):
            raise RuntimeError("wikidict-gio must be a symlink to the installed wikidict")
        alias = bin_dir / "dict"
        if not alias.is_symlink() or os.readlink(alias) != "wikidict" or not os.path.samefile(binary, alias):
            raise RuntimeError("dict must remain a symlink to the installed wikidict")
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
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORM", "QT_QPA_PLATFORM_PLUGIN_PATH", "QT_PLUGIN_PATH", "QT_QPA_GENERIC_PLUGINS", "QT_QPA_PLATFORMTHEME", "QT_STYLE_OVERRIDE"):
            env.pop(name, None)
        env["LD_DEBUG"] = "libs"
        dynamic, _ = run(["readelf", "-d", str(binary)], env, root, "readelf")
        if b"libQt" in dynamic or b"libwikidict-gui" in dynamic:
            raise RuntimeError("CLI has a direct Qt or GUI shared-library dependency")
        gui_library = bin_dir.parent / "lib/libwikidict-gui.so"
        gui_dynamic, _ = run(["readelf", "-d", str(gui_library)], env, root, "gui-readelf")
        if not re.search(rb"\(NEEDED\)[^\n]*\[libQt6Svg\.so(?:\.[^\]]*)?\]", gui_dynamic):
            raise RuntimeError("GUI must declare its QtSvg runtime dependency")
        rpaths = re.findall(rb"\((?:RUNPATH|RPATH)\)[^\n]*\[([^\]]*)\]", gui_dynamic)
        if rpaths != [b"$ORIGIN"] or re.search(rb"\(NEEDED\)[^\n]*\[/", gui_dynamic):
            raise RuntimeError("GUI dependencies must resolve through the installed library directory or system paths")
        if args.private_qt_runtime:
            manifest, runtime_paths, runtime_sonames = runtime_inventory(prefix, env, root)
            support_dynamic, _ = run(["readelf", "-d", str(bootstrap)], env, root, "support-readelf")
            if re.findall(rb"\((?:RUNPATH|RPATH)\)[^\n]*\[([^\]]*)\]", support_dynamic) != [b"$ORIGIN"]:
                raise RuntimeError("installed test support must resolve Core through its own directory")
            for dependency in re.findall(rb"\(NEEDED\)[^\n]*\[([^\]]*)\]", gui_dynamic + support_dynamic):
                if dependency.startswith(b"libQt") and dependency.decode() not in runtime_sonames:
                    raise RuntimeError("GUI/test support Qt dependency absent from installed closure")
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
            raise RuntimeError("installed GUI did not resolve QtSvg")
        if b"libwikidict-gui" not in smoke_err:
            raise RuntimeError("GUI symlink did not load the GUI component")
        if args.private_qt_runtime:
            loaded = validate_loaded_runtime(smoke_err, prefix, runtime_paths, runtime_sonames)
            print("installed-runtime-result=" + json.dumps({"manifest": manifest, "loaded": loaded, "relocated": bool(args.install_from), "configuration": args.config, "ld_library_path_present": "LD_LIBRARY_PATH" in env}, sort_keys=True), flush=True)
    except Exception:
        print(f"Qualification failed; evidence retained at {root}", flush=True)
        raise
    shutil.rmtree(root)
    print("installed symlink, library paths, headless CLI and isolated GUI startup smoke passed")


if __name__ == "__main__":
    main()
