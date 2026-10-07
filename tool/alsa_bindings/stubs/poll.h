/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/* Linux LP64 (glibc) stand-in for <poll.h>, only for ffigen. */
#ifndef AUD_MIDI_STUB_POLL_H
#define AUD_MIDI_STUB_POLL_H
#define POLLIN 0x001
#define POLLPRI 0x002
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLHUP 0x010
#define POLLNVAL 0x020
typedef unsigned long int nfds_t;
struct pollfd {
  int fd;
  short int events;
  short int revents;
};
#endif
