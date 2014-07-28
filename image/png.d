// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
// TODO finish paletted images
module image.png;

public import image.image;

import std.algorithm;   // min
import std.bitmanip;      // bigEndianToNative()
import std.digest.crc;
import std.zlib;

static immutable ubyte[8] png_file_header =
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

struct PNG_Header {
    int     width;
    int     height;
    ubyte   bit_depth;
    ubyte   color_type;
    ubyte   compression_method;
    ubyte   filter_method;
    ubyte   interlace_method;
}

PNG_Header read_png_header(in char[] filename) {
    auto stream = new InStream(filename);
    scope(exit) stream.close();
    return read_png_header(stream);
}

PNG_Header read_png_header(InStream stream) {
    ubyte[33] tmp = void;  // file header, IHDR len+type+data+crc
    stream.readExact(tmp, tmp.length);

    if ( tmp[0..8] != png_file_header[0..$]              ||
         tmp[8..16] != [0x0,0x0,0x0,0xd,'I','H','D','R'] ||
         crc32Of(tmp[12..29]).reverse != tmp[29..33] )
        throw new ImageException("corrupt header");

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

/*
    Returns: by req_chans:
        0 -> Keeps original format
        1 -> Gray8
        2 -> GrayAlpha8
        3 -> RGB8
        4 -> RGBA8
*/
ubyte[] read_png(in char[] filename, out int w, out int h, out int chans, int req_chans = 0) {
    if (!filename.length)
        throw new ImageException("no filename");
    auto stream = new InStream(filename);
    scope(exit) stream.close();
    return read_png(stream, w, h, chans, req_chans);
}

ubyte[] read_png(InStream stream, out int w, out int h, out int chans, int req_chans = 0) {
    if (stream is null || req_chans < 0 || 4 < req_chans)
        throw new ImageException("come on...");

    PNG_Header hdr = read_png_header(stream);

    if (hdr.width < 1 || hdr.height < 1 || int.max < cast(ulong) hdr.width * hdr.height)
        throw new ImageException("invalid dimensions");
    if (hdr.bit_depth != 8)
        throw new ImageException("only 8-bit images supported");
    if (! (hdr.color_type == PNG_ColorType.Y    ||
           hdr.color_type == PNG_ColorType.RGB  ||
           hdr.color_type == PNG_ColorType.Idx  ||
           hdr.color_type == PNG_ColorType.YA   ||
           hdr.color_type == PNG_ColorType.RGBA) )
        throw new ImageException("color type not supported");
    if (hdr.compression_method != 0 || hdr.filter_method != 0 || hdr.interlace_method != 0)
        throw new ImageException("not supported");

    PNG_Decoder dc;
    dc.stream = stream;
    dc.src_indexed = (hdr.color_type == PNG_ColorType.Idx);
    dc.src_chans = channels(cast(PNG_ColorType) hdr.color_type);
    dc.tgt_chans = (req_chans == 0) ? dc.src_chans : req_chans;
    dc.w = hdr.width;
    dc.h = hdr.height;

    w = dc.w;
    h = dc.h;
    chans = dc.tgt_chans;
    return decode_png(dc);
}

private int channels(PNG_ColorType ct) pure nothrow {
    final switch (ct) with (PNG_ColorType) {
        case Y: return 1;
        case RGB, Idx: return 3;
        case YA: return 2;
        case RGBA: return 4;
    }
}

private PNG_ColorType color_type(int channels) pure nothrow {
    switch (channels) {
        case 1: return PNG_ColorType.Y;
        case 2: return PNG_ColorType.YA;
        case 3: return PNG_ColorType.RGB;
        case 4: return PNG_ColorType.RGBA;
        default: assert(0);
    }
}

private struct PNG_Decoder {
    InStream stream;
    bool src_indexed;
    int src_chans;
    int tgt_chans;
    int w, h;

    UnCompress uc;
    CRC32 crc;
    ubyte[12] chunkmeta;  // crc | length and type
    ubyte[] read_buf;
    ubyte[] uc_buf;     // uncompressed
    ubyte[] palette;
    ubyte[] result;     // image data
}

private ubyte[] decode_png(ref PNG_Decoder dc) {
    dc.uc = new UnCompress(HeaderFormat.deflate);
    dc.read_buf = new ubyte[4096];

    enum Stage {
        IHDR_parsed,
        PLTE_parsed,
        IDAT_parsed,
        IEND_parsed,
    }

    auto stage = Stage.IHDR_parsed;
    dc.stream.readExact(dc.chunkmeta[4..$], 8);  // next chunk's len and type

    while (stage != Stage.IEND_parsed) {
        int len = bigEndianToNative!int(dc.chunkmeta[4..8]);
        if (len < 0)
            throw new ImageException("chunk too long");

        // standard allows PLTE chunk for RGB and RGBA too but we don't
        switch (cast(char[]) dc.chunkmeta[8..12]) {    // chunk type
            case "IDAT":
                if (! (stage == Stage.IHDR_parsed ||
                      (stage == Stage.PLTE_parsed && dc.src_indexed)) )
                    throw new ImageException("corrupt chunk stream");
                read_IDAT_stream(dc, len);
                stage = Stage.IDAT_parsed;
                break;
            case "PLTE":
                if (stage != Stage.IHDR_parsed)
                    throw new ImageException("corrupt chunk stream");
                int entries = len / 3;
                if (len % 3 != 0 || 256 < entries)
                    throw new ImageException("corrupt chunk");
                dc.palette = new ubyte[len];
                dc.stream.readExact(dc.palette, dc.palette.length);
                dc.crc.put(dc.chunkmeta[8..12]);  // type
                dc.crc.put(dc.palette);
                dc.stream.readExact(dc.chunkmeta, 12); // crc | len, type
                if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
                    throw new ImageException("corrupt chunk");
                stage = Stage.PLTE_parsed;
                break;
            case "IEND":
                if (stage != Stage.IDAT_parsed)
                    throw new ImageException("corrupt chunk stream");
                dc.stream.readExact(dc.chunkmeta, 4); // crc
                if (len != 0 || dc.chunkmeta[0..4] != [0xae, 0x42, 0x60, 0x82])
                    throw new ImageException("corrupt chunk");
                stage = Stage.IEND_parsed;
                break;
            case "IHDR":
                throw new ImageException("corrupt chunk stream");
            default:
                // unknown chunk, ignore but check crc
                dc.crc.put(dc.chunkmeta[8..12]);  // type
                while (0 < len) {
                    size_t bytes_read = dc.stream
                        .readBlock(dc.read_buf, min(len, dc.read_buf.length));
                    len -= bytes_read;
                    dc.crc.put(dc.read_buf[0..bytes_read]);
                }
                dc.stream.readExact(dc.chunkmeta, 12); // crc | len, type
                if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
                    throw new ImageException("corrupt chunk");
        }
    }

    return dc.result;
}

private enum PNG_ColorType : ubyte {
    Y    = 0,
    RGB  = 2,
    Idx  = 3,
    YA   = 4,
    RGBA = 6,
}

private enum PNG_FilterType : ubyte {
    None    = 0,
    Sub     = 1,
    Up      = 2,
    Average = 3,
    Paeth   = 4,
}

private void read_IDAT_stream(ref PNG_Decoder dc, int len) {
    dc.crc.put(dc.chunkmeta[8..12]);  // type

    immutable int filter_step = dc.src_chans; // pixel-wise step, in bytes
    immutable long src_sl_size = dc.w * dc.src_chans;
    immutable long tgt_sl_size = dc.w * dc.tgt_chans;

    auto cline = new ubyte[src_sl_size+1];   // current line + filter byte
    auto pline = new ubyte[src_sl_size+1];   // previous line, inited to 0
    debug(DebugPNG) assert(pline[0] == 0);

    dc.result = new ubyte[dc.w * dc.h * dc.tgt_chans];

    void function(in ubyte[] src_line, ubyte[] tgt_line) convert;
    convert = get_converter(dc.src_chans, dc.tgt_chans);

    bool metaready = false;     // chunk len, type, crc

    long tgt_si = 0;    // scanline index in target buffer
    foreach (j; 0 .. dc.h) {
        uncompress_line(dc, len, metaready, cline);
        ubyte filter_type = cline[0];

        recon(cline[1..$], pline[1..$], filter_type, filter_step);
        convert(cline[1 .. $], dc.result[tgt_si .. tgt_si + tgt_sl_size]);
        tgt_si += tgt_sl_size;

        ubyte[] _swap = pline;
        pline = cline;
        cline = _swap;
    }

    if (!metaready) {
        dc.stream.readExact(dc.chunkmeta, 12);   // crc | len & type
        if (dc.crc.finish.reverse != dc.chunkmeta[0..4])
            throw new ImageException("corrupt chunk");
    }
}

private void uncompress_line(ref PNG_Decoder dc, ref int length, ref bool metaready, ubyte[] dst) {
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
                throw new ImageException("corrupt chunk");

            length = bigEndianToNative!int(dc.chunkmeta[4..8]);
            if (dc.chunkmeta[8..12] != "IDAT") {
                // no new IDAT chunk so flush, this is the end of the IDAT stream
                metaready = true;
                dc.uc_buf = cast(ubyte[]) dc.uc.flush();
                size_t part2 = dst.length - readysize;
                if (dc.uc_buf.length < part2)
                    throw new ImageException("not enough data");
                dst[readysize .. readysize+part2] = dc.uc_buf[0 .. part2];
                dc.uc_buf = dc.uc_buf[part2 .. $];
                return;
            }
            if (length <= 0)    // empty IDAT chunk
                throw new ImageException("not enough data");
            dc.crc.put(dc.chunkmeta[8..12]);  // type
        }

        size_t bytes_read =
            dc.stream.readBlock(dc.read_buf, min(length, dc.read_buf.length));
        length -= bytes_read;
        dc.crc.put(dc.read_buf[0..bytes_read]);

        if (bytes_read <= 0)
            throw new ImageException("not enough data");

        dc.uc_buf = cast(ubyte[]) dc.uc.uncompress(dc.read_buf[0..bytes_read].dup);

        size_t part2 = min(dst.length - readysize, dc.uc_buf.length);
        dst[readysize .. readysize+part2] = dc.uc_buf[0 .. part2];
        dc.uc_buf = dc.uc_buf[part2 .. $];
        readysize += part2;
    }
}

private void recon(ubyte[] cline, in ubyte[] pline, ubyte ftype, int fstep) pure {
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
            throw new ImageException("filter type not supported");
    }
}

private ubyte paeth(ubyte a, ubyte b, ubyte c) pure nothrow {
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

// PNG encoder

void write_png(in char[] filename, size_t w, size_t h, in ubyte[] data, int tgt_chans = 0) {
    if (!filename.length)
        throw new ImageException("no filename");
    auto stream = new OutStream(filename);
    scope(exit) stream.flush_and_close();
    write_png(stream, w, h, data, tgt_chans);
}

// NOTE: *caller* has to flush the stream
void write_png(OutStream stream, size_t w, size_t h, in ubyte[] data, int tgt_chans = 0) {
    if (stream is null)
        throw new ImageException("no stream");
    if (w < 1 || h < 1 || int.max < w || int.max < h)
        throw new ImageException("invalid dimensions");
    ulong src_chans = data.length / w / h;
    if (src_chans < 1 || 4 < src_chans || tgt_chans < 0 || 4 < tgt_chans)
        throw new ImageException("invalid channel count");
    if (src_chans * w * h != data.length)
        throw new ImageException("mismatching dimensions and length");

    PNG_Encoder ec;
    ec.stream = stream;
    ec.w = cast(int) w;
    ec.h = cast(int) h;
    ec.src_chans = cast(int) src_chans;
    ec.tgt_chans = (tgt_chans) ? tgt_chans : ec.src_chans;
    ec.data = data;

    write_png(ec);
}

struct PNG_Encoder {
    OutStream stream;
    int w, h;
    int src_chans;
    int tgt_chans;
    const(ubyte)[] data;

    CRC32 crc;

    uint writelen;      // how much written of current idat data
    ubyte[] chunk_buf;  // len type data crc
    ubyte[] data_buf;   // slice of chunk_buf, for just chunk data
}

private void write_png(ref PNG_Encoder ec) {
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
    ec.stream.writeBlock(hdr);

    write_IDATs(ec);

    static immutable ubyte[12] iend =
        [0, 0, 0, 0, 'I','E','N','D', 0xae, 0x42, 0x60, 0x82];
    ec.stream.writeBlock(iend);
}

private void write_IDATs(ref PNG_Encoder ec) {
    static immutable ubyte[4] IDAT_type = ['I','D','A','T'];
    long max_idatlen = 4 * 4096;
    ec.writelen = 0;
    ec.chunk_buf = new ubyte[8 + max_idatlen + 4];
    ec.data_buf = ec.chunk_buf[8 .. 8 + max_idatlen];
    ec.chunk_buf[4 .. 8] = IDAT_type;

    int filter_step = ec.tgt_chans;     // step between pixels, in bytes
    long linesize = ec.w * ec.tgt_chans + 1; // +1 for filter type
    ubyte[] cline = new ubyte[linesize];
    ubyte[] pline = new ubyte[linesize];
    debug(DebugPNG) assert(pline[0] == 0);

    ubyte[] filtered_line = new ubyte[linesize];
    ubyte[] filtered_image;

    void function(in ubyte[] src_line, ubyte[] tgt_line) convert;
    convert = get_converter(ec.src_chans, ec.tgt_chans);

    long src_line_size = ec.w * ec.src_chans;

    long si = 0;
    foreach (j; 0 .. ec.h) {
        convert(ec.data[si .. si+src_line_size], cline[1..$]);
        si += src_line_size;

        // filter with paeth TODO clean this up
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

private void write_to_IDAT_stream(ref PNG_Encoder ec, in void[] _compressed) {
    ubyte[] compressed = cast(ubyte[]) _compressed;
    while (compressed.length) {
        long space_left = ec.data_buf.length - ec.writelen;
        long writenow_len = min(space_left, compressed.length);
        ec.data_buf[ec.writelen .. ec.writelen + writenow_len] =
            compressed[0 .. writenow_len];
        ec.writelen += writenow_len;
        compressed = compressed[writenow_len .. $];
        if (ec.writelen == ec.data_buf.length)
            ec.write_IDAT_chunk();
    }
}

// chunk: len type data crc, type is already in buf
private void write_IDAT_chunk(ref PNG_Encoder ec) {
    ec.chunk_buf[0 .. 4] = nativeToBigEndian!uint(ec.writelen);
    ec.crc.put(ec.chunk_buf[4 .. 8 + ec.writelen]);   // crc of type and data
    ec.chunk_buf[8 + ec.writelen .. 8 + ec.writelen + 4] = ec.crc.finish().reverse;
    ec.stream.writeBlock(ec.chunk_buf[0 .. 8 + ec.writelen + 4]);
    ec.writelen = 0;
}

private ImageInfo read_png_info(InStream stream) {
    PNG_Header hdr = read_png_header(stream);
    return ImageInfo(hdr.width, hdr.height);    // TODO format
}

static this() {
    register["png"] = ImageIOFuncs(&read_png, &write_png, &read_png_info);
}
