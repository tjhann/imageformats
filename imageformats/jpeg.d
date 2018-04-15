// Baseline JPEG decoder

module imageformats.jpeg;

import std.math         : ceil;
import std.bitmanip     : bigEndianToNative;
import std.stdio        : File, SEEK_SET, SEEK_CUR;
import std.typecons     : scoped;
import core.stdc.stdlib : alloca;
import imageformats;

private:

/// Reads a JPEG image. req_chans defines the format of returned image
/// (you can use ColFmt here).
public IFImage read_jpeg(in char[] filename, long req_chans = 0) {
    auto reader = scoped!FileReader(filename);
    return read_jpeg(reader, req_chans);
}

/// Reads an image from a buffer containing a JPEG image. req_chans defines the
/// format of returned image (you can use ColFmt here).
public IFImage read_jpeg_from_mem(in ubyte[] source, long req_chans = 0) {
    auto reader = scoped!MemReader(source);
    return read_jpeg(reader, req_chans);
}

/// Returns width, height and color format information via w, h and chans.
public void read_jpeg_info(in char[] filename, out int w, out int h, out int chans) {
    auto reader = scoped!FileReader(filename);
    return read_jpeg_info(reader, w, h, chans);
}

/// Returns width, height and color format information via w, h and chans.
public void read_jpeg_info_from_mem(in ubyte[] source, out int w, out int h, out int chans) {
    auto reader = scoped!MemReader(source);
    return read_jpeg_info(reader, w, h, chans);
}

// Detects whether a JPEG image is readable from stream.
package bool detect_jpeg(Reader stream) {
    try {
        int w, h, c;
        read_jpeg_info(stream, w, h, c);
        return true;
    } catch (Throwable) {
        return false;
    } finally {
        stream.seek(0, SEEK_SET);
    }
}

package IFImage read_jpeg(Reader stream, long req_chans = 0) {
    if (req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    // SOI
    ubyte[2] tmp = void;
    stream.readExact(tmp, tmp.length);
    if (tmp[0..2] != jpeg_soi_marker)
        throw new ImageIOException("not JPEG");

    JPEG_Decoder dc = { stream: stream };

    read_markers(dc);   // reads until first scan header or eoi
    if (dc.eoi_reached)
        throw new ImageIOException("no image data");

    dc.tgt_chans = (req_chans == 0) ? dc.num_comps : cast(int) req_chans;

    IFImage result = {
        w      : dc.width,
        h      : dc.height,
        c      : cast(ColFmt) dc.tgt_chans,
        pixels : decode_jpeg(dc),
    };
    return result;
}

struct JPEG_Decoder {
    Reader stream;

    bool has_frame_header = false;
    bool eoi_reached = false;

    ubyte[64][4] qtables;
    HuffTab[2] ac_tables;
    HuffTab[2] dc_tables;

    ubyte cb;  // current byte (next bit always at MSB)
    int bits_left;   // num of unused bits in cb

    bool correct_comp_ids;
    Component[3] comps;
    ubyte num_comps;
    int tgt_chans;

    int width, height;

    int hmax, vmax;

    ushort restart_interval;    // number of MCUs in restart interval

    // image component
    struct Component {
        ubyte sfx, sfy;   // sampling factors, aka. h and v
        size_t x, y;       // total num of samples, without fill samples
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
        ubyte ci = tmp[i*3];
        // JFIF says ci should be i+1, but there are images where ci is i. Normalize ids
        // so that ci == i, always. So much for standards...
        if (i == 0) { dc.correct_comp_ids = ci == i+1; }
        if ((dc.correct_comp_ids && ci != i+1)
        || (!dc.correct_comp_ids && ci != i))
            throw new ImageIOException("invalid component id");

        auto comp = &dc.comps[i];
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
        dc.comps[i].x = cast(size_t) ceil(dc.width * (cast(double) dc.comps[i].sfx / dc.hmax));
        dc.comps[i].y = cast(size_t) ceil(dc.height * (cast(double) dc.comps[i].sfy / dc.vmax));

        debug(DebugJPEG) writefln("%d comp %d sfx/sfy: %d/%d", i, dc.comps[i].id,
                                                                  dc.comps[i].sfx,
                                                                  dc.comps[i].sfy);
    }

    size_t mcu_w = dc.hmax * 8;
    size_t mcu_h = dc.vmax * 8;
    dc.num_mcu_x = cast(int) ((dc.width + mcu_w-1) / mcu_w);
    dc.num_mcu_y = cast(int) ((dc.height + mcu_h-1) / mcu_h);

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
        uint ci = buf[i*2] - ((dc.correct_comp_ids) ? 1 : 0);
        if (ci >= dc.num_comps)
            throw new ImageIOException("invalid component id");

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

    // throw away fill samples and convert to target format
    return dc.reconstruct();
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

            // decode mcu
            foreach (c; 0..dc.num_comps) {
                auto comp = &dc.comps[c];
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

            --mcus;

            if (!mcus) {
                --intervals;
                if (!intervals)
                    return;

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
void read_restart(Reader stream) {
    ubyte[2] tmp = void;
    stream.readExact(tmp, tmp.length);
    if (tmp[0] != 0xff || tmp[1] < Marker.RST0 || Marker.RST7 < tmp[1])
        throw new ImageIOException("reset marker missing");
    // the markers should cycle 0 through 7, could check that here...
}

immutable ubyte[64] dezigzag = [
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
short[64] decode_block(ref JPEG_Decoder dc, ref JPEG_Decoder.Component comp,
                                                    in ref ubyte[64] qtable)
{
    short[64] res = 0;

    ubyte t = decode_huff(dc, dc.dc_tables[comp.dc_table]);
    int diff = t ? dc.receive_and_extend(t) : 0;

    comp.pred = comp.pred + diff;
    res[0] = cast(short) (comp.pred * qtable[0]);

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
            dc.stream.readExact(bytebuf, 1);
            if (bytebuf[0] != 0x0) {
                throw new ImageIOException("unexpected marker");
            }
        }
    }

    ubyte r = dc.cb >> 7;
    dc.cb <<= 1;
    dc.bits_left -= 1;
    return r;
}

ubyte[] reconstruct(in ref JPEG_Decoder dc) {
    auto result = new ubyte[dc.width * dc.height * dc.tgt_chans];

    switch (dc.num_comps * 10 + dc.tgt_chans) {
        case 34, 33:
            // Use specialized bilinear filtering functions for the frequent cases where
            // Cb & Cr channels have half resolution.
            if ((dc.comps[0].sfx <= 2 && dc.comps[0].sfy <= 2)
            && (dc.comps[0].sfx + dc.comps[0].sfy >= 3)
            && dc.comps[1].sfx == 1 && dc.comps[1].sfy == 1
            && dc.comps[2].sfx == 1 && dc.comps[2].sfy == 1) {
                void function(in ubyte[], in ubyte[], ubyte[]) resample;
                switch (dc.comps[0].sfx * 10 + dc.comps[0].sfy) {
                    case 22: resample = &upsample_h2_v2; break;
                    case 21: resample = &upsample_h2_v1; break;
                    case 12: resample = &upsample_h1_v2; break;
                    default: throw new ImageIOException("bug");
                }

                auto comp1 = new ubyte[](dc.width);
                auto comp2 = new ubyte[](dc.width);

                size_t s = 0;
                size_t di = 0;
                foreach (j; 0 .. dc.height) {
                    size_t mi = j / dc.comps[0].sfy;
                    size_t si = (mi == 0 || mi >= (dc.height-1)/dc.comps[0].sfy)
                              ? mi : mi - 1 + s * 2;
                    s = s ^ 1;

                    size_t cs = dc.num_mcu_x * dc.comps[1].sfx * 8;
                    size_t cl0 = mi * cs;
                    size_t cl1 = si * cs;
                    resample(dc.comps[1].data[cl0 .. cl0 + dc.comps[1].x],
                             dc.comps[1].data[cl1 .. cl1 + dc.comps[1].x],
                             comp1[]);
                    resample(dc.comps[2].data[cl0 .. cl0 + dc.comps[2].x],
                             dc.comps[2].data[cl1 .. cl1 + dc.comps[2].x],
                             comp2[]);

                    foreach (i; 0 .. dc.width) {
                        result[di .. di+3] = ycbcr_to_rgb(
                            dc.comps[0].data[j * dc.num_mcu_x * dc.comps[0].sfx * 8 + i],
                            comp1[i],
                            comp2[i],
                        );
                        if (dc.tgt_chans == 4)
                            result[di+3] = 255;
                        di += dc.tgt_chans;
                    }
                }

                return result;
            }

            foreach (const ref comp; dc.comps[0..dc.num_comps]) {
                if (comp.sfx != dc.hmax || comp.sfy != dc.vmax)
                    return dc.upsample(result);
            }

            size_t si, di;
            foreach (j; 0 .. dc.height) {
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = ycbcr_to_rgb(
                        dc.comps[0].data[si+i],
                        dc.comps[1].data[si+i],
                        dc.comps[2].data[si+i],
                    );
                    if (dc.tgt_chans == 4)
                        result[di+3] = 255;
                    di += dc.tgt_chans;
                }
                si += dc.num_mcu_x * dc.comps[0].sfx * 8;
            }
            return result;
        case 32, 12, 31, 11:
            const comp = &dc.comps[0];
            if (comp.sfx == dc.hmax && comp.sfy == dc.vmax) {
                size_t si, di;
                if (dc.tgt_chans == 2) {
                    foreach (j; 0 .. dc.height) {
                        foreach (i; 0 .. dc.width) {
                            result[di++] = comp.data[si+i];
                            result[di++] = 255;
                        }
                        si += dc.num_mcu_x * comp.sfx * 8;
                    }
                } else {
                    foreach (j; 0 .. dc.height) {
                        result[di .. di+dc.width] = comp.data[si .. si+dc.width];
                        si += dc.num_mcu_x * comp.sfx * 8;
                        di += dc.width;
                    }
                }
                return result;
            } else {
                // need to resample (haven't tested this...)
                return dc.upsample_luma(result);
            }
        case 14, 13:
            const comp = &dc.comps[0];
            size_t si, di;
            foreach (j; 0 .. dc.height) {
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = comp.data[si+i];
                    if (dc.tgt_chans == 4)
                        result[di+3] = 255;
                    di += dc.tgt_chans;
                }
                si += dc.num_mcu_x * comp.sfx * 8;
            }
            return result;
        default: assert(0);
    }
}

void upsample_h2_v2(in ubyte[] line0, in ubyte[] line1, ubyte[] result) {
    ubyte mix(ubyte mm, ubyte ms, ubyte sm, ubyte ss) {
       return cast(ubyte) (( cast(uint) mm * 3 * 3
                           + cast(uint) ms * 3 * 1
                           + cast(uint) sm * 1 * 3
                           + cast(uint) ss * 1 * 1
                           + 8) / 16);
    }

    result[0] = cast(ubyte) (( cast(uint) line0[0] * 3
                             + cast(uint) line1[0] * 1
                             + 2) / 4);
    if (line0.length == 1) return;
    result[1] = mix(line0[0], line0[1], line1[0], line1[1]);

    size_t di = 2;
    foreach (i; 1 .. line0.length) {
        result[di] = mix(line0[i], line0[i-1], line1[i], line1[i-1]);
        di += 1;
        if (i == line0.length-1) {
            if (di < result.length) {
                result[di] = cast(ubyte) (( cast(uint) line0[i] * 3
                                          + cast(uint) line1[i] * 1
                                          + 2) / 4);
            }
            return;
        }
        result[di] = mix(line0[i], line0[i+1], line1[i], line1[i+1]);
        di += 1;
    }
}

void upsample_h2_v1(in ubyte[] line0, in ubyte[] _line1, ubyte[] result) {
    result[0] = line0[0];
    if (line0.length == 1) return;
    result[1] = cast(ubyte) (( cast(uint) line0[0] * 3
                             + cast(uint) line0[1] * 1
                             + 2) / 4);
    size_t di = 2;
    foreach (i; 1 .. line0.length) {
        result[di] = cast(ubyte) (( cast(uint) line0[i-1] * 1
                                  + cast(uint) line0[i+0] * 3
                                  + 2) / 4);
        di += 1;
        if (i == line0.length-1) {
            if (di < result.length) result[di] = line0[i];
            return;
        }
        result[di] = cast(ubyte) (( cast(uint) line0[i+0] * 3
                                  + cast(uint) line0[i+1] * 1
                                  + 2) / 4);
        di += 1;
    }
}

void upsample_h1_v2(in ubyte[] line0, in ubyte[] line1, ubyte[] result) {
    foreach (i; 0 .. result.length) {
        result[i] = cast(ubyte) (( cast(uint) line0[i] * 3
                                 + cast(uint) line1[i] * 1
                                 + 2) / 4);
    }
}

// Nearest neighbor
ubyte[] upsample_luma(in ref JPEG_Decoder dc, ubyte[] result) {
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const y_step0 = cast(float) dc.comps[0].sfy / cast(float) dc.vmax;
    const x_step0 = cast(float) dc.comps[0].sfx / cast(float) dc.hmax;

    float y0 = y_step0 * 0.5f;
    size_t y0i = 0;

    size_t di;

    foreach (j; 0 .. dc.height) {
        float x0 = x_step0 * 0.5f;
        size_t x0i = 0;
        foreach (i; 0 .. dc.width) {
            result[di] = dc.comps[0].data[y0i + x0i];
            if (dc.tgt_chans == 2)
                result[di+1] = 255;
            di += dc.tgt_chans;
            x0 += x_step0;
            if (x0 >= 1.0f) { x0 -= 1.0f; x0i += 1; }
        }
        y0 += y_step0;
        if (y0 >= 1.0f) { y0 -= 1.0f; y0i += stride0; }
    }
    return result;
}

// Nearest neighbor
ubyte[] upsample(in ref JPEG_Decoder dc, ubyte[] result) {
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const size_t stride1 = dc.num_mcu_x * dc.comps[1].sfx * 8;
    const size_t stride2 = dc.num_mcu_x * dc.comps[2].sfx * 8;

    const y_step0 = cast(float) dc.comps[0].sfy / cast(float) dc.vmax;
    const y_step1 = cast(float) dc.comps[1].sfy / cast(float) dc.vmax;
    const y_step2 = cast(float) dc.comps[2].sfy / cast(float) dc.vmax;
    const x_step0 = cast(float) dc.comps[0].sfx / cast(float) dc.hmax;
    const x_step1 = cast(float) dc.comps[1].sfx / cast(float) dc.hmax;
    const x_step2 = cast(float) dc.comps[2].sfx / cast(float) dc.hmax;

    float y0 = y_step0 * 0.5f;
    float y1 = y_step1 * 0.5f;
    float y2 = y_step2 * 0.5f;
    size_t y0i = 0;
    size_t y1i = 0;
    size_t y2i = 0;

    size_t di;

    foreach (_j; 0 .. dc.height) {
        float x0 = x_step0 * 0.5f;
        float x1 = x_step1 * 0.5f;
        float x2 = x_step2 * 0.5f;
        size_t x0i = 0;
        size_t x1i = 0;
        size_t x2i = 0;
        foreach (i; 0 .. dc.width) {
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[y0i + x0i],
                dc.comps[1].data[y1i + x1i],
                dc.comps[2].data[y2i + x2i],
            );
            if (dc.tgt_chans == 4)
                result[di+3] = 255;
            di += dc.tgt_chans;
            x0 += x_step0;
            x1 += x_step1;
            x2 += x_step2;
            if (x0 >= 1.0) { x0 -= 1.0f; x0i += 1; }
            if (x1 >= 1.0) { x1 -= 1.0f; x1i += 1; }
            if (x2 >= 1.0) { x2 -= 1.0f; x2i += 1; }
        }
        y0 += y_step0;
        y1 += y_step1;
        y2 += y_step2;
        if (y0 >= 1.0) { y0 -= 1.0f; y0i += stride0; }
        if (y1 >= 1.0) { y1 -= 1.0f; y1i += stride1; }
        if (y2 >= 1.0) { y2 -= 1.0f; y2i += stride2; }
    }
    return result;
}

ubyte[3] ycbcr_to_rgb(ubyte y, ubyte cb, ubyte cr) pure {
    ubyte[3] rgb = void;
    rgb[0] = clamp(y + 1.402*(cr-128));
    rgb[1] = clamp(y - 0.34414*(cb-128) - 0.71414*(cr-128));
    rgb[2] = clamp(y + 1.772*(cb-128));
    return rgb;
}

ubyte clamp(float x) pure {
    if (x < 0) return 0;
    if (255 < x) return 255;
    return cast(ubyte) x;
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
pure void stbi__idct_block(ubyte* dst, int dst_stride, in ref short[64] data) {
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

static immutable ubyte[2] jpeg_soi_marker = [0xff, 0xd8];

// the above is adapted from stb_image
// ------------------------------------------------------------

package void read_jpeg_info(Reader stream, out int w, out int h, out int chans) {
    ubyte[2] marker = void;
    stream.readExact(marker, 2);

    // SOI
    if (marker[0..2] != jpeg_soi_marker)
        throw new ImageIOException("not JPEG");

    while (true) {
        stream.readExact(marker, 2);

        if (marker[0] != 0xff)
            throw new ImageIOException("no frame header");
        while (marker[1] == 0xff)
            stream.readExact(marker[1..$], 1);

        enum SKIP = 0xff;
        switch (marker[1]) with (Marker) {
            case SOF0: .. case SOF3: goto case;
            case SOF9: .. case SOF11:
                ubyte[8] tmp;
                stream.readExact(tmp[0..8], 8);
                //int len = bigEndianToNative!ushort(tmp[0..2]);
                w = bigEndianToNative!ushort(tmp[5..7]);
                h = bigEndianToNative!ushort(tmp[3..5]);
                chans = tmp[7];
                return;
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
