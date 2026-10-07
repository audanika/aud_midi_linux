/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Linux LP64 (glibc) stand-in for <time.h>, only for ffigen. */
#ifndef AUD_MIDI_STUB_TIME_H
#define AUD_MIDI_STUB_TIME_H
#include <sys/types.h>
struct timespec {
  time_t tv_sec;
  long tv_nsec;
};
struct timeval {
  time_t tv_sec;
  suseconds_t tv_usec;
};
#endif
