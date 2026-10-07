/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Linux stand-in for <endian.h>, only for ffigen (little endian targets). */
#ifndef AUD_MIDI_STUB_ENDIAN_H
#define AUD_MIDI_STUB_ENDIAN_H
#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN 4321
#define __BYTE_ORDER __LITTLE_ENDIAN
#endif
