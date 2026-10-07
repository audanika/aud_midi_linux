/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Linux LP64 (glibc) stand-in for <sys/types.h>, only for ffigen. */
#ifndef AUD_MIDI_STUB_SYS_TYPES_H
#define AUD_MIDI_STUB_SYS_TYPES_H
#include <stddef.h>
typedef long ssize_t;
typedef long off_t;
typedef int pid_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned int mode_t;
typedef long time_t;
typedef long suseconds_t;
#endif
