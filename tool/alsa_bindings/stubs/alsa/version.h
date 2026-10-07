/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Stand-in for the <alsa/version.h> that alsa-lib's build writes; the
   values match the alsa-lib release the bindings are generated from. */
#define SND_LIB_MAJOR 1
#define SND_LIB_MINOR 2
#define SND_LIB_SUBMINOR 16
#define SND_LIB_EXTRAVER 1000000
#define SND_LIB_VER(maj, min, sub) (((maj)<<16)|((min)<<8)|(sub))
#define SND_LIB_VERSION SND_LIB_VER(SND_LIB_MAJOR, SND_LIB_MINOR, SND_LIB_SUBMINOR)
#define SND_LIB_VERSION_STR "1.2.16.1"
