"""Fail the build if a shipped .so imports something Android 6.0 does not have.

The minSdk 23 build is a best-effort fallback, and a symbol that the device's
libc lacks is not a soft failure: bionic binds eagerly, so the library never
loads and the app closes before its first frame. That is invisible in CI
unless we look for it here - the APK installs fine either way.
"""
import sys
import zipfile

from elf_symbols import Elf

# Anything bionic only gained after API 23. Extend when a Flutter bump brings
# in another one; tools/patch_apk_minsdk.py holds the replacement map.
LATE_LIBC = {
    'pthread_setname_np': 24,
    'pthread_getname_np': 24,
    'android_get_device_api_level': 24,
    'android_get_application_target_sdk_version': 24,
    'AAssetManager_openDir': 24,
    'AAssetDir_getNextFileName': 24,
    'AHardwareBuffer_allocate': 26,
    'AHardwareBuffer_release': 26,
    'ASurfaceTexture_acquireANativeWindow': 28,
    'getrandom': 28,
    'getentropy': 28,
    'memfd_create': 30,
    '__system_property_read_callback': 26,
}


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: check_so_api23.py APK [APK...]')
    bad = False
    for path in sys.argv[1:]:
        print('==', path)
        with zipfile.ZipFile(path) as z:
            libs = sorted(n for n in z.namelist() if n.endswith('.so'))
            if not libs:
                print('  no native libraries')
            for name in libs:
                rows = Elf(bytearray(z.read(name))).imports()
                late = sorted((LATE_LIBC[n], n) for n, bind in rows if bind != 2 and n in LATE_LIBC)
                if late:
                    bad = True
                    print('  FAIL %-46s %s' % (name, late))
                else:
                    print('  ok   %s' % name)
    if bad:
        print('\nA library imports a symbol Android 6.0 does not export; it will not load.')
        raise SystemExit(1)
    print('\nall native libraries are loadable on API 23')


if __name__ == '__main__':
    main()
