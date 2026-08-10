import os
import sys
from .dmm import *


def _self_test():
    # test: can we load every DMM in the tree
    count = 0
    invalid_models = []
    for dirpath, dirnames, filenames in os.walk('.'):
        if '.git' in dirnames:
            dirnames.remove('.git')
        for filename in filenames:
            if filename.endswith('.dmm'):
                fullpath = os.path.join(dirpath, filename)
                try:
                    dmm = DMM.from_file(fullpath)
                except Exception:
                    print('Failed on:', fullpath)
                    raise
                for key, atoms in dmm.dictionary.items():
                    has_turf = any(atom.startswith('/turf') for atom in atoms)
                    has_area = any(atom.startswith('/area') for atom in atoms)
                    if has_turf and has_area:
                        continue
                    missing = []
                    if not has_turf:
                        missing.append('turf')
                    if not has_area:
                        missing.append('area')
                    model_key = num_to_key(key, dmm.key_length, allow_overflow=True)
                    invalid_models.append(
                        f"{fullpath}: model '{model_key}' is missing {' and '.join(missing)}"
                    )
                count += 1

    if invalid_models:
        print('\n'.join(invalid_models))
        raise AssertionError(f'{len(invalid_models)} invalid DMM model(s)')

    print(f"{os.path.relpath(__file__)}: successfully parsed {count} .dmm files")


def _usage():
    print(f"Usage:")
    print(f"    tools{os.sep}bootstrap{os.sep}python -m {__spec__.name}")
    exit(1)


def _main():
    if len(sys.argv) == 1:
        return _self_test()

    return _usage()


if __name__ == '__main__':
    _main()
