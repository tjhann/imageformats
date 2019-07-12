module imageformats.png;

import etc.c.zlib;
import std.algorithm  : min, reverse;
import std.bitmanip   : bigEndianToNative, nativeToBigEndian;
import std.stdio      : File, SEEK_SET;
import std.digest.crc : CRC32, crc32Of;
import std.typecons   : scoped;
import imageformats;

private:

/// Header of a PNG file.
public struct PNG_Header {
    int     width;
    int     height;
    ubyte   bit_depth;
    ubyte   color_type;
    ubyte   compression_method;
    ubyte   filter_method;
    ubyte   interlace_method;
}

/// Returns the header of a PNG file.
public PNG_Header read_png_header(in char[] filename) {
    auto reader = scoped!FileReader(filename);
    return read_png_header(reader);
}

/// Returns the header of the image in the buffer.
public PNG_Header read_png_header_from_mem(in ubyte[] source) {
    auto reader = scoped!MemReader(source);
    return read_png_header(reader);
}

/// Reads an 8-bit or 16-bit PNG image and returns it as an 8-bit image.
/// req_chans defines the format of returned image (you can use ColFmt here).
public IFImage read_png(in char[] filename, long req_chans = 0) {
    auto reader = scoped!FileReader(filename);
    return read_png(reader, req_chans);
}

/// Reads an 8-bit or 16-bit PNG image from a buffer and returns it as an
/// 8-bit image.  req_chans defines the format of returned image (you can use
/// ColFmt here).
public IFImage read_png_from_mem(in ubyte[] source, long req_chans = 0) {
    auto reader = scoped!MemReader(source);
    return read_png(reader, req_chans);
}

/// Reads an 8-bit or 16-bit PNG image and returns it as a 16-bit image.
/// req_chans defines the format of returned image (you can use ColFmt here).
public IFImage16 read_png16(in char[] filename, long req_chans = 0) {
    auto reader = scoped!FileReader(filename);
    return read_png16(reader, req_chans);
}

/// Reads an 8-bit or 16-bit PNG image from a buffer and returns it as a
/// 16-bit image.  req_chans defines the format of returned image (you can use
/// ColFmt here).
public IFImage16 read_png16_from_mem(in ubyte[] source, long req_chans = 0) {
    auto reader = scoped!MemReader(source);
    return read_png16(reader, req_chans);
}

/// Writes a PNG image into a file.
public void write_png(in char[] file, long w, long h, in ubyte[] data, long tgt_chans = 0)
{
    auto writer = scoped!FileWriter(file);
    write_png(writer, w, h, data, tgt_chans);
}

/// Writes a PNG image into a buffer.
public ubyte[] write_png_to_mem(long w, long h, in ubyte[] data, long tgt_chans = 0) {
    auto writer = scoped!MemWriter();
    write_png(writer, w, h, data, tgt_chans);
    return writer.result;
}

/// Returns width, height and color format information via w, h and chans.
public void read_png_info(in char[] filename, out int w, out int h, out int chans) {
    auto reader = scoped!FileReader(filename);
    return read_png_info(reader, w, h, chans);
}

/// Returns width, height and color format information via w, h and chans.
public void read_png_info_from_mem(in ubyte[] source, out int w, out int h, out int chans) {
    auto reader = scoped!MemReader(source);
    return read_png_info(reader, w, h, chans);
}

// Detects whether a PNG image is readable from stream.
package bool detect_png(Reader stream) {
    try {
        ubyte[8] tmp = void;
        stream.readExact(tmp, tmp.length);
        return (tmp[0..8] == png_file_header[0..$]);
    } catch (Throwable) {
        return false;
    } finally {
        stream.seek(0, SEEK_SET);
    }
}

PNG_Header read_png_header(Reader stream) {
    ubyte[33] tmp = void;  // file header, IHDR len+type+data+crc
    stream.readExact(tmp, tmp.length);

    ubyte[4] crc = crc32Of(tmp[12..29]);
    reverse(crc[]);
    if ( tmp[0..8] != png_file_header[0..$]              ||
         tmp[8..16] != png_image_header                  ||
         crc != tmp[29..33] )
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

package IFImage read_png(Reader stream, long req_chans = 0) {
    PNG_Decoder dc = init_png_decoder(stream, req_chans, 8);
    IFImage result = {
        w      : dc.w,
        h      : dc.h,
        c      : cast(ColFmt) dc.tgt_chans,
        pixels : decode_png(dc).bpc8
    };
    return result;
}

IFImage16 read_png16(Reader stream, long req_chans = 0) {
    PNG_Decoder dc = init_png_decoder(stream, req_chans, 16);
    IFImage16 result = {
        w      : dc.w,
        h      : dc.h,
        c      : cast(ColFmt) dc.tgt_chans,
        pixels : decode_png(dc).bpc16
    };
    return result;
}

PNG_Decoder init_png_decoder(Reader stream, long req_chans, int req_bpc) {
    if (req_chans < 0 || 4 < req_chans)
        throw new ImageIOException("come on...");

    PNG_Header hdr = read_png_header(stream);

    if (hdr.width < 1 || hdr.height < 1 || int.max < cast(ulong) hdr.width * hdr.height)
        throw new ImageIOException("invalid dimensions");
    if ((hdr.bit_depth != 8 && hdr.bit_depth != 16) || (req_bpc != 8 && req_bpc != 16))
        throw new ImageIOException("only 8-bit and 16-bit images supported");
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
        bpc         : hdr.bit_depth,
        req_bpc     : req_bpc,
        ilace       : hdr.interlace_method,
        w           : hdr.width,
        h           : hdr.height,
    };
    dc.tgt_chans = (req_chans == 0) ? dc.src_chans : cast(int) req_chans;
    return dc;
}

immutable ubyte[8] png_file_header =
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

immutable ubyte[8] png_image_header =
    [0x0, 0x0, 0x0, 0xd, 'I','H','D','R'];

int channels(PNG_ColorType ct) pure nothrow {
    final switch (ct) with (PNG_ColorType) {
        case Y: return 1;
        case RGB: return 3;
        case YA: return 2;
        case RGBA, Idx: return 4;
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
    int bpc;
    int req_bpc;
    int w, h;
    ubyte ilace;

    CRC32 crc;
    ubyte[12] chunkmeta;  // crc | length and type
    ubyte[] read_buf;
    ubyte[] palette;
    ubyte[] transparency;

    // decompression
    z_stream*   z;              // zlib stream
    uint        avail_idat;     // available bytes in current idat chunk
    ubyte[]     idat_window;    // slice of read_buf
}

Buffer decode_png(ref PNG_Decoder dc) {
    dc.read_buf = new ubyte[4096];

    enum Stage {
        IHDR_parsed,
        PLTE_parsed,
        IDAT_parsed,
        IEND_parsed,
    }

    Buffer result;
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
                dc.stream.readExact(dc.chunkmeta, 12); // crc | len, type
                ubyte[4] crc = dc.crc.finish;
                reverse(crc[]);
                if (crc != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
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
                ubyte[4] crc = dc.crc.finish;
                reverse(crc[]);
                if (crc != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
                stage = Stage.PLTE_parsed;
                break;
            case "tRNS":
                if (! (stage == Stage.IHDR_parsed ||
                      (stage == Stage.PLTE_parsed && dc.src_indexed)) )
                    throw new ImageIOException("corrupt chunk stream");
                if (dc.src_indexed) {
                    size_t entries = dc.palette.length / 3;
                    if (len > entries)
                        throw new ImageIOException("corrupt chunk");
                }
                dc.transparency = new ubyte[len];
                dc.stream.readExact(dc.transparency, dc.transparency.length);
                dc.stream.readExact(dc.chunkmeta, 12);
                dc.crc.put(dc.transparency);
                ubyte[4] crc = dc.crc.finish;
                reverse(crc[]);
                if (crc != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
                break;
            case "IEND":
                if (stage != Stage.IDAT_parsed)
                    throw new ImageIOException("corrupt chunk stream");
                dc.stream.readExact(dc.chunkmeta, 4); // crc
                static immutable ubyte[4] expectedCRC = [0xae, 0x42, 0x60, 0x82];
                if (len != 0 || dc.chunkmeta[0..4] != expectedCRC)
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
                ubyte[4] crc = dc.crc.finish;
                reverse(crc[]);
                if (crc != dc.chunkmeta[0..4])
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

union Buffer {
    ubyte[] bpc8;
    ushort[] bpc16;
}

Buffer read_IDAT_stream(ref PNG_Decoder dc, int len) {
    assert(dc.req_bpc == 8 || dc.req_bpc == 16);

    // initialize zlib stream
    z_stream z = { zalloc: null, zfree: null, opaque: null };
    if (inflateInit(&z) != Z_OK)
        throw new ImageIOException("can't init zlib");
    dc.z = &z;
    dc.avail_idat = len;
    scope(exit)
        inflateEnd(&z);

    const size_t filter_step = dc.src_indexed
                             ? 1 : dc.src_chans * (dc.bpc == 8 ? 1 : 2);

    ubyte[] depaletted = dc.src_indexed ? new ubyte[dc.w * 4] : null;

    auto cline = new ubyte[dc.w * filter_step + 1]; // +1 for filter type byte
    auto pline = new ubyte[dc.w * filter_step + 1]; // +1 for filter type byte
    auto cline8 = (dc.req_bpc == 8 && dc.bpc != 8) ? new ubyte[dc.w * dc.src_chans] : null;
    auto cline16 = (dc.req_bpc == 16) ? new ushort[dc.w * dc.src_chans] : null;
    ubyte[]  result8  = (dc.req_bpc == 8)  ? new ubyte[dc.w * dc.h * dc.tgt_chans] : null;
    ushort[] result16 = (dc.req_bpc == 16) ? new ushort[dc.w * dc.h * dc.tgt_chans] : null;

    const LineConv!ubyte convert8   = get_converter!ubyte(dc.src_chans, dc.tgt_chans);
    const LineConv!ushort convert16 = get_converter!ushort(dc.src_chans, dc.tgt_chans);

    if (dc.ilace == InterlaceMethod.None) {
        const size_t src_linelen = dc.w * dc.src_chans;
        const size_t tgt_linelen = dc.w * dc.tgt_chans;

        size_t ti = 0;    // target index
        foreach (j; 0 .. dc.h) {
            uncompress(dc, cline);
            ubyte filter_type = cline[0];

            recon(cline[1..$], pline[1..$], filter_type, filter_step);

            ubyte[] bytes;  // defiltered bytes or 8-bit samples from palette
            if (dc.src_indexed) {
                depalette(dc.palette, dc.transparency, cline[1..$], depaletted);
                bytes = depaletted[0 .. src_linelen];
            } else {
                bytes = cline[1..$];
            }

            // convert colors
            if (dc.req_bpc == 8) {
                line8_from_bytes(bytes, dc.bpc, cline8);
                convert8(cline8[0 .. src_linelen], result8[ti .. ti + tgt_linelen]);
            } else {
                line16_from_bytes(bytes, dc.bpc, cline16);
                convert16(cline16[0 .. src_linelen], result16[ti .. ti + tgt_linelen]);
            }

            ti += tgt_linelen;

            ubyte[] _swap = pline;
            pline = cline;
            cline = _swap;
        }
    } else {
        // Adam7 interlacing

        immutable size_t[7] redw = [(dc.w + 7) / 8,
                                    (dc.w + 3) / 8,
                                    (dc.w + 3) / 4,
                                    (dc.w + 1) / 4,
                                    (dc.w + 1) / 2,
                                    (dc.w + 0) / 2,
                                    (dc.w + 0) / 1];

        immutable size_t[7] redh = [(dc.h + 7) / 8,
                                    (dc.h + 7) / 8,
                                    (dc.h + 3) / 8,
                                    (dc.h + 3) / 4,
                                    (dc.h + 1) / 4,
                                    (dc.h + 1) / 2,
                                    (dc.h + 0) / 2];

        auto redline8 = (dc.req_bpc == 8) ? new ubyte[dc.w * dc.tgt_chans] : null;
        auto redline16 = (dc.req_bpc == 16) ? new ushort[dc.w * dc.tgt_chans] : null;

        foreach (pass; 0 .. 7) {
            const A7_Catapult tgt_px = a7_catapults[pass];   // target pixel
            const size_t src_linelen = redw[pass] * dc.src_chans;
            ubyte[] cln = cline[0 .. redw[pass] * filter_step + 1];
            ubyte[] pln = pline[0 .. redw[pass] * filter_step + 1];
            pln[] = 0;

            foreach (j; 0 .. redh[pass]) {
                uncompress(dc, cln);
                ubyte filter_type = cln[0];

                recon(cln[1..$], pln[1..$], filter_type, filter_step);

                ubyte[] bytes;  // defiltered bytes or 8-bit samples from palette
                if (dc.src_indexed) {
                    depalette(dc.palette, dc.transparency, cln[1..$], depaletted);
                    bytes = depaletted[0 .. src_linelen];
                } else {
                    bytes = cln[1..$];
                }

                // convert colors and sling pixels from reduced image to final buffer
                if (dc.req_bpc == 8) {
                    line8_from_bytes(bytes, dc.bpc, cline8);
                    convert8(cline8[0 .. src_linelen], redline8[0 .. redw[pass]*dc.tgt_chans]);
                    for (size_t i, redi; i < redw[pass]; ++i, redi += dc.tgt_chans) {
                        size_t tgt = tgt_px(i, j, dc.w) * dc.tgt_chans;
                        result8[tgt .. tgt + dc.tgt_chans] =
                            redline8[redi .. redi + dc.tgt_chans];
                    }
                } else {
                    line16_from_bytes(bytes, dc.bpc, cline16);
                    convert16(cline16[0 .. src_linelen], redline16[0 .. redw[pass]*dc.tgt_chans]);
                    for (size_t i, redi; i < redw[pass]; ++i, redi += dc.tgt_chans) {
                        size_t tgt = tgt_px(i, j, dc.w) * dc.tgt_chans;
                        result16[tgt .. tgt + dc.tgt_chans] =
                            redline16[redi .. redi + dc.tgt_chans];
                    }
                }

                ubyte[] _swap = pln;
                pln = cln;
                cln = _swap;
            }
        }
    }

    Buffer result;
    switch (dc.req_bpc) {
        case 8: result.bpc8 = result8; return result;
        case 16: result.bpc16 = result16; return result;
        default: throw new ImageIOException("internal error");
    }
}

void line8_from_bytes(ubyte[] src, int bpc, ref ubyte[] tgt) {
    switch (bpc) {
    case 8:
        tgt = src;
        break;
    case 16:
        for (size_t k, t;   k < src.length;   k+=2, t+=1) { tgt[t] = src[k]; /* truncate */ }
        break;
    default: throw new ImageIOException("unsupported bit depth (and bug)");
    }
}

void line16_from_bytes(in ubyte[] src, int bpc, ushort[] tgt) {
    switch (bpc) {
    case 8:
        for (size_t k;   k < src.length;   k+=1) { tgt[k] = src[k] * 256 + 128; }
        break;
    case 16:
        for (size_t k, t;   k < src.length;   k+=2, t+=1) { tgt[t] = src[k] << 8 | src[k+1]; }
        break;
    default: throw new ImageIOException("unsupported bit depth (and bug)");
    }
}

void depalette(in ubyte[] palette, in ubyte[] transparency, in ubyte[] src_line, ubyte[] depaletted) pure {
    for (size_t s, d;  s < src_line.length;  s+=1, d+=4) {
        ubyte pid = src_line[s];
        size_t pidx = pid * 3;
        if (palette.length < pidx + 3)
            throw new ImageIOException("palette index wrong");
        depaletted[d .. d+3] = palette[pidx .. pidx+3];
        depaletted[d+3] = (pid < transparency.length) ? transparency[pid] : 255;
    }
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

// Uncompresses a line from the IDAT stream into dst.
void uncompress(ref PNG_Decoder dc, ubyte[] dst)
{
    dc.z.avail_out = cast(uint) dst.length;
    dc.z.next_out = dst.ptr;

    while (true) {
        if (!dc.z.avail_in) {
            if (!dc.avail_idat) {
                dc.stream.readExact(dc.chunkmeta, 12);   // crc | len & type
                ubyte[4] crc = dc.crc.finish;
                reverse(crc[]);
                if (crc != dc.chunkmeta[0..4])
                    throw new ImageIOException("corrupt chunk");
                dc.avail_idat = bigEndianToNative!uint(dc.chunkmeta[4..8]);
                if (!dc.avail_idat)
                    throw new ImageIOException("invalid data");
                if (dc.chunkmeta[8..12] != "IDAT")
                    throw new ImageIOException("not enough data");
                dc.crc.put(dc.chunkmeta[8..12]);
            }

            const size_t n = min(dc.avail_idat, dc.read_buf.length);
            dc.stream.readExact(dc.read_buf, n);
            dc.idat_window = dc.read_buf[0..n];

            if (!dc.idat_window)
                throw new ImageIOException("TODO");
            dc.crc.put(dc.idat_window);
            dc.avail_idat -= cast(uint) dc.idat_window.length;
            dc.z.avail_in = cast(uint) dc.idat_window.length;
            dc.z.next_in = dc.idat_window.ptr;
        }

        int q = inflate(dc.z, Z_NO_FLUSH);

        if (dc.z.avail_out == 0)
            return;
        if (q != Z_OK)
            throw new ImageIOException("zlib error");
    }
}

void recon(ubyte[] cline, in ubyte[] pline, ubyte ftype, size_t fstep) pure {
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
    int pc = c;
    int pa = b - pc;
    int pb = a - pc;
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

enum MAXIMUM_CHUNK_SIZE = 8192;

struct PNG_Encoder {
    Writer stream;
    size_t w, h;
    uint src_chans;
    uint tgt_chans;
    const(ubyte)[] data;

    CRC32       crc;
    z_stream*   z;
    ubyte[]     idatbuf;
}

void write_png(ref PNG_Encoder ec) {
    ubyte[33] hdr = void;
    hdr[ 0 ..  8] = png_file_header;
    hdr[ 8 .. 16] = png_image_header;
    hdr[16 .. 20] = nativeToBigEndian(cast(uint) ec.w);
    hdr[20 .. 24] = nativeToBigEndian(cast(uint) ec.h);
    hdr[24      ] = 8;  // bit depth
    hdr[25      ] = color_type(ec.tgt_chans);
    hdr[26 .. 29] = 0;  // compression, filter and interlace methods
    ec.crc.start();
    ec.crc.put(hdr[12 .. 29]);
    ubyte[4] crc = ec.crc.finish();
    reverse(crc[]);
    hdr[29 .. 33] = crc;
    ec.stream.rawWrite(hdr);

    write_IDATs(ec);

    static immutable ubyte[12] iend =
        [0, 0, 0, 0, 'I','E','N','D', 0xae, 0x42, 0x60, 0x82];
    ec.stream.rawWrite(iend);
}

void write_IDATs(ref PNG_Encoder ec) {
    // initialize zlib stream
    z_stream z = { zalloc: null, zfree: null, opaque: null };
    if (deflateInit(&z, Z_DEFAULT_COMPRESSION) != Z_OK)
        throw new ImageIOException("zlib init error");
    scope(exit)
        deflateEnd(ec.z);
    ec.z = &z;

    const LineConv!ubyte convert = get_converter!ubyte(ec.src_chans, ec.tgt_chans);

    const size_t filter_step = ec.tgt_chans;   // step between pixels, in bytes
    const size_t slinesz = ec.w * ec.src_chans;
    const size_t tlinesz = ec.w * ec.tgt_chans + 1;
    const size_t workbufsz = 3 * tlinesz + MAXIMUM_CHUNK_SIZE;

    ubyte[] workbuf  = new ubyte[workbufsz];
    ubyte[] cline    = workbuf[0 .. tlinesz];
    ubyte[] pline    = workbuf[tlinesz .. 2 * tlinesz];
    ubyte[] filtered = workbuf[2 * tlinesz .. 3 * tlinesz];
    ec.idatbuf       = workbuf[$-MAXIMUM_CHUNK_SIZE .. $];
    workbuf[0..$] = 0;
    ec.z.avail_out = cast(uint) ec.idatbuf.length;
    ec.z.next_out = ec.idatbuf.ptr;

    const size_t ssize = ec.w * ec.src_chans * ec.h;

    for (size_t si; si < ssize; si += slinesz) {
        convert(ec.data[si .. si + slinesz], cline[1..$]);

        // these loops could be merged with some extra space...
        foreach (i; 1 .. filter_step+1)
            filtered[i] = cast(ubyte) (cline[i] - paeth(0, pline[i], 0));
        foreach (i; filter_step+1 .. tlinesz)
            filtered[i] = cast(ubyte)
            (cline[i] - paeth(cline[i-filter_step], pline[i], pline[i-filter_step]));
        filtered[0] = PNG_FilterType.Paeth;

        compress(ec, filtered);
        ubyte[] _swap = pline;
        pline = cline;
        cline = _swap;
    }

    while (true) {  // flush zlib
        int q = deflate(ec.z, Z_FINISH);
        if (ec.idatbuf.length - ec.z.avail_out > 0)
            flush_idat(ec);
        if (q == Z_STREAM_END) break;
        if (q == Z_OK) continue;    // not enough avail_out
        throw new ImageIOException("zlib compression error");
    }
}

void compress(ref PNG_Encoder ec, in ubyte[] line)
{
    ec.z.avail_in = cast(uint) line.length;
    ec.z.next_in = line.ptr;
    while (ec.z.avail_in) {
        int q = deflate(ec.z, Z_NO_FLUSH);
        if (q != Z_OK)
            throw new ImageIOException("zlib compression error");
        if (ec.z.avail_out == 0)
            flush_idat(ec);
    }
}

void flush_idat(ref PNG_Encoder ec)      // writes an idat chunk
{
    const uint len = cast(uint) (ec.idatbuf.length - ec.z.avail_out);
    ec.crc.put(cast(const(ubyte)[]) "IDAT");
    ec.crc.put(ec.idatbuf[0 .. len]);
    ubyte[8] meta;
    meta[0..4] = nativeToBigEndian!uint(len);
    meta[4..8] = cast(ubyte[4]) "IDAT";
    ec.stream.rawWrite(meta);
    ec.stream.rawWrite(ec.idatbuf[0 .. len]);
    ubyte[4] crc = ec.crc.finish();
    reverse(crc[]);
    ec.stream.rawWrite(crc[0..$]);
    ec.z.next_out = ec.idatbuf.ptr;
    ec.z.avail_out = cast(uint) ec.idatbuf.length;
}

package void read_png_info(Reader stream, out int w, out int h, out int chans) {
    PNG_Header hdr = read_png_header(stream);
    w = hdr.width;
    h = hdr.height;
    chans = channels(cast(PNG_ColorType) hdr.color_type);
}
