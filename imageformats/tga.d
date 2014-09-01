// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module imageformats.tga;

public import imageformats.common;

import std.algorithm;   // min
import std.bitmanip;      // bigEndianToNative()
import std.stdio;       // File

// ----------------------------------------------------------------------
// Public API

TGA_Header read_tga_header(in char[] filename);
TGA_Header read_tga_header(File stream);
ubyte[] read_tga(in char[] filename, out long w, out long h, out int chans, int req_chans = 0);
ubyte[] read_tga(File stream, out long w, out long h, out int chans, int req_chans = 0);
void write_tga(in char[] filename, long w, long h, in ubyte[] data, int tgt_chans = 0);
void write_tga(File stream, long w, long h, in ubyte[] data, int tgt_chans = 0);

struct TGA_Header {
   ubyte id_length;
   ubyte palette_type;
   ubyte data_type;
   ushort palette_start;
   ushort palette_length;
   ubyte palette_bits;
   ushort x_origin;
   ushort y_origin;
   ushort width;
   ushort height;
   ubyte bits_pp;
   ubyte flags;
}

// ----------------------------------------------------------------------

TGA_Header read_tga_header(in char[] filename) {
    auto stream = File(filename.idup, "rb");
    scope(exit) stream.close();
    return read_tga_header(stream);
}

TGA_Header read_tga_header(File stream) {
    ubyte[18] tmp = void;
    stream.readExact(tmp, tmp.length);

    TGA_Header header = {
        id_length       : tmp[0],
        palette_type    : tmp[1],
        data_type       : tmp[2],
        palette_start   : littleEndianToNative!ushort(tmp[3..5]),
        palette_length  : littleEndianToNative!ushort(tmp[5..7]),
        palette_bits    : tmp[7],
        x_origin        : littleEndianToNative!ushort(tmp[8..10]),
        y_origin        : littleEndianToNative!ushort(tmp[10..12]),
        width           : littleEndianToNative!ushort(tmp[12..14]),
        height          : littleEndianToNative!ushort(tmp[14..16]),
        bits_pp         : tmp[16],
        flags           : tmp[17],
    };
    return header;
}

ubyte[] read_tga(in char[] filename, out long w, out long h, out int chans, int req_chans = 0) {
    if (!filename.length)
        throw new ImageIOException("no filename");
    auto stream = File(filename.idup, "rb");
    scope(exit) stream.close();
    return read_tga(stream, w, h, chans, req_chans);
}

ubyte[] read_tga(File stream, out long w, out long h, out int chans, int req_chans = 0) {
    if (req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    TGA_Header hdr = read_tga_header(stream);

    if (hdr.width < 1 || hdr.height < 1)
        throw new ImageIOException("invalid dimensions");
    if (hdr.flags & 0xc0)   // two bits
        throw new ImageIOException("interlaced TGAs not supported");
    if (hdr.flags & 0x10)
        throw new ImageIOException("right-to-left TGAs not supported");
    ubyte attr_bits_pp = (hdr.flags & 0xf);
    if (! (attr_bits_pp == 0 || attr_bits_pp == 8)) // some set it 0 although data has 8
        throw new ImageIOException("only 8-bit alpha/attribute(s) supported");
    if (hdr.palette_type)
        throw new ImageIOException("paletted TGAs not supported");

    bool rle = false;
    switch (hdr.data_type) with (TGA_DataType) {
        //case 1: ;   // paletted, uncompressed
        case TrueColor:
            if (! (hdr.bits_pp == 24 || hdr.bits_pp == 32))
                throw new ImageIOException("not supported");
            break;
        case Gray:
            if (! (hdr.bits_pp == 8 || (hdr.bits_pp == 16 && attr_bits_pp == 8)))
                throw new ImageIOException("not supported");
            break;
        //case 9: ;   // paletted, RLE
        case TrueColor_RLE:
            if (! (hdr.bits_pp == 24 || hdr.bits_pp == 32))
                throw new ImageIOException("not supported");
            rle = true;
            break;
        case Gray_RLE:
            if (! (hdr.bits_pp == 8 || (hdr.bits_pp == 16 && attr_bits_pp == 8)))
                throw new ImageIOException("not supported");
            rle = true;
            break;
        default: throw new ImageIOException("data type not supported");
    }

    int src_chans = hdr.bits_pp / 8;

    if (hdr.id_length)
        stream.seek(hdr.id_length, SEEK_CUR);

    TGA_Decoder dc;
    dc.stream         = stream;
    dc.w              = hdr.width;
    dc.h              = hdr.height;
    dc.origin_at_top  = cast(bool) (hdr.flags & 0x20);  // src
    dc.bytes_pp       = hdr.bits_pp / 8;
    dc.rle            = rle;
    dc.tgt_chans      = (req_chans == 0) ? src_chans : req_chans;

    switch (dc.bytes_pp) {
        case 1: dc.src_fmt = _ColFmt.Y; break;
        case 2: dc.src_fmt = _ColFmt.YA; break;
        case 3: dc.src_fmt = _ColFmt.BGR; break;
        case 4: dc.src_fmt = _ColFmt.BGRA; break;
        default: throw new ImageIOException("TGA: format not supported");
    }

    w = dc.w;
    h = dc.h;
    chans = dc.tgt_chans;
    return decode_tga(dc);
}

void write_tga(in char[] filename, long w, long h, in ubyte[] data, int tgt_chans = 0) {
    if (!filename.length)
        throw new ImageIOException("no filename");
    auto stream = File(filename.idup, "wb");
    scope(exit) stream.close();
    write_tga(stream, w, h, data, tgt_chans);
}

void write_tga(File stream, long w, long h, in ubyte[] data, int tgt_chans = 0) {
    if (w < 1 || h < 1 || ushort.max < w || ushort.max < h)
        throw new ImageIOException("invalid dimensions");
    ulong src_chans = data.length / w / h;
    if (src_chans < 1 || 4 < src_chans || tgt_chans < 0 || 4 < tgt_chans)
        throw new ImageIOException("invalid channel count");
    if (src_chans * w * h != data.length)
        throw new ImageIOException("mismatching dimensions and length");

    TGA_Encoder ec;
    ec.stream = stream;
    ec.w = cast(ushort) w;
    ec.h = cast(ushort) h;
    ec.src_chans = cast(int) src_chans;
    ec.tgt_chans = (tgt_chans) ? tgt_chans : ec.src_chans;
    ec.rle = true;
    ec.data = data;

    write_tga(ec);
    stream.flush();
}

// ----------------------------------------------------------------------
private:

struct TGA_Decoder {
    File stream;
    long w, h;
    bool origin_at_top;    // src
    int bytes_pp;
    bool rle;   // run length comressed
    _ColFmt src_fmt;
    int tgt_chans;
}

ubyte[] decode_tga(ref TGA_Decoder dc) {
    auto result = new ubyte[dc.w * dc.h * dc.tgt_chans];

    immutable long tgt_linesize = dc.w * dc.tgt_chans;
    immutable long src_linesize = dc.w * dc.bytes_pp;
    auto src_line = new ubyte[src_linesize];

    immutable long tgt_stride = (dc.origin_at_top) ? tgt_linesize : -tgt_linesize;
    long ti                   = (dc.origin_at_top) ? 0 : (dc.h-1) * tgt_linesize;

    void function(in ubyte[] src_line, ubyte[] tgt_line) convert;
    convert = get_converter(dc.src_fmt, dc.tgt_chans);

    if (!dc.rle) {
        foreach (_j; 0 .. dc.h) {
            dc.stream.readExact(src_line, src_linesize);
            convert(src_line, result[ti .. ti + tgt_linesize]);
            ti += tgt_stride;
        }
        return result;
    }

    // ----- RLE  -----

    auto rbuf = new ubyte[src_linesize];
    long plen = 0;      // packet length
    bool its_rle = false;

    foreach (_j; 0 .. dc.h) {
        // fill src_line with uncompressed data (this works like a stream)
        long wanted = src_linesize;
        while (wanted) {
            if (plen == 0) {
                dc.stream.readExact(rbuf, 1);
                its_rle = cast(bool) (rbuf[0] & 0x80);
                plen = ((rbuf[0] & 0x7f) + 1) * dc.bytes_pp; // length in bytes
            }
            long gotten = src_linesize - wanted;
            if (its_rle) {
                dc.stream.readExact(rbuf, dc.bytes_pp);
                long copysize = min(plen, wanted);
                for (long p = gotten; p < gotten+copysize; p += dc.bytes_pp)
                    src_line[p .. p+dc.bytes_pp] = rbuf[0 .. dc.bytes_pp];
                wanted -= copysize;
                plen -= copysize;
            } else {    // it's raw
                long copysize = min(plen, wanted);
                auto slice = src_line[gotten .. gotten+copysize];
                dc.stream.readExact(slice, copysize);
                wanted -= copysize;
                plen -= copysize;
            }
        }

        convert(src_line, result[ti .. ti + tgt_linesize]);
        ti += tgt_stride;
    }

    return result;
}

// ----------------------------------------------------------------------
// TGA encoder

struct TGA_Encoder {
    File stream;
    ushort w, h;
    int src_chans;
    int tgt_chans;
    bool rle;   // run length compression
    const(ubyte)[] data;
}

void write_tga(ref TGA_Encoder ec) {
    ubyte data_type;
    bool has_alpha = false;
    switch (ec.tgt_chans) with (TGA_DataType) {
        case 1: data_type = ec.rle ? Gray_RLE : Gray;                             break;
        case 2: data_type = ec.rle ? Gray_RLE : Gray;           has_alpha = true; break;
        case 3: data_type = ec.rle ? TrueColor_RLE : TrueColor;                   break;
        case 4: data_type = ec.rle ? TrueColor_RLE : TrueColor; has_alpha = true; break;
        default: throw new ImageIOException("internal error");
    }

    ubyte[18] hdr = void;
    hdr[0] = 0;         // id length
    hdr[1] = 0;         // palette type
    hdr[2] = data_type;
    hdr[3..8] = 0;         // palette start (2), len (2), bits per palette entry (1)
    hdr[8..12] = 0;     // x origin (2), y origin (2)
    hdr[12..14] = nativeToLittleEndian(ec.w);
    hdr[14..16] = nativeToLittleEndian(ec.h);
    hdr[16] = cast(ubyte) (ec.tgt_chans * 8);     // bits per pixel
    hdr[17] = (has_alpha) ? 0x8 : 0x0;     // flags: attr_bits_pp = 8
    ec.stream.rawWrite(hdr);

    write_image_data(ec);

    ubyte[26] ftr = void;
    ftr[0..4] = 0;   // extension area offset
    ftr[4..8] = 0;   // developer directory offset
    ftr[8..26] = ['T','R','U','E','V','I','S','I','O','N','-','X','F','I','L','E','.', 0];
    ec.stream.rawWrite(ftr);
}

void write_image_data(ref TGA_Encoder ec) {
    _ColFmt tgt_fmt;
    switch (ec.tgt_chans) {
        case 1: tgt_fmt = _ColFmt.Y; break;
        case 2: tgt_fmt = _ColFmt.YA; break;
        case 3: tgt_fmt = _ColFmt.BGR; break;
        case 4: tgt_fmt = _ColFmt.BGRA; break;
        default: throw new ImageIOException("internal error");
    }

    void function(in ubyte[] src_line, ubyte[] tgt_line) convert;
    convert = get_converter(ec.src_chans, tgt_fmt);

    immutable long src_linesize = ec.w * ec.src_chans;
    immutable long tgt_linesize = ec.w * ec.tgt_chans;
    auto tgt_line = new ubyte[tgt_linesize];

    long si = (ec.h-1) * src_linesize;     // origin at bottom

    if (!ec.rle) {
        foreach (_; 0 .. ec.h) {
            convert(ec.data[si .. si + src_linesize], tgt_line);
            ec.stream.rawWrite(tgt_line);
            si -= src_linesize; // origin at bottom
        }
        return;
    }

    // ----- RLE  -----

    immutable bpp = ec.tgt_chans;
    immutable long max_packets_per_line = (tgt_linesize+127) / 128;
    auto tgt_cmp = new ubyte[tgt_linesize + max_packets_per_line];  // compressed line
    foreach (_; 0 .. ec.h) {
        convert(ec.data[si .. si + src_linesize], tgt_line);
        ubyte[] compressed_line = rle_compress(tgt_line, tgt_cmp, ec.w, bpp);
        ec.stream.rawWrite(compressed_line);
        si -= src_linesize; // origin at bottom
    }
}

ubyte[] rle_compress(in ubyte[] line, ubyte[] tgt_cmp, in long w, in int bpp) pure {
    immutable int rle_limit = (1 < bpp) ? 2 : 3;    // run len that is worth an RLE packet
    long runlen = 0;
    long rawlen = 0;
    long raw_i = 0; // start of raw packet data in line
    long cmp_i = 0;
    long pixels_left = w;
    const (ubyte)[] px;
    for (long i = bpp; pixels_left; i += bpp) {
        runlen = 1;
        px = line[i-bpp .. i];
        while (i < line.length && line[i .. i+bpp] == px[0..$] && runlen < 128) {
            ++runlen;
            i += bpp;
        }
        pixels_left -= runlen;

        if (runlen < rle_limit) {
            // data goes to raw packet
            rawlen += runlen;
            runlen = 0;
            if (128 <= rawlen) {     // full packet, need to store it
                long copysize = 128 * bpp;
                tgt_cmp[cmp_i++] = 0x7f; // raw packet header
                tgt_cmp[cmp_i .. cmp_i+copysize] = line[raw_i .. raw_i+copysize];
                cmp_i += copysize;
                raw_i += copysize;
                rawlen -= 128;
            }
        } else {
            // RLE packet is worth it

            // store raw packet first, if any
            if (rawlen) {
                assert(rawlen < 128);
                long copysize = rawlen * bpp;
                tgt_cmp[cmp_i++] = cast(ubyte) (rawlen-1); // raw packet header
                tgt_cmp[cmp_i .. cmp_i+copysize] = line[raw_i .. raw_i+copysize];
                cmp_i += copysize;
                rawlen = 0;
            }

            // store RLE packet
            tgt_cmp[cmp_i++] = cast(ubyte) (0x80 | (runlen-1)); // packet header
            tgt_cmp[cmp_i .. cmp_i+bpp] = px[0..$];                   // packet data
            cmp_i += bpp;
            raw_i = i;
            runlen = 0;
        }
    }   // for

    if (rawlen) {   // last packet of the line
        long copysize = rawlen * bpp;
        tgt_cmp[cmp_i++] = cast(ubyte) (rawlen-1); // raw packet header
        tgt_cmp[cmp_i .. cmp_i+copysize] = line[raw_i .. raw_i+copysize];
        cmp_i += copysize;
        rawlen = 0;
    }
    return tgt_cmp[0 .. cmp_i];
}

enum TGA_DataType : ubyte {
    Idx           = 1,
    TrueColor     = 2,
    Gray          = 3,
    Idx_RLE       = 9,
    TrueColor_RLE = 10,
    Gray_RLE      = 11,
}

void read_tga_info(File stream, out long w, out long h, out int chans) {
    TGA_Header hdr = read_tga_header(stream);
    w = hdr.width;
    h = hdr.height;

    // TGA is awkward...
    auto dt = hdr.data_type;
    if ((dt == TGA_DataType.TrueColor     || dt == TGA_DataType.Gray ||
         dt == TGA_DataType.TrueColor_RLE || dt == TGA_DataType.Gray_RLE)
         && (hdr.bits_pp % 8) == 0)
    {
        chans = hdr.bits_pp / 8;
        return;
    } else if (dt == TGA_DataType.Idx || dt == TGA_DataType.Idx_RLE) {
        switch (hdr.palette_bits) {
            case 15: chans = 3; return;
            case 16: chans = 3; return; // one bit could be for some "interrupt control"
            case 24: chans = 3; return;
            case 32: chans = 4; return;
            default:
        }
    }
    chans = 0;  // unknown
}

static this() {
    register["tga"] = ImageIOFuncs(&read_tga, &write_tga, &read_tga_info);
}
