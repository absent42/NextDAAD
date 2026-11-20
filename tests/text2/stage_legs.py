"""Stage the text2 legs: one build-tests.ps1 run per switch (it stages a single leg per run).

python tests/text2/stage_legs.py reader|loader
Needs an NDRC with -nxtext: NEXTDAAD_NDRC defaults to D:\\NDRC\\ndrc.exe.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SHELL = shutil.which('pwsh') or shutil.which('powershell') or 'powershell'
SETS = {
    'reader': ['-Text2', '-Text2Ctl', '-Text2Wide', '-Text2WideCtl', '-Text2Nest', '-Text2NestCtl',
               '-Text2Xmb', '-Text2XmbPart', '-Text2XmbFp'],
    'loader': ['-Text2', '-Text2Wide', '-Text2Ctl', '-Text2Bad', '-Text2Region', '-Text2RegionCtl',
               '-Text2RegionBad'],
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in SETS:
        sys.exit(__doc__)
    env = dict(os.environ)
    env.setdefault('NEXTDAAD_NDRC', r'D:\NDRC\ndrc.exe')
    for sw in SETS[sys.argv[1]]:
        argv = [SHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                os.path.join(ROOT, 'tests', 'build-tests.ps1'), sw]
        print('stage', sw, flush=True)
        rc = subprocess.run(argv, cwd=ROOT, env=env).returncode
        if rc:
            sys.exit('build-tests.ps1 %s failed (rc %d)' % (sw, rc))


if __name__ == '__main__':
    main()
