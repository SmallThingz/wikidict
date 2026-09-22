#!/usr/bin/env python3
"""Encode and verify a whole corpus using an already compiled native expander.

The output is published only after every indexed page is selected and the blob
verifier passes. Failed/interrupted builds remain in a marked staging directory.
"""

import argparse
import datetime
import json
import re
import subprocess
from pathlib import Path


def validate(args):
    staging = args.output.with_name("." + args.output.name + ".building")
    if args.output.exists() or staging.exists():
        raise ValueError("Output and staging directories must not exist")
    args.report.mkdir(parents=True, exist_ok=True)
    log_path = args.report / "full-corpus.log"
    with log_path.open("x") as log:
        staging.mkdir(parents=True)
        marker = staging / ".incomplete"
        marker.write_text("Whole-corpus validation has not passed.\n")
        status = {"state": "running", "stage": "index", "output": str(args.output),
                  "staging": str(staging), "log": str(log_path), "workers": args.workers}

        def report():
            status["updated_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            (args.report / "status.json").write_text(json.dumps(status, indent=2) + "\n")

        report()
        try:
            with (args.expander_root / "page-index.tsv").open("rb") as index:
                status["expected_pages"] = sum(1 for line in index if line.strip() and not line.startswith(b"#"))
            if not status["expected_pages"]:
                raise ValueError("Empty corpus index")
            status["stage"] = "encode"
            report()
            subprocess.run([str(args.builder), str(args.dump), str(staging),
                            "--expander-root", str(args.expander_root), "--workers", str(args.workers)],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
            log.flush()
            summary = re.search(r"^pages=(\d+) main_pages=", log_path.read_text(), re.MULTILINE)
            if summary is None or int(summary[1]) != status["expected_pages"]:
                raise ValueError("Encoder did not report the complete indexed corpus")
            status["selected_pages"] = int(summary[1])
            status["stage"] = "verify"
            report()
            # The verifier rejects marked bundles; this directory remains hidden
            # and is never the published output until verification succeeds.
            marker.unlink()
            subprocess.run([str(args.verifier), str(staging)], stdout=log, stderr=subprocess.STDOUT, check=True)
            if args.output.exists():
                raise ValueError("Output appeared during validation; refusing to replace it")
            staging.rename(args.output)
            status.update(state="passed", stage="complete")
            report()
        except BaseException as error:
            if staging.exists():
                marker.write_text("Whole-corpus validation failed or was interrupted.\n")
            status.update(state="failed", error=str(error))
            report()
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("builder", "verifier", "dump", "expander-root", "output", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be positive")
    # Absolute executable paths also handle commands supplied without a slash.
    args.builder = args.builder.resolve()
    args.verifier = args.verifier.resolve()
    validate(args)
