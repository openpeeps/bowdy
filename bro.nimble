# Package

version       = "0.2.1"
author        = "George Lemon"
description   = "A super fast CSS preprocessor for cool kids!"
license       = "LGPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
installDirs   = @["bowdy"]
bin           = @["bowdy"]
binDir        = "bin"


# Dependencies

requires "nim >= 2.0.0"

requires "kapsis >= 0.4.5"
requires "semver >= 1.2.3"
requires "openparser >= 0.3.1"
requires "checksums >= 0.2.2"
requires "voodoo >= 0.2.0"
requires "vancode >= 0.2.7"
requires "watchout >= 0.3.0"
requires "nimsimd >= 1.3.2"
