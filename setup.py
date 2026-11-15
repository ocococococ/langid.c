"""
Build the _langid Python extension (Python 2.7 and 3.x).

langid.pb-c.c / langid.pb-c.h are generated from langid.proto with protoc-c
(or `protoc --c_out=.`) if they are missing.
"""
import os
import subprocess
import sys

try:
    from setuptools import setup, Extension
except ImportError:  # very old Python 2 without setuptools
    from distutils.core import setup, Extension

HERE = os.path.dirname(os.path.abspath(__file__))


def pkg_config(*args):
    try:
        out = subprocess.check_output(("pkg-config",) + args + ("libprotobuf-c",))
    except (OSError, subprocess.CalledProcessError):
        return []
    return out.decode("utf-8").split()


def ensure_protobuf_c_sources():
    if os.path.exists(os.path.join(HERE, "langid.pb-c.c")):
        return
    for cmd in (["protoc-c", "--c_out=."], ["protoc", "--c_out=."]):
        try:
            subprocess.check_call(cmd + ["langid.proto"], cwd=HERE)
            return
        except (OSError, subprocess.CalledProcessError):
            continue
    sys.exit("error: could not generate langid.pb-c.c; install protobuf-c (protoc-c)")


ensure_protobuf_c_sources()

cflags = pkg_config("--cflags-only-I")
libflags = pkg_config("--libs-only-L")

langid = Extension(
    "_langid",
    language="c",
    libraries=["protobuf-c"],
    include_dirs=[f[2:] for f in cflags if f.startswith("-I")],
    library_dirs=[f[2:] for f in libflags if f.startswith("-L")],
    sources=["_langid.c", "liblangid.c", "model.c", "sparseset.c", "langid.pb-c.c"],
)

setup(
    name="langid_c",
    version="0.1",
    ext_modules=[langid],
)
