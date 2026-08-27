#!/usr/bin/env python3
"""Idempotently adds Patrol's Android test setup to app/build.gradle(.kts)."""
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
if "PatrolJUnitRunner" in src:
    print("gradle: already patched")
    sys.exit(0)

kts = path.suffix == ".kts"
if kts:
    inject = (
        '        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"\n'
        '        testInstrumentationRunnerArguments["clearPackageData"] = "true"\n'
    )
    tail = (
        '\nandroid {\n    testOptions {\n'
        '        execution = "ANDROIDX_TEST_ORCHESTRATOR"\n    }\n}\n'
        '\ndependencies {\n'
        '    androidTestUtil("androidx.test:orchestrator:1.5.1")\n}\n'
    )
else:
    inject = (
        '        testInstrumentationRunner "pl.leancode.patrol.PatrolJUnitRunner"\n'
        '        testInstrumentationRunnerArguments clearPackageData: "true"\n'
    )
    tail = (
        '\nandroid {\n    testOptions {\n'
        '        execution "ANDROIDX_TEST_ORCHESTRATOR"\n    }\n}\n'
        '\ndependencies {\n'
        '    androidTestUtil "androidx.test:orchestrator:1.5.1"\n}\n'
    )

m = re.search(r"defaultConfig\s*\{\n", src)
if not m:
    print("gradle: ERROR — defaultConfig block not found in", path)
    sys.exit(1)
out = src[: m.end()] + inject + src[m.end() :] + tail
path.write_text(out)
print("gradle: patched", path)
