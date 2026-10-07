/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Linux LP64 (glibc) stand-in for <string.h>, only for ffigen. */
#ifndef AUD_MIDI_STUB_STRING_H
#define AUD_MIDI_STUB_STRING_H
#include <stddef.h>
void *memset(void *s, int c, size_t n);
void *memcpy(void *dest, const void *src, size_t n);
#endif
