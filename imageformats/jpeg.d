// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
/*
    Only decodes baseline JPEG/JFIF images
    - not quite optimized but should be well usable already. seems to be
    something like 1.78 times slower than stb_image. i think the nextbit
    and receive functions especially need work.
    - memory use could be reduced by processing MCU-row at a time, and, if
    only grayscale result is requested, the Cb and Cr components could be
    discarded much earlier.
*/
module imageformats.jpeg;

import std.algorithm;   // min
import std.bitmanip;
import std.math;    // floor, ceil
import std.stdio;
import core.stdc.stdlib : alloca;

public import imageformats.common;

//debug = DebugJPEG;

// ----------------------------------------------------------------------
// Public API

JPEG_Header read_jpeg_header(in char[] filename);
JPEG_Header read_jpeg_header(File stream);
ubyte[] read_jpeg(in char[] filename, out long w, out long h, out int chans, int req_chans = 0);
ubyte[] read_jpeg(File stream, out long w, out long h, out int chans, int req_chans = 0);

struct JPEG_Header {    // JFIF
    ubyte version_major;
    ubyte version_minor;
    ushort width, height;
    ubyte num_comps;
    ubyte precision;    // sample precision
    ubyte density_unit;     // 0 = no units but aspect ratio, 1 = dots/inch, 2 = dots/cm
    ushort density_x;
    ushort density_y;
    ubyte type; // 0xc0 = baseline, 0xc2 = progressive, ..., see Marker
}

// ----------------------------------------------------------------------

JPEG_Header read_jpeg_header(in char[] filename) {
    auto stream = File(filename.idup, "rb");
    scope(exit) stream.close();
    return read_jpeg_header(stream);
}

JPEG_Header read_jpeg_header(File stream) {
    if (!stream.isOpen)
        throw new ImageIOException("File not open");
    ubyte[20 + 8] tmp = void;   // SOI, APP0 + SOF0
    stream.readExact(tmp, 20);

    ushort len = bigEndianToNative!ushort(tmp[4..6]);
    if ( tmp[0..4] != [0xff,0xd8,0xff,0xe0] ||
         tmp[6..11] != ['J','F','I','F',0]  ||
         len < 16 )
        throw new ImageIOException("not JPEG/JFIF");

    int thumbsize = tmp[18] * tmp[19] * 3;
    if (thumbsize != cast(int) len - 16)
        throw new ImageIOException("corrupt header");
    if (thumbsize)
        stream.seek(thumbsize, SEEK_CUR);

    JPEG_Header header = {
        version_major      : tmp[11],
        version_minor      : tmp[12],
        density_unit       : tmp[13],
        density_x          : bigEndianToNative!ushort(tmp[14..16]),
        density_y          : bigEndianToNative!ushort(tmp[16..18]),
    };

    while (true) {
        ubyte[2] marker;
        stream.readExact(marker, 2);

        if (marker[0] != 0xff)
            throw new ImageIOException("no frame header");
        while (marker[1] == 0xff)
            stream.readExact(marker[1..$], 1);

        enum SKIP = 0xff;
        switch (marker[1]) with (Marker) {
            case SOF0: .. case SOF3: goto case;
            case SOF9: .. case SOF11:
                header.type = marker[1];
                stream.readExact(tmp[20..28], 8);
                //int len = bigEndianToNative!ushort(tmp[20..22]);
                header.precision = tmp[22];
                header.height = bigEndianToNative!ushort(tmp[23..25]);
                header.width = bigEndianToNative!ushort(tmp[25..27]);
                header.num_comps = tmp[27];
                // ignore the rest
                return header;
            case SOS, EOI: throw new ImageIOException("no frame header");
            case DRI, DHT, DQT, COM: goto case SKIP;
            case APP0: .. case APPf: goto case SKIP;
            case SKIP:
                ubyte[2] lenbuf = void;
                stream.readExact(lenbuf, 2);
                int skiplen = bigEndianToNative!ushort(lenbuf) - 2;
                stream.seek(skiplen, SEEK_CUR);
                break;
            default: throw new ImageIOException("unsupported marker");
        }
    }
    assert(0);
}

ubyte[] read_jpeg(in char[] filename, out long w, out long h, out int chans, int req_chans = 0) {
    if (!filename.length)
        throw new ImageIOException("no filename");
    auto stream = File(filename.idup, "rb");
    scope(exit) stream.close();
    return read_jpeg(stream, w, h, chans, req_chans);
}

ubyte[] read_jpeg(File stream, out long w, out long h, out int chans, int req_chans = 0) {
    if (!stream.isOpen || req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    ubyte[20] tmp = void;   // SOI, APP0, len, data
    stream.readExact(tmp, tmp.length);

    ushort len = bigEndianToNative!ushort(tmp[4..6]);
    if ( tmp[0..4] != [0xff,0xd8,0xff,0xe0] ||
         tmp[6..11] != ['J','F','I','F',0]  ||
         len < 16 )
        throw new ImageIOException("not JPEG/JFIF");

    if (tmp[11] != 1)   // major version (minor is at tmp[12])
        throw new ImageIOException("version not supported");

    //ubyte density_unit = tmp[13];
    //int density_x = bigEndianToNative!ushort(tmp[14..16]);
    //int density_y = bigEndianToNative!ushort(tmp[16..18]);

    int thumbsize = tmp[18] * tmp[19] * 3;
    if (thumbsize != cast(int) len - 16)
        throw new ImageIOException("corrupt header");
    if (thumbsize)
        stream.seek(thumbsize, SEEK_CUR);

    JPEG_Decoder dc;
    dc.stream = stream;

    read_markers(dc);   // reads until first scan header or eoi
    if (dc.eoi_reached)
        throw new ImageIOException("no image data");

    dc.tgt_chans = (req_chans == 0) ? dc.num_comps : req_chans;

    w = dc.width;
    h = dc.height;
    chans = dc.tgt_chans;
    return decode_jpeg(dc);
}

// ----------------------------------------------------------------------
private:

struct JPEG_Decoder {
    File stream;

    bool has_frame_header = false;
    bool eoi_reached = false;

    ubyte[64][4] qtables;
    HuffTab[2] ac_tables;
    HuffTab[2] dc_tables;

    ubyte cb;  // current byte (next bit always at MSB)
    int bits_left;   // num of unused bits in cb

    Component[3] comps;
    ubyte num_comps;
    int[3] index_for;   // index_for[0] is index of comp that comes first in stream
    int tgt_chans;

    int width, height;

    int hmax, vmax;

    ushort restart_interval;    // number of MCUs in restart interval

    // image component
    struct Component {
        ubyte id;
        ubyte sfx, sfy;   // sampling factors, aka. h and v
        int x, y;       // total num of samples, without fill samples
        ubyte qtable;
        ubyte ac_table;
        ubyte dc_table;
        int pred;                // dc prediction
        ubyte[] data;   // reconstructed samples
    }

    int num_mcu_x;
    int num_mcu_y;
}

struct HuffTab {
    // TODO where in the spec does it say 256 values/codes at most?
    ubyte[256] values;
    ubyte[257] sizes;
    short[16] mincode, maxcode;
    short[16] valptr;
}

enum Marker : ubyte {
    SOI = 0xd8,     // start of image
    SOF0 = 0xc0,    // start of frame / baseline DCT
    //SOF1 = 0xc1,    // start of frame / extended seq.
    //SOF2 = 0xc2,    // start of frame / progressive DCT
    SOF3 = 0xc3,    // start of frame / lossless
    SOF9 = 0xc9,    // start of frame / extended seq., arithmetic
    SOF11 = 0xcb,    // start of frame / lossless, arithmetic
    DHT = 0xc4,     // define huffman tables
    DQT = 0xdb,     // define quantization tables
    DRI = 0xdd,     // define restart interval
    SOS = 0xda,     // start of scan
    DNL = 0xdc,     // define number of lines
    RST0 = 0xd0,    // restart entropy coded data
    // ...
    RST7 = 0xd7,    // restart entropy coded data
    APP0 = 0xe0,    // application 0 segment
    // ...
    APPf = 0xef,    // application f segment
    //DAC = 0xcc,     // define arithmetic conditioning table
    COM = 0xfe,     // comment
    EOI = 0xd9,     // end of image
}

void read_markers(ref JPEG_Decoder dc) {
    bool has_next_scan_header = false;
    while (!has_next_scan_header && !dc.eoi_reached) {
        ubyte[2] marker;
        dc.stream.readExact(marker, 2);

        if (marker[0] != 0xff)
            throw new ImageIOException("no marker");
        while (marker[1] == 0xff)
            dc.stream.readExact(marker[1..$], 1);

        debug(DebugJPEG) writefln("marker: %s (%1$x)\t", cast(Marker) marker[1]);
        switch (marker[1]) with (Marker) {
            case DHT: dc.read_huffman_tables(); break;
            case DQT: dc.read_quantization_tables(); break;
            case SOF0:
                if (dc.has_frame_header)
                    throw new ImageIOException("extra frame header");
                debug(DebugJPEG) writeln();
                dc.read_frame_header();
                dc.has_frame_header = true;
                break;
            case SOS:
                if (!dc.has_frame_header)
                    throw new ImageIOException("no frame header");
                dc.read_scan_header();
                has_next_scan_header = true;
                break;
            case DRI: dc.read_restart_interval(); break;
            case EOI: dc.eoi_reached = true; break;
            case APP0: .. case APPf: goto case;
            case COM:
                debug(DebugJPEG) writefln("-> skipping segment");
                ubyte[2] lenbuf = void;
                dc.stream.readExact(lenbuf, lenbuf.length);
                int len = bigEndianToNative!ushort(lenbuf) - 2;
                dc.stream.seek(len, SEEK_CUR);
                break;
            default: throw new ImageIOException("invalid / unsupported marker");
        }
    }
}

// DHT -- define huffman tables
void read_huffman_tables(ref JPEG_Decoder dc) {
    ubyte[19] tmp = void;
    dc.stream.readExact(tmp, 2);
    int len = bigEndianToNative!ushort(tmp[0..2]);
    len -= 2;

    while (0 < len) {
        dc.stream.readExact(tmp, 17);   // info byte & the BITS
        ubyte table_slot = tmp[0] & 0xf; // must be 0 or 1 for baseline
        ubyte table_class = tmp[0] >> 4;  // 0 = dc table, 1 = ac table
        if (1 < table_slot || 1 < table_class)
            throw new ImageIOException("invalid / not supported");

        // compute total number of huffman codes
        int mt = 0;
        foreach (i; 1..17)
            mt += tmp[i];
        if (256 < mt)   // TODO where in the spec?
            throw new ImageIOException("invalid / not supported");

        if (table_class == 0) {
            dc.stream.readExact(dc.dc_tables[table_slot].values, mt);
            derive_table(dc.dc_tables[table_slot], tmp[1..17]);
        } else {
            dc.stream.readExact(dc.ac_tables[table_slot].values, mt);
            derive_table(dc.ac_tables[table_slot], tmp[1..17]);
        }

        len -= 17 + mt;
    }
}

// num_values is the BITS
void derive_table(ref HuffTab table, in ref ubyte[16] num_values) {
    short[256] codes;

    int k = 0;
    foreach (i; 0..16) {
        foreach (j; 0..num_values[i]) {
            table.sizes[k] = cast(ubyte) (i + 1);
            ++k;
        }
    }
    table.sizes[k] = 0;

    k = 0;
    short code = 0;
    ubyte si = table.sizes[k];
    while (true) {
        do {
            codes[k] = code;
            ++code;
            ++k;
        } while (si == table.sizes[k]);

        if (table.sizes[k] == 0)
            break;

        debug(DebugJPEG) assert(si < table.sizes[k]);
        do {
            code <<= 1;
            ++si;
        } while (si != table.sizes[k]);
    }

    derive_mincode_maxcode_valptr(
        table.mincode, table.maxcode, table.valptr,
        codes, num_values
    );
}

// F.15
void derive_mincode_maxcode_valptr(
        ref short[16] mincode, ref short[16] maxcode, ref short[16] valptr,
        in ref short[256] codes, in ref ubyte[16] num_values) pure
{
    mincode[] = -1;
    maxcode[] = -1;
    valptr[] = -1;

    int j = 0;
    foreach (i; 0..16) {
        if (num_values[i] != 0) {
            valptr[i] = cast(short) j;
            mincode[i] = codes[j];
            j += num_values[i] - 1;
            maxcode[i] = codes[j];
            j += 1;
        }
    }
}

// DQT -- define quantization tables
void read_quantization_tables(ref JPEG_Decoder dc) {
    ubyte[2] tmp = void;
    dc.stream.readExact(tmp, 2);
    int len = bigEndianToNative!ushort(tmp[0..2]);
    if (len % 65 != 2)
        throw new ImageIOException("invalid / not supported");
    len -= 2;
    while (0 < len) {
        dc.stream.readExact(tmp, 1);
        ubyte table_info = tmp[0];
        ubyte table_slot = table_info & 0xf;
        ubyte precision = table_info >> 4;  // 0 = 8 bit, 1 = 16 bit
        if (3 < table_slot || precision != 0)    // only 8 bit for baseline
            throw new ImageIOException("invalid / not supported");

        dc.stream.readExact(dc.qtables[table_slot], 64);
        len -= 1 + 64;
    }
}

// SOF0 -- start of frame
void read_frame_header(ref JPEG_Decoder dc) {
    ubyte[9] tmp = void;
    dc.stream.readExact(tmp, 8);
    int len = bigEndianToNative!ushort(tmp[0..2]);  // 8 + num_comps*3
    ubyte precision = tmp[2];
    dc.height = bigEndianToNative!ushort(tmp[3..5]);
    dc.width = bigEndianToNative!ushort(tmp[5..7]);
    dc.num_comps = tmp[7];

    if ( precision != 8 ||
         (dc.num_comps != 1 && dc.num_comps != 3) ||
         len != 8 + dc.num_comps*3 )
        throw new ImageIOException("invalid / not supported");

    dc.hmax = 0;
    dc.vmax = 0;
    int mcu_du = 0; // data units in one mcu
    dc.stream.readExact(tmp, dc.num_comps*3);
    foreach (i; 0..dc.num_comps) {
        uint ci = tmp[i*3]-1;
        if (dc.num_comps <= ci)
            throw new ImageIOException("invalid / not supported");
        dc.index_for[i] = ci;
        auto comp = &dc.comps[ci];
        comp.id = tmp[i*3];
        ubyte sampling_factors = tmp[i*3 + 1];
        comp.sfx = sampling_factors >> 4;
        comp.sfy = sampling_factors & 0xf;
        comp.qtable = tmp[i*3 + 2];
        if ( comp.sfy < 1 || 4 < comp.sfy ||
             comp.sfx < 1 || 4 < comp.sfx ||
             3 < comp.qtable )
            throw new ImageIOException("invalid / not supported");

        if (dc.hmax < comp.sfx) dc.hmax = comp.sfx;
        if (dc.vmax < comp.sfy) dc.vmax = comp.sfy;

        mcu_du += comp.sfx * comp.sfy;
    }
    if (10 < mcu_du)
        throw new ImageIOException("invalid / not supported");

    foreach (i; 0..dc.num_comps) {
        dc.comps[i].x = cast(int) ceil(dc.width * (cast(double) dc.comps[i].sfx / dc.hmax));
        dc.comps[i].y = cast(int) ceil(dc.height * (cast(double) dc.comps[i].sfy / dc.vmax));

        debug(DebugJPEG) writefln("%d comp %d sfx/sfy: %d/%d", i, dc.comps[i].id,
                                                                  dc.comps[i].sfx,
                                                                  dc.comps[i].sfy);
    }

    uint mcu_w = dc.hmax * 8;
    uint mcu_h = dc.vmax * 8;
    dc.num_mcu_x = (dc.width + mcu_w-1) / mcu_w;
    dc.num_mcu_y = (dc.height + mcu_h-1) / mcu_h;

    debug(DebugJPEG) {
        writefln("\tlen: %s", len);
        writefln("\tprecision: %s", precision);
        writefln("\tdimensions: %s x %s", dc.width, dc.height);
        writefln("\tnum_comps: %s", dc.num_comps);
        writefln("\tnum_mcu_x: %s", dc.num_mcu_x);
        writefln("\tnum_mcu_y: %s", dc.num_mcu_y);
    }

}

// SOS -- start of scan
void read_scan_header(ref JPEG_Decoder dc) {
    ubyte[3] tmp = void;
    dc.stream.readExact(tmp, tmp.length);
    ushort len = bigEndianToNative!ushort(tmp[0..2]);
    ubyte num_scan_comps = tmp[2];

    if ( num_scan_comps != dc.num_comps ||
         len != (6+num_scan_comps*2) )
        throw new ImageIOException("invalid / not supported");

    auto buf = (cast(ubyte*) alloca((len-3) * ubyte.sizeof))[0..len-3];
    dc.stream.readExact(buf, buf.length);

    foreach (i; 0..num_scan_comps) {
        ubyte comp_id = buf[i*2];
        int ci;    // component index
        while (ci < dc.num_comps && dc.comps[ci].id != comp_id) ++ci;
        if (dc.num_comps <= ci)
            throw new ImageIOException("invalid / not supported");

        ubyte tables = buf[i*2+1];
        dc.comps[ci].dc_table = tables >> 4;
        dc.comps[ci].ac_table = tables & 0xf;
        if ( 1 < dc.comps[ci].dc_table ||
             1 < dc.comps[ci].ac_table )
            throw new ImageIOException("invalid / not supported");
    }

    // ignore these
    //ubyte spectral_start = buf[$-3];
    //ubyte spectral_end = buf[$-2];
    //ubyte approx = buf[$-1];
}

void read_restart_interval(ref JPEG_Decoder dc) {
    ubyte[4] tmp = void;
    dc.stream.readExact(tmp, tmp.length);
    ushort len = bigEndianToNative!ushort(tmp[0..2]);
    if (len != 4)
        throw new ImageIOException("invalid / not supported");
    dc.restart_interval = bigEndianToNative!ushort(tmp[2..4]);
    debug(DebugJPEG) writeln("restart interval set to: ", dc.restart_interval);
}

// reads data after the SOS segment
ubyte[] decode_jpeg(ref JPEG_Decoder dc) {
    foreach (ref comp; dc.comps[0..dc.num_comps])
        comp.data = new ubyte[dc.num_mcu_x*comp.sfx*8*dc.num_mcu_y*comp.sfy*8];

    // E.7 -- Multiple scans are for progressive images which are not supported
    //while (!dc.eoi_reached) {
        decode_scan(dc);    // E.2.3
        //read_markers(dc);   // reads until next scan header or eoi
    //}

    immutable conversion = dc.num_comps * 10 + dc.tgt_chans;
    switch (conversion) {
        case 30 + 4: return dc.reconstruct_image_rgba();
        case 30 + 3: return dc.reconstruct_image_rgb();
        case 30 + 2, 10 + 2:
            auto comp = &dc.comps[0];
            auto result = new ubyte[dc.width * dc.height * 2];
            if (comp.sfx == dc.hmax && comp.sfy == dc.vmax) {
                long si, di;
                foreach (j; 0 .. dc.height) {
                    si = j * dc.num_mcu_x * comp.sfx * 8;
                    foreach (i; 0 .. dc.width) {
                        result[di++] = comp.data[si++];
                        result[di++] = 255;
                    }
                }
                return result;
            } else {
                // need to resample (haven't tested this...)
                dc.upsample_gray_add_alpha(result);
                return result;
            }
        case 30 + 1, 10 + 1:
            auto comp = &dc.comps[0];
            if (comp.sfx == dc.hmax && comp.sfy == dc.vmax) {
                if (comp.data.length == dc.width * dc.height)
                    return comp.data;    // lucky!
                auto result = new ubyte[dc.width * dc.height];
                long si;
                foreach (j; 0 .. dc.height) {
                    result[j*dc.width .. (j+1)*dc.width] =
                        comp.data[si .. si+dc.width];
                    si += dc.num_mcu_x * comp.sfx * 8;
                }
                return result;
            } else {
                // need to resample (haven't tested this...)
                auto result = new ubyte[dc.width * dc.height];
                dc.upsample_gray(result);
                return result;
            }
        case 10 + 4:
            auto result = new ubyte[dc.width * dc.height * 4];
            long di;
            foreach (j; 0 .. dc.height) {
                long si = j * dc.num_mcu_x * dc.comps[0].sfx * 8;
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = dc.comps[0].data[si++];
                    result[di+3] = 255;
                    di += 4;
                }
            }
            return result;
        case 10 + 3:
            auto result = new ubyte[dc.width * dc.height * 3];
            long di;
            foreach (j; 0 .. dc.height) {
                long si = j * dc.num_mcu_x * dc.comps[0].sfx * 8;
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = dc.comps[0].data[si++];
                    di += 3;
                }
            }
            return result;
        default: assert(0);
    }
}

ubyte[] reconstruct_image_rgb(ref JPEG_Decoder dc) {
    bool resample = false;
    foreach (const ref comp; dc.comps[0..dc.num_comps]) {
        if (comp.sfx != dc.hmax || comp.sfy != dc.vmax) {
            resample = true;
            break;
        }
    }

    ubyte[] result = new ubyte[dc.width * dc.height * 3];

    if (resample) {
        debug(DebugJPEG) writeln("resampling...");
        dc.upsample_nearest(result);
        return result;
    }

    long stride = dc.num_mcu_x * dc.comps[0].sfx * 8;
    foreach (j; 0 .. dc.height) {
        foreach (i; 0 .. dc.width) {
            long di = (j*dc.width + i) * 3;
            long si = j*stride + i;
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[si],
                dc.comps[1].data[si],
                dc.comps[2].data[si],
            );
        }
    }
    return result;
}

ubyte[] reconstruct_image_rgba(ref JPEG_Decoder dc) {
    bool resample = false;
    foreach (const ref comp; dc.comps[0..dc.num_comps]) {
        if (comp.sfx != dc.hmax || comp.sfy != dc.vmax) {
            resample = true;
            break;
        }
    }

    ubyte[] result = new ubyte[dc.width * dc.height * 4];

    if (resample) {
        debug(DebugJPEG) writeln("resampling...");
        dc.upsample_nearest(result);
        return result;
    }

    long stride = dc.num_mcu_x * dc.comps[0].sfx * 8;
    foreach (j; 0 .. dc.height) {
        foreach (i; 0 .. dc.width) {
            long di = (j*dc.width + i) * 4;
            long si = j*stride + i;
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[si],
                dc.comps[1].data[si],
                dc.comps[2].data[si],
            );
            result[di+3] = 255;
        }
    }
    return result;
}

void upsample_gray(ref JPEG_Decoder dc, ubyte[] result) {
    long stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    double si0yratio = cast(double) dc.comps[0].y / dc.height;
    double si0xratio = cast(double) dc.comps[0].x / dc.width;
    long si0;

    foreach (j; 0 .. dc.height) {
        si0 = cast(long) floor(j * si0yratio) * stride0;
        foreach (i; 0 .. dc.width) {
            long di = (j*dc.width + i);
            result[di] =
                dc.comps[0].data[si0 + cast(long) floor(i * si0xratio)];
        }
    }
}

void upsample_gray_add_alpha(ref JPEG_Decoder dc, ubyte[] result) {
    long stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    double si0yratio = cast(double) dc.comps[0].y / dc.height;
    double si0xratio = cast(double) dc.comps[0].x / dc.width;
    long si0, di;

    foreach (j; 0 .. dc.height) {
        si0 = cast(long) floor(j * si0yratio) * stride0;
        foreach (i; 0 .. dc.width) {
            result[di++] = dc.comps[0].data[si0 + cast(long) floor(i * si0xratio)];
            result[di++] = 255;
        }
    }
}

void upsample_nearest(ref JPEG_Decoder dc, ubyte[] result) {
    long stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    long stride1 = dc.num_mcu_x * dc.comps[1].sfx * 8;
    long stride2 = dc.num_mcu_x * dc.comps[2].sfx * 8;

    double si0yratio = cast(double) dc.comps[0].y / dc.height;
    double si1yratio = cast(double) dc.comps[1].y / dc.height;
    double si2yratio = cast(double) dc.comps[2].y / dc.height;
    double si0xratio = cast(double) dc.comps[0].x / dc.width;
    double si1xratio = cast(double) dc.comps[1].x / dc.width;
    double si2xratio = cast(double) dc.comps[2].x / dc.width;
    long si0, si1, si2, di;

    foreach (j; 0 .. dc.height) {
        si0 = cast(long) floor(j * si0yratio) * stride0;
        si1 = cast(long) floor(j * si1yratio) * stride1;
        si2 = cast(long) floor(j * si2yratio) * stride2;

        foreach (i; 0 .. dc.width) {
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[si0 + cast(long) floor(i * si0xratio)],
                dc.comps[1].data[si1 + cast(long) floor(i * si1xratio)],
                dc.comps[2].data[si2 + cast(long) floor(i * si2xratio)],
            );
            if (dc.tgt_chans == 4)
                result[di+3] = 255;
            di += dc.tgt_chans;
        }
    }
}

// E.2.3 and E.8 and E.9
void decode_scan(ref JPEG_Decoder dc) {
    debug(DebugJPEG) writeln("decode scan...");

    int intervals, mcus;
    if (0 < dc.restart_interval) {
        int total_mcus = dc.num_mcu_x * dc.num_mcu_y;
        intervals = (total_mcus + dc.restart_interval-1) / dc.restart_interval;
        mcus = dc.restart_interval;
    } else {
        intervals = 1;
        mcus = dc.num_mcu_x * dc.num_mcu_y;
    }
    debug(DebugJPEG) writeln("intervals: ", intervals);

    foreach (mcu_j; 0 .. dc.num_mcu_y) {
        foreach (mcu_i; 0 .. dc.num_mcu_x) {
            decode_mcu(dc, mcu_i, mcu_j);
            --mcus;

            if (!mcus) {
                --intervals;
                if (!intervals)
                    break;

                read_restart(dc.stream);    // RSTx marker

                if (intervals == 1) {
                    // last interval, may have fewer MCUs than defined by DRI
                    mcus = (dc.num_mcu_y - mcu_j - 1) * dc.num_mcu_x + dc.num_mcu_x - mcu_i - 1;
                } else {
                    mcus = dc.restart_interval;
                }

                // reset decoder
                dc.cb = 0;
                dc.bits_left = 0;
                foreach (k; 0..dc.num_comps)
                    dc.comps[k].pred = 0;
            }

        }
    }
}

// RST0-RST7
void read_restart(File stream) {
    ubyte[2] tmp = void;
    stream.readExact(tmp, tmp.length);
    if (tmp[0] != 0xff || tmp[1] < Marker.RST0 || Marker.RST7 < tmp[1])
        throw new ImageIOException("reset marker missing");
    // the markers should cycle 0 through 7, could check that here...
}

void decode_mcu(ref JPEG_Decoder dc, in int mcu_i, in int mcu_j) {
    foreach (_c; 0..dc.num_comps) {
        auto comp = &dc.comps[dc.index_for[_c]];
        foreach (du_j; 0 .. comp.sfy) {
            foreach (du_i; 0 .. comp.sfx) {
                // decode entropy, dequantize & dezigzag
                short[64] data = decode_block(dc, *comp, dc.qtables[comp.qtable]);

                // idct & level-shift
                int outx = (mcu_i * comp.sfx + du_i) * 8;
                int outy = (mcu_j * comp.sfy + du_j) * 8;
                int dst_stride = dc.num_mcu_x * comp.sfx*8;
                ubyte* dst = comp.data.ptr + outy*dst_stride + outx;
                stbi__idct_block(dst, dst_stride, data);
            }
        }
    }
}

static immutable ubyte[64] dezigzag = [
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
];

// decode entropy, dequantize & dezigzag (see section F.2)
short[64] decode_block(ref JPEG_Decoder dc, ref JPEG_Decoder.Component comp, ref ubyte[64] qtable) {
    short[64] res;

    ubyte t = decode_huff(dc, dc.dc_tables[comp.dc_table]);
    int diff = t ? dc.receive_and_extend(t) : 0;

    comp.pred = comp.pred + diff;
    res[0] = cast(short) (comp.pred * qtable[0]);

    res[1..64] = 0;
    int k = 1;
    do {
        ubyte rs = decode_huff(dc, dc.ac_tables[comp.ac_table]);
        ubyte rrrr = rs >> 4;
        ubyte ssss = rs & 0xf;

        if (ssss == 0) {
            if (rrrr != 0xf)
                break;      // end of block
            k += 16;    // run length is 16
            continue;
        }

        k += rrrr;

        if (63 < k)
            throw new ImageIOException("corrupt block");
        res[dezigzag[k]] = cast(short) (dc.receive_and_extend(ssss) * qtable[k]);
        k += 1;
    } while (k < 64);

    return res;
}

int receive_and_extend(ref JPEG_Decoder dc, ubyte s) {
    // receive
    int symbol = 0;
    foreach (_; 0..s)
        symbol = (symbol << 1) + nextbit(dc);
    // extend
    int vt = 1 << (s-1);
    if (symbol < vt)
        return symbol + (-1 << s) + 1;
    return symbol;
}

// F.16 -- the DECODE
ubyte decode_huff(ref JPEG_Decoder dc, in ref HuffTab tab) {
    short code = nextbit(dc);

    int i = 0;
    while (tab.maxcode[i] < code) {
        code = cast(short) ((code << 1) + nextbit(dc));
        i += 1;
        if (tab.maxcode.length <= i)
            throw new ImageIOException("corrupt huffman coding");
    }
    int j = tab.valptr[i] + code - tab.mincode[i];
    if (tab.values.length <= cast(uint) j)
        throw new ImageIOException("corrupt huffman coding");
    return tab.values[j];
}

// F.2.2.5 and F.18
ubyte nextbit(ref JPEG_Decoder dc) {
    if (!dc.bits_left) {
        ubyte[1] bytebuf;
        dc.stream.readExact(bytebuf, 1);
        dc.cb = bytebuf[0];
        dc.bits_left = 8;

        if (dc.cb == 0xff) {
            ubyte b2;
            dc.stream.readExact(bytebuf, 1);
            b2 = bytebuf[0];

            if (b2 != 0x0) {
                throw new ImageIOException("unexpected marker");
            }
        }
    }

    ubyte r = dc.cb >> 7;
    dc.cb <<= 1;
    dc.bits_left -= 1;
    return r;
}

ubyte clamp(float x) pure {
    if (x < 0) return 0;
    else if (255 < x) return 255;
    return cast(ubyte) x;
}

ubyte[3] ycbcr_to_rgb(ubyte y, ubyte cb, ubyte cr) pure {
    ubyte[3] rgb = void;
    rgb[0] = clamp(y + 1.402*(cr-128));
    rgb[1] = clamp(y - 0.34414*(cb-128) - 0.71414*(cr-128));
    rgb[2] = clamp(y + 1.772*(cb-128));
    return rgb;
}

// ------------------------------------------------------------
// The IDCT stuff here (to the next dashed line) is copied and adapted from
// stb_image which is released under public domain.  Many thanks to stb_image
// author, Sean Barrett.
// Link: https://github.com/nothings/stb/blob/master/stb_image.h

pure int f2f(float x) { return cast(int) (x * 4096 + 0.5); }
pure int fsh(int x) { return x << 12; }

// from stb_image, derived from jidctint -- DCT_ISLOW
pure void STBI__IDCT_1D(ref int t0, ref int t1, ref int t2, ref int t3,
                        ref int x0, ref int x1, ref int x2, ref int x3,
        int s0, int s1, int s2, int s3, int s4, int s5, int s6, int s7)
{
   int p1,p2,p3,p4,p5;
   //int t0,t1,t2,t3,p1,p2,p3,p4,p5,x0,x1,x2,x3;
   p2 = s2;
   p3 = s6;
   p1 = (p2+p3) * f2f(0.5411961f);
   t2 = p1 + p3 * f2f(-1.847759065f);
   t3 = p1 + p2 * f2f( 0.765366865f);
   p2 = s0;
   p3 = s4;
   t0 = fsh(p2+p3);
   t1 = fsh(p2-p3);
   x0 = t0+t3;
   x3 = t0-t3;
   x1 = t1+t2;
   x2 = t1-t2;
   t0 = s7;
   t1 = s5;
   t2 = s3;
   t3 = s1;
   p3 = t0+t2;
   p4 = t1+t3;
   p1 = t0+t3;
   p2 = t1+t2;
   p5 = (p3+p4)*f2f( 1.175875602f);
   t0 = t0*f2f( 0.298631336f);
   t1 = t1*f2f( 2.053119869f);
   t2 = t2*f2f( 3.072711026f);
   t3 = t3*f2f( 1.501321110f);
   p1 = p5 + p1*f2f(-0.899976223f);
   p2 = p5 + p2*f2f(-2.562915447f);
   p3 = p3*f2f(-1.961570560f);
   p4 = p4*f2f(-0.390180644f);
   t3 += p1+p4;
   t2 += p2+p3;
   t1 += p2+p4;
   t0 += p1+p3;
}

// idct and level-shift
pure void stbi__idct_block(ubyte* dst, int dst_stride, in short[64] data) {
   int i;
   int[64] val;
   int* v = val.ptr;
   const(short)* d = data.ptr;

   // columns
   for (i=0; i < 8; ++i,++d, ++v) {
      // if all zeroes, shortcut -- this avoids dequantizing 0s and IDCTing
      if (d[ 8]==0 && d[16]==0 && d[24]==0 && d[32]==0
           && d[40]==0 && d[48]==0 && d[56]==0) {
         //    no shortcut                 0     seconds
         //    (1|2|3|4|5|6|7)==0          0     seconds
         //    all separate               -0.047 seconds
         //    1 && 2|3 && 4|5 && 6|7:    -0.047 seconds
         int dcterm = d[0] << 2;
         v[0] = v[8] = v[16] = v[24] = v[32] = v[40] = v[48] = v[56] = dcterm;
      } else {
         int t0,t1,t2,t3,x0,x1,x2,x3;
         STBI__IDCT_1D(
             t0, t1, t2, t3,
             x0, x1, x2, x3,
             d[ 0], d[ 8], d[16], d[24],
             d[32], d[40], d[48], d[56]
         );
         // constants scaled things up by 1<<12; let's bring them back
         // down, but keep 2 extra bits of precision
         x0 += 512; x1 += 512; x2 += 512; x3 += 512;
         v[ 0] = (x0+t3) >> 10;
         v[56] = (x0-t3) >> 10;
         v[ 8] = (x1+t2) >> 10;
         v[48] = (x1-t2) >> 10;
         v[16] = (x2+t1) >> 10;
         v[40] = (x2-t1) >> 10;
         v[24] = (x3+t0) >> 10;
         v[32] = (x3-t0) >> 10;
      }
   }

   ubyte* o = dst;
   for (i=0, v=val.ptr; i < 8; ++i,v+=8,o+=dst_stride) {
      // no fast case since the first 1D IDCT spread components out
      int t0,t1,t2,t3,x0,x1,x2,x3;
      STBI__IDCT_1D(
          t0, t1, t2, t3,
          x0, x1, x2, x3,
          v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]
      );
      // constants scaled things up by 1<<12, plus we had 1<<2 from first
      // loop, plus horizontal and vertical each scale by sqrt(8) so together
      // we've got an extra 1<<3, so 1<<17 total we need to remove.
      // so we want to round that, which means adding 0.5 * 1<<17,
      // aka 65536. Also, we'll end up with -128 to 127 that we want
      // to encode as 0-255 by adding 128, so we'll add that before the shift
      x0 += 65536 + (128<<17);
      x1 += 65536 + (128<<17);
      x2 += 65536 + (128<<17);
      x3 += 65536 + (128<<17);
      // tried computing the shifts into temps, or'ing the temps to see
      // if any were out of range, but that was slower
      o[0] = stbi__clamp((x0+t3) >> 17);
      o[7] = stbi__clamp((x0-t3) >> 17);
      o[1] = stbi__clamp((x1+t2) >> 17);
      o[6] = stbi__clamp((x1-t2) >> 17);
      o[2] = stbi__clamp((x2+t1) >> 17);
      o[5] = stbi__clamp((x2-t1) >> 17);
      o[3] = stbi__clamp((x3+t0) >> 17);
      o[4] = stbi__clamp((x3-t0) >> 17);
   }
}

// clamp to 0-255
pure ubyte stbi__clamp(int x) {
   if (cast(uint) x > 255) {
      if (x < 0) return 0;
      if (x > 255) return 255;
   }
   return cast(ubyte) x;
}

// the above is adapted from stb_image
// ------------------------------------------------------------

void read_jpeg_info(File stream, out long w, out long h, out int chans) {
    JPEG_Header hdr = read_jpeg_header(stream);
    w = hdr.width;
    h = hdr.height;
    chans = hdr.num_comps;
}

static this() {
    register["jpg"] = ImageIOFuncs(&read_jpeg, null, &read_jpeg_info);
    register["jpeg"] = ImageIOFuncs(&read_jpeg, null, &read_jpeg_info);
}
