/*
 * @license
 * Copyright (c) Audanika
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

/*
 * Entry point for ffigen: the part of <alsa/asoundlib.h> the sequencer
 * backend binds. alsa-lib's configure script assembles asoundlib.h from
 * asoundlib-head.h, a list of headers and asoundlib-tail.h; this file
 * repeats that order for the headers the sequencer API needs.
 */

#ifndef AUD_MIDI_ALSA_SEQ_H
#define AUD_MIDI_ALSA_SEQ_H

#define __ASOUNDLIB_H

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <string.h>
#include <fcntl.h>
#include <assert.h>
#include <poll.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <time.h>
#include <endian.h>

#include <alsa/asoundef.h>
#include <alsa/version.h>
#include <alsa/global.h>
#include <alsa/input.h>
#include <alsa/output.h>
#include <alsa/error.h>
#include <alsa/conf.h>
#include <alsa/rawmidi.h>
#include <alsa/ump.h>
#include <alsa/timer.h>
#include <alsa/ump_msg.h>
#include <alsa/seq_event.h>
#include <alsa/seq.h>
#include <alsa/seqmid.h>
#include <alsa/seq_midi_event.h>

#endif
