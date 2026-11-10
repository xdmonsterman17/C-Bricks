/* audioconv: turns an audio file (WAV, OGG Vorbis, MP3) into what a MS-DOS C-Bricks program plays:
   an 8-bit, mono, 22222 Hz WAV (the Sound Blaster mixer's format). Built by the editor with the C
   compiler it finds (Toolchains.dos_converter), from the decoders in raylib's source tree (dr_wav,
   dr_mp3, stb_vorbis: public domain / MIT-0), and run on each audio file when a project is built
   for MS-DOS.   Usage: audioconv <in> <out.wav>   (exit 0: written; 1: couldn't read it) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"
#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"
#include "stb_vorbis.c"

#define RATE 22222

static void put32(unsigned char *p, unsigned v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24); }

int main(int argc, char **argv) {
    const char *in, *out, *dot;
    short *pcm = NULL;
    unsigned ch = 0, rate = 0;
    unsigned long long frames = 0;
    char ext[8] = "";
    unsigned char *mono, hdr[44];
    long out_n, i;
    double ratio;
    FILE *f;
    if (argc != 3) { fputs("usage: audioconv <in> <out.wav>\n", stderr); return 2; }
    in = argv[1]; out = argv[2];
    dot = strrchr(in, '.');
    if (dot) { size_t k; for (k = 0; k < sizeof ext - 1 && dot[k + 1]; k++) ext[k] = (char)tolower((unsigned char)dot[k + 1]); ext[k] = 0; }
    if (strcmp(ext, "wav") == 0) {
        drwav_uint64 n = 0;
        unsigned int c = 0, r = 0;
        pcm = drwav_open_file_and_read_pcm_frames_s16(in, &c, &r, &n, NULL);
        ch = c; rate = r; frames = n;
    } else if (strcmp(ext, "mp3") == 0) {
        drmp3_config cfg;
        drmp3_uint64 n = 0;
        pcm = drmp3_open_file_and_read_pcm_frames_s16(in, &cfg, &n, NULL);
        ch = cfg.channels; rate = cfg.sampleRate; frames = n;
    } else if (strcmp(ext, "ogg") == 0 || strcmp(ext, "oga") == 0) {
        int c = 0, r = 0, n;
        n = stb_vorbis_decode_filename(in, &c, &r, &pcm);
        if (n > 0) { ch = (unsigned)c; rate = (unsigned)r; frames = (unsigned long long)n; }
    }
    if (!pcm || ch < 1 || rate < 1 || frames < 1) { fprintf(stderr, "audioconv: can't read %s (WAV, OGG or MP3)\n", in); return 1; }
    ratio = (double)rate / RATE;
    out_n = (long)((double)frames / ratio);
    if (out_n < 1) out_n = 1;
    mono = (unsigned char *)malloc((size_t)out_n);
    if (!mono) return 1;
    for (i = 0; i < out_n; i++) {   /* each output sample: the average of the input samples it covers (a box filter: fewer aliasing whistles going down) */
        double a = (double)i * ratio, b = a + ratio, acc = 0, w = 0;
        long k = (long)floor(a);
        for (; (double)k < b && (unsigned long long)k < frames; k++) {
            double lo = (double)k > a ? (double)k : a, hi = (double)(k + 1) < b ? (double)(k + 1) : b, cov = hi - lo, s = 0;
            unsigned c;
            if (cov <= 0) continue;
            for (c = 0; c < ch; c++) s += pcm[(size_t)k * ch + c];
            acc += (s / ch) * cov; w += cov;
        }
        {
            int v = (int)(w > 0 ? acc / w : 0) / 256 + 128;
            mono[i] = (unsigned char)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }
    memcpy(hdr, "RIFF", 4); put32(hdr + 4, 36 + (unsigned)out_n); memcpy(hdr + 8, "WAVEfmt ", 8); put32(hdr + 16, 16);
    hdr[20] = 1; hdr[21] = 0; hdr[22] = 1; hdr[23] = 0; put32(hdr + 24, RATE); put32(hdr + 28, RATE); hdr[32] = 1; hdr[33] = 0; hdr[34] = 8; hdr[35] = 0;
    memcpy(hdr + 36, "data", 4); put32(hdr + 40, (unsigned)out_n);
    f = fopen(out, "wb");
    if (!f) { fprintf(stderr, "audioconv: can't write %s\n", out); return 1; }
    fwrite(hdr, 1, 44, f); fwrite(mono, 1, (size_t)out_n, f); fclose(f);
    return 0;
}
