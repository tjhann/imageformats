// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module imageformats;

import std.algorithm;   // min
import std.bitmanip;   // endianness stuff
import std.stdio;    // File
import std.string;  // toLower, lastIndexOf

struct IFImage {
    long        w, h;
    ColFmt      c;
    ubyte[]     pixels;
}

enum ColFmt {
    Y = 1,
    YA = 2,
    RGB = 3,
    RGBA = 4,
}

IFImage read_image(in char[] file, long req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(file);

    IFImage function(Reader, long) read_image;
    switch (ext) {
        case "png": read_image = &read_png; break;
        case "tga": read_image = &read_tga; break;
        case "jpg": read_image = &read_jpeg; break;
        case "jpeg": read_image = &read_jpeg; break;
        default: throw new ImageIOException("unknown image extension/type");
    }
    scope reader = new Reader(file);
    return read_image(reader, req_chans);
}

void write_image(in char[] file, long w, long h, in ubyte[] data, long req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(file);

    void function(Writer, long, long, in ubyte[], long) write_image;
    switch (ext) {
        case "png": write_image = &write_png; break;
        case "tga": write_image = &write_tga; break;
        default: throw new ImageIOException("unknown image extension/type");
    }
    scope writer = new Writer(file);
    write_image(writer, w, h, data, req_chans);
}

// chans is set to zero if num of channels is unknown
void read_image_info(in char[] file, out long w, out long h, out long chans) {
    const(char)[] ext = extract_extension_lowercase(file);

    void function(Reader, out long, out long, out long) read_image_info;
    switch (ext) {
        case "png": read_image_info = &read_png_info; break;
        case "tga": read_image_info = &read_tga_info; break;
        case "jpg": read_image_info = &read_jpeg_info; break;
        case "jpeg": read_image_info = &read_jpeg_info; break;
        default: throw new ImageIOException("unknown image extension/type");
    }
    scope reader = new Reader(file);
    return read_image_info(reader, w, h, chans);
}

class ImageIOException : Exception {
   @safe pure const
   this(string msg, string file = __FILE__, size_t line = __LINE__) {
       super(msg, file, line);
   }
}

// From here, things are private by default and public only explicitly.
private:

// --------------------------------------------------------------------------------
// PNG

import std.digest.crc;
import std.zlib;

public struct PNG_Header {
    int     width;
    int     height;
    ubyte   bit_depth;
    ubyte   color_type;
    ubyte   compression_method;
    ubyte   filter_method;
    ubyte   interlace_method;
}

public PNG_Header read_png_header(in char[] filename) {
    scope reader = new Reader(filename);
    return read_png_header(reader);
}

PNG_Header read_png_header(Reader stream) {
    ubyte[33] tmp = void;  // file header, IHDR len+type+data+crc
    stream.readExact(tmp, tmp.length);

    if ( tmp[0..8] != png_file_header[0..$]              ||
         tmp[8..16] != [0x0,0x0,0x0,0xd,'I','H','D','R'] ||
         crc32Of(tmp[12..29]).reverse != tmp[29..33] )
        throw new ImageIOException("corrupt header");

    PNG_Header header = {
        width              : bigEndianToNative!int(tmp[16..20]),
        height             : bigEndianToNative!int(tmp[20..24]),
        bit_depth          : tmp[24],
        color_type         : tmp[25],
        compression_method : tmp[26],
        filter_method      : tmp[27],
        interlace_method   : tmp[28],
    };
    return header;
}

public IFImage read_png(in char[] filename, long req_chans = 0) {
    scope reader = new Reader(filename);
    return read_png(reader, req_chans);
}

public IFImage read_png_from_mem(in ubyte[] source, long req_chans = 0) {
    scope reader = new Reader(source);
    return read_png(reader, req_chans);
}

IFImage read_png(Reader stream, long req_chans = 0) {
    if (req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    PNG_Header hdr = read_png_header(stream);

    if (hdr.width < 1 || hdr.height < 1 || int.max < cast(ulong) hdr.width * hdr.height)
        throw new ImageIOException("invalid dimensions");
    if (hdr.bit_depth != 8)
        throw new ImageIOException("only 8-bit images supported");
    if (! (hdr.color_type == PNG_ColorType.Y    ||
           hdr.color_type == PNG_ColorType.RGB  ||
           hdr.color_type == PNG_ColorType.Idx  ||
           hdr.color_type == PNG_ColorType.YA   ||
           hdr.color_type == PNG_ColorType.RGBA) )
        throw new ImageIOException("color type not supported");
    if (hdr.compression_method != 0 || hdr.filter_method != 0 ||
        (hdr.interlace_method != 0 && hdr.interlace_method != 1))
        throw new ImageIOException("not supported");

    PNG_Decoder dc = {
        stream      : stream,
        src_indexed : (hdr.color_type == PNG_ColorType.Idx),
        src_chans   : channels(cast(PNG_ColorType) hdr.color_type),
        ilace       : hdr.interlace_method,
        w           : hdr.width,
        h           : hdr.height,
    };
    dc.tgt_chans = (req_chans == 0) ? dc.src_chans : cast(int) req_chans;

    IFImage result = {
        w      : dc.w,
        h      : dc.h,
        c      : cast(ColFmt) dc.tgt_chans,
        pixels : decode_png(dc)
    };
    return result;
}

public void write_png(in char[] file, long w, long h, in ubyte[] data, long tgt_chans = 0)
{
    scope writer = new Writer(file);
    write_png(writer, w, h, data, tgt_chans);
}

public ubyte[] write_png_to_mem(long w, long h, in ubyte[] data, long tgt_chans = 0) {
    scope writer = new Writer();
    write_png(writer, w, h, data, tgt_chans);
    return writer.result;
}

immutable ubyte[8] png_file_header =
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

int channels(PNG_ColorType ct) pure nothrow {
    final switch (ct) with (PNG_ColorType) {
        case Y: return 1;
        case RGB, Idx: return 3;
        case YA: return 2;
        case RGBA: return 4;
    }
}

PNG_ColorType color_type(long channels) pure nothrow {
    switch (channels) {
        case 1: return PNG_ColorType.Y;
        case 2: return PNG_ColorType.YA;
        case 3: return PNG_ColorType.RGB;
        case 4: return PNG_ColorType.RGBA;
        default: assert(0);
    }
}

struct PNG_Decoder {
    Reader stream;
    bool src_indexed;
    int src_chans;
    int tgt_chans;
    size_t w, h;
    ubyte ilace;

    UnCompress uc;
    CRC32 crc;
    ubyte[12] chunkmeta;  // crc | length and type
    ubyte[] read_buf;
    ubyte[] uc_buf;     // uncompressed
    ubyte[] palette;
}

ubyte[] decode_png(ref PNG_Decoder dc) {
    dc.uc = new UnCompress(HeaderFormat.deflate);
    dc.read_buf = new ubyte[4096];

    enum Stage {
        IHDR_parsed,
        PLTE_parsed,
        IDAT_parsed,
        IEND_parsed,
    }

    ubyte[] result;
    auto stage = Stage.IHDR_parsed;
    dc.stream.readExact(dc.chunkmeta[4..$], 8);  // next chunk's len and type

    while (stage != Stage.IEND_parsed) {
        int len = bigEndianToNative!int(dc.chunkmeta[4..8]);
        if (len < 0)
            throw new ImageIOException("chunk too long");

        // standard allows PLTE chunk for non-indexed images too but we don't
        dc.crc.put(dc.chunkmeta[8..12]);  // type
        switch (cast(char[]) dc.chunkmeta[8..12]) {    // chunk type
            case "IDAT":
                if (! (stage == Stage.IHDR_parsed ||
                      (stage == Stage.PLTE_parsed && dc.src_indexed)) )
                    throw new ImageIOException("corrupt chunk stream");
                result = read_IDAT_stream(dc, len);
                stage = Stage.IDAT_parsed;
                break;
            case "PLTE":
                if (stage != Stage.IHDR_parsed)
                    throw new ImageIOException("corrupt chunk stream");
                int entries = len / 3;
                if (len % 3 != 0 || 256 < entries)
                    throw new ImageIOException("corrupt chunk");
                dc.palette = new ubyte[len];
                dc.stream.readExact(dc.palette, dc.palette.length);
                dc.crc.put(dc.palette);
                dc.stream.readExact(dc.chunkmeta, 12); // crc | len, type
                if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
                stage = Stage.PLTE_parsed;
                break;
            case "IEND":
                if (stage != Stage.IDAT_parsed)
                    throw new ImageIOException("corrupt chunk stream");
                dc.stream.readExact(dc.chunkmeta, 4); // crc
                if (len != 0 || dc.chunkmeta[0..4] != [0xae, 0x42, 0x60, 0x82])
                    throw new ImageIOException("corrupt chunk");
                stage = Stage.IEND_parsed;
                break;
            case "IHDR":
                throw new ImageIOException("corrupt chunk stream");
            default:
                // unknown chunk, ignore but check crc
                while (0 < len) {
                    size_t bytes = min(len, dc.read_buf.length);
                    dc.stream.readExact(dc.read_buf, bytes);
                    len -= bytes;
                    dc.crc.put(dc.read_buf[0..bytes]);
                }
                dc.stream.readExact(dc.chunkmeta, 12); // crc | len, type
                if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
        }
    }

    return result;
}

enum PNG_ColorType : ubyte {
    Y    = 0,
    RGB  = 2,
    Idx  = 3,
    YA   = 4,
    RGBA = 6,
}

enum PNG_FilterType : ubyte {
    None    = 0,
    Sub     = 1,
    Up      = 2,
    Average = 3,
    Paeth   = 4,
}

enum InterlaceMethod {
    None = 0, Adam7 = 1
}

ubyte[] read_IDAT_stream(ref PNG_Decoder dc, int len) {
    bool metaready = false;     // chunk len, type, crc

    immutable uint filter_step = dc.src_indexed ? 1 : dc.src_chans;
    immutable size_t tgt_linesize = cast(size_t) (dc.w * dc.tgt_chans);

    ubyte[] depaletted_line = dc.src_indexed ? new ubyte[cast(size_t)dc.w * 3] : null;
    ubyte[] result = new ubyte[cast(size_t)(dc.w * dc.h * dc.tgt_chans)];

    const LineConv chan_convert = get_converter(dc.src_chans, dc.tgt_chans);

    void depalette_convert(in ubyte[] src_line, ubyte[] tgt_line) {
        for (size_t s, d;  s < src_line.length;  s+=1, d+=3) {
            size_t pidx = src_line[s] * 3;
            if (dc.palette.length < pidx + 3)
                throw new ImageIOException("palette idx wrong");
            depaletted_line[d .. d+3] = dc.palette[pidx .. pidx+3];
        }
        chan_convert(depaletted_line[0 .. src_line.length*3], tgt_line);
    }

    void simple_convert(in ubyte[] src_line, ubyte[] tgt_line) {
        chan_convert(src_line, tgt_line);
    }

    const convert = dc.src_indexed ? &depalette_convert : &simple_convert;

    if (dc.ilace == InterlaceMethod.None) {
        immutable size_t src_sl_size = cast(size_t) dc.w * filter_step;
        auto cline = new ubyte[src_sl_size+1];   // current line + filter byte
        auto pline = new ubyte[src_sl_size+1];   // previous line, inited to 0
        debug(DebugPNG) assert(pline[0] == 0);

        size_t tgt_si = 0;    // scanline index in target buffer
        foreach (j; 0 .. dc.h) {
            uncompress_line(dc, len, metaready, cline);
            ubyte filter_type = cline[0];

            recon(cline[1..$], pline[1..$], filter_type, filter_step);
            convert(cline[1 .. $], result[tgt_si .. tgt_si + tgt_linesize]);
            tgt_si += tgt_linesize;

            ubyte[] _swap = pline;
            pline = cline;
            cline = _swap;
        }
    } else {
        // Adam7 interlacing

        immutable size_t[7] redw = [
            (dc.w + 7) / 8,
            (dc.w + 3) / 8,
            (dc.w + 3) / 4,
            (dc.w + 1) / 4,
            (dc.w + 1) / 2,
            (dc.w + 0) / 2,
            (dc.w + 0) / 1,
        ];
        immutable size_t[7] redh = [
            (dc.h + 7) / 8,
            (dc.h + 7) / 8,
            (dc.h + 3) / 8,
            (dc.h + 3) / 4,
            (dc.h + 1) / 4,
            (dc.h + 1) / 2,
            (dc.h + 0) / 2,
        ];

        const size_t max_scanline_size = cast(size_t) (dc.w * filter_step);
        const linebuf0 = new ubyte[max_scanline_size+1]; // +1 for filter type byte
        const linebuf1 = new ubyte[max_scanline_size+1]; // +1 for filter type byte
        auto redlinebuf = new ubyte[cast(size_t) dc.w * dc.tgt_chans];

        foreach (pass; 0 .. 7) {
            const A7_Catapult tgt_px = a7_catapults[pass];   // target pixel
            const size_t src_linesize = redw[pass] * filter_step;
            auto cline = cast(ubyte[]) linebuf0[0 .. src_linesize+1];
            auto pline = cast(ubyte[]) linebuf1[0 .. src_linesize+1];

            foreach (j; 0 .. redh[pass]) {
                uncompress_line(dc, len, metaready, cline);
                ubyte filter_type = cline[0];

                recon(cline[1..$], pline[1..$], filter_type, filter_step);
                convert(cline[1 .. $], redlinebuf[0 .. redw[pass]*dc.tgt_chans]);

                for (size_t i, redi; i < redw[pass]; ++i, redi += dc.tgt_chans) {
                    size_t tgt = tgt_px(i, j, dc.w) * dc.tgt_chans;
                    result[tgt .. tgt + dc.tgt_chans] =
                        redlinebuf[redi .. redi + dc.tgt_chans];
                }

                ubyte[] _swap = pline;
                pline = cline;
                cline = _swap;
            }
        }
    }

    if (!metaready) {
        dc.stream.readExact(dc.chunkmeta, 12);   // crc | len & type
        if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
            throw new ImageIOException("corrupt chunk");
    }
    return result;
}

alias A7_Catapult = size_t function(size_t redx, size_t redy, size_t dstw);
immutable A7_Catapult[7] a7_catapults = [
    &a7_red1_to_dst,
    &a7_red2_to_dst,
    &a7_red3_to_dst,
    &a7_red4_to_dst,
    &a7_red5_to_dst,
    &a7_red6_to_dst,
    &a7_red7_to_dst,
];

pure nothrow {
  size_t a7_red1_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*8*dstw + redx*8;     }
  size_t a7_red2_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*8*dstw + redx*8+4;   }
  size_t a7_red3_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*8+4)*dstw + redx*4; }
  size_t a7_red4_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*4*dstw + redx*4+2;   }
  size_t a7_red5_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*4+2)*dstw + redx*2; }
  size_t a7_red6_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*2*dstw + redx*2+1;   }
  size_t a7_red7_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*2+1)*dstw + redx;   }
}

void uncompress_line(ref PNG_Decoder dc, ref int length, ref bool metaready, ubyte[] dst) {
    size_t readysize = min(dst.length, dc.uc_buf.length);
    dst[0 .. readysize] = dc.uc_buf[0 .. readysize];
    dc.uc_buf = dc.uc_buf[readysize .. $];

    if (readysize == dst.length)
        return;

    while (readysize != dst.length) {
        // need new data for dc.uc_buf...
        if (length <= 0) {  // IDAT is read -> read next chunks meta
            dc.stream.readExact(dc.chunkmeta, 12);   // crc | len & type
            if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
                throw new ImageIOException("corrupt chunk");

            length = bigEndianToNative!int(dc.chunkmeta[4..8]);
            if (dc.chunkmeta[8..12] != "IDAT") {
                // no new IDAT chunk so flush, this is the end of the IDAT stream
                metaready = true;
                dc.uc_buf = cast(ubyte[]) dc.uc.flush();
                size_t part2 = dst.length - readysize;
                if (dc.uc_buf.length < part2)
                    throw new ImageIOException("not enough data");
                dst[readysize .. readysize+part2] = dc.uc_buf[0 .. part2];
                dc.uc_buf = dc.uc_buf[part2 .. $];
                return;
            }
            if (length <= 0)    // empty IDAT chunk
                throw new ImageIOException("not enough data");
            dc.crc.put(dc.chunkmeta[8..12]);  // type
        }

        size_t bytes = min(length, dc.read_buf.length);
        dc.stream.readExact(dc.read_buf, bytes);
        length -= bytes;
        dc.crc.put(dc.read_buf[0..bytes]);

        if (bytes <= 0)
            throw new ImageIOException("not enough data");

        dc.uc_buf = cast(ubyte[]) dc.uc.uncompress(dc.read_buf[0..bytes].dup);

        size_t part2 = min(dst.length - readysize, dc.uc_buf.length);
        dst[readysize .. readysize+part2] = dc.uc_buf[0 .. part2];
        dc.uc_buf = dc.uc_buf[part2 .. $];
        readysize += part2;
    }
}

void recon(ubyte[] cline, in ubyte[] pline, ubyte ftype, int fstep) pure {
    switch (ftype) with (PNG_FilterType) {
        case None:
            break;
        case Sub:
            foreach (k; fstep .. cline.length)
                cline[k] += cline[k-fstep];
            break;
        case Up:
            foreach (k; 0 .. cline.length)
                cline[k] += pline[k];
            break;
        case Average:
            foreach (k; 0 .. fstep)
                cline[k] += pline[k] / 2;
            foreach (k; fstep .. cline.length)
                cline[k] += cast(ubyte)
                    ((cast(uint) cline[k-fstep] + cast(uint) pline[k]) / 2);
            break;
        case Paeth:
            foreach (i; 0 .. fstep)
                cline[i] += paeth(0, pline[i], 0);
            foreach (i; fstep .. cline.length)
                cline[i] += paeth(cline[i-fstep], pline[i], pline[i-fstep]);
            break;
        default:
            throw new ImageIOException("filter type not supported");
    }
}

ubyte paeth(ubyte a, ubyte b, ubyte c) pure nothrow {
    int pc = cast(int) c;
    int pa = cast(int) b - pc;
    int pb = cast(int) a - pc;
    pc = pa + pb;
    if (pa < 0) pa = -pa;
    if (pb < 0) pb = -pb;
    if (pc < 0) pc = -pc;

    if (pa <= pb && pa <= pc) {
        return a;
    } else if (pb <= pc) {
        return b;
    }
    return c;
}

// ----------------------------------------------------------------------
// PNG encoder

void write_png(Writer stream, long w, long h, in ubyte[] data, long tgt_chans = 0) {
    if (w < 1 || h < 1 || int.max < w || int.max < h)
        throw new ImageIOException("invalid dimensions");
    uint src_chans = cast(uint) (data.length / w / h);
    if (src_chans < 1 || 4 < src_chans || tgt_chans < 0 || 4 < tgt_chans)
        throw new ImageIOException("invalid channel count");
    if (src_chans * w * h != data.length)
        throw new ImageIOException("mismatching dimensions and length");

    PNG_Encoder ec = {
        stream    : stream,
        w         : cast(size_t) w,
        h         : cast(size_t) h,
        src_chans : src_chans,
        tgt_chans : tgt_chans ? cast(uint) tgt_chans : src_chans,
        data      : data,
    };

    write_png(ec);
    stream.flush();
}

struct PNG_Encoder {
    Writer stream;
    size_t w, h;
    uint src_chans;
    uint tgt_chans;
    const(ubyte)[] data;

    CRC32 crc;

    uint writelen;      // how much written of current idat data
    ubyte[] chunk_buf;  // len type data crc
    ubyte[] data_buf;   // slice of chunk_buf, for just chunk data
}

void write_png(ref PNG_Encoder ec) {
    ubyte[33] hdr = void;
    hdr[ 0 ..  8] = png_file_header;
    hdr[ 8 .. 16] = [0x0, 0x0, 0x0, 0xd, 'I','H','D','R'];
    hdr[16 .. 20] = nativeToBigEndian(cast(uint) ec.w);
    hdr[20 .. 24] = nativeToBigEndian(cast(uint) ec.h);
    hdr[24      ] = 8;  // bit depth
    hdr[25      ] = color_type(ec.tgt_chans);
    hdr[26 .. 29] = 0;  // compression, filter and interlace methods
    ec.crc.start();
    ec.crc.put(hdr[12 .. 29]);
    hdr[29 .. 33] = ec.crc.finish().reverse;
    ec.stream.rawWrite(hdr);

    write_IDATs(ec);

    static immutable ubyte[12] iend =
        [0, 0, 0, 0, 'I','E','N','D', 0xae, 0x42, 0x60, 0x82];
    ec.stream.rawWrite(iend);
}

void write_IDATs(ref PNG_Encoder ec) {
    static immutable ubyte[4] IDAT_type = ['I','D','A','T'];
    immutable long max_idatlen = 4 * 4096;
    ec.writelen = 0;
    ec.chunk_buf = new ubyte[8 + max_idatlen + 4];
    ec.data_buf = ec.chunk_buf[8 .. 8 + max_idatlen];
    ec.chunk_buf[4 .. 8] = IDAT_type;

    immutable size_t linesize = ec.w * ec.tgt_chans + 1; // +1 for filter type
    ubyte[] cline = new ubyte[linesize];
    ubyte[] pline = new ubyte[linesize];
    debug(DebugPNG) assert(pline[0] == 0);

    ubyte[] filtered_line = new ubyte[linesize];
    ubyte[] filtered_image;

    const LineConv convert = get_converter(ec.src_chans, ec.tgt_chans);

    immutable size_t filter_step = ec.tgt_chans;   // step between pixels, in bytes
    immutable size_t src_linesize = ec.w * ec.src_chans;

    size_t si = 0;
    foreach (j; 0 .. ec.h) {
        convert(ec.data[si .. si+src_linesize], cline[1..$]);
        si += src_linesize;

        foreach (i; 1 .. filter_step+1)
            filtered_line[i] = cast(ubyte) (cline[i] - paeth(0, pline[i], 0));
        foreach (i; filter_step+1 .. cline.length)
            filtered_line[i] = cast(ubyte)
                (cline[i] - paeth(cline[i-filter_step], pline[i], pline[i-filter_step]));

        filtered_line[0] = PNG_FilterType.Paeth;

        filtered_image ~= filtered_line;

        ubyte[] _swap = pline;
        pline = cline;
        cline = _swap;
    }

    const (void)[] xx = compress(filtered_image, 6);

    ec.write_to_IDAT_stream(xx);
    if (0 < ec.writelen)
        ec.write_IDAT_chunk();
}

void write_to_IDAT_stream(ref PNG_Encoder ec, in void[] _compressed) {
    ubyte[] compressed = cast(ubyte[]) _compressed;
    while (compressed.length) {
        size_t space_left = ec.data_buf.length - ec.writelen;
        size_t writenow_len = min(space_left, compressed.length);
        ec.data_buf[ec.writelen .. ec.writelen + writenow_len] =
            compressed[0 .. writenow_len];
        ec.writelen += writenow_len;
        compressed = compressed[writenow_len .. $];
        if (ec.writelen == ec.data_buf.length)
            ec.write_IDAT_chunk();
    }
}

// chunk: len type data crc, type is already in buf
void write_IDAT_chunk(ref PNG_Encoder ec) {
    ec.chunk_buf[0 .. 4] = nativeToBigEndian!uint(ec.writelen);
    ec.crc.put(ec.chunk_buf[4 .. 8 + ec.writelen]);   // crc of type and data
    ec.chunk_buf[8 + ec.writelen .. 8 + ec.writelen + 4] = ec.crc.finish().reverse;
    ec.stream.rawWrite(ec.chunk_buf[0 .. 8 + ec.writelen + 4]);
    ec.writelen = 0;
}

void read_png_info(Reader stream, out long w, out long h, out long chans) {
    PNG_Header hdr = read_png_header(stream);
    w = hdr.width;
    h = hdr.height;
    chans = channels(cast(PNG_ColorType) hdr.color_type);
}

// --------------------------------------------------------------------------------
// TGA

public struct TGA_Header {
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

public TGA_Header read_tga_header(in char[] filename) {
    scope reader = new Reader(filename);
    return read_tga_header(reader);
}

TGA_Header read_tga_header(Reader stream) {
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

public IFImage read_tga(in char[] filename, long req_chans = 0) {
    scope reader = new Reader(filename);
    return read_tga(reader, req_chans);
}

public IFImage read_tga_from_mem(in ubyte[] source, long req_chans = 0) {
    scope reader = new Reader(source);
    return read_tga(reader, req_chans);
}

IFImage read_tga(Reader stream, long req_chans = 0) {
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

    TGA_Decoder dc = {
        stream         : stream,
        w              : hdr.width,
        h              : hdr.height,
        origin_at_top  : cast(bool) (hdr.flags & 0x20),
        bytes_pp       : hdr.bits_pp / 8,
        rle            : rle,
        tgt_chans      : (req_chans == 0) ? src_chans : cast(int) req_chans,
    };

    switch (dc.bytes_pp) {
        case 1: dc.src_fmt = _ColFmt.Y; break;
        case 2: dc.src_fmt = _ColFmt.YA; break;
        case 3: dc.src_fmt = _ColFmt.BGR; break;
        case 4: dc.src_fmt = _ColFmt.BGRA; break;
        default: throw new ImageIOException("TGA: format not supported");
    }

    IFImage result = {
        w      : dc.w,
        h      : dc.h,
        c      : cast(ColFmt) dc.tgt_chans,
        pixels : decode_tga(dc),
    };
    return result;
}

public void write_tga(in char[] file, long w, long h, in ubyte[] data, long tgt_chans = 0)
{
    scope writer = new Writer(file);
    write_tga(writer, w, h, data, tgt_chans);
}

public ubyte[] write_tga_to_mem(long w, long h, in ubyte[] data, long tgt_chans = 0) {
    scope writer = new Writer();
    write_tga(writer, w, h, data, tgt_chans);
    return writer.result;
}

void write_tga(Writer stream, long w, long h, in ubyte[] data, long tgt_chans = 0) {
    if (w < 1 || h < 1 || ushort.max < w || ushort.max < h)
        throw new ImageIOException("invalid dimensions");
    ulong src_chans = data.length / w / h;
    if (src_chans < 1 || 4 < src_chans || tgt_chans < 0 || 4 < tgt_chans)
        throw new ImageIOException("invalid channel count");
    if (src_chans * w * h != data.length)
        throw new ImageIOException("mismatching dimensions and length");

    TGA_Encoder ec = {
        stream    : stream,
        w         : cast(ushort) w,
        h         : cast(ushort) h,
        src_chans : cast(int) src_chans,
        tgt_chans : cast(int) ((tgt_chans) ? tgt_chans : src_chans),
        rle       : true,
        data      : data,
    };

    write_tga(ec);
    stream.flush();
}

struct TGA_Decoder {
    Reader stream;
    size_t w, h;
    bool origin_at_top;    // src
    uint bytes_pp;
    bool rle;   // run length compressed
    _ColFmt src_fmt;
    uint tgt_chans;
}

ubyte[] decode_tga(ref TGA_Decoder dc) {
    auto result = new ubyte[dc.w * dc.h * dc.tgt_chans];

    immutable size_t tgt_linesize = dc.w * dc.tgt_chans;
    immutable size_t src_linesize = dc.w * dc.bytes_pp;
    auto src_line = new ubyte[src_linesize];

    immutable ptrdiff_t tgt_stride = (dc.origin_at_top) ? tgt_linesize : -tgt_linesize;
    ptrdiff_t ti                   = (dc.origin_at_top) ? 0 : (dc.h-1) * tgt_linesize;

    const LineConv convert = get_converter(dc.src_fmt, dc.tgt_chans);

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
    size_t plen = 0;      // packet length
    bool its_rle = false;

    foreach (_j; 0 .. dc.h) {
        // fill src_line with uncompressed data (this works like a stream)
        size_t wanted = src_linesize;
        while (wanted) {
            if (plen == 0) {
                dc.stream.readExact(rbuf, 1);
                its_rle = cast(bool) (rbuf[0] & 0x80);
                plen = ((rbuf[0] & 0x7f) + 1) * dc.bytes_pp; // length in bytes
            }
            const size_t gotten = src_linesize - wanted;
            const size_t copysize = min(plen, wanted);
            if (its_rle) {
                dc.stream.readExact(rbuf, dc.bytes_pp);
                for (size_t p = gotten; p < gotten+copysize; p += dc.bytes_pp)
                    src_line[p .. p+dc.bytes_pp] = rbuf[0 .. dc.bytes_pp];
            } else {    // it's raw
                auto slice = src_line[gotten .. gotten+copysize];
                dc.stream.readExact(slice, copysize);
            }
            wanted -= copysize;
            plen -= copysize;
        }

        convert(src_line, result[ti .. ti + tgt_linesize]);
        ti += tgt_stride;
    }

    return result;
}

// ----------------------------------------------------------------------
// TGA encoder

immutable ubyte[18] tga_footer_sig =
    ['T','R','U','E','V','I','S','I','O','N','-','X','F','I','L','E','.', 0];

struct TGA_Encoder {
    Writer stream;
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
    ftr[8..26] = tga_footer_sig;
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

    const LineConv convert = get_converter(ec.src_chans, tgt_fmt);

    immutable size_t src_linesize = ec.w * ec.src_chans;
    immutable size_t tgt_linesize = ec.w * ec.tgt_chans;
    auto tgt_line = new ubyte[tgt_linesize];

    ptrdiff_t si = (ec.h-1) * src_linesize;     // origin at bottom

    if (!ec.rle) {
        foreach (_; 0 .. ec.h) {
            convert(ec.data[si .. si + src_linesize], tgt_line);
            ec.stream.rawWrite(tgt_line);
            si -= src_linesize; // origin at bottom
        }
        return;
    }

    // ----- RLE  -----

    immutable bytes_pp = ec.tgt_chans;
    immutable size_t max_packets_per_line = (tgt_linesize+127) / 128;
    auto tgt_cmp = new ubyte[tgt_linesize + max_packets_per_line];  // compressed line
    foreach (_; 0 .. ec.h) {
        convert(ec.data[si .. si + src_linesize], tgt_line);
        ubyte[] compressed_line = rle_compress(tgt_line, tgt_cmp, ec.w, bytes_pp);
        ec.stream.rawWrite(compressed_line);
        si -= src_linesize; // origin at bottom
    }
}

ubyte[] rle_compress(in ubyte[] line, ubyte[] tgt_cmp, in size_t w, in int bytes_pp) pure {
    immutable int rle_limit = (1 < bytes_pp) ? 2 : 3;  // run len worth an RLE packet
    size_t runlen = 0;
    size_t rawlen = 0;
    size_t raw_i = 0; // start of raw packet data in line
    size_t cmp_i = 0;
    size_t pixels_left = w;
    const (ubyte)[] px;
    for (size_t i = bytes_pp; pixels_left; i += bytes_pp) {
        runlen = 1;
        px = line[i-bytes_pp .. i];
        while (i < line.length && line[i .. i+bytes_pp] == px[0..$] && runlen < 128) {
            ++runlen;
            i += bytes_pp;
        }
        pixels_left -= runlen;

        if (runlen < rle_limit) {
            // data goes to raw packet
            rawlen += runlen;
            if (128 <= rawlen) {     // full packet, need to store it
                size_t copysize = 128 * bytes_pp;
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
                size_t copysize = rawlen * bytes_pp;
                tgt_cmp[cmp_i++] = cast(ubyte) (rawlen-1); // raw packet header
                tgt_cmp[cmp_i .. cmp_i+copysize] = line[raw_i .. raw_i+copysize];
                cmp_i += copysize;
                rawlen = 0;
            }

            // store RLE packet
            tgt_cmp[cmp_i++] = cast(ubyte) (0x80 | (runlen-1)); // packet header
            tgt_cmp[cmp_i .. cmp_i+bytes_pp] = px[0..$];       // packet data
            cmp_i += bytes_pp;
            raw_i = i;
        }
    }   // for

    if (rawlen) {   // last packet of the line
        size_t copysize = rawlen * bytes_pp;
        tgt_cmp[cmp_i++] = cast(ubyte) (rawlen-1); // raw packet header
        tgt_cmp[cmp_i .. cmp_i+copysize] = line[raw_i .. raw_i+copysize];
        cmp_i += copysize;
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

void read_tga_info(Reader stream, out long w, out long h, out long chans) {
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

// --------------------------------------------------------------------------------
/*
    Baseline JPEG/JFIF decoder
    - not quite optimized but should be well usable already. seems to be
    something like 1.66 times slower with ldc and 1.78 times slower with gdc
    than stb_image.
    - memory use could be reduced by processing MCU-row at a time, and, if
    only grayscale result is requested, the Cb and Cr components could be
    discarded much earlier.
*/

import std.math;    // floor, ceil
import core.stdc.stdlib : alloca;

//debug = DebugJPEG;

public struct JPEG_Header {    // JFIF
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

public JPEG_Header read_jpeg_header(in char[] filename) {
    scope reader = new Reader(filename);
    return read_jpeg_header(reader);
}

JPEG_Header read_jpeg_header(Reader stream) {
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

public IFImage read_jpeg(in char[] filename, long req_chans = 0) {
    scope reader = new Reader(filename);
    return read_jpeg(reader, req_chans);
}

public IFImage read_jpeg_from_mem(in ubyte[] source, long req_chans = 0) {
    scope reader = new Reader(source);
    return read_jpeg(reader, req_chans);
}

IFImage read_jpeg(Reader stream, long req_chans = 0) {
    if (req_chans < 0 || 4 < req_chans)
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

    Component[3] comps;
    ubyte num_comps;
    int[3] index_for;   // index_for[0] is index of comp that comes first in stream
    int tgt_chans;

    size_t width, height;

    int hmax, vmax;

    ushort restart_interval;    // number of MCUs in restart interval

    // image component
    struct Component {
        ubyte id;
        ubyte sfx, sfy;   // sampling factors, aka. h and v
        long x, y;       // total num of samples, without fill samples
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
        dc.comps[i].x = cast(long) ceil(dc.width * (cast(double) dc.comps[i].sfx / dc.hmax));
        dc.comps[i].y = cast(long) ceil(dc.height * (cast(double) dc.comps[i].sfy / dc.vmax));

        debug(DebugJPEG) writefln("%d comp %d sfx/sfy: %d/%d", i, dc.comps[i].id,
                                                                  dc.comps[i].sfx,
                                                                  dc.comps[i].sfy);
    }

    long mcu_w = dc.hmax * 8;
    long mcu_h = dc.vmax * 8;
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
            foreach (_c; 0..dc.num_comps) {
                auto comp = &dc.comps[dc.index_for[_c]];
                foreach (du_j; 0 .. comp.sfy) {
                    foreach (du_i; 0 .. comp.sfx) {
                        // decode entropy, dequantize & dezigzag
                        short[64] data = decode_block(dc, *comp, dc.qtables[comp.qtable]);
                        // idct & level-shift
                        long outx = (mcu_i * comp.sfx + du_i) * 8;
                        long outy = (mcu_j * comp.sfy + du_j) * 8;
                        long dst_stride = dc.num_mcu_x * comp.sfx*8;
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
            foreach (const ref comp; dc.comps[0..dc.num_comps]) {
                if (comp.sfx != dc.hmax || comp.sfy != dc.vmax)
                    return dc.upsample_rgb(result);
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
                return dc.upsample_gray(result);
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

ubyte[] upsample_gray(in ref JPEG_Decoder dc, ubyte[] result) {
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const double si0yratio = cast(double) dc.comps[0].y / dc.height;
    const double si0xratio = cast(double) dc.comps[0].x / dc.width;
    size_t si0, di;

    foreach (j; 0 .. dc.height) {
        si0 = cast(size_t) floor(j * si0yratio) * stride0;
        foreach (i; 0 .. dc.width) {
            result[di] = dc.comps[0].data[si0 + cast(size_t) floor(i * si0xratio)];
            if (dc.tgt_chans == 2)
                result[di+1] = 255;
            di += dc.tgt_chans;
        }
    }
    return result;
}

ubyte[] upsample_rgb(in ref JPEG_Decoder dc, ubyte[] result) {
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const size_t stride1 = dc.num_mcu_x * dc.comps[1].sfx * 8;
    const size_t stride2 = dc.num_mcu_x * dc.comps[2].sfx * 8;

    const double si0yratio = cast(double) dc.comps[0].y / dc.height;
    const double si1yratio = cast(double) dc.comps[1].y / dc.height;
    const double si2yratio = cast(double) dc.comps[2].y / dc.height;
    const double si0xratio = cast(double) dc.comps[0].x / dc.width;
    const double si1xratio = cast(double) dc.comps[1].x / dc.width;
    const double si2xratio = cast(double) dc.comps[2].x / dc.width;
    size_t si0, si1, si2, di;

    foreach (j; 0 .. dc.height) {
        si0 = cast(size_t) floor(j * si0yratio) * stride0;
        si1 = cast(size_t) floor(j * si1yratio) * stride1;
        si2 = cast(size_t) floor(j * si2yratio) * stride2;

        foreach (i; 0 .. dc.width) {
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[si0 + cast(size_t) floor(i * si0xratio)],
                dc.comps[1].data[si1 + cast(size_t) floor(i * si1xratio)],
                dc.comps[2].data[si2 + cast(size_t) floor(i * si2xratio)],
            );
            if (dc.tgt_chans == 4)
                result[di+3] = 255;
            di += dc.tgt_chans;
        }
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
pure void stbi__idct_block(ubyte* dst, long dst_stride, in ref short[64] data) {
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

void read_jpeg_info(Reader stream, out long w, out long h, out long chans) {
    JPEG_Header hdr = read_jpeg_header(stream);
    w = hdr.width;
    h = hdr.height;
    chans = hdr.num_comps;
}

// --------------------------------------------------------------------------------
// Conversions

enum _ColFmt : int {
    Unknown = 0,
    Y = 1,
    YA,
    RGB,
    RGBA,
    BGR,
    BGRA,
}

alias LineConv = void function(in ubyte[] src, ubyte[] tgt);

LineConv get_converter(long src_chans, long tgt_chans) pure {
    long combo(long a, long b) pure nothrow { return a*16 + b; }

    if (src_chans == tgt_chans)
        return &copy_line;

    switch (combo(src_chans, tgt_chans)) with (_ColFmt) {
        case combo(Y, YA)      : return &Y_to_YA;
        case combo(Y, RGB)     : return &Y_to_RGB;
        case combo(Y, RGBA)    : return &Y_to_RGBA;
        case combo(Y, BGR)     : return &Y_to_BGR;
        case combo(Y, BGRA)    : return &Y_to_BGRA;
        case combo(YA, Y)      : return &YA_to_Y;
        case combo(YA, RGB)    : return &YA_to_RGB;
        case combo(YA, RGBA)   : return &YA_to_RGBA;
        case combo(YA, BGR)    : return &YA_to_BGR;
        case combo(YA, BGRA)   : return &YA_to_BGRA;
        case combo(RGB, Y)     : return &RGB_to_Y;
        case combo(RGB, YA)    : return &RGB_to_YA;
        case combo(RGB, RGBA)  : return &RGB_to_RGBA;
        case combo(RGB, BGR)   : return &RGB_to_BGR;
        case combo(RGB, BGRA)  : return &RGB_to_BGRA;
        case combo(RGBA, Y)    : return &RGBA_to_Y;
        case combo(RGBA, YA)   : return &RGBA_to_YA;
        case combo(RGBA, RGB)  : return &RGBA_to_RGB;
        case combo(RGBA, BGR)  : return &RGBA_to_BGR;
        case combo(RGBA, BGRA) : return &RGBA_to_BGRA;
        case combo(BGR, Y)     : return &BGR_to_Y;
        case combo(BGR, YA)    : return &BGR_to_YA;
        case combo(BGR, RGB)   : return &BGR_to_RGB;
        case combo(BGR, RGBA)  : return &BGR_to_RGBA;
        case combo(BGRA, Y)    : return &BGRA_to_Y;
        case combo(BGRA, YA)   : return &BGRA_to_YA;
        case combo(BGRA, RGB)  : return &BGRA_to_RGB;
        case combo(BGRA, RGBA) : return &BGRA_to_RGBA;
        default                : throw new ImageIOException("internal error");
    }
}

void copy_line(in ubyte[] src, ubyte[] tgt) pure nothrow {
    tgt[0..$] = src[0..$];
}

ubyte luminance(ubyte r, ubyte g, ubyte b) pure nothrow {
    return cast(ubyte) (0.21*r + 0.64*g + 0.15*b); // somewhat arbitrary weights
}

void Y_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=2) {
        tgt[t] = src[k];
        tgt[t+1] = 255;
    }
}

alias Y_to_BGR = Y_to_RGB;
void Y_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

alias Y_to_BGRA = Y_to_RGBA;
void Y_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = 255;
    }
}

void YA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=1)
        tgt[t] = src[k];
}

alias YA_to_BGR = YA_to_RGB;
void YA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

alias YA_to_BGRA = YA_to_RGBA;
void YA_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = src[k+1];
    }
}

void RGB_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void RGB_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = 255;
    }
}

void RGB_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t .. t+3] = src[k .. k+3];
        tgt[t+3] = 255;
    }
}

void RGBA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void RGBA_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = src[k+3];
    }
}

void RGBA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=3)
        tgt[t .. t+3] = src[k .. k+3];
}

void BGR_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
}

void BGR_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
        tgt[t+1] = 255;
    }
}

alias RGB_to_BGR = BGR_to_RGB;
void BGR_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

alias RGB_to_BGRA = BGR_to_RGBA;
void BGR_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = 255;
    }
}

void BGRA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
}

void BGRA_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
        tgt[t+1] = 255;
    }
}

alias RGBA_to_BGR = BGRA_to_RGB;
void BGRA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

alias RGBA_to_BGRA = BGRA_to_RGBA;
void BGRA_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}

// --------------------------------------------------------------------------------

class Reader {
    const void delegate(ubyte[], size_t) readExact;
    const void delegate(ptrdiff_t, int) seek;

    this(in char[] filename) {
        this(File(filename.idup, "rb"));
    }

    this(File f) {
        if (!f.isOpen) throw new ImageIOException("File not open");
        this.f = f;
        this.readExact = &file_readExact;
        this.seek = &file_seek;
        this.source = null;
    }

    this(in ubyte[] source) {
        this.source = source;
        this.readExact = &mem_readExact;
        this.seek = &mem_seek;
    }

    private:

    File f;
    void file_readExact(ubyte[] buffer, size_t bytes) {
        auto slice = this.f.rawRead(buffer[0..bytes]);
        if (slice.length != bytes)
            throw new Exception("not enough data");
    }
    void file_seek(ptrdiff_t offset, int origin) { this.f.seek(offset, origin); }

    const ubyte[] source;
    ptrdiff_t cursor;
    void mem_readExact(ubyte[] buffer, size_t bytes) {
        if (source.length - cursor < bytes)
            throw new Exception("not enough data");
        buffer[0..bytes] = source[cursor .. cursor+bytes];
        cursor += bytes;
    }
    void mem_seek(ptrdiff_t offset, int origin) {
        switch (origin) {
            case SEEK_SET:
                if (offset < 0 || source.length <= offset)
                    throw new Exception("seek error");
                cursor = offset;
                break;
            case SEEK_CUR:
                ptrdiff_t dst = cursor + offset;
                if (dst < 0 || source.length <= dst)
                    throw new Exception("seek error");
                cursor = dst;
                break;
            case SEEK_END:
                if (0 <= offset || source.length < -offset)
                    throw new Exception("seek error");
                cursor = cast(ptrdiff_t) source.length + offset;
                break;
            default: assert(0);
        }
    }
}

class Writer {
    const void delegate(in ubyte[]) rawWrite;
    const void delegate() flush;

    this(in char[] filename) {
        this(File(filename.idup, "wb"));
    }

    this(File f) {
        if (!f.isOpen) throw new ImageIOException("File not open");
        this.f = f;
        this.rawWrite = &file_rawWrite;
        this.flush = &file_flush;
    }

    this() {
        this.rawWrite = &mem_rawWrite;
        this.flush = &mem_flush;
    }

    @property ubyte[] result() { return buffer; }

    private:

    File f;
    void file_rawWrite(in ubyte[] block) { this.f.rawWrite(block); }
    void file_flush() { this.f.flush(); }

    ubyte[] buffer;
    void mem_rawWrite(in ubyte[] block) { this.buffer ~= block; }
    void mem_flush() { }
}

const(char)[] extract_extension_lowercase(in char[] filename) {
    ptrdiff_t di = filename.lastIndexOf('.');
    return (0 < di && di+1 < filename.length) ? filename[di+1..$].toLower() : "";
}
