// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module imageformats.tga;

public import imageformats.common;

import std.algorithm;   // min
import std.bitmanip;      // bigEndianToNative()

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

TGA_Header read_tga_header(in char[] filename) {
    auto stream = new InStream(filename);
    scope(exit) stream.close();
    return read_tga_header(stream);
}

TGA_Header read_tga_header(InStream stream) {
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
    auto stream = new InStream(filename);
    scope(exit) stream.close();
    return read_tga(stream, w, h, chans, req_chans);
}

ubyte[] read_tga(InStream stream, out long w, out long h, out int chans, int req_chans = 0) {
    if (stream is null || req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    TGA_Header hdr = read_tga_header(stream);

    if (hdr.width < 1 || hdr.height < 1)
        throw new ImageIOException("invalid dimensions");
    if (hdr.flags & 0xc0)   // two bits
        throw new ImageIOException("interlaced TGAs not supported");
    ubyte attr_bits_pp = (hdr.flags & 0xf);
    if (! (attr_bits_pp == 0 || attr_bits_pp == 8)) // some set it 0 although data has 8
        throw new ImageIOException("only 8-bit alpha/attribute(s) supported");
    if (hdr.palette_type)
        throw new ImageIOException("paletted TGAs not supported");

    bool rle = false;
    switch (hdr.data_type) {
        //case 1: ;   // paletted, uncompressed
        case 2: if (! (hdr.bits_pp == 24 || hdr.bits_pp == 32))
                    throw new ImageIOException("not supported");
                break;      // RGB/RGBA, uncompressed
        case 3: if (! (hdr.bits_pp == 8 || hdr.bits_pp == 16))
                    throw new ImageIOException("not supported");
                break;      // gray, uncompressed
        //case 9: ;   // paletted, RLE
        case 10: if (! (hdr.bits_pp == 24 || hdr.bits_pp == 32))
                    throw new ImageIOException("not supported");
                 rle = true;
                 break;     // RGB/RGBA, RLE
        case 11: if (! (hdr.bits_pp == 8 || hdr.bits_pp == 16))
                    throw new ImageIOException("not supported");
                 rle = true;
                 break;     // gray, RLE
        default: throw new ImageIOException("data type not supported");
    }

    int src_chans = hdr.bits_pp / 8;

    if (hdr.id_length) {
        auto shitbuf = new ubyte[hdr.id_length];    // FIXME
        stream.readExact(shitbuf, hdr.id_length);   // FIXME
    }

    // set decoder...
    TGA_Decoder dc;
    dc.stream         = stream;
    dc.w              = hdr.width;
    dc.h              = hdr.height;
    dc.origin_at_top  = cast(bool) (hdr.flags & 0x20);  // src
    dc.bytes_pp       = hdr.bits_pp / 8;
    dc.rle            = rle;
    dc.tgt_chans      = (req_chans == 0) ? src_chans : req_chans;

    switch (dc.bytes_pp) {
        case 1: dc.src_fmt = ColFmt.Y; break;
        case 2: dc.src_fmt = ColFmt.YA; break;
        case 3: dc.src_fmt = ColFmt.BGR; break;
        case 4: dc.src_fmt = ColFmt.BGRA; break;
        default: throw new ImageIOException("TGA: format not supported");
    }

    //import std.stdio;
    //writeln("src_fmt: ", dc.src_fmt);
    //writeln("origin: ", (dc.origin_at_top) ? "top left" : "bottom left");
    //writeln("rle: ", dc.rle);

    w = dc.w;
    h = dc.h;
    chans = dc.tgt_chans;
    return decode_tga(dc);
}

private struct TGA_Decoder {
    InStream stream;
    long w, h;
    bool origin_at_top;    // src
    int bytes_pp;
    bool rle;   // run length comressed
    ColFmt src_fmt;
    int tgt_chans;

    ubyte[] result;     // image data
}

private ubyte[] decode_tga(ref TGA_Decoder dc) {
    dc.result = new ubyte[dc.w * dc.h * dc.tgt_chans];

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
            convert(src_line, dc.result[ti .. ti + tgt_linesize]);
            ti += tgt_stride;
        }
        return dc.result;
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

        convert(src_line, dc.result[ti .. ti + tgt_linesize]);
        ti += tgt_stride;
    }

    return dc.result;
}

void write_tga(OutStream stream, long w, long h, in ubyte[] data, int tgt_chans = 0) {
    throw new ImageIOException("this is on the todo list");
}

private void read_tga_info(InStream stream, out long w, out long h, out int chans) {
    TGA_Header hdr = read_tga_header(stream);
    w = hdr.width;
    h = hdr.height;
    chans = 0;  // TODO
}

static this() {
    register["tga"] = ImageIOFuncs(&read_tga, &write_tga, &read_tga_info);
}
