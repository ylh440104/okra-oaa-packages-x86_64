#!/usr/bin/env python3
"""Add ExtraPackages (host build dependencies) to recipes that need them."""

import pathlib
import sys

ExtraPackages = {
    "glibc": "bison gawk texinfo",
    "gcc": "flex bison gawk texinfo wget libgmp-dev libmpfr-dev libmpc-dev",
    "binutils": "texinfo",
    "iputils": "meson ninja-build",
    "systemd": "meson ninja-build gperf",
    "procps": "autoconf automake libtool pkg-config gettext",
}

def main() -> int:
    Directory = pathlib.Path(sys.argv[1])
    for Name, Packages in ExtraPackages.items():
        Path = Directory / (Name + ".conf")
        if not Path.is_file():
            print("missing recipe", Path)
            continue
        Text = Path.read_text()
        if "ExtraPackages=" in Text:
            print("already patched", Name)
            continue
        Path.write_text(Text.rstrip("\n") + "\nExtraPackages=(%s)\n" % Packages)
        print("patched", Name, "->", Packages)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
