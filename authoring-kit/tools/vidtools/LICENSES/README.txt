Third-party components in tools\vidtools\
==========================================

videnc.exe and vidtune.exe are built with PyInstaller from the kit's own
lib\ sources (MIT, see the NextDAAD LICENSE). They bundle the following
libraries in _internal\, each under its own licence:

Component            Licence                               File here
-------------------  ------------------------------------  -----------------------
Python runtime       PSF License                           Python-LICENSE.txt
Qt 6 (PySide6,       LGPL-3.0 (option chosen from          LGPL-3.0.txt,
  shiboken6)           LGPL-3.0 / GPL-2.0 / GPL-3.0)         GPL-3.0.txt
numpy                BSD-3-Clause, plus the licences of    numpy-LICENSE.txt
                       its bundled OpenBLAS and runtime
Pillow               MIT-CMU                               Pillow-LICENSE.txt
PyInstaller          GPL-2.0 with a bootloader exception   PyInstaller-COPYING.txt
  bootloader           permitting distribution

Qt and PySide6 are used unmodified as dynamically linked DLLs, which you
may replace with your own compatible build in _internal\PySide6\. Their
source is available from https://download.qt.io/ and
https://pypi.org/project/PySide6/#files.
